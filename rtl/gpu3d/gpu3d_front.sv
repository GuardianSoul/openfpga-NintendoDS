// Span setup for gpu3d_raster: input stage (polygon stream -> two banks),
// one edge unit (gpu3d_edge, left then right slope) and the span stage
// (EdgeParams, fill rules, swap, X reciprocal, linear-stepper divisions),
// overlapped through double buffers. Also sequences the lines (clears of
// lines 0-2, end of line, waiting on the final pass).
module gpu3d_front #(
    parameter bit AREA = 0,           // 1: one divider for both clients (see gpu3d_raster)
    parameter bit RECIP = 1,          // 1: linear spans carry ceil(2^37/xdiff) (see gpu3d_raster)
    parameter bit DS_TOON = 1,        // the toon index from red without the fill (see gpu3d_raster)
    parameter bit DS_LIN17 = 1,       // linear interpolation by a 17-bit factor (see gpu3d_raster)
    parameter bit DS_LINZ = 1,        // Z-buffer Z by the same factor (see gpu3d_raster)
    parameter bit DS_YPERSP = 1,      // the DS's Y factor and linear test (see gpu3d_raster)
    parameter bit DS_XPERSP16 = 1,    // the X factor's w >> 8 for large w (see gpu3d_raster)
    parameter bit DS_AACOV = 1,       // the DS's X-major AA coverage start (see gpu3d_raster)
    parameter bit DS_AAYCOV = 1,      // the DS's Y-major full-coverage test (see gpu3d_raster)
    parameter bit DS_TEXRND = 1,      // the DS's texcoord rounding along Y (see gpu3d_raster)
    parameter bit LROM2 = 1,          // one dual-port ceil(2^37/n) table for the span and the edge
    parameter bit ER_M10K = 0,        // 1: the left-slope ring u_er0 in M10K (5 blocks and 36 flops for its 13 MLAB LABs); 0: MLAB
    parameter bit HDR_M10K = 1,       // 1: the header ring u_hdr in M10K (2 blocks in the card build for its 4-5 MLAB LABs); 0: MLAB
    parameter bit AVM_M10K = 1,       // 1: AVM's u_er0 (107 bits) in M10K (3 blocks for its 5 MLAB LABs); 0: MLAB
    // AVS_M10K: AVM's u_avl, u_avr and u_eps (4 MLAB LABs in #886) in M10K, registered reads at the
    // entry the reader takes next: 2 u_avl and u_avr in one block (halves, byte enables) and u_eps in
    // one (2 blocks); 1 three blocks; 0 MLAB
    parameter int AVS_M10K = 2,
    // VYS_M10K: the vertex y table u_vys (1 MLAB LAB in #886) in an M10K read at the entry and bank the
    // edge unit's walk reads next (gpu3d_edge vys_ra_n, vb_w after a_rel); 0: MLAB
    parameter bit VYS_M10K = 1,
    parameter bit FEAT_TOON = 1,      // 0: toon/highlight polygons draw as modulate (see gpu3d_raster)
    parameter bit FEAT_SHADOW = 1,    // 0: shadow-mask and shadow polygons are skipped (see gpu3d_raster)
    parameter bit VREG = 0,           // gpu3d_edge VREG
    // LOV (gpu3d_raster): the next line starts once this one's spans are
    // handed over, while its pixels drain (lines_done follows the drain, by
    // the parity of the lines the pipeline still holds: pipe_lp)
    parameter bit LOV = 0,
    // EDIV4: the edge unit's perspective-factor divider four quotient bits a
    // clock (three clocks for its 10 bits, two radix-2 steps more a clock)
    parameter bit EDIV4 = 0,
    // EDGE2: a second edge unit for the right slope, so a polygon's two
    // edges are set up at once (its own vertex RAM, divider and tables)
    parameter bit EDGE2 = 0,
    // EP2: the edge unit as two stages (gpu3d_edge STAGE 1 and 2): an edge's
    // walk, slope and perspective division while the edge before it has its
    // Z, factor, items and coverage. The bank goes back once the right slope
    // is handed over (stage 2 holds what it needs)
    parameter bit EP2 = 0,
    // FDB (EP2, not PP2): the input stage loads the next polygon while stage 1
    // walks this one, as PP2 does: the bank goes back when stage 1 takes the
    // polygon (its header latched in q_*), the vertex RAMs get four banks (the
    // input stage's, stage 1's and stage 2's) and the header ring eight entries.
    // Stage 2 then takes the next polygon before the span stage takes the last
    // one: finished slopes queue as with PP2 (up to three polygons, the left
    // records in u_er0, the right ones in the rr ring)
    parameter bit FDB = 0,
    // ARC (EP2): stage 1's kept results (u_ares) read without an output
    // register (see g_arc): 79 flops fewer, the same data where it is used
    parameter bit ARC = 1,
    // TOONR (see gpu3d_raster): a toon polygon's fill-less red is the edge
    // units' red (item 1); no rt, and no sixth attribute in the span setup
    parameter bit TOONR = 0,
    // YNW (gpu3d_edge): the Y perspective numerator in 33 bits (no wrap); the edge dividers take a 33-bit numerator
    parameter bit YNW = 0,
    parameter bit YP16 = 0            // gpu3d_edge YP16: Z-buffer Y factor w >> 8 at max(w) >= 0x8000
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [15:0]  dispcnt,
    input  logic         fill_all,     // DISP3DCNT bit 4 or 5 as the game wrote them, with the feature off or on: edges filled
    input  logic [4:0]   alpharef,
    input  logic         frame_start,
    // polygon stream
    output logic         ps_line_req,
    output logic [7:0]   ps_line_y,
    input  logic         ps_valid,
    output logic         ps_ready,
    input  logic [1:0]   ps_type,
    input  logic [127:0] ps_data,
    // span descriptors to the pixel pipeline
    output gpu3d_pkg::span_t fe_desc,
    output logic         fe_wr,
    input  logic         nx_full,      // the pipeline's next-span register is full
    input  logic         pipe_idle,
    input  logic [1:0]   pipe_lp,      // LOV: the pipeline holds a span or pixel of a line of this parity
    // line sequencing
    output logic [7:0]   y,
    output logic [1:0]   y3,           // y mod 3 (gpu3d_raster TR3), counted with y
    output logic [8:0]   clr_x,
    output logic         clr_we,       // clear line y (lines 0-2) at clr_x
    output logic         st_clr,       // clear the stencil at clr_x
    output logic [7:0]   lines_done,
    output logic [8:0]   lines_go,     // lines started this frame (their line buffers cleared)
    output logic         frame_go,     // frame_start accepted
    input  logic [7:0]   fp_done,
    input  logic         fp_run,
    output logic         busy,
    output logic [2:0]   dbg_phase,
    output logic         dbg_span
);
    typedef gpu3d_pkg::span_t span_t;
`ifndef SYNTHESIS
    initial if (YNW && (AREA || (DS_LIN17 && !DS_LINZ))) $error("gpu3d_front: YNW needs the separate 10-bit edge divider (AREA 0, DS_LINZ)");
`endif

    // ==================================================================
    // span setup: input stage -> two edge units -> span stage -> pipeline
    // ==================================================================
    // Each hand-over is double-buffered, so the input stage reads polygon
    // n+2 while the edge units set up polygon n+1 and the span stage
    // finishes polygon n:
    //   input stage  polygon stream -> bank (header, vertex records),
    //                coverage test, shadow stencil clears
    //   edge units   gpu3d_edge x2: both slopes at y and W, Z, colour and
    //                texture coordinates along them (about 24 cycles)
    //   span stage   EdgeParams, fill rules, swap, X reciprocal, linear
    //                stepper divisions -> span descriptor
    typedef enum logic [3:0] {
        S_IDLE, S_CLEAR, S_LREQ, S_HDR, S_VTX, S_PCHK, S_STCLR, S_LDONE, S_LWAIT
    } state_t;
    state_t st;

    // frame / line

    // polygon header being read
    logic        p_mask;              // IsShadowMask, from the header
    logic        p_toon;              // toon/highlight polygon (DS_TOON)
    logic        p_shd;               // shadow or shadow-mask polygon (mode 3)
    logic [3:0]  p_nv, p_vtop, p_vbot, p_dvl, p_dvr;
    logic [7:0]  p_ytop, p_ybot;
    logic        p_facing, p_wbuf;
    logic [3:0]  vcnt;
    // the x of vertices 0, 1 and the last one (n-1): S_PCHK's single-line
    // case reads no other (the vertices arrive in order, 1 <= nv <= 10)
    logic [8:0]  vx0, vx1, vxl;
    logic        prev_mask;           // PrevIsShadowMask

    // PP2 (EDGE2 with EP2): two EP2 pipelines, the left slope's (u_edge, u_edgeb)
    // and the right slope's (u_edge2a, u_edge2b), a polygon's two slopes at once;
    // E2S: EDGE2's two whole units (no EP2)
    localparam bit PP2 = EDGE2 && EP2;
    localparam bit E2S = EDGE2 && !EP2;
    // EPF (with PP2): the span stage's X-major AA coverage starts of the two
    // sides on two dividers at once, four quotient bits a clock each (the left
    // one's divide no longer waits before the right side's setup)
    localparam bit EPF = PP2;
    // QB: the stage 1s take the polygon from the bank (a_tk), so it loads the next (PP2, or FDB with EP2)
    localparam bit QB = PP2 || (EP2 && FDB);
    // QR: finished slopes queue for the span stage (lcn, rcn; the rr ring) instead of waiting in stage 2
    localparam bit QR = QB;
`ifndef SYNTHESIS
    initial if (FDB && (!EP2 || PP2 || ER_M10K)) $error("gpu3d_front: FDB needs EP2 without PP2, and AVM (ER_M10K 0)");
`endif
    // ---------------- banks (input stage -> edge units) ----------------
    // One bank: the input stage reads the next polygon only once the edge
    // unit has finished with this one (p_* are the bank's header).
    logic        bk_full;
`ifdef G3D_ABL_FDB
    logic [1:0]  bk_n;               // (ablation) polygons loaded, not yet given back
`endif
    logic        bk_commit;           // input stage: the bank is complete
    logic [3:0]  vys_ra;              // vertex y table, read by the edge unit
    logic [7:0]  vys_q;
    wire              vm_we    = (st == S_VTX) && ps_valid && ps_type == 2'd1;
    // EP2: the input stage writes the vertex RAMs' bank vb_w, the other one
    // after each polygon goes back (a_rel), so stage 2 may still read the last
    // polygon's vertices while the next one loads
    // PP2: four banks; the input stage loads the next polygon into bank vb_w
    // while the stage 1s walk bank vb_s (handed over at a_go), and stage 2 may
    // still read the one before (vertex RAM addresses {bank, vertex})
    // FDB: the same with one pipeline (stage 1 takes the polygon at its left slope's start)
    localparam int VBW = QB ? 2 : 1;
    logic [VBW-1:0]   vb_w, vb_s;
    logic        a_go;                // PP2: both stage 1s start the polygon in the bank
    logic        a_tk;                // QB: the stage 1s take the polygon from the bank (PP2: a_go)
    wire  [VBW-1:0]   vb_e  = QB ? (a_tk ? vb_w : vb_s) : vb_w;   // the stage 1s' bank (this clock)
    logic [3:0]  vys_ra_n;
    logic        a_rel;
    generate if (VYS_M10K) begin : g_vysm
        wire [VBW-1:0] vb_wn = (rst || !EP2) ? '0 : QB ? vb_e : a_rel ? VBW'(!vb_w) : vb_w;   // the walk's bank after this clock
        gpu3d_ram #(.W(8), .AW(VBW + 4), .STYLE("M10K, no_rw_check")) u_vys (
            .clk, .we(vm_we), .waddr({vb_w, vcnt}), .wdata(ps_data[16:9]), .raddr({vb_wn, vys_ra_n}), .rdata(vys_q));
`ifndef SYNTHESIS
        // synthesis translate_off
        logic [7:0] vys_s;
        gpu3d_lram #(.W(8), .AW(VBW + 4)) s_vys (
            .clk, .we(vm_we), .waddr({vb_w, vcnt}), .wdata(ps_data[16:9]), .raddr({QB ? vb_s : vb_w, vys_ra}), .rdata(vys_s));
        always_ff @(posedge clk)
            if (!rst && int'(u_edge.xs) == 1 && vys_q != vys_s)   // (1: X_WALK, the walk's read)
                $error("gpu3d_front VYS_M10K: {%0d, %0d}: M10K %02x, MLAB %02x", vb_w, vys_ra, vys_q, vys_s);
        // synthesis translate_on
`endif
    end else begin : g_vys
        gpu3d_lram #(.W(8), .AW(VBW + 4)) u_vys (
            .clk, .we(vm_we), .waddr({vb_w, vcnt}), .wdata(ps_data[16:9]), .raddr({QB ? vb_s : vb_w, vys_ra}), .rdata(vys_q));
    end endgenerate
    wire  [VBW+3:0]   vm_waddr = {vb_w, vcnt};
    // QB: the stage 1s' polygon header, latched at a_tk (p_* then load the next)
    logic [3:0]  q_nv, q_vtop, q_vbot, q_dvl, q_dvr;
    logic [7:0]  q_ytop, q_ybot;
    logic        q_facing, q_wbuf, q_toon;
    always_ff @(posedge clk)
        if (a_tk) begin
            q_nv <= p_nv; q_vtop <= p_vtop; q_vbot <= p_vbot; q_dvl <= p_dvl; q_dvr <= p_dvr;
            q_ytop <= p_ytop; q_ybot <= p_ybot; q_facing <= p_facing; q_wbuf <= p_wbuf; q_toon <= p_toon;
        end
    wire [3:0]  k_nv   = (QB && !a_tk) ? q_nv   : p_nv;
    wire [3:0]  k_vtop = (QB && !a_tk) ? q_vtop : p_vtop;
    wire [3:0]  k_vbot = (QB && !a_tk) ? q_vbot : p_vbot;
    wire [3:0]  k_dvl  = (QB && !a_tk) ? q_dvl  : p_dvl;
    wire [3:0]  k_dvr  = (QB && !a_tk) ? q_dvr  : p_dvr;
    wire        k_dummy = (QB && !a_tk) ? q_ytop == q_ybot : p_ytop == p_ybot;
    wire        k_facing = (QB && !a_tk) ? q_facing : p_facing;
    wire        k_wbuf  = (QB && !a_tk) ? q_wbuf : p_wbuf;
    wire        k_toon  = (QB && !a_tk) ? q_toon : p_toon;

    // ---------------- edge units ----------------
    logic        e_go, e_run, e_wait, e_fin, e_res, e_take;
    // polygon headers: a 4-entry ring (M10K) written as the input stage loads
    // a header (entry h_w, which moves on when the edge units finish the
    // polygon), taken by the edge units (h_e) and then the span stage (h_s),
    // which reads it. Live entries: the span stage's, the edge units' and
    // the one being loaded, so the write never lands on one in use.
    localparam int HRW = 95;          // {attr, texparam, texpal, ytop, ybot, facing, wbuf}
    // PP2: 8 header entries (the span stage's, up to 3 ready, the pipelines' and the one loading);
    // FDB: the span stage's, the ready one, stage 2's, stage 1's and the one loading
    localparam int HAW = QB ? 3 : 2;
    logic [HAW-1:0] h_w, h_e, h_s;
    logic [HRW-1:0] hr_q;

    // one unit, run twice per polygon: the left slope's results are kept
    // in the u_er0 ring, the right slope's are the unit's own outputs
    logic        e_side, e_start, eu_b;
    logic [1:0]  a_ph;                // EP2: stage 1's polygon: 0 none, 1 left, 2 left handed over, 3 right
    wire         e_start_side = PP2 ? 1'b0 : EP2 ? (a_ph == 2'd2 || a_ph == 2'd1) : E2S ? 1'b0 : !e_go;   // side of the run being started (EDGE2: unit 0 is the left)
    localparam int EW = 432;          // the stage 1 -> 2 handover (gpu3d_edge HW)
    logic        a_ho_v;
    logic        a_pf_v;
    logic [78:0] a_res;               // EP2: stage 1's {inc, neg, dx, xval, vbx} of the edge it hands over
    logic [VBW+7:0] a_pf_idx;
    logic        a_ho_rdy;
    logic [EW-1:0] a_ho;
    logic [26:0] u_inc;  logic u_neg, u_xmaj;  logic [31:0] u_dx;
    logic [9:0]  u_xval, u_xlen, u_xcovinc;  logic [7:0] u_ylen;  logic [8:0] u_vbx;
    logic [15:0] u_w;  logic [23:0] u_z;  logic [4:0][16:0] u_av;  logic [8:0] u_rt;
    logic [7:0]  e_lr_addr;  logic [37:0] e_lr_q;   // LROM2: the edge's port of the shared table
    logic [8:0]  e_rom_a;    logic [26:0] e_rom_q;  // LROM2: the edge's port of the shared (1<<26)/n table
    gpu3d_edge #(.DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ), .DS_YPERSP(DS_YPERSP), .DS_TEXRND(DS_TEXRND),
                 .EXT_LROM(LROM2), .EXT_ROM(LROM2), .VREG(VREG), .STAGE(EP2 ? 1 : 0), .WL0(EP2 && FDB && !PP2), .HW(EW), .TOONR(TOONR), .YNW(YNW), .YP16(YP16), .BKW(VBW)) u_edge (
        .clk, .rst, .lr_addr(e_lr_addr), .lr_qx(e_lr_q), .rom_ao(e_rom_a), .rom_qx(e_rom_q),
        .vm_we, .vm_waddr, .vm_wdata(ps_data[115:0]),
        .start(e_start), .side(e_start_side), .bank(vb_e), .y, .wbuf(k_wbuf), .aa(dispcnt[4]),
        .facing(k_facing), .dummy(k_dummy), .toon(DS_TOON && k_toon),
        .nv(k_nv), .vtop(k_vtop), .vbot(k_vbot),
        .dv((e_start_side && !E2S) ? k_dvr : k_dvl),
        .dv_start(ea_dv_start), .dv_num(ea_dv_num), .dv_den(ea_dv_den), .dv_req(ea_dv_req), .dv_hold(ea_dv_hold),
        .dv_mode(ea_dv_mode), .dv_gnt(e_dv_gnt), .dv_busy(e_dv_busy), .dv_q(e_dv_q), .vys_ra, .vys_ra_n, .vys_q,
        .busy(eu_b), .fin(), .ho_valid(a_ho_v), .ho_ready(a_ho_rdy), .ho(a_ho), .hi_valid(1'b0), .hi('0),
        .pfo_v(a_pf_v), .pfo_idx(a_pf_idx), .pfi_v(1'b0), .pfi_idx('0), .ho_res(a_res), .it_we(), .it_k(), .it_v(),
        .inc(u_inc), .neg(u_neg), .xmaj(u_xmaj), .dx(u_dx),
        .xval(u_xval), .xlen(u_xlen), .xcovinc(u_xcovinc),
        .ylen(u_ylen), .vbx(u_vbx), .w(u_w), .z(u_z), .av(u_av), .rt(u_rt));

    // EDGE2: the right slope's unit (u_edge1, side 1), started with unit 0
    logic        eu_b1;
    logic [26:0] u1_inc;  logic u1_neg, u1_xmaj;  logic [31:0] u1_dx;
    logic [9:0]  u1_xval, u1_xlen, u1_xcovinc;  logic [7:0] u1_ylen;  logic [8:0] u1_vbx;
    logic [15:0] u1_w;  logic [23:0] u1_z;  logic [4:0][16:0] u1_av;  logic [8:0] u1_rt;
    generate if (E2S) begin : g_edge2
        logic [3:0]  vys1_ra;
        logic [7:0]  vys1_q;
        gpu3d_lram #(.W(8), .AW(4)) u_vys1 (
            .clk, .we(vm_we), .waddr(vcnt), .wdata(ps_data[16:9]), .raddr(vys1_ra), .rdata(vys1_q));
        logic        d1_start, d1_busy, d1_done, d1_req, d1_hold, d1_mode;
        logic [31+YNW:0] d1_num;
        logic [24:0] d1_den, d1_r;
        localparam int EQB1 = EDIV4 ? 12 : 10;
        logic [EQB1-1:0] d1_q;
        gpu3d_div4 #(.NW(32 + YNW), .DW(25), .QB(EQB1), .SPC(EDIV4 ? 4 : 2)) u_div1 (
            .clk, .rst, .start(d1_start), .num(d1_num), .den(d1_den),
            .busy(d1_busy), .done(d1_done), .q(d1_q), .r(d1_r));
        gpu3d_edge #(.DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ), .DS_YPERSP(DS_YPERSP), .DS_TEXRND(DS_TEXRND),
                     .EXT_LROM(1'b0), .EXT_ROM(1'b0), .VREG(VREG), .TOONR(TOONR), .YNW(YNW), .YP16(YP16)) u_edge1 (
            .clk, .rst, .lr_addr(), .lr_qx('0), .rom_ao(), .rom_qx('0),
            .vm_we, .vm_waddr, .vm_wdata(ps_data[115:0]),
            .start(e_go), .side(1'b1), .bank(1'b0), .y, .wbuf(p_wbuf), .aa(dispcnt[4]),
            .facing(p_facing), .dummy(p_ytop == p_ybot), .toon(DS_TOON && p_toon),
            .nv(p_nv), .vtop(p_vtop), .vbot(p_vbot), .dv(p_dvr),
            .dv_start(d1_start), .dv_num(d1_num), .dv_den(d1_den), .dv_req(d1_req), .dv_hold(d1_hold),
            .dv_mode(d1_mode), .dv_gnt(1'b1), .dv_busy(d1_busy), .dv_q(18'(d1_q[9:0])), .vys_ra(vys1_ra), .vys_ra_n(), .vys_q(vys1_q),
            .busy(eu_b1), .fin(), .ho_valid(), .ho_ready(1'b0), .ho(), .hi_valid(1'b0), .hi('0),
            .pfo_v(), .pfo_idx(), .pfi_v(1'b0), .pfi_idx('0), .ho_res(), .it_we(), .it_k(), .it_v(),
            .inc(u1_inc), .neg(u1_neg), .xmaj(u1_xmaj), .dx(u1_dx),
            .xval(u1_xval), .xlen(u1_xlen), .xcovinc(u1_xcovinc),
            .ylen(u1_ylen), .vbx(u1_vbx), .w(u1_w), .z(u1_z), .av(u1_av), .rt(u1_rt));
`ifndef SYNTHESIS
        initial if (AREA || (DS_LIN17 && !DS_LINZ)) $error("gpu3d_front: EDGE2 needs separate dividers and DS_LINZ (10-bit edge quotients)");
`endif
    end else begin : g_edge1
        assign eu_b1 = 1'b0;
        assign {u1_inc, u1_neg, u1_xmaj, u1_dx, u1_xval, u1_xlen, u1_xcovinc, u1_ylen, u1_vbx, u1_w, u1_z, u1_av, u1_rt} = '0;
    end endgenerate

    // EP2: stage 2 (u_edgeb) and the divider shared by the two stages (stage 1
    // starts a division only when stage 2 is free: ho_ready)
    logic        ea_dv_start, ea_dv_req, ea_dv_hold, ea_dv_mode;
    logic [31+YNW:0] ea_dv_num;
    logic [24:0] ea_dv_den;
    logic        eb_dv_start, eb_dv_req, eb_dv_hold, eb_dv_mode;
    logic [31+YNW:0] eb_dv_num;
    logic [24:0] eb_dv_den;
    logic        eu_bb;
    logic        eu_bf;               // stage 2's edge ends this clock
    logic [26:0] ub_inc;  logic ub_neg, ub_xmaj;  logic [31:0] ub_dx;
    logic [9:0]  ub_xval, ub_xlen, ub_xcovinc;  logic [7:0] ub_ylen;  logic [8:0] ub_vbx;
    logic [15:0] ub_w;  logic [23:0] ub_z;  logic [4:0][16:0] ub_av;  logic [8:0] ub_rt;
    logic        b_it_we;  logic [3:0] b_it_k;  logic [16:0] b_it_v;   // stage 2's item writes
    generate if (EP2) begin : g_ep2
        gpu3d_edge #(.DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ), .DS_YPERSP(DS_YPERSP), .DS_TEXRND(DS_TEXRND),
                     .EXT_LROM(1'b1), .EXT_ROM(1'b1), .VREG(VREG), .STAGE(2), .PFE(FDB && !PP2), .HW(EW), .TOONR(TOONR), .YNW(YNW), .YP16(YP16), .BKW(VBW)) u_edgeb (
            .clk, .rst, .lr_addr(), .lr_qx('0), .rom_ao(), .rom_qx('0),
            .vm_we, .vm_waddr, .vm_wdata(ps_data[115:0]),
            .start(1'b0), .side(1'b0), .bank(1'b0), .y, .wbuf(1'b0), .aa(1'b0),
            .facing(1'b0), .dummy(1'b0), .toon(1'b0), .nv('0), .vtop('0), .vbot('0), .dv('0),
            .dv_start(eb_dv_start), .dv_num(eb_dv_num), .dv_den(eb_dv_den), .dv_req(eb_dv_req), .dv_hold(eb_dv_hold),
            .dv_mode(eb_dv_mode), .dv_gnt(e_dv_gnt), .dv_busy(e_dv_busy), .dv_q(e_dv_q), .vys_ra(), .vys_ra_n(), .vys_q('0),
            .busy(eu_bb), .fin(eu_bf), .ho_valid(), .ho_ready(1'b0), .ho(), .hi_valid(a_ho_v), .hi(a_ho),
            .pfo_v(), .pfo_idx(), .pfi_v(a_pf_v), .pfi_idx(a_pf_idx), .ho_res(), .it_we(b_it_we), .it_k(b_it_k), .it_v(b_it_v),
            .inc(ub_inc), .neg(ub_neg), .xmaj(ub_xmaj), .dx(ub_dx),
            .xval(ub_xval), .xlen(ub_xlen), .xcovinc(ub_xcovinc),
            .ylen(ub_ylen), .vbx(ub_vbx), .w(ub_w), .z(ub_z), .av(ub_av), .rt(ub_rt));
`ifndef SYNTHESIS
        initial if (AREA) $error("gpu3d_front: EP2 needs separate dividers");
`endif
    end else begin : g_ep1
        assign {eb_dv_start, eb_dv_req, eb_dv_hold, eb_dv_mode, eb_dv_num, eb_dv_den, eu_bb, eu_bf} = '0;
        assign {ub_inc, ub_neg, ub_xmaj, ub_dx, ub_xval, ub_xlen, ub_xcovinc, ub_ylen, ub_vbx, ub_w, ub_z, ub_av, ub_rt} = '0;
        assign {b_it_we, b_it_k, b_it_v} = '0;
    end endgenerate
    // PP2: the right slope's pipeline (stage 1 u_edge2a, stage 2 u_edge2b), its
    // own divider (shared by its two stages as u_edge and u_edgeb share theirs),
    // vertex RAM copies (in the units) and vertex y table; tables from its own ROMs
    logic        a2_ho_v, a2_ho_rdy, a2_pf_v, eu_b2, eu_bb2;
    logic [EW-1:0] a2_ho;
    logic [78:0] a2_res;
    logic [VBW+7:0] a2_pf_idx;
    logic [26:0] ub2_inc;  logic ub2_neg, ub2_xmaj;  logic [31:0] ub2_dx;
    logic [9:0]  ub2_xval, ub2_xlen, ub2_xcovinc;  logic [7:0] ub2_ylen;  logic [8:0] ub2_vbx;
    logic [15:0] ub2_w;  logic [23:0] ub2_z;  logic [4:0][16:0] ub2_av;  logic [8:0] ub2_rt;
    logic        b2_it_we;  logic [3:0] b2_it_k;  logic [16:0] b2_it_v;
    generate if (PP2) begin : g_pp2
        logic [3:0]  vys2_ra;
        logic [7:0]  vys2_q;
        gpu3d_lram #(.W(8), .AW(VBW + 4)) u_vys2 (
            .clk, .we(vm_we), .waddr({vb_w, vcnt}), .wdata(ps_data[16:9]), .raddr({vb_s, vys2_ra}), .rdata(vys2_q));
        logic        d2a_start, d2a_req, d2a_hold, d2a_mode, d2b_start, d2b_req, d2b_hold, d2b_mode, d2_busy, d2_done;
        logic [31+YNW:0] d2a_num, d2b_num;
        logic [24:0] d2a_den, d2b_den, d2_r;
        localparam int EQB2 = EDIV4 ? 12 : 10;
        logic [EQB2-1:0] d2_q;
        gpu3d_div4 #(.NW(32 + YNW), .DW(25), .QB(EQB2), .SPC(EDIV4 ? 4 : 2)) u_div2 (
            .clk, .rst, .start(d2a_start || d2b_start), .num(d2a_start ? d2a_num : d2b_num),
            .den(d2a_start ? d2a_den : d2b_den), .busy(d2_busy), .done(d2_done), .q(d2_q), .r(d2_r));
        gpu3d_edge #(.DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ), .DS_YPERSP(DS_YPERSP), .DS_TEXRND(DS_TEXRND),
                     .EXT_LROM(1'b0), .EXT_ROM(1'b0), .VREG(VREG), .STAGE(1), .HW(EW), .TOONR(TOONR), .YNW(YNW), .YP16(YP16), .BKW(VBW)) u_edge2a (
            .clk, .rst, .lr_addr(), .lr_qx('0), .rom_ao(), .rom_qx('0),
            .vm_we, .vm_waddr, .vm_wdata(ps_data[115:0]),
            .start(a_go), .side(1'b1), .bank(vb_e), .y, .wbuf(k_wbuf), .aa(dispcnt[4]),
            .facing(k_facing), .dummy(k_dummy), .toon(DS_TOON && k_toon),
            .nv(k_nv), .vtop(k_vtop), .vbot(k_vbot), .dv(k_dvr),
            .dv_start(d2a_start), .dv_num(d2a_num), .dv_den(d2a_den), .dv_req(d2a_req), .dv_hold(d2a_hold),
            .dv_mode(d2a_mode), .dv_gnt(1'b1), .dv_busy(d2_busy), .dv_q(18'(d2_q[9:0])), .vys_ra(vys2_ra), .vys_ra_n(), .vys_q(vys2_q),
            .busy(eu_b2), .fin(), .ho_valid(a2_ho_v), .ho_ready(a2_ho_rdy), .ho(a2_ho), .hi_valid(1'b0), .hi('0),
            .pfo_v(a2_pf_v), .pfo_idx(a2_pf_idx), .pfi_v(1'b0), .pfi_idx('0), .ho_res(a2_res), .it_we(), .it_k(), .it_v(),
            .inc(), .neg(), .xmaj(), .dx(), .xval(), .xlen(), .xcovinc(), .ylen(), .vbx(), .w(), .z(), .av(), .rt());
        gpu3d_edge #(.DS_LIN17(DS_LIN17), .DS_LINZ(DS_LINZ), .DS_YPERSP(DS_YPERSP), .DS_TEXRND(DS_TEXRND),
                     .EXT_LROM(1'b1), .EXT_ROM(1'b1), .VREG(VREG), .STAGE(2), .HW(EW), .TOONR(TOONR), .YNW(YNW), .YP16(YP16), .BKW(VBW)) u_edge2b (
            .clk, .rst, .lr_addr(), .lr_qx('0), .rom_ao(), .rom_qx('0),
            .vm_we, .vm_waddr, .vm_wdata(ps_data[115:0]),
            .start(1'b0), .side(1'b0), .bank(1'b0), .y, .wbuf(1'b0), .aa(1'b0),
            .facing(1'b0), .dummy(1'b0), .toon(1'b0), .nv('0), .vtop('0), .vbot('0), .dv('0),
            .dv_start(d2b_start), .dv_num(d2b_num), .dv_den(d2b_den), .dv_req(d2b_req), .dv_hold(d2b_hold),
            .dv_mode(d2b_mode), .dv_gnt(1'b1), .dv_busy(d2_busy), .dv_q(18'(d2_q[9:0])), .vys_ra(), .vys_ra_n(), .vys_q('0),
            .busy(eu_bb2), .fin(), .ho_valid(), .ho_ready(1'b0), .ho(), .hi_valid(a2_ho_v), .hi(a2_ho),
            .pfo_v(), .pfo_idx(), .pfi_v(a2_pf_v), .pfi_idx(a2_pf_idx), .ho_res(), .it_we(b2_it_we), .it_k(b2_it_k), .it_v(b2_it_v),
            .inc(ub2_inc), .neg(ub2_neg), .xmaj(ub2_xmaj), .dx(ub2_dx),
            .xval(ub2_xval), .xlen(ub2_xlen), .xcovinc(ub2_xcovinc),
            .ylen(ub2_ylen), .vbx(ub2_vbx), .w(ub2_w), .z(ub2_z), .av(ub2_av), .rt(ub2_rt));
`ifndef SYNTHESIS
        initial if (!DS_LINZ || ER_M10K) $error("gpu3d_front: PP2 needs DS_LINZ (10-bit edge quotients) and AVM (ER_M10K 0)");
`endif
    end else begin : g_pp1
        assign {a2_ho_v, a2_pf_v, eu_b2, eu_bb2, a2_ho, a2_res, a2_pf_idx} = '0;
        assign {ub2_inc, ub2_neg, ub2_xmaj, ub2_dx, ub2_xval, ub2_xlen, ub2_xcovinc, ub2_ylen, ub2_vbx, ub2_w, ub2_z, ub2_av, ub2_rt} = '0;
        assign {b2_it_we, b2_it_k, b2_it_v} = '0;
    end endgenerate
    assign e_dv_start = ea_dv_start || eb_dv_start;
    assign e_dv_num   = ea_dv_start ? ea_dv_num : eb_dv_num;
    assign e_dv_den   = ea_dv_start ? ea_dv_den : eb_dv_den;
    assign e_dv_mode  = ea_dv_start ? ea_dv_mode : eb_dv_mode;
    assign e_dv_req   = ea_dv_req || eb_dv_req;
    assign e_dv_hold  = ea_dv_hold || eb_dv_hold;
    // EP2: stage 1's {inc, neg, dx, xval, vbx} of each edge, kept from the
    // handover (a left and a right slope at most wait: an M10K, entry = side)
    // and read for stage 2's edge (b_side, set long before it finishes)
    logic [78:0] ar_q;
    logic        b_side;
    logic [78:0] ar2;                 // PP2: the right pipeline's kept stage 1 results
    generate if (PP2) begin : g_arp
        // PP2: each pipeline's own (its stage 2 takes the next slope only once
        // the last one's results are used: they hold until then)
        logic [78:0] ar1;
        always_ff @(posedge clk) begin
            if (a_ho_v) ar1 <= a_res;
            if (a2_ho_v) ar2 <= a2_res;
        end
        assign ar_q = ar1;
    end else if (EP2 && ARC) begin : g_arc
        // ARC: the two entries read combinationally at the entry b_side had a
        // clock ago (the registered read's address), without its 79-bit output
        // register. The same data whenever it is used (the ring write at
        // b_done, the take): no handover writes that entry the clock before
        // (checked against the registered read below)
        (* ramstyle = "logic" *) logic [78:0] ar_m [0:1];   // flops: Quartus made it 2 M10K (#1016)
        logic        b_side_q;
        always_ff @(posedge clk) begin
            if (a_ho_v) ar_m[a_ph == 2'd3] <= a_res;
            b_side_q <= b_side;
        end
        assign ar_q = ar_m[b_side_q];
`ifndef SYNTHESIS
        // synthesis translate_off
        logic [78:0] ar_ref;
        gpu3d_ram #(.W(79), .AW(1)) u_ares_ref (
            .clk, .we(a_ho_v), .waddr(a_ph == 2'd3), .wdata(a_res), .raddr(b_side), .rdata(ar_ref));
        always_ff @(posedge clk)
            if (!rst && (er_we || (QR && b_done && b_side) || (!QR && ss == SS_IDLE && e_res && !e_take)) && ar_q !== ar_ref)
                $error("gpu3d_front: ARC read differs from the registered read");
        // synthesis translate_on
`endif
    end else if (EP2) begin : g_ares
        gpu3d_ram #(.W(79), .AW(1), .STYLE("MLAB")) u_ares (
            .clk, .we(a_ho_v), .waddr(a_ph == 2'd3), .wdata(a_res), .raddr(b_side), .rdata(ar_q));
    end else begin : g_nares
        assign ar_q = '0;
    end endgenerate
    // the results the ring and the take read (EP2: stage 2's, and the kept ones)
    wire [26:0] r_inc = EP2 ? ar_q[78:52] : u_inc;   wire r_neg = EP2 ? ar_q[51] : u_neg;   wire r_xmaj = EP2 ? ub_xmaj : u_xmaj;
    wire [31:0] r_dx = EP2 ? ar_q[50:19] : u_dx;      wire [9:0] r_xval = EP2 ? ar_q[18:9] : u_xval;
    wire [9:0]  r_xlen = EP2 ? ub_xlen : u_xlen; wire [9:0] r_xcovinc = EP2 ? ub_xcovinc : u_xcovinc;
    wire [7:0]  r_ylen = EP2 ? ub_ylen : u_ylen; wire [8:0] r_vbx = EP2 ? ar_q[8:0] : u_vbx;
    wire [15:0] r_w = EP2 ? ub_w : u_w;          wire [23:0] r_z = EP2 ? ub_z : u_z;
    wire [4:0][16:0] r_av = EP2 ? ub_av : u_av;  wire [8:0] r_rt = TOONR ? 9'd0 : EP2 ? ub_rt : u_rt;
    generate if (!PP2) begin : g_nar2 assign ar2 = '0; end endgenerate
    // the results the take copies into e1_* (the right slope's): PP2 the right
    // pipeline's, otherwise r_*
    // PP2: the right slope's record (all but r g b s t, dx, xlen, ylen: AVM) into
    // a 4-entry ring as its stage 2 finishes (rr_w2, at e_wp's pace), read at the take
    localparam int RRW = 27 + 1 + 1 + 10 + 10 + 9 + 16 + 24 + 9;
    logic [RRW-1:0] rr_q;
    logic [RRW-1:0] er_rr;            // FDB: u_er0's output, the next polygon's right record at the take
    logic [1:0]     rr_wp;            // FDB: the right records' entry
    // FDB: stage 2's right slope as it finishes (ar_q is still its stage 1 results then)
    generate if (PP2) begin : g_rring
        logic [RRW-1:0] rr_m [0:3];
        logic [1:0]     rr_wp;
        always_ff @(posedge clk) begin
            if (rst) rr_wp <= 2'd0;
            else if (b2_done) begin
                rr_m[rr_wp] <= {ar2[78:52], ar2[51], ub2_xmaj, ar2[18:9], ub2_xcovinc, ar2[8:0], ub2_w, ub2_z, ub2_rt};
                rr_wp <= rr_wp + 2'd1;
            end
        end
        assign rr_q = rr_m[2'(e_rn)];
    end else if (QR) begin : g_rring1
        // FDB: the right records go into u_er0's spare words (g_er_avm: entries {1, rr_wp}, the left ones' {0, e_wp});
        // its read port pre-reads the next polygon's from SS_RCP on (the left record is used up to SS_ATTR), so
        // its output is the record the take copies (rr_q = er_rr)
        always_ff @(posedge clk)
            if (rst) rr_wp <= 2'd0;
            else if (b_done && b_side) rr_wp <= rr_wp + 2'd1;
        assign rr_q = er_rr;
    end else begin : g_nrring
        assign rr_q = '0;
    end endgenerate
    wire [26:0] rr_inc  = QR ? rr_q[RRW-1 -: 27] : r_inc;   wire rr_neg = QR ? rr_q[RRW-28] : r_neg;
    wire        rr_xmaj = QR ? rr_q[RRW-29] : r_xmaj;    wire [9:0] rr_xval = QR ? rr_q[RRW-30 -: 10] : r_xval;
    wire [9:0]  rr_xcovinc = QR ? rr_q[RRW-40 -: 10] : r_xcovinc;  wire [8:0] rr_vbx = QR ? rr_q[RRW-50 -: 9] : r_vbx;
    wire [15:0] rr_w = QR ? rr_q[RRW-59 -: 16] : r_w;   wire [23:0] rr_z = QR ? rr_q[RRW-75 -: 24] : r_z;
    wire [8:0]  rr_rt = TOONR ? 9'd0 : QR ? rr_q[8:0] : r_rt;
    wire [4:0][16:0] rr_av = PP2 ? ub2_av : r_av;  wire [31:0] rr_dx = PP2 ? ar2[50:19] : r_dx;
    wire [9:0]  rr_xlen = PP2 ? ub2_xlen : r_xlen;  wire [7:0] rr_ylen = PP2 ? ub2_ylen : r_ylen;
    // EP2 control: stage 1 takes the left slope when the bank is full, the
    // right once the left is handed over, and gives the bank back once the
    // right is; stage 2 takes an edge when free, a left slope only once the
    // last polygon's results are taken (its ring entry); a left slope's
    // results go into the ring, a right one's make the polygon's (e_res)
    logic        a_wait, bb_q;
    logic [HAW-1:0] ha, hb;
    // FDB: also in the clock the last edge is handed over (a_ho_v: stage 1 is idle from it)
    wire         a_nx    = FDB && a_ho_v;
    wire         a_new   = a_ph == 2'd0 || (a_nx && a_ph == 2'd3);   // the next start is a polygon's left slope
    wire         a_start = EP2 && !PP2 && !a_wait && !eu_b && ((a_new && bk_full) || a_ph == 2'd2 || (a_nx && a_ph == 2'd1));
    wire         b_done  = EP2 && bb_q && !eu_bb;
    // PP2 control: both stage 1s start the polygon in the bank (a_go), each hands
    // its slope to its own stage 2, and the bank goes back once both have (a_rel).
    // A stage 2 takes the next polygon's slope only once its last result is taken
    // (lp, rp: the left one's record went into the ring, the right one's results
    // wait in u_edge2b / ar2); the polygon's results are ready (e_res) once both are
    logic        pp_on, h1d, h2d, lp, rp, bb2_q;
    logic [HAW-1:0] pha, hb2;
    wire         b2_done = PP2 && bb2_q && !eu_bb2;
    assign a_go      = PP2 && bk_full && !pp_on && !a_wait && !eu_b && !eu_b2;
    assign a_tk      = PP2 ? a_go : QB && a_start && a_new;
    // (lp, rp: slopes done and not yet taken, 3 at most: the rings hold 4)
    logic [1:0]  lcn, rcn;
    assign lp = lcn != 2'd0;
    assign rp = rcn != 2'd0;
    // (a slope finishing this clock counts: the queue holds 3 at most)
    assign a2_ho_rdy = !eu_bb2 && !a2_ho_v && rcn != 2'd3 && !(rcn == 2'd2 && b2_done);
    // (FDB: a left slope can be ready as stage 2 finishes the last right one, whose e_res is set next clock)
    // FDB: a left slope starts a polygon in stage 2 while at most two wait for the span stage (lcn: left
    // slopes finished, not taken; the polygon rings hold four with the span stage's)
`ifdef G3D_FDB_MUT
    wire   fdb_room = 1'b1;                                     // (mutant: FDB without the queue's limit)
`else
    wire   fdb_room = a_ph != 2'd1 || lcn != 2'd3;
`endif
    assign a_ho_rdy  = PP2 ? !eu_bb && !a_ho_v && lcn != 2'd3 && !(lcn == 2'd2 && b_done)
                     : QR ? (!eu_bb || eu_bf) && !a_ho_v && fdb_room   // (FDB: handed over as stage 2 ends, taken the clock after)
                     : !eu_bb && !a_ho_v && !(a_ph == 2'd1 && e_res);
    wire         e_runx  = PP2 ? (pp_on || eu_bb || eu_bb2 || a_ho_v || a2_ho_v || b_done || b2_done || lp || rp)
                         : EP2 ? (a_ph != 2'd0 || eu_bb || a_ho_v || b_done || (QR && (lp || rp))) : e_run;   // (b_done: e_res is set next clock)
    always_ff @(posedge clk) begin
        bb2_q <= eu_bb2;
        if (rst || !QR) begin
            pp_on <= 1'b0; h1d <= 1'b0; h2d <= 1'b0; lcn <= 2'd0; rcn <= 2'd0;
        end else if (!PP2) begin                // FDB: one stage 2, left then right
            lcn <= lcn + 2'(b_done && !b_side) - 2'(e_take);
            rcn <= rcn + 2'(b_done && b_side) - 2'(e_take);
`ifndef SYNTHESIS
            if (lcn == 2'd3 && b_done && !b_side && !e_take) $error("gpu3d_front FDB: the left result queue overflows");
`endif
        end else begin
            if (a_go) begin pp_on <= 1'b1; pha <= h_w; end
            if (a_ho_v) h1d <= 1'b1;
            if (a2_ho_v) begin h2d <= 1'b1; hb2 <= pha; end
            if (a_rel) begin pp_on <= 1'b0; h1d <= 1'b0; h2d <= 1'b0; end
            lcn <= lcn + 2'(b_done) - 2'(e_take);
`ifndef SYNTHESIS
            if (lcn == 2'd3 && b_done && !e_take) $error("gpu3d_front PP2: the left result queue overflows");
            if (rcn == 2'd3 && b2_done && !e_take) $error("gpu3d_front PP2: the right result queue overflows");
`endif
            rcn <= rcn + 2'(b2_done) - 2'(e_take);
        end
    end
    always_ff @(posedge clk) begin
        bb_q <= eu_bb;
        if (rst || !EP2) begin vb_w <= '0; vb_s <= '0; end
        else if (QB) begin if (a_tk) begin vb_s <= vb_w; vb_w <= vb_w + 1'b1; end end
        else if (a_rel) vb_w <= VBW'(!vb_w);
        a_wait <= 1'b0;
        if (PP2 && a_go) a_wait <= 1'b1;
        if (rst || !EP2 || PP2) a_ph <= 2'd0;
        else begin
            if (a_ho_v) begin
                if (a_ph == 2'd1) begin a_ph <= 2'd2; b_side <= 1'b0; hb <= ha; end
                else begin a_ph <= 2'd0; b_side <= 1'b1; end
            end
            if (a_start) begin                  // (FDB: may follow a handover in the same clock)
                a_wait <= 1'b1;
                if (a_new) begin a_ph <= 2'd1; ha <= h_w; end
                else a_ph <= 2'd3;
            end
        end
    end
    wire e_done1 = e_run && !e_wait && !eu_b && !eu_b1;   // the current side (EDGE2: both) is finished
    assign e_go    = !e_run && !e_res && bk_full;
    assign e_fin   = E2S ? e_done1 : e_done1 && e_side;
    assign e_start = PP2 ? a_go : EP2 ? a_start : E2S ? e_go : e_go || (e_done1 && !e_side);
    wire   er_we   = PP2 ? b_done : EP2 ? b_done && !b_side : E2S ? e_fin : e_done1 && !e_side;  // the left slope's record into the ring
    assign a_rel   = PP2 ? pp_on && (h1d || a_ho_v) && (h2d || a2_ho_v)   // PP2: both slopes handed over
                         : EP2 && a_ho_v && a_ph == 2'd3;     // EP2: the bank goes back (the right slope is handed over)
    always_ff @(posedge clk) begin
        if (rst) begin
            e_run <= 1'b0; e_wait <= 1'b0; e_res <= 1'b0; e_side <= 1'b0; e_wp <= '0;
            h_w <= '0;
            if (QR) h_e <= '0;
        end else if (PP2) begin
            // polygons finish in order: the next ready one's header follows the last taken
            if (a_go) h_w <= h_w + 1'b1;     // (the bank is handed over: the next header loads)
            if (b_done) e_wp <= e_wp + 1'b1;
            if (lp && rp && !e_res && !e_take) e_res <= 1'b1;
            if (e_take) begin e_res <= 1'b0; h_e <= h_e + 1'b1; end
        end else if (EP2 && QR) begin
            // FDB: as PP2, polygons finish in order (the next ready one's header follows the last taken)
            if (a_tk) h_w <= h_w + 1'b1;     // (the next header loads while stage 1 walks)
            if (er_we) e_wp <= e_wp + 1'b1;
            if (rp && !e_res && !e_take) e_res <= 1'b1;
            if (e_take) begin e_res <= 1'b0; h_e <= h_e + 1'b1; end
        end else if (EP2) begin
            if (a_rel) h_w <= h_w + 2'd1;
            if (b_done && b_side) begin e_res <= 1'b1; h_e <= hb; end
            if (e_take) begin e_res <= 1'b0; e_wp <= ~e_wp; end
        end else begin
            e_wait <= 1'b0;
            if (e_go) begin
                e_run <= 1'b1; e_wait <= 1'b1; e_side <= 1'b0;   // busy from the next cycle
                h_e <= h_w;
            end
            if (!E2S && e_done1 && !e_side) begin
                e_side <= 1'b1; e_wait <= 1'b1;
            end
            if (e_fin) begin e_run <= 1'b0; e_res <= 1'b1; h_w <= h_w + 2'd1; end
            if (e_take) begin e_res <= 1'b0; e_wp <= ~e_wp; end
        end
    end

    always_ff @(posedge clk) begin
`ifdef G3D_ABL_FDB
        // (simulation ablation, the bench's load3d scenes only: the input stage loads one polygon ahead, as a second
        // bank would; the polygon fields and vertex RAM are not protected, so only same-shaped quads time right)
        if (rst) bk_n <= 2'd0;
        else bk_n <= bk_n + (bk_commit ? 2'd1 : 2'd0) - ((EP2 ? a_rel : e_fin) ? 2'd1 : 2'd0);
        bk_full <= !rst && (bk_n + (bk_commit ? 2'd1 : 2'd0) - ((EP2 ? a_rel : e_fin) ? 2'd1 : 2'd0)) != 2'd0;
`else
        if (rst) bk_full <= 1'b0;
        else if (bk_commit) bk_full <= 1'b1;
`ifdef G3D_PP2_MUT
        else if (QB ? a_tk : EP2 ? a_go : e_fin) bk_full <= 1'b0;     // (mutant: EP2 alone gives the bank back at a_go)
`else
        else if (QB ? a_tk : EP2 ? a_rel : e_fin) bk_full <= 1'b0;
`endif
`endif
    end

    // ---------------- span stage ----------------
    typedef enum logic [3:0] {
        SS_IDLE, SS_SP0, SS_EPS, SS_EP, SS_EPM, SS_EPW, SS_FILL, SS_ATTR, SS_RCP, SS_LX, SS_OUT
    } sstate_t;
    sstate_t ss;

    // the polygon (from the edge units)
    logic [31:0] s_attr, s_texparam;
    logic [12:0] s_texpal;
    logic [7:0]  s_ytop, s_ybot;
    logic        s_facing, s_wbuf;
    // M10K with a registered read (an MLAB took 5 LABs): it reads the entry
    // h_s takes next, so the header is out the cycle after the take, as with
    // the combinational MLAB. An entry does not change while it is read.
    wire         s_take = ss == SS_IDLE && e_res && !e_take;   // the span stage takes the next polygon
    wire  [HAW-1:0] h_sn = s_take ? h_e : h_s;
    wire  [HRW-1:0] hr_wd = {ps_data[31:0], ps_data[63:32], ps_data[76:64], ps_data[96:89], ps_data[104:97], ps_data[105], ps_data[106]};
    wire            hr_we = st == S_HDR && ps_valid && ps_ready && ps_type == 2'd0;
    generate
    if (HDR_M10K) begin : g_hdr_m10k
        gpu3d_ram #(.W(HRW), .AW(HAW), .STYLE("M10K")) u_hdr (.clk, .we(hr_we), .waddr(h_w), .wdata(hr_wd), .raddr(h_sn), .rdata(hr_q));
    end else begin : g_hdr_mlab
        gpu3d_lram #(.W(HRW), .AW(HAW)) u_hdr (.clk, .we(hr_we), .waddr(h_w), .wdata(hr_wd), .raddr(h_s), .rdata(hr_q));
    end
    endgenerate
    assign {s_attr, s_texparam, s_texpal, s_ytop, s_ybot, s_facing, s_wbuf} = hr_q;
    wire  [4:0]  s_alpha = s_attr[20:16];
    wire         s_wire  = (s_alpha == 0);
    wire         s_ismask = FEAT_SHADOW && (s_attr & 32'h3F000030) == 32'h00000030;
    // edges (index 0 = left slope, 1 = right slope). The left slope's
    // results go into a two-entry MLAB ring when the unit finishes side 0
    // (entry e_wp) and the span stage reads them at e_rp, the entry of the
    // run it took; the next run writes the other entry. The right slope's
    // are the unit's outputs, copied to e1_* at the take.
    localparam int ERW = 242;         // left-slope record width
    // PP2: 4 entries (the span stage's and up to 3 ready left slopes); e_wp
    // moves on with each left slope written, e_rp with each take
    // FDB: likewise (the span stage's and up to three ready left slopes)
    localparam int EQW = QR ? 2 : 1;
    logic [EQW-1:0] e_wp, e_rp;
    wire  [EQW-1:0] e_rn = QR ? EQW'(e_rp + 1'b1) : e_wp;   // the entry the next take reads
    logic [ERW-1:0] er_q;
    // AVM (EP2): the attributes r g b s t of both slopes are not in the ring
    // or e1_av but in two MLABs, one a slope, a 17-bit entry {polygon, k} per
    // attribute, written as stage 2 interpolates them (its item writes:
    // every edge writes all five, before it finishes) and read at {polygon,
    // at_k} by SS_ATTR, the only reader (g_avm)
    localparam bit AVM = EP2 && !ER_M10K;
    logic [16:0] avl_q, avr_q;        // AVM: attribute at_k of the left, right slope
    // AVM: likewise {dx, xlen, ylen} of both slopes, which only SS_EPS reads, one
    // slope at a time (ep_k ^ sw): one MLAB, entry {polygon, side} written as
    // stage 2 finishes the edge (b_done: the left slope's with the ring's
    // record, the right one's as e1_* would copy them at the take: they
    // hold until then), read at {polygon, ep_k ^ sw}
    logic [49:0] eps_q;
    generate
    if (ER_M10K) begin : g_er_m10k
        // registered read at the entry e_rp takes next (e_wp at the take), so
        // the record is out the cycle after the take, as from the MLAB.
        // 200 bits in 5 M10K: the colour lanes (r g b) are kept as 9 bits
        // (interpolated between two 9-bit vertex colours: 0..511), and vbx
        // and rt (18 bits) sit in a two-entry register pair read the same way
        logic [199:0] er_m;
        logic [17:0]  er_f [0:1];
        logic [17:0]  er_fq;
        wire          er_ra = s_take ? e_wp : e_rp;
        gpu3d_ram #(.W(200), .AW(1), .STYLE("M10K")) u_er0 (
            .clk, .we(er_we), .waddr(e_wp),
            .wdata({r_inc, r_neg, r_xmaj, r_dx, r_xval, r_xlen, r_xcovinc, r_ylen, r_w, r_z,
                    r_av[4], r_av[3], r_av[2][8:0], r_av[1][8:0], r_av[0][8:0]}),
            .raddr(er_ra), .rdata(er_m));
        always_ff @(posedge clk) begin
            if (er_we) er_f[e_wp] <= {r_vbx, r_rt};
            er_fq <= er_f[er_ra];
        end
        // er_m: {inc .. ylen [199:101]} {w z av4 av3 [100:27]} {av2 [26:18]} {av1 [17:9]} {av0 [8:0]};
        // er_q is the MLAB record {inc .. ylen, vbx, w, z, av4 .. av0, rt}
        assign er_q = {er_m[199:101], er_fq[17:9], er_m[100:27], 8'd0, er_m[26:18], 8'd0, er_m[17:9], 8'd0, er_m[8:0], er_fq[8:0]};
        assign er_rr = '0;
`ifndef SYNTHESIS
        initial if (ERW != 242) $error("gpu3d_front: the M10K ring's packing assumes ERW = 242");
        always_ff @(posedge clk)
            if (!rst && er_we && (r_av[0][16:9] != 0 || r_av[1][16:9] != 0 || r_av[2][16:9] != 0))
                $error("gpu3d_front: an edge colour above 511 (the M10K ring keeps 9 bits)");
`endif
    end else if (AVM) begin : g_er_avm
        // the record without the attributes, dx, xlen and ylen (AVM: u_avl, u_eps)
        // (AVM_M10K: a registered read at the entry e_rp takes next, as g_er_m10k)
        logic [ERW-136:0] er_n;
        wire  [ERW-136:0] er_wd = {r_inc, r_neg, r_xmaj, r_xval, r_xcovinc, r_vbx, r_w, r_z, r_rt};
        if (AVM_M10K && QR && !PP2) begin : g_m10k1
            // FDB: the right records too, in the same blocks' spare words (both sides' records have the same
            // fields; a slope at a time finishes, so one write port); read: the left record at e_rp up to SS_ATTR
            // (and at the take: {0, e_rn}), the next polygon's right record from SS_RCP on
            wire pre = ss == SS_RCP || ss == SS_LX || ss == SS_OUT || ss == SS_IDLE;
`ifdef G3D_RR_MUT
            wire [EQW:0] ra = s_take ? {1'b0, e_rn} : pre ? {1'b1, EQW'(e_rp)} : {1'b0, e_rp};   // (mutant: this polygon's right record)
`else
            wire [EQW:0] ra = s_take ? {1'b0, e_rn} : pre ? {1'b1, e_rn} : {1'b0, e_rp};
`endif
            gpu3d_ram #(.W(ERW - 135), .AW(EQW + 1), .STYLE("M10K")) u_er0 (
                .clk, .we(b_done), .waddr(b_side ? {1'b1, EQW'(rr_wp)} : {1'b0, e_wp}), .wdata(er_wd),
                .raddr(ra), .rdata(er_n));
            assign er_rr = er_n;
        end else if (AVM_M10K) begin : g_m10k
            gpu3d_ram #(.W(ERW - 135), .AW(EQW), .STYLE("M10K")) u_er0 (
                .clk, .we(er_we), .waddr(e_wp), .wdata(er_wd), .raddr(s_take ? e_rn : e_rp), .rdata(er_n));
            assign er_rr = '0;
        end else begin : g_mlab
            gpu3d_lram #(.W(ERW - 135), .AW(EQW)) u_er0 (
                .clk, .we(er_we), .waddr(e_wp), .wdata(er_wd), .raddr(e_rp), .rdata(er_n));
            assign er_rr = '0;
`ifndef SYNTHESIS
            initial if (QR && !PP2) $error("gpu3d_front: FDB needs AVM_M10K (its right records live in u_er0's M10K)");
`endif
        end
        // er_q: {inc, neg, xmaj} [241:213], dx [212:181], {xval} [180:171], xlen [170:161],
        // xcovinc [160:151], ylen [150:143], {vbx, w, z} [142:94], av [93:9], rt [8:0]
        assign er_q = {er_n[106:78], 32'd0, er_n[77:68], 10'd0, er_n[67:58], 8'd0, er_n[57:9], 85'd0, er_n[8:0]};
    end else begin : g_er_mlab
        gpu3d_lram #(.W(ERW), .AW(1)) u_er0 (
            .clk, .we(er_we), .waddr(e_wp),
            .wdata({r_inc, r_neg, r_xmaj, r_dx, r_xval, r_xlen, r_xcovinc, r_ylen, r_vbx, r_w, r_z, r_av, r_rt}),
            .raddr(e_rp), .rdata(er_q));
        assign er_rr = '0;
    end
    endgenerate
    logic [26:0] e1_inc;  logic e1_neg, e1_xmaj;  logic signed [31:0] e1_dx;
    logic [9:0]  e1_xval, e1_xlen, e1_xcovinc;  logic [7:0] e1_ylen;  logic [8:0] e1_vbx;
    logic [15:0] e1_w;  logic [23:0] e1_z;  logic [4:0][16:0] e1_av;  logic [8:0] e1_rt;
    logic [26:0] e_inc [0:1];
    logic        e_neg [0:1], e_xmaj [0:1];
    logic signed [31:0] e_dx [0:1];
    logic [9:0]  e_xval [0:1], e_xlen [0:1], e_xcovinc [0:1];
    logic [7:0]  e_ylen [0:1];
    logic [8:0]  e_vbx [0:1];
    logic [15:0] e_w [0:1];
    logic [23:0] e_z [0:1];
    logic [4:0][16:0] e_av [0:1];
    logic [8:0]  e_rt [0:1];
    always_comb begin
        {e_inc[0], e_neg[0], e_xmaj[0], e_dx[0], e_xval[0], e_xlen[0], e_xcovinc[0],
         e_ylen[0], e_vbx[0], e_w[0], e_z[0], e_av[0], e_rt[0]} = er_q;
        e_inc[1] = e1_inc; e_neg[1] = e1_neg; e_xmaj[1] = e1_xmaj; e_dx[1] = e1_dx;
        e_xval[1] = e1_xval; e_xlen[1] = e1_xlen; e_xcovinc[1] = e1_xcovinc;
        e_ylen[1] = e1_ylen; e_vbx[1] = e1_vbx; e_w[1] = e1_w; e_z[1] = e1_z; e_av[1] = e1_av; e_rt[1] = e1_rt;
    end
    // span
    logic        sw;
    logic signed [11:0] xs, xe;
    logic signed [11:0] l_len, r_len;
    logic        l_covx, r_covx;      // coverage from the X-major formula
    logic [9:0]  l_cstart, r_cstart;
    logic [4:0]  l_cov5, r_cov5;
    logic        l_fill, r_fill;
    logic        ep_k;                // EdgeParams side being computed
    logic        ep_neg;              // its coverage numerator was negative
    logic        ep_sub;              // DS_AACOV: a Negative edge, numerator - 1
    // per attribute (r g b s t), left/right after the swap: one per cycle
    logic [2:0]  at_k;
    logic [4:0]  a_alt;               // left < right
    logic [4:0][15:0] a_base;         // min(left, right), modulo 2^16
    logic [4:0][16:0] a_ad;           // |right - left|
    logic        t_alt;               // DS_TOON: the same for the fill-less red
    logic [8:0]  t_base, t_ad;
    // SS_SP0: the span's ends and the swap (sp_sw also addresses AVS's u_eps read)
    logic signed [11:0] sp_a, sp_b;
    logic        sp_sw;
    always_comb begin
        sp_a = $signed({2'b0, e_xval[0]});
        sp_b = $signed({2'b0, e_xval[1]});
        // right vertical edges are pushed 1px to the left
        if (e_inc[1] == 0 && (e_inc[0] != 0 || sp_a != sp_b) && sp_b != 0) sp_b = sp_b - 12'sd1;
        sp_sw = sp_a > sp_b;
    end

    // AVM's MLABs (above, with the ring)
    generate if (AVM) begin : g_avm
        // entries by polygon, four (the MLAB's depth is 32 anyway): stage 2
        // writes polygon av_wp's (the next after each right slope), the span
        // stage reads av_rp's (the next at each take). Polygons are taken in
        // order, so the entry read is the one written for that polygon,
        // whichever of the two runs ahead
        logic [1:0] av_wp, av_rp;
        always_ff @(posedge clk)
            if (rst) begin av_wp <= 2'd0; av_rp <= 2'd3; end
            else begin
                if (b_done && b_side) av_wp <= av_wp + 2'd1;
                if (s_take) av_rp <= av_rp + 2'd1;
            end
        wire [4:0] av_wa = {av_wp, 3'(b_it_k - 4'd1)};
        wire       av_we = b_it_we && b_it_k >= 4'd1 && b_it_k <= 4'd5;
        if (PP2) begin : g_avp
            // PP2: each pipeline writes its own side's tables at its own polygon
            // (av1_wp, av2_wp: the next after each of its slopes), in the same
            // clock if need be; the span stage reads both at av_rp as before
            // (registered reads, as AVS_M10K 1: attributes two clocks ahead
            // into an output register, {dx, xlen, ylen} a clock ahead)
            logic [1:0]  av1_wp, av2_wp;
            always_ff @(posedge clk)
                if (rst) begin av1_wp <= 2'd0; av2_wp <= 2'd0; end
                else begin
                    if (b_done) av1_wp <= av1_wp + 2'd1;
                    if (b2_done) av2_wp <= av2_wp + 2'd1;
                end
            wire [4:0] av_ra2 = {av_rp, ss == SS_FILL ? 3'd1 : ss == SS_ATTR ? 3'(at_k + 3'd2) : 3'd0};
            wire       ep_sd  = ss == SS_SP0 ? sp_sw : !sw;
            logic [16:0] avl_m, avr_m;
            logic [49:0] epsl_m, epsr_m;
            logic        ep_sd_q;
            gpu3d_ram #(.W(17), .AW(5), .STYLE("M10K, no_rw_check")) u_avl (.clk,
                .we(b_it_we && b_it_k >= 4'd1 && b_it_k <= 4'd5), .waddr({av1_wp, 3'(b_it_k - 4'd1)}),
                .wdata(b_it_v), .raddr(av_ra2), .rdata(avl_m));
            gpu3d_ram #(.W(17), .AW(5), .STYLE("M10K, no_rw_check")) u_avr (.clk,
                .we(b2_it_we && b2_it_k >= 4'd1 && b2_it_k <= 4'd5), .waddr({av2_wp, 3'(b2_it_k - 4'd1)}),
                .wdata(b2_it_v), .raddr(av_ra2), .rdata(avr_m));
            gpu3d_ram #(.W(50), .AW(2), .STYLE("M10K, no_rw_check")) u_epsl (.clk, .we(b_done), .waddr(av1_wp),
                .wdata({r_dx, r_xlen, r_ylen}), .raddr(av_rp), .rdata(epsl_m));
            gpu3d_ram #(.W(50), .AW(2), .STYLE("M10K, no_rw_check")) u_epsr (.clk, .we(b2_done), .waddr(av2_wp),
                .wdata({rr_dx, rr_xlen, rr_ylen}), .raddr(av_rp), .rdata(epsr_m));
            always_ff @(posedge clk) begin avl_q <= avl_m; avr_q <= avr_m; ep_sd_q <= ep_sd; end
            assign eps_q = ep_sd_q ? epsr_m : epsl_m;
        end else if (AVS_M10K != 0) begin : g_avs
            // AVS_M10K: SS_ATTR uses entry {av_rp, at_k}, at_k 0 from SS_FILL on, +1 a clock: read two
            // clocks ahead into the block's output register ({av_rp, 0} before SS_FILL, 1 in it, at_k + 2
            // in SS_ATTR); SS_EPS uses {av_rp, ep_k ^ sw}: read in the clock before (SS_SP0: ep_k 0 and
            // the swap SS_SP0 sets, sp_sw; SS_EPW: ep_k 1, the swap set). av_rp holds from the take to
            // the next, and stage 2 writes polygon av_wp's entries, not yet av_rp's (checked below)
            wire [4:0] av_ra2 = {av_rp, ss == SS_FILL ? 3'd1 : ss == SS_ATTR ? 3'(at_k + 3'd2) : 3'd0};
            wire [2:0] ep_ra1 = {av_rp, ss == SS_SP0 ? sp_sw : !sw};
            if (AVS_M10K == 2) begin : g_be
                gpu3d_ram_be2 #(.W(17), .AW(5), .K(2)) u_avlr (.clk, .we0(av_we && !b_side), .we1(av_we && b_side),
                    .waddr(av_wa), .wdata(b_it_v), .raddr(av_ra2), .rdata0(avl_q), .rdata1(avr_q));
            end else begin : g_two
                logic [16:0] avl_m, avr_m;
                gpu3d_ram #(.W(17), .AW(5), .STYLE("M10K, no_rw_check")) u_avl (.clk, .we(av_we && !b_side),
                    .waddr(av_wa), .wdata(b_it_v), .raddr(av_ra2), .rdata(avl_m));
                gpu3d_ram #(.W(17), .AW(5), .STYLE("M10K, no_rw_check")) u_avr (.clk, .we(av_we && b_side),
                    .waddr(av_wa), .wdata(b_it_v), .raddr(av_ra2), .rdata(avr_m));
                always_ff @(posedge clk) begin avl_q <= avl_m; avr_q <= avr_m; end
            end
            gpu3d_ram #(.W(50), .AW(3), .STYLE("M10K, no_rw_check")) u_eps (.clk, .we(b_done), .waddr({av_wp, b_side}),
                .wdata({r_dx, r_xlen, r_ylen}), .raddr(ep_ra1), .rdata(eps_q));
`ifndef SYNTHESIS
            // synthesis translate_off
            // the MLABs' reads as they were, against the M10K words where they are used
            logic [16:0] avl_s, avr_s;
            logic [49:0] eps_s;
            gpu3d_lram #(.W(17), .AW(5)) s_avl (.clk, .we(av_we && !b_side), .waddr(av_wa), .wdata(b_it_v),
                .raddr({av_rp, at_k}), .rdata(avl_s));
            gpu3d_lram #(.W(17), .AW(5)) s_avr (.clk, .we(av_we && b_side), .waddr(av_wa), .wdata(b_it_v),
                .raddr({av_rp, at_k}), .rdata(avr_s));
            gpu3d_lram #(.W(50), .AW(3)) s_eps (.clk, .we(b_done), .waddr({av_wp, b_side}), .wdata({r_dx, r_xlen, r_ylen}),
                .raddr({av_rp, ep_k ^ sw}), .rdata(eps_s));
            always_ff @(posedge clk) if (!rst) begin
                if (ss == SS_ATTR && at_k < 3'd5 && (avl_q != avl_s || avr_q != avr_s))
                    $error("gpu3d_front AVS: attribute %0d of polygon %0d: M10K %05x %05x, MLAB %05x %05x",
                           at_k, av_rp, avl_q, avr_q, avl_s, avr_s);
                if (ss == SS_EPS && eps_q != eps_s)
                    $error("gpu3d_front AVS: u_eps {%0d, %0d}: M10K %013x, MLAB %013x", av_rp, ep_k ^ sw, eps_q, eps_s);
            end
            // synthesis translate_on
`endif
        end else begin : g_mlab
            gpu3d_lram #(.W(17), .AW(5)) u_avl (.clk, .we(av_we && !b_side), .waddr(av_wa), .wdata(b_it_v),
                .raddr({av_rp, at_k}), .rdata(avl_q));
            gpu3d_lram #(.W(17), .AW(5)) u_avr (.clk, .we(av_we && b_side), .waddr(av_wa), .wdata(b_it_v),
                .raddr({av_rp, at_k}), .rdata(avr_q));
            gpu3d_lram #(.W(50), .AW(3)) u_eps (.clk, .we(b_done), .waddr({av_wp, b_side}), .wdata({r_dx, r_xlen, r_ylen}),
                .raddr({av_rp, ep_k ^ sw}), .rdata(eps_q));
        end
    end else begin : g_navm
        assign {avl_q, avr_q, eps_q} = '0;
    end endgenerate
    wire         s_toon = DS_TOON && FEAT_TOON && s_attr[5:4] == 2'd2;
    // the span's ends after the swap: e_* and sw hold until the next take
    // FDB: the left record's w and z kept from SS_FILL, as u_er0's port reads the next right record from SS_RCP on
    // (and xcovinc for fe_desc's coverage step)
    logic [15:0] ew0_q;
    logic [23:0] ez0_q;
    logic [9:0]  ec0_q;
    wire  [15:0] ew0 = (QR && !PP2 && AVM_M10K) ? ew0_q : e_w[0];
    wire  [23:0] ez0 = (QR && !PP2 && AVM_M10K) ? ez0_q : e_z[0];
    wire  [9:0]  ec0 = (QR && !PP2 && AVM_M10K) ? ec0_q : e_xcovinc[0];
    always_ff @(posedge clk) if (ss == SS_FILL) begin ew0_q <= e_w[0]; ez0_q <= e_z[0]; ec0_q <= e_xcovinc[0]; end
    wire  [15:0] wl = sw ? e_w[1] : ew0, wr = sw ? ew0 : e_w[1];
    wire  [23:0] zl = sw ? e_z[1] : ez0, zr = sw ? ez0 : e_z[1];
    logic [9:0]  xdiffx;
    logic [22:0] xrecipx;
    logic        linx;
    logic [2:0]  lin_k;               // linear path: attribute being divided
    // RECIP: ceil(2^37/xdiff) (gpu3d_lrecip, address xdiffx). The descriptor
    // reads the table's registered output itself: its address xdiffx holds
    // from SS_FILL until the next polygon's, so lr_q is the same word from
    // SS_RCP to SS_OUT (the raster takes fe_desc only with fe_wr)
    logic [37:0] lr_q;
    generate
    if (LROM2) begin : g_lrom2
        gpu3d_lrecip2 u_lrecip (.clk, .addr_a(xdiffx), .q_a(lr_q), .addr_b({2'b0, e_lr_addr}), .q_b(e_lr_q));
    end else begin : g_lrom1
        gpu3d_lrecip u_lrecip (.clk, .addr(xdiffx), .q(lr_q));
        assign e_lr_q = '0;
    end
    endgenerate
    logic [4:0][15:0] lq;             // ad / xdiff and ad % xdiff per attribute
    logic [4:0][9:0]  lr;

    // Slope::EdgeParams for the left (ep_k = 0), then the right (ep_k = 1)
    // span edge; the slope used is ep_k ^ sw (swapped spans take the other
    // slope's)
    logic signed [11:0] ep_len_c;
    logic        ep_covx_c;
    logic [4:0]  ep_cov5_c;
    logic [24:0] ep_cn_c;             // |startx*1024 + 0x1FF| (DS_AACOV: + 0x200)
    logic [24:0] ep_cn;               // ... registered, then * ylen
    logic [7:0]  ep_ylen;
    logic        ep_go;               // coverage division needed
    logic        ep_negn_c;
    // the slope EdgeParams uses (ep_k ^ sw), registered in SS_EPS
    logic signed [31:0] ps_dx;
    logic [26:0] ps_inc;
    logic        ps_neg, ps_xmaj;
    logic [9:0]  ps_xlen;
    logic [7:0]  ps_ylen;
    always_comb begin
        begin
            logic sel, sd;
            logic signed [31:0] dx, inc;
            logic signed [12:0] len, startx;
            logic signed [24:0] cn;
            logic [5:0] cov;
            logic signed [31:0] c;
            c = '0;
            sel = ep_k ^ sw;          // slope used: left param <- R when swapped
            sd  = sel;                // the slope's own side
            dx  = ps_dx;
            inc = $signed({5'b0, ps_inc});
            len = 13'sd1; startx = '0; cn = '0; cov = '0;
            ep_len_c = 12'sd1; ep_covx_c = 1'b0; ep_cov5_c = 5'd0;
            ep_cn_c = '0; ep_negn_c = 1'b0;
            if (ps_xmaj) begin
                if (!sw || sd) begin
                    if (sd ^ ps_neg) len = 13'((dx >>> 18) - ((dx - inc) >>> 18));
                    else                 len = 13'(((dx + inc) >>> 18) - (dx >>> 18));
                end
                startx = 13'(dx >>> 18);
                if (ps_neg) startx = $signed({3'b0, ps_xlen}) - startx;
                if (sd)         startx = startx - len + 13'sd1;
                ep_len_c = sw ? 12'sd1 : 12'(len);
                cn = $signed({startx, 10'b0}) + (DS_AACOV ? 25'sh200 : 25'sh1FF);
                ep_negn_c = cn < 0;
                ep_cn_c = 25'((cn < 0) ? -cn : cn);
                ep_covx_c = 1'b1;
            end else begin
                if (ps_inc == 0) cov = sw ? 6'd0 : 6'd31;
                else begin
                    c = ((dx >>> 9) + (inc >>> 10)) >>> 4;
                    if (DS_AAYCOV ? ((dx + inc - 32'sd1) >>> 18) != (dx >>> 18)
                                  : (c >>> 5) != (dx >>> 18)) c = 32'sd31;
                    cov = {1'b0, c[4:0]};
                    if (sw) begin if (sd ^ ps_neg)    cov = 6'd31 - cov; end
                    else    begin if (!(sd ^ ps_neg)) cov = 6'd31 - cov; end
                end
                ep_cov5_c = cov[4:0];
            end
        end
    end

    // coverage start: (|cn| * ylen) / xlen, only needed with AA; also the
    // linear path's ad / xdiff and ad % xdiff (SS_LX)
    // AREA: one divider for the edge unit (10-bit quotients) and the span
    // stage (32-bit). A client starts only while it owns it (dv_own) and
    // keeps it until its result is read; the edge unit wins a tie.
    // Otherwise each has its own and the grants are always given.
    logic        ed_start, ed_busy;
    logic        ed2_start, ed2_busy;     // EPF: the right side's coverage divider
    logic [31:0] ed2_q;
    logic        ep_negl;                 // EPF: the left side's numerator was negative
    logic [31:0] ed_num, ed_q;
    logic [9:0]  ed_den, ed_r;
    logic        e_dv_start, e_dv_req, e_dv_hold, e_dv_gnt, f_dv_req, f_dv_hold, f_dv_gnt;
    logic [31+YNW:0] e_dv_num;
    logic [24:0] e_dv_den;
    logic        e_dv_busy;
    logic [17:0] e_dv_q;
    logic        e_dv_mode;           // the edge unit asks for a wide quotient (DS_LIN17)
    generate
    if (AREA) begin : g_dshare
        logic [24:0] sh_r;
        logic [1:0]  dv_own;          // 0 free, 1 edge unit, 2 span stage
        gpu3d_div4m u_div (
            .clk, .rst, .start(e_dv_start || ed_start), .mode(ed_start || e_dv_mode),
            .num(ed_start ? ed_num : e_dv_num[31:0]), .den(ed_start ? 25'(ed_den) : e_dv_den),
            .busy(ed_busy), .q(ed_q), .r(sh_r));
        assign ed_r = sh_r[9:0];
        assign e_dv_busy = ed_busy;
        assign e_dv_q = ed_q[17:0];
        assign e_dv_gnt = dv_own == 2'd1 || (dv_own == 2'd0 && e_dv_req);
        assign f_dv_gnt = dv_own == 2'd2 || (dv_own == 2'd0 && !e_dv_req && f_dv_req);
        always_ff @(posedge clk) begin
            if (rst) dv_own <= 2'd0;
            else case (dv_own)
                2'd0:    dv_own <= e_dv_req ? 2'd1 : f_dv_req ? 2'd2 : 2'd0;
                2'd1:    if (!e_dv_hold && !e_dv_req) dv_own <= 2'd0;
                default: if (!f_dv_hold && !f_dv_req) dv_own <= 2'd0;
            endcase
`ifndef SYNTHESIS
            if (!rst && e_dv_start && ed_start) $error("gpu3d_front: both clients start the divider");
            if (!rst && ((e_dv_start && dv_own != 2'd1) || (ed_start && dv_own != 2'd2)))
                $error("gpu3d_front: divider started without owning it");
`endif
        end
    end else begin : g_dsep
        logic e_dv_done, ed_done;
        logic [24:0] e_dv_r;
        if (DS_LIN17 && !DS_LINZ) begin : g_ediv
            // the linear factor by division (DS_LIN17 without DS_LINZ's table)
            // needs up to 18 quotient bits: the 10/32-bit divider
            logic [31:0] e_q32;
            gpu3d_div4m u_div (
                .clk, .rst, .start(e_dv_start), .mode(e_dv_mode), .num(e_dv_num[31:0]), .den(e_dv_den),
                .busy(e_dv_busy), .q(e_q32), .r(e_dv_r));
            assign e_dv_q = e_q32[17:0];
        end else begin : g_ediv
            // (EDIV4: a 12-bit quotient, its top two bits 0 as num < den << 10)
            localparam int EQB = EDIV4 ? 12 : 10;
            logic [EQB-1:0] e_q10;
            gpu3d_div4 #(.NW(32 + YNW), .DW(25), .QB(EQB), .SPC(EDIV4 ? 4 : 2)) u_div (
                .clk, .rst, .start(e_dv_start), .num(e_dv_num), .den(e_dv_den),
                .busy(e_dv_busy), .done(e_dv_done), .q(e_q10), .r(e_dv_r));
            assign e_dv_q = 18'(e_q10[9:0]);
        end
        gpu3d_div4 #(.NW(32), .DW(10), .QB(32), .SPC(EPF ? 4 : 2)) u_epdiv (
            .clk, .rst, .start(ed_start), .num(ed_num), .den(ed_den),
            .busy(ed_busy), .done(ed_done), .q(ed_q), .r(ed_r));
        if (EPF) begin : g_epd2
            logic ed2_done;
            logic [9:0] ed2_r;
            gpu3d_div4 #(.NW(32), .DW(10), .QB(32), .SPC(4)) u_epdiv2 (
                .clk, .rst, .start(ed2_start), .num(ed_num), .den(ed_den),
                .busy(ed2_busy), .done(ed2_done), .q(ed2_q), .r(ed2_r));
        end else begin : g_epd1
            assign ed2_busy = 1'b0; assign ed2_q = '0;
        end
        assign e_dv_gnt = 1'b1;
        assign f_dv_gnt = 1'b1;
    end
    endgenerate

    // X reciprocal and linear-step divisions share a table and a multiplier
    logic [8:0]  sr_addr;
    logic [26:0] sr_q;
    generate
    if (LROM2) begin : g_rom2
        gpu3d_recip2 u_srecip (.clk, .addr_a(sr_addr), .q_a(sr_q), .addr_b(e_rom_a), .q_b(e_rom_q));
    end else begin : g_rom1
        gpu3d_recip u_srecip (.clk, .addr(sr_addr), .q(sr_q));
        assign e_rom_q = '0;
    end
    endgenerate
    logic signed [11:0] fx_s0, fx_e0; // span ends after the swap
    logic [9:0]  fx_xd;
    always_comb begin
        fx_s0 = sw ? xe : xs;
        fx_e0 = sw ? xs : xe;
        fx_xd = 10'(fx_e0 + 12'sd1 - fx_s0);
        sr_addr = 9'(xdiffx - 10'd1);  // xdiffx is set in SS_FILL, read in SS_RCP
    end

    // W at the span ends, after the swap (for the linear test in SS_FILL)
    wire [15:0] wl_c = sw ? e_w[1] : e_w[0];
    wire [15:0] wr_c = sw ? e_w[0] : e_w[1];
    wire  s_drop = s_ismask && (s_wire ? 5'd31 : s_alpha) <= alpharef;   // masks test alpha once per line

    always_ff @(posedge clk) begin
        ed_start <= 1'b0;
        ed2_start <= 1'b0;
        e_take <= 1'b0;
        if (rst) begin ss <= SS_IDLE; if (QR) e_rp <= '1; end
        else case (ss)
        SS_IDLE: if (e_res && !e_take) begin
            e_take <= 1'b1;
            h_s <= h_e;
            e_rp <= e_rn;
            if (E2S) begin
                e1_inc <= u1_inc; e1_neg <= u1_neg; e1_xmaj <= u1_xmaj; e1_dx <= u1_dx;
                e1_xval <= u1_xval; e1_xlen <= u1_xlen; e1_xcovinc <= u1_xcovinc;
                e1_ylen <= u1_ylen; e1_vbx <= u1_vbx; e1_w <= u1_w; e1_z <= u1_z; e1_av <= u1_av; e1_rt <= u1_rt;
            end else begin
                e1_inc <= rr_inc; e1_neg <= rr_neg; e1_xmaj <= rr_xmaj;
                e1_xval <= rr_xval; e1_xcovinc <= rr_xcovinc;
                e1_vbx <= rr_vbx; e1_w <= rr_w; e1_z <= rr_z; e1_rt <= rr_rt;
                if (!AVM) begin e1_av <= rr_av; e1_dx <= rr_dx; e1_xlen <= rr_xlen; e1_ylen <= rr_ylen; end
            end
            ss <= SS_SP0;
        end
        SS_SP0: begin
            xs <= sp_a; xe <= sp_b;
            sw <= sp_sw;
            ep_k <= 1'b0;
            ss <= SS_EPS;
        end
        SS_EPS: begin
            ps_dx <= AVM ? eps_q[49:18] : e_dx[ep_k ^ sw]; ps_inc <= e_inc[ep_k ^ sw];
            ps_neg <= e_neg[ep_k ^ sw]; ps_xmaj <= e_xmaj[ep_k ^ sw];
            ps_xlen <= AVM ? eps_q[17:8] : e_xlen[ep_k ^ sw]; ps_ylen <= AVM ? eps_q[7:0] : e_ylen[ep_k ^ sw];
            ss <= SS_EP;
        end
        SS_EP: begin
            if (!ep_k) begin
                l_len <= ep_len_c; l_covx <= ep_covx_c; l_cov5 <= ep_cov5_c;
            end else begin
                r_len <= ep_len_c; r_covx <= ep_covx_c; r_cov5 <= ep_cov5_c;
            end
            ep_neg <= ep_negn_c;
            ep_sub <= DS_AACOV && ps_neg;
            ep_cn <= ep_cn_c; ep_ylen <= ps_ylen; ed_den <= ps_xlen;
            ep_go <= dispcnt[4] && ep_covx_c;
            ss <= SS_EPM;
        end
        SS_EPM: if (!ep_go || f_dv_gnt) begin
            // DS_AACOV: (cn * ylen - 1) / xlen on Negative edges, truncated
            // toward zero; cn is never 0, so |cn * ylen - 1| = |cn| * ylen -+ 1
            if (ep_go) begin
                if (EPF && ep_k) ed2_start <= 1'b1; else ed_start <= 1'b1;
                ed_num <= 32'(ep_cn) * 32'(ep_ylen) + (!ep_sub ? 32'd0 : ep_neg ? 32'd1 : 32'hFFFF_FFFF);
            end
            if (!ep_k) ep_negl <= ep_neg;
            ss <= SS_EPW;
        end
        SS_EPW: if (EPF && !ep_k) begin
            // EPF: the left side's divide runs on; the right side's setup now
            ep_k <= 1'b1;
            ss <= SS_EPS;
        end else if (EPF ? !ed_start && !ed_busy && !ed2_start && !ed2_busy : !ed_start && !ed_busy) begin
            logic [31:0] q, q2;
            q = (EPF ? ep_negl : ep_neg) ? -ed_q : ed_q;
            q2 = ep_neg ? -ed2_q : ed2_q;
            if (EPF) begin l_cstart <= q[9:0]; r_cstart <= q2[9:0]; end
            else if (!ep_k) l_cstart <= q[9:0]; else r_cstart <= q[9:0];
            ep_k <= 1'b1;
            ss <= ep_k ? SS_FILL : SS_EPS;
        end
        SS_FILL: begin
            // swap, fill rules
            logic forced, ybm, xne;
            forced = fill_all || (s_alpha < 31 && dispcnt[3]) || s_wire;
            ybm = ({1'b0, y} == {1'b0, s_ybot} - 9'd1);
            xne = e_vbx[0] != e_vbx[1];
            xs <= fx_s0; xe <= fx_e0;
            if (forced) begin l_fill <= 1'b1; r_fill <= 1'b1; end
            else if (sw) begin
                l_fill <= (e_neg[1] || !e_xmaj[1]) || (ybm && e_xmaj[1] && xne);
                r_fill <= (!e_neg[0] && e_xmaj[0]) || (!(e_neg[0] && e_xmaj[0]) && e_inc[1] == 0)
                       || (ybm && e_xmaj[0] && xne);
            end else begin
                l_fill <= ((e_neg[0] || !e_xmaj[0]) || (ybm && e_xmaj[0] && xne))
                       || (e_inc[0] == e_inc[1] && fx_s0 + l_len == fx_e0 + 12'sd1);
                r_fill <= (!e_neg[1] && e_xmaj[1]) || (e_inc[1] == 0) || (ybm && e_xmaj[1] && xne);
            end
            xdiffx <= fx_xd;
            linx <= (wl_c == wr_c) && ((wl_c & 16'h7F) == 0);
            at_k <= 3'd0;
            ss <= SS_ATTR;
        end
        // attribute k: compared without swapping (min and |difference| do not
        // depend on the order; left < right is the other comparison when swapped)
        SS_ATTR: begin
            logic signed [17:0] a, b;
            a = 18'($signed(AVM ? avl_q : e_av[0][at_k])); b = 18'($signed(AVM ? avr_q : e_av[1][at_k]));
            // constant indices (a variable one becomes a shifter and mask)
            for (int j = 0; j < 5; j++) if (at_k == 3'(j)) begin
                a_alt[j]  <= sw ? (b < a) : (a < b);
                a_base[j] <= (a < b) ? a[15:0] : b[15:0];
                a_ad[j]   <= 17'((a < b) ? b - a : a - b);
            end
            if (at_k == 3'd5) begin
                // DS_TOON: the fill-less red (toon/highlight spans only)
                logic [8:0] ta, tb;
                ta = e_rt[0]; tb = e_rt[1];
                t_alt  <= sw ? (tb < ta) : (ta < tb);
                t_base <= (ta < tb) ? ta : tb;
                t_ad   <= (ta < tb) ? tb - ta : ta - tb;
            end
            at_k <= at_k + 3'd1;
            if (at_k == 3'd5 || (at_k == 3'd4 && (TOONR || !s_toon))) ss <= SS_RCP;
        end
        SS_RCP: if (RECIP || !linx || f_dv_gnt) begin
            // (1<<22)/xdiff from the table (sr_addr was presented in SS_FILL)
            if (!s_wbuf) xrecipx <= 23'(sr_q >> 4);
            lin_k <= 3'd0;
            if (RECIP) begin
                // linear spans: ceil(2^37/xdiff) instead of five divisions (lr_q)
                ss <= SS_OUT;
            end else begin
                if (linx) begin ed_start <= 1'b1; ed_num <= 32'(a_ad[0]); ed_den <= xdiffx; end
                ss <= linx ? SS_LX : SS_OUT;
            end
        end
        // linear path: ad / xdiff and ad % xdiff per attribute
        SS_LX: if (!ed_start && !ed_busy) begin
            for (int j = 0; j < 5; j++) if (lin_k == 3'(j)) begin
                lq[j] <= ed_q[15:0];
                lr[j] <= ed_r;
            end
            lin_k <= lin_k + 3'd1;
            if (lin_k == 3'd4) ss <= SS_OUT;
            else begin
                ed_start <= 1'b1; ed_num <= 32'(a_ad[3'(lin_k + 3'd1)]); ed_den <= xdiffx;
            end
        end
        SS_OUT: if (s_drop || fe_wr) ss <= SS_IDLE;
        default: ss <= SS_IDLE;
        endcase
    end

    // ---------------- input stage ----------------
`ifdef G3D_ABL_FDB
    assign ps_ready = (st == S_HDR && bk_n < 2'd2 && !(bk_commit && bk_n == 2'd1)) || (st == S_VTX);
`else
    assign ps_ready = (st == S_HDR && !bk_full && !bk_commit) || (st == S_VTX);
`endif
    wire fe_quiet = !bk_full && !e_runx && !e_res && ss == SS_IDLE && pipe_idle;
    // LOV: the line's spans are all handed over (its pixels may still drain);
    // one line at most waits for its drain (ld_pend, line ld_y)
    logic        ld_pend;
    logic [7:0]  ld_y;
    wire  fe_out = !bk_full && !e_runx && !e_res && ss == SS_IDLE && !ld_pend;
    assign busy = (st != S_IDLE) || fp_run;
    // lines_go: lines 0 .. lines_go-1 started (LLR: a slot holds the newest of them)
    always_ff @(posedge clk)
        if (rst) lines_go <= 9'd0;
        else if (st == S_IDLE && frame_start && !ld_pend) lines_go <= 9'd0;
        else if (st == S_LREQ) lines_go <= {1'b0, y} + 9'd1;
    assign clr_we = (st == S_CLEAR);

    function automatic [3:0] vstep(input [3:0] i, input plus, input [3:0] n);
        if (plus) vstep = (i + 4'd1 >= n) ? 4'd0 : i + 4'd1;
        else      vstep = (i == 0) ? n - 4'd1 : i - 4'd1;
    endfunction

    always_ff @(posedge clk) begin
        ps_line_req <= 1'b0;
        bk_commit   <= 1'b0;
        if (rst) begin
            st <= S_IDLE;
            ld_pend <= 1'b0;
        end else begin
        // LOV: the waiting line has drained
        if (LOV && ld_pend && !pipe_lp[ld_y[0]]) begin ld_pend <= 1'b0; lines_done <= ld_y + 8'd1; end
        case (st)
        S_IDLE: if (frame_start && !ld_pend) begin
            prev_mask <= 1'b0;
            y <= 8'd0; y3 <= 2'd0;
            lines_done <= 8'd0;
            clr_x <= 9'd0;
            st <= S_CLEAR;
        end
        S_CLEAR: begin
            clr_x <= clr_x + 9'd1;
            if (clr_x == 9'd255) st <= S_LREQ;
        end
        S_LREQ: begin
            ps_line_req <= 1'b1;
            ps_line_y   <= y;
            st <= S_HDR;
        end
        S_HDR: if (ps_valid && ps_ready) begin
            if (ps_type == 2'd3) st <= S_LDONE;
            else if (ps_type == 2'd0) begin
                p_mask     <= FEAT_SHADOW && (ps_data[31:0] & 32'h3F000030) == 32'h00000030;
                p_toon     <= FEAT_TOON && ps_data[5:4] == 2'd2;
                p_shd      <= ps_data[5:4] == 2'd3;
                p_nv       <= ps_data[80:77];
                p_vtop     <= ps_data[84:81];
                p_vbot     <= ps_data[88:85];
                p_ytop     <= ps_data[96:89];
                p_ybot     <= ps_data[104:97];
                p_facing   <= ps_data[105];
                p_wbuf     <= ps_data[106];
                vcnt <= 4'd0;
                st <= S_VTX;
            end
        end
        S_VTX: if (ps_valid && ps_type == 2'd1) begin
            if (vcnt == 4'd0) vx0 <= ps_data[8:0];
            if (vcnt == 4'd1) vx1 <= ps_data[8:0];
            vxl <= ps_data[8:0];
            vcnt <= vcnt + 4'd1;
            if (vcnt + 4'd1 == p_nv) st <= S_PCHK;
        end
        S_PCHK: begin
            // RenderScanline: polygon covers this line?
            if ((FEAT_SHADOW || !p_shd) && y >= p_ytop && (y < p_ybot || (y == p_ytop && p_ybot == p_ytop))) begin
                // SetupPolygon, single-line case: leftmost/rightmost of vertices 0, 1, n-1
                // (vxl is vertex n-1, the last one written)
                logic [3:0] vl, vr, l;
                logic [8:0] xl, xr;
                vl = 4'd0; vr = 4'd0; l = p_nv - 4'd1; xl = vx0; xr = vx0;
                if (vx1 < xl) begin vl = 4'd1; xl = vx1; end
                if (vx1 > xr) begin vr = 4'd1; xr = vx1; end
                if (vxl < xl) vl = l;
                if (vxl > xr) vr = l;
                p_dvl <= vl; p_dvr <= vr;
                // RenderShadowMaskScanline clears this line's stencil unless the
                // previously drawn polygon was a mask too
                prev_mask <= p_mask;
                clr_x <= 9'd0;
                if (p_mask && !prev_mask) st <= S_STCLR;
                else begin bk_commit <= 1'b1; st <= S_HDR; end
            end else st <= S_HDR;
        end
        S_STCLR: if (fe_quiet) begin
            // earlier pixels may still use the stencil: everything drains first
            clr_x <= clr_x + 9'd1;
            if (clr_x == 9'd255) begin bk_commit <= 1'b1; st <= S_HDR; end
        end
        // ---------------- end of line ----------------
        S_LDONE: if (LOV ? fe_out : fe_quiet) begin
            if (LOV) begin ld_pend <= 1'b1; ld_y <= y; end
            else lines_done <= y + 8'd1;
            if (y == 8'd191) st <= S_IDLE;
            else begin
                y <= y + 8'd1; y3 <= (y3 == 2'd2) ? 2'd0 : y3 + 2'd1;
                st <= S_LWAIT;
            end
        end
        S_LWAIT: begin
            // lines 0-2 are cleared here; line y >= 3 reuses the slot of
            // line y-4, which the final pass of line y-3 clears
            clr_x <= 9'd0;
            // (LOV: a clear has the write port only once the last line drained)
            if (y < 8'd3) begin if (!LOV || !ld_pend) st <= S_CLEAR; end
            else if ({1'b0, fp_done} >= {1'b0, y} - 9'd2) st <= S_LREQ;
        end
        default: st <= S_IDLE;
        endcase
        end
    end

    // profiling: 1 clear, 2 stream, 3 waiting on the edge units, 4 on the
    // span stage, 5 on the pixel pipeline (incl. the end-of-line drain),
    // 6 on the final pass
    always_comb begin
        case (st)
            S_CLEAR: dbg_phase = 3'd1;
            S_STCLR: dbg_phase = 3'd3;
            S_HDR: begin
                if (!(ps_valid && bk_full)) dbg_phase = 3'd2;
                else if (!e_res)               dbg_phase = 3'd3;
                else if (ss != SS_OUT)         dbg_phase = 3'd4;
                else                           dbg_phase = 3'd5;
            end
            S_LDONE: dbg_phase = 3'd5;
            S_LWAIT: dbg_phase = 3'd6;
            S_IDLE:  dbg_phase = 3'd0;
            default: dbg_phase = 3'd2;
        endcase
    end
    assign dbg_span = (ss == SS_SP0);

    // ---------------- span descriptor from the span stage ----------------
    // the three span parts as segments [sb, se): part 1 from xs (skipped
    // unless filled), part 2 from where part 1 ended (skipped for wireframe
    // inside), part 3 from where part 2 ended (if filled). The limits are
    // registered in SS_ATTR (xs/xe and the edge lengths are final), the
    // segment starts in SS_RCP (the fill rules are final)
    logic signed [11:0] g_lim1, g_lim2, g_lim3, g_x1, g_x2;
    logic signed [11:0] r_lim1, r_lim2, r_lim3;
    logic signed [11:0] p_l1, p_l2, p_xe1;   // xs + l_len, xe - r_len + 1, xe + 1
    logic [3:0]  g_ye;
    always_comb begin
        g_ye = (y == s_ytop) ? 4'h4 : ({1'b0, y} == {1'b0, s_ybot} - 9'd1) ? 4'h8 : 4'h0;
        // (the sums are registered in SS_ATTR's first clock, the limits from
        // them in the later ones: SS_ATTR lasts five clocks or six, and xs, xe
        // and the lengths hold through it; nds-fit #688: xe -> r_lim1 -1.1 ns)
        g_lim1 = p_l1;  if (g_lim1 > p_xe1) g_lim1 = p_xe1; if (g_lim1 > 12'sd256) g_lim1 = 12'sd256;
        g_lim2 = p_l2;  if (g_lim2 > p_xe1) g_lim2 = p_xe1; if (g_lim2 > 12'sd256) g_lim2 = 12'sd256;
        g_lim3 = p_xe1; if (g_lim3 > 12'sd256) g_lim3 = 12'sd256;
        g_x1 = (l_fill && xs > r_lim1) ? xs : r_lim1;
        g_x2 = (g_x1 > r_lim2) ? g_x1 : r_lim2;
    end
    // sg_*: registered in SS_RCP. Segment 1's start (xs) and the ends
    // (r_lim*) are the registers themselves: xs, xe and the lengths hold
    // from SS_FILL / SS_ATTR until the next take, so they are unchanged in
    // SS_OUT, the only state the raster takes fe_desc in (fe_wr)
    logic [3:0]  sg_ye;
    logic [2:0]  sg_en;
    logic signed [1:0][11:0] sg_sb;
    always_ff @(posedge clk) begin
        if (ss == SS_ATTR) begin
            p_l1 <= xs + l_len; p_l2 <= xe - r_len + 12'sd1; p_xe1 <= xe + 12'sd1;
            if (at_k != 3'd0) begin r_lim1 <= g_lim1; r_lim2 <= g_lim2; r_lim3 <= g_lim3; end
        end
`ifndef SYNTHESIS
        // the limits as one clock's formula from xs, xe and the lengths
        if (!rst && ss == SS_RCP) begin
            logic signed [11:0] o1, o2, o3;
            o1 = xs + l_len;          if (o1 > xe + 12'sd1) o1 = xe + 12'sd1; if (o1 > 12'sd256) o1 = 12'sd256;
            o2 = xe - r_len + 12'sd1; if (o2 > xe + 12'sd1) o2 = xe + 12'sd1; if (o2 > 12'sd256) o2 = 12'sd256;
            o3 = xe + 12'sd1;         if (o3 > 12'sd256) o3 = 12'sd256;
            if ({r_lim1, r_lim2, r_lim3} != {o1, o2, o3})
                $error("gpu3d_front: span limits %0d %0d %0d, the formula gives %0d %0d %0d", r_lim1, r_lim2, r_lim3, o1, o2, o3);
        end
`endif
        if (ss == SS_RCP) begin
            sg_ye <= g_ye;
            sg_en <= {r_fill, !(s_wire && g_ye == 0), l_fill};
            sg_sb <= {g_x2, g_x1};
        end
    end
    always_comb begin
        fe_desc = '0;
        fe_desc.attr = s_attr; fe_desc.texparam = s_texparam; fe_desc.texpal = s_texpal;
        fe_desc.facing = s_facing; fe_desc.wbuf = s_wbuf; fe_desc.lin = linx;
        fe_desc.yedge = sg_ye;
        fe_desc.xs = xs;
        fe_desc.en = sg_en;
        fe_desc.sb = {sg_sb, xs};
        fe_desc.se = {r_lim3, r_lim2, r_lim1};
        // DS_XPERSP16: the X factor uses w >> 8 when either w is >= 0x8000
        // (the linear test above keeps the full w)
        // (not on W-buffered polygons: hwref run 20, wbuf_* panels)
        if (DS_XPERSP16 && !s_wbuf && (wl[15] || wr[15])) begin fe_desc.wl = wl >> 8; fe_desc.wr = wr >> 8; end
        else begin fe_desc.wl = wl; fe_desc.wr = wr; end fe_desc.xdiff = xdiffx; fe_desc.xrecip = xrecipx;
        fe_desc.alt = a_alt; fe_desc.abase = a_base; fe_desc.ad = a_ad;
        fe_desc.toon = s_toon; fe_desc.talt = t_alt; fe_desc.tbase = t_base; fe_desc.tad = 10'(t_ad);
        // RECIP: the reciprocal travels in the quotient fields
        fe_desc.aqs = RECIP ? 80'(lr_q) : lq; fe_desc.ars = RECIP ? '0 : lr;
        fe_desc.zlt = zl < zr;
        fe_desc.zbase = (zl < zr) ? zl : zr;
        fe_desc.dz = (zl < zr) ? zr - zl : zl - zr;
        fe_desc.l_cinc = sw ? e_xcovinc[1] : ec0; fe_desc.r_cinc = sw ? ec0 : e_xcovinc[1];
        fe_desc.l_covx = l_covx; fe_desc.l_cstart = l_cstart; fe_desc.l_cov5 = l_cov5;
        fe_desc.r_covx = r_covx; fe_desc.r_cstart = r_cstart; fe_desc.r_cov5 = r_cov5;
        fe_desc.lp = y[0];
    end
    assign fe_wr = (ss == SS_OUT) && !s_drop && !nx_full;
    // the span stage's divider use: coverage (SS_EPM -> SS_EPW), linear steps
    // (SS_RCP, SS_LX)
    assign f_dv_req  = (ss == SS_EPM && ep_go) || (ss == SS_RCP && linx && !RECIP);
    assign f_dv_hold = ed_start || (ss == SS_EPW && ep_go) || ss == SS_LX;

    assign st_clr = (st == S_STCLR) && fe_quiet;
    assign frame_go = (st == S_IDLE) && frame_start && !ld_pend;
endmodule
