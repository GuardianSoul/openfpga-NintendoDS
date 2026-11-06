// Final pass of gpu3d_raster (ScanlineFinalPass): edge marking, fog and
// anti-aliasing of line f once line f+1 is rendered, nine cycles per pixel,
// clearing line f-1 (whose ring slot line f+3 reuses) as it goes. Owns the
// fog-density and edge-colour tables.
module gpu3d_fpass #(
    parameter bit DS_AA0 = 1,         // see gpu3d_raster
    // 0 (gpu3d_raster FEAT_FOG = 0): no fog datapath. DISPCNT's fog bits then read 0, so the
    // density chain is dead, but it feeds the lanes AA shares, and synthesis keeps it unless
    // it is cut here (Yosys, AA on: -282 cells, -214 FF, -3 DSP multipliers, the two tables)
    parameter bit FOG = 1,
    // FPSKIP: a pixel skips the fog steps the frame does not use: without
    // fog (DISP3DCNT bit 7) F_FT, F_4W and F_4 (F_EM sets the colours as they
    // would without fog), without AA (bit 4) the lower layer's fog (F_4W,
    // F_4: its colour is only seen through AA). 9 -> 6 or 7 clocks a pixel
    parameter bit FPSKIP = 0,
    // FPCLR: the clear of line f-1 at x waits from F_3 on (its read is taken
    // then) for a clock the renderer does not write, not from F_5: F_5 holds
    // only while it is still waiting
    parameter bit FPCLR = 0,
    // TR3 (gpu3d_raster, no edge marking): the line buffers are three slots
    // (line mod 3); the pass clears its own line at x (it has read it), not
    // the line above, whose slot holds the line two below now
    parameter bit TR3 = 0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [15:0]  dispcnt,
    input  logic [31:0]  clear_attr1,
    input  logic [14:0]  clear_depth,
    input  logic [20:0]  fog_color,
    input  logic [14:0]  fog_offset,
    input  logic         tbl_we,
    input  logic [1:0]   tbl_sel,
    input  logic [4:0]   tbl_addr,
    input  logic [14:0]  tbl_data,
    input  logic         frame_go,
    input  logic [7:0]   lines_done,
    // line buffer (its own read copies, address {slot, x}): reads of lines
    // fp_y-1, fp_y, fp_y+1, and a clear of line fp_y-1 at fp_x when granted
    output logic [9:0]   top_raddr,
    output logic [9:0]   bot_raddr,
    input  logic [70:0]  top_q,
    input  logic [70:0]  bot_q,
    output logic         fp_clr_req,
    output logic [9:0]   fp_clr_addr,
    input  logic         fp_clr_ack,
    input  logic         px_hold,       // the pixel may not go out yet (3D ring staging: nds_gpu3d YLIM2)
    output logic [7:0]   fp_y,
    output logic [7:0]   fp_done,
    output logic         fp_run,
    output logic         fp_act,        // a line in progress (its reads)
    output logic         frame_done,
    output logic         px_valid,
    output logic [7:0]   px_x,
    output logic [7:0]   px_y,
    output logic [22:0]  px_color
);
    localparam int LW = 71;   // {attr (packed) 24, depth 24, colour 23}
    function automatic [5:0] exp5(input [4:0] c);  // 5-bit -> 6-bit colour
        exp5 = (c != 0) ? {c, 1'b1} : 6'd0;
    endfunction
    function automatic [5:0] lerp6(input [5:0] base, input [16:0] p, input [3:0] k);
        lerp6 = 6'($signed({1'b0, base}) + ($signed(p) >>> k));
    endfunction
    // line-buffer entry fields
    // The attribute keeps only the bits any write can set (0-4, 8-12, 15,
    // 16-22, 24-29), packed to 24.
    function automatic [23:0] a_pack(input [31:0] a);
        a_pack = {a[29:24], a[22:16], a[15], a[12:8], a[4:0]};
    endfunction
    function automatic [31:0] a_unpack(input [23:0] p);
        a_unpack = {2'b0, p[23:18], 1'b0, p[17:11], p[10], 2'b0, p[9:5], 3'b0, p[4:0]};
    endfunction
    function automatic [22:0] e_color(input [LW-1:0] e); e_color = e[22:0];  endfunction
    function automatic [23:0] e_depth(input [LW-1:0] e); e_depth = e[46:23]; endfunction
    function automatic [31:0] e_attr (input [LW-1:0] e); e_attr  = a_unpack(e[70:47]); endfunction
    function automatic [5:0]  e_pid  (input [LW-1:0] e); e_pid   = e[70:65]; endfunction

    // ------------------------------------------------------------------
    // tables
    // ------------------------------------------------------------------
    // edge colours: an MLAB read combinationally (nds-fit #433 built the
    // inferred array as 120 flops and a mux); the toon table is a RAM in the
    // pipeline, P14
    logic [2:0]  et_ra;
    logic [14:0] et_q;
    gpu3d_lram #(.W(15), .AW(3)) u_edge_tbl (.clk, .we(tbl_we && tbl_sel == 2'd1), .waddr(tbl_addr[2:0]),
        .wdata(tbl_data), .raddr(et_ra), .rdata(et_q));
    // fog density table: one copy (entry k at address k), read twice a
    // layer: T[id] the clock the index is formed, then T[id-1] (T[0] for id
    // 0, T[0] below the offset, T[31] for id >= 32: the off-table entries)
    logic [6:0]  fog_q;
    logic [4:0]  fog_a;
    wire         fog_we = FOG && tbl_we && tbl_sel[1];
    gpu3d_ram #(.W(7), .AW(5), .STYLE("MLAB")) u_fog (
        .clk, .we(fog_we), .waddr(tbl_addr), .wdata(tbl_data[6:0]), .raddr(fog_a), .rdata(fog_q));

    wire [23:0] clearz = {clear_depth, 9'h1FF};
    wire [5:0]  clear_pid = clear_attr1[29:24];

    // final pass, its own engine running beside the renderer: line f starts
    // once line f+1 is rendered, and clears line f-1 (slot of f+3) as it goes.
    // Nine cycles per pixel: the three top-layer reads (line above, line
    // below, next pixel) go out one per cycle and are latched.
    typedef enum logic [3:0] {
        F_IDLE, F_0, F_1, F_2, F_3, F_3B, F_4A, F_EM, F_FT, F_4W, F_4, F_5
    } fstate_t;
    fstate_t     fst;
    logic [7:0]  fp_x;
    // TR3: three slots (line mod 3; the line above is not kept: no edge marking)
    // (fy3 = fp_y mod 3 and fd3 = fp_done mod 3, counted with them: the slot is
    // a register, not a mod 3 of fp_y in the address path, fit #1020)
    logic [1:0]  fy3, fd3;
    wire  [1:0]  fy3_n = (fy3 == 2'd2) ? 2'd0 : fy3 + 2'd1;
    wire  [1:0]  fp_sl = TR3 ? fy3 : fp_y[1:0];
    wire  [1:0]  fp_up = TR3 ? ((fy3 == 2'd0) ? 2'd2 : fy3 - 2'd1) : fp_y[1:0] - 2'd1;
    wire  [1:0]  fp_dn = TR3 ? fy3_n : fp_y[1:0] + 2'd1;
    logic [LW-1:0] fp_cur, fp_prev, fp_nxt, fp_upe, fp_dne, fp_bot;
    // the neighbours (left, above, below) are only compared by polygon ID and
    // depth, and the lower layer only gives colour, depth and its fog flag:
    // the other bits are latched as 0, so they need no registers
    localparam logic [LW-1:0] M_NB  = {6'h3F, 18'h0, 24'hFFFFFF, 23'h0};
    localparam logic [LW-1:0] M_BOT = {13'h0, 1'b1, 10'h0, 24'hFFFFFF, 23'h7FFFFF};

    always_comb begin
        case (fst)
            F_0:     top_raddr = {fp_sl, 8'd0};
            F_2:     top_raddr = {fp_up, fp_x};
            F_3:     top_raddr = {fp_dn, fp_x};
            default: top_raddr = {fp_sl, 8'(fp_x + 8'd1)};
        endcase
        bot_raddr = {fp_sl, fp_x};
    end
    assign fp_act = fst != F_IDLE;
    logic        clr_p;               // FPCLR: the clear of x is waiting
    assign fp_clr_req  = FPCLR ? clr_p : (fst == F_5);
    assign fp_clr_addr = {TR3 ? fp_sl : fp_up, fp_x};

    // ---- final pass (ScanlineFinalPass), nine cycles per pixel ----
    // CalculateFogDensity: RenderFogDensityTable[0] = T[0], [k] = T[k-1] for
    // k = 1..32, so entry id is T[id-1] (T[0] for id 0), entry id+1 is T[id].
    // density = T0 + (((T1-T0) * frac) >>> 17) (exact: T0*0x20000 is a
    // multiple of 2^17); the product runs on the final pass's own multiplier.
    // per layer (top from fp_cur at F_2, lower layer from fp_bot at F_3B):
    // index and fraction registered, T[id] read; next clock T0 read; then
    // T1 - T0, the product, the density (top by F_EM, lower by F_4W)
    logic [23:0] fd_z;
    assign fd_z = (fst == F_3B) ? e_depth(fp_bot) : e_depth(fp_cur);
    logic [14:0] fz_id;
    logic [16:0] fz_frac;
    logic        fz_lt;               // depth below the fog offset
    // density as one multiply-add: (T1-T0) * frac + T0 << 17, >>> 17 (the
    // T0 of the same pixel and layer is still in fr_t0 when fm_p is used)
    logic signed [7:0] fm_a;
    logic [16:0] fm_b;
    // ((z - offset) >> 2) << shift, as a multiply by 1 << shift (a DSP block,
    // not a barrel shifter). Only z >= offset uses it, so the operand is the
    // 22-bit non-negative difference; the product keeps the 32-bit wrap. The
    // subtract's borrow is "below the offset".
    logic [31:0] fd_zz;
    wire  [24:0] fd_dif = {1'b0, fd_z} - {1'b0, fog_offset, 9'h0};
    wire         fd_lt = fd_dif[24];
    assign fd_zz = 32'(fd_dif[23:2] * (16'd1 << dispcnt[11:8]));
    // table reads: T[id] with the index (F_2 top, F_3B lower layer), then
    // T[id-1] or the off-table entry from the registered index (F_3, F_4A)
    wire         fz_spec = fz_lt || (fz_id >= 32);
    always_comb
        if (fst == F_3 || fst == F_4A)
            fog_a = fz_lt ? 5'd0 : (fz_id >= 32) ? 5'd31 : (fz_id == 15'd0) ? 5'd0 : 5'(fz_id - 15'd1);
        else
            fog_a = fd_zz[21:17];
    logic        fr_spec;
    logic [6:0]  fr_t0, fr_t1;    // T0 (or the off-table entry), T1
    logic signed [7:0] fq_dd;
    wire  signed [25:0] fm_p = 26'(fm_a * $signed({1'b0, fm_b})) + $signed({2'b0, fr_t0, 17'd0});
    logic [16:0] fq_frac;
    logic [7:0]  fog_d;           // density for the step after the multiply
    logic [7:0]  fog_dt, fog_db;  // ... registered: top, lower layer
    logic [22:0] fp_ecol;         // top colour after edge marking
    always_comb begin
        logic [7:0] dens;
        dens = fr_spec ? {1'b0, fr_t0} : 8'(fm_p >>> 17);
        fog_d = (dens >= 127) ? 8'd128 : dens;
    end
    function automatic [22:0] fog_mix(input [22:0] c, input [16:0] p0, input [16:0] p1,
                                      input [16:0] p2, input [16:0] p3, input alpha_only);
        logic [4:0] a;
        a = 5'($signed({1'b0, c[22:18]}) + ($signed(p3) >>> 7));
        fog_mix = alpha_only ? {a, c[17:0]}
                             : {a, lerp6(c[17:12], p2, 7), lerp6(c[11:6], p1, 7), lerp6(c[5:0], p0, 7)};
    endfunction

    logic [22:0]   fp_col, fp_bcol;
    logic [31:0]   fp_attr;
    // edge marking of the current pixel: one neighbour per cycle as its
    // read arrives (F_3 left, F_3B above, F_4A below, F_EM right; the clear
    // values off the screen edge), accumulated in em_acc
    logic [22:0]   em_col;
    logic [31:0]   em_attr;
    logic          em_acc, em_hit;
    always_comb begin
        logic [5:0]  npid;
        logic [23:0] nz;
        logic        off;
        case (fst)
            F_3:     begin off = fp_x == 0;      npid = e_pid(fp_prev); nz = e_depth(fp_prev); end
            F_3B:    begin off = fp_y == 0;      npid = e_pid(fp_upe);  nz = e_depth(fp_upe);  end
            F_4A:    begin off = fp_y == 8'd191; npid = e_pid(fp_dne);  nz = e_depth(fp_dne);  end
            default: begin off = fp_x == 8'd255; npid = e_pid(fp_nxt);  nz = e_depth(fp_nxt);  end
        endcase
        if (off) begin npid = clear_pid; nz = clearz; end
        em_hit = (e_pid(fp_cur) != npid) && (e_depth(fp_cur) < nz);
    end
    always_comb begin
        logic [5:0]  pid;
        logic        em;
        logic [14:0] ec;
        ec = '0;
        em_attr = e_attr(fp_cur); em_col = e_color(fp_cur); pid = em_attr[29:24];
        et_ra = pid[5:3];
        em = dispcnt[5] && em_attr[3:0] != 0 && (em_acc || em_hit);
        if (em) begin
            ec = et_q;
            em_col = {em_col[22:18], exp5(ec[14:10]), exp5(ec[9:5]), exp5(ec[4:0])};
            em_attr[12:8] = 5'h10;
        end
    end
    // AA blend of fp_col over fp_bcol (F_5)
    logic [22:0] fp_out;
    // colour being fogged (top in F_FT, lower layer in F_4) and the result
    wire [22:0] fog_c = (fst == F_FT) ? fp_ecol : e_color(fp_bot);
    // the final pass's own four lanes: fog (F_FT top, F_4 bottom), AA (F_5)
    logic [3:0][7:0]  fl_x, fl_f;
    logic [3:0][16:0] fl_p;
    wire [22:0] fog_out = fog_mix(fog_c, fl_p[0], fl_p[1], fl_p[2], fl_p[3], dispcnt[6]);
    genvar gv_g_flane;
    generate
    for (gv_g_flane = 0; gv_g_flane < 4; gv_g_flane = gv_g_flane + 1) begin : g_flane
        assign fl_p[gv_g_flane] = 17'($signed(fl_x[gv_g_flane]) * $signed({1'b0, fl_f[gv_g_flane]}));
    end
    endgenerate
    always_comb begin
        logic [4:0] cov;
        fp_out = fp_col;
        cov = fp_attr[12:8];
        if (dispcnt[4] && fp_attr[3:0] != 0) begin
            // coverage 0: the lower pixel; on the DS (DS_AA0) only an opaque one,
            // over a transparent one the blend keeps the top colour, alpha 0
            if (cov == 0) fp_out = (!DS_AA0 || fp_bcol[22:18] != 0) ? fp_bcol : {5'd0, fp_col[17:0]};
            else if (cov != 5'h1F) begin
                if (fp_bcol[22:18] != 0)
                    fp_out[17:0] = {lerp6(fp_bcol[17:12], fl_p[2], 5), lerp6(fp_bcol[11:6], fl_p[1], 5),
                                    lerp6(fp_bcol[5:0], fl_p[0], 5)};
                fp_out[22:18] = 5'($signed({1'b0, fp_bcol[22:18]}) + ($signed(fl_p[3]) >>> 5));
            end
        end
    end
    always_comb begin
        logic [22:0] fc6, c;
        fc6 = {fog_color[20:16], exp5(fog_color[14:10]), exp5(fog_color[9:5]), exp5(fog_color[4:0])};
        c = fog_c;
        fl_x = '0; fl_f = '0;
        if (fst == F_5) begin           // AA: (top - bottom) * (coverage + 1)
            fl_x[0] = 8'(fp_col[5:0])   - 8'(fp_bcol[5:0]);
            fl_x[1] = 8'(fp_col[11:6])  - 8'(fp_bcol[11:6]);
            fl_x[2] = 8'(fp_col[17:12]) - 8'(fp_bcol[17:12]);
            fl_x[3] = 8'(fp_col[22:18]) - 8'(fp_bcol[22:18]);
            for (int i = 0; i < 4; i++) fl_f[i] = 8'(fp_attr[12:8]) + 8'd1;
        end else if (FOG) begin         // fog: (fog - c) * density
            fl_x[0] = 8'(fc6[5:0])   - 8'(c[5:0]);
            fl_x[1] = 8'(fc6[11:6])  - 8'(c[11:6]);
            fl_x[2] = 8'(fc6[17:12]) - 8'(c[17:12]);
            fl_x[3] = 8'(fc6[22:18]) - 8'(c[22:18]);
            for (int i = 0; i < 4; i++) fl_f[i] = (fst == F_FT) ? fog_dt : fog_db;
        end
    end

    // ------------------------------------------------------------------
    // final pass engine (ScanlineFinalPass), nine cycles per pixel
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        px_valid   <= 1'b0;
        frame_done <= 1'b0;
        if (fp_clr_ack) clr_p <= 1'b0;
        if (rst) begin
            fst <= F_IDLE;
            fp_run <= 1'b0;
            clr_p <= 1'b0;
        end else if (frame_go) begin
            fp_done <= 8'd0; fd3 <= 2'd0;
            fp_run <= 1'b1;
        end else case (fst)
        F_IDLE: begin
            // line f needs line f+1 rendered (or f = 191 and the frame done)
            if (fp_run && fp_done != 8'd192 &&
                ({1'b0, lines_done} >= {1'b0, fp_done} + 9'd2 || lines_done == 8'd192)) begin
                fp_y <= fp_done; fy3 <= fd3;
                fst <= F_0;
            end
        end
        F_0: fst <= F_1;                  // read x = 0 of the line
        F_1: begin
            fp_cur <= top_q;
            fp_prev <= '0;
            fp_x <= 8'd0;
            fst <= F_2;
        end
        F_2: begin
            // read the line above and the lower layer; top fog table index
            fz_id <= fd_zz[31:17]; fz_frac <= fd_zz[16:0]; fz_lt <= fd_lt;
            if (FPCLR) clr_p <= 1'b1;            // up at x is read: its clear may go from F_3 on
            fst <= F_3;
        end
        F_3: begin
            // read the line below; top fog table lookup
            em_acc <= em_hit;
            fp_upe <= top_q & M_NB;
            fp_bot <= bot_q & M_BOT;
            fr_t1 <= fog_q; fq_frac <= fz_frac; fr_spec <= fz_spec;     // top: T1
            fst <= F_3B;
        end
        F_3B: begin
            // read x+1; top fog density product; lower-layer table index
            em_acc <= em_acc || em_hit;
            fp_dne <= top_q & M_NB;
            fr_t0 <= fog_q; fq_dd <= $signed(8'(fr_t1) - 8'(fog_q));    // top: T0, T1 - T0
            fz_id <= fd_zz[31:17]; fz_frac <= fd_zz[16:0]; fz_lt <= fd_lt;
            fst <= F_4A;
        end
        F_4A: begin
            // top density; lower-layer table lookup
            em_acc <= em_acc || em_hit;
            fp_nxt <= top_q;
            fm_a <= fq_dd; fm_b <= fq_frac;                             // top density product
            fr_t1 <= fog_q; fq_frac <= fz_frac;                         // lower layer: T1
            fst <= F_EM;
        end
        F_EM: begin
            // lower-layer density product
            fp_attr <= em_attr;
            fp_ecol <= em_col;
            fog_dt <= fog_d;                                            // top density
            fr_t0 <= fog_q; fq_dd <= $signed(8'(fr_t1) - 8'(fog_q)); fr_spec <= fz_spec;   // lower: T0
            if (FPSKIP && !(FOG && dispcnt[7])) begin
                fp_col <= em_col;                // F_FT's colour without fog
                fp_bcol <= e_color(fp_bot);      // F_4's
                fst <= F_5;
            end else fst <= F_FT;
        end
        F_FT: begin
            // fog on the top pixel; lower-layer density
            fp_col <= (FOG && dispcnt[7] && fp_attr[15]) ? fog_out : fp_ecol;
            fm_a <= fq_dd; fm_b <= fq_frac;                             // lower-layer density product
            fst <= (FPSKIP && !dispcnt[4]) ? F_5 : F_4W;               // (the lower layer: AA only)
        end
        F_4W: begin
            fog_db <= fog_d;                                            // lower-layer density
            fst <= F_4;
        end
        F_4: begin
            // fog on the lower pixel (only seen through AA)
            fp_bcol <= (FOG && dispcnt[7] && fp_attr[3:0] != 0 && fp_bot[47+10])   // fog flag: attr bit 15, packed bit 10
                     ? fog_out
                     : e_color(fp_bot);
            fst <= F_5;
        end
        F_5: if (!px_hold && (FPCLR ? (!clr_p || fp_clr_ack) : fp_clr_ack)) begin
            // output; the line above is no longer needed at x: cleared now
            // (the request waits while the renderer writes)
            px_valid <= 1'b1;
            px_x <= fp_x;
            px_y <= fp_y;
            px_color <= fp_out;
            fp_prev <= fp_cur & M_NB;
            fp_cur <= fp_nxt;
            fp_x <= fp_x + 8'd1;
            if (fp_x == 8'd255) begin
                fp_done <= fp_y + 8'd1; fd3 <= fy3_n;
                if (fp_y == 8'd191) begin
                    frame_done <= 1'b1;
                    fp_run <= 1'b0;
                end
                fst <= F_IDLE;
            end else fst <= F_2;
        end
        default: fst <= F_IDLE;
        endcase
    end

endmodule
