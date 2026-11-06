// NDS geometry engine datapath (docs/geometry-engine.md): a scalar
// microcoded engine that runs the GX entries the timing model
// (gpu3d_gxfront) has executed, bit-exact against melonDS's GPU3D.cpp.
// All command state (matrices, stacks, lights, vertices, clip lists,
// polygon state) lives in the register file; the logic is one ALU, one
// multiply-accumulate unit and the divider.
//
// Pipeline, one microinstruction per cycle:
//   I  issue    sequencer; register-file read addresses (base + index
//               register) for ports A and B; write address; index and loop
//               counter operations (control slice A)
//   O  operand  operand selection, ALU -> R, MAC operands, divider start
//               (control slice B)
//   M           R -> register file and outputs; 32x32 product
//   A           64-bit accumulator
// Latencies: tools/gxasm/isa.py (the assembler enforces them).
//
// Register file: 2048 x 32, two copies for two read ports. Layout:
// tools/gxasm/ucode.py.
module gpu3d_gxeng #(
    // Area/speed trades of the geometry engine, switchable back (docs/geometry-engine.md, "SMALL"):
    // 0: the first version, 1: the smaller one (cycle-equivalent unless a trade states otherwise)
    parameter bit SMALL = 1'b1,
    // 1: the DS's strip rule, no vertex sharing after a clipped polygon (hwref runs 15-19); 0: melonDS's
    parameter bit DS_STRIPCLIP = 1'b1,
    // 1: the DS's far plane, a strip polygon reusing two vertices is rejected too (hwref rand3d); 0: melonDS's,
    // which keeps the reused pair as a polygon of 2 vertices
    parameter bit DS_FARREJ = 1'b1,
    // 1: the DS's clipper interpolates red without the colour fill (hwref rules3d clip_col); 0: melonDS's
    parameter bit DS_CLIPRED = 1'b1,
    // 1: the polygon sort in microcode with the sort tables here (so_*; ucode.py USORT, the control store
    // gpu3d_gxrom_us); 0: gpu3d_gxsort beside the engine (ks_*, sort_*)
    parameter bit USORT = 1'b0,
    // 1 (with USORT): the lighting unit gpu3d_gxlight computes NORMAL's colour beside the engine
    // (the control store gpu3d_gxrom_ul); while it works the engine dispatches only LU_SAFE commands
    parameter bit LUNIT = 1'b0,
    // 1: the vertex-finish unit gpu3d_gxvfin (with LUNIT): VPV's final colour, beat words and bounds beside the
    // engine (docs/geometry-engine.md, item D; the control store gpu3d_gxrom_uv)
    parameter int VFIN = 0,          // 2: VFIN-lite (gpu3d_gxvfin BOUNDS = 0; the control store gpu3d_gxrom_uw)
    parameter bit DIV_R4 = 1'b0,        // the divider takes two quotient bits per clock (gpu3d_gxdiv R4)
    parameter bit DIV_P2X = 1'b0,       // with DIV_R4: from one subtractor on clk_2x (gpu3d_gxdiv P2X)
    // 1 (with USORT, LUNIT and VFIN 1): the geometry redesign (docs/geometry-redesign.md): attribute latches, the
    // dispatcher's COLOR / TEXCOORD / vertex commands, the vector MAC, the polygon unit (PU below; the control store
    // gpu3d_gxrom_uf)
    parameter bit FF = 1'b0,
    // VC_M10K (SMALL): the outcode unit's x, y, z (u_vc, 2 MLAB LABs in #886) in an M10K read two clocks
    // ahead (the stepper's position two clocks on, from the word in M) into its output register; 0: MLAB
    parameter bit VC_M10K = 1'b1,
    // STK_M10K (SMALL): the return stack (u_stk, 1 MLAB LAB in #886) in an M10K read at the top the next
    // clock has (ssp after this clock's CALL or RET); 0: MLAB
    parameter bit STK_M10K = 1'b1,
    // VOC_M10K: the outcode table u_voc (1 MLAB LAB in #886) in an M10K: the same registered read at xr1
    // (old data on a same-address write, which the MLAB left undefined); 0: MLAB
    parameter bit VOC_M10K = 1'b1
) (
    input  logic         clk,
    input  logic         clk_2x,        // DIV_P2X: 2 x clk, rising with it
    input  logic         rst,
    // entries
    output logic [8:0]   e_addr,
    input  logic [39:0]  e_data,
    input  logic [8:0]   mx,
    input  logic         e_avail,       // gpu3d_gxfront: an entry the model executed is ready (dp != mx, or SPILL's)
    output logic         e_pop,         // the engine pops an entry this clock (gpu3d_gxfront SPILL counts it)
    input  logic         e_more,        // gpu3d_gxfront: entries the model executed are not all popped (idle needs none)
    output logic [8:0]   dp,
    input  logic [23:0]  zerodot,
    input  logic         swap_go,       // VBlank with a flush pending
    output logic         swap_ack,
    // polygon outcomes to the timing model
    output logic         oc_valid,
    output logic         oc_rej,
    output logic         oc_quad,
    // GXSTAT, RAM counts, DISP3DCNT overflow
    output logic         boxres,
    output logic         test_done,     // a test command's results are in
    output logic [11:0]  npoly,
    output logic [12:0]  nvert,
    output logic         ovf_set,
    // register-file-backed reads (clip/vector matrix, test results)
    input  logic         mrd_req,
    input  logic [4:0]   mrd_sel,
    output logic         mrd_ack,
    output logic [31:0]  mrd_data,      // R: the result in the clock mrd_cap is high (gpu3d_geom captures it)
    output logic         mrd_cap,
    // polygon records: header beat then vertex beats (gpu3d_raster ps_* format)
    output logic         po_valid,
    input  logic         po_ready,
    input  logic         s_draw,        // the polygon store draws a frame from its on-chip lists: a swap's sort output waits
    output logic         po_type,       // 0 header, 1 vertex
    output logic [127:0] po_data,
    output logic [10:0]  po_index,
    output logic         po_wv,         // the output word po_wk (0..3 of po_data) is written with po_wd
    output logic [1:0]   po_wk,
    output logic [31:0]  po_wd,
    // sort keys and start
    output logic         ks_we,
    output logic [10:0]  ks_idx,
    output logic [16:0]  ks_key,        // {translucent, ybot, ytop}
    output logic         sort_go,
    output logic         sort_manual,
    output logic [11:0]  sort_n,
    input  logic         sort_busy,
    // USORT: the sorted order, as gpu3d_gxsort's
    output logic         so_we,
    output logic [10:0]  so_pos,
    output logic [10:0]  so_idx,
    output logic         so_done,
    // test bench
    output logic [10:0]  dbg_upc,
    output logic         idle           // waiting for an entry, nothing in flight
);
    import gpu3d_gxu_pkg::*;

    // ------------------------------------------------------------------
    // control store
    // ------------------------------------------------------------------
    logic [10:0]     upc, upc_n;
    logic [A_W-1:0]  ua;
    logic [B_W-1:0]  ub;
    // slice B is read one cycle early and registered: the operand stage gets
    // its fields from flip-flops (the same cycle as reading it at upc); SMALL:
    // that register is the M10K's output register (gpu3d_gxrom B2)
    logic [B_W-1:0]  ub_q, ub_p;
    // slice B stores its immediate, with its mode applied, as an index (B_IMI) into the image's table of
    // distinct 32-bit operands (tools/gxasm emit, which checks every word): the control store reads the
    // table, an M10K ROM, at ub_n's index, so t_imm is ub's operand (the mode mux and a register gone)
    logic [B_IMI_W-1:0] imi_n;
    logic [IMX_W-1:0]   t_imm;
    generate if (FF) begin : g_romf
        gpu3d_gxrom_uf #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end else if (VFIN == 2) begin : g_romw
        gpu3d_gxrom_uw #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end else if (VFIN != 0) begin : g_romv
        gpu3d_gxrom_uv #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end else if (LUNIT) begin : g_roml
        gpu3d_gxrom_ul #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end else if (USORT) begin : g_romu
        gpu3d_gxrom_us #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end else begin : g_rom
        gpu3d_gxrom #(.B2(SMALL)) u_rom (.clk, .a_addr(upc_n), .a_q(ua), .b_addr(upc_n), .b_q(ub_q), .b_p(ub_p), .t_idx(imi_n), .t_imm(t_imm));
    end endgenerate
    // ub_n: the word ub takes at the next clock (the operand-stage decodes below are registered from it)
    wire [B_W-1:0] ub_n = SMALL ? ub_p : ub_q;
    assign imi_n = B_IMI_W'((ub_n >> B_IMI_LO) & ((B_W'(1) << B_IMI_W) - 1));
    generate if (SMALL) begin : g_ub
        assign ub = ub_q;
    end else begin : g_ubr
        always_ff @(posedge clk) ub <= ub_q;
    end endgenerate
    assign dbg_upc = upc;

    function automatic [31:0] fa(input [A_W-1:0] w, input int lo, input int wd);
        fa = 32'((w >> lo) & ((64'd1 << wd) - 1));
    endfunction
    function automatic [31:0] fb(input [B_W-1:0] w, input int lo, input int wd);
        fb = 32'((w >> lo) & ((64'd1 << wd) - 1));
    endfunction

    wire [2:0]  a_nx   = fa(ua, A_NX_LO, A_NX_W);
    wire [10:0] a_tgt  = fa(ua, A_TGT_LO, A_TGT_W);
    wire [4:0]  a_cond = fa(ua, A_COND_LO, A_COND_W);
    wire [10:0] a_ra   = fa(ua, A_RA_LO, A_RA_W);
    wire [1:0]  a_rax  = fa(ua, A_RAX_LO, A_RAX_W);
    wire [10:0] a_rb   = fa(ua, A_RB_LO, A_RB_W);
    wire [1:0]  a_rbx  = fa(ua, A_RBX_LO, A_RBX_W);
    wire [10:0] a_wa   = fa(ua, A_WA_LO, A_WA_W);
    wire [1:0]  a_wx   = fa(ua, A_WX_LO, A_WX_W);
    wire        a_we   = fa(ua, A_WE_LO, A_WE_W);
    wire [2:0]  a_xop  = fa(ua, A_XOP_LO, A_XOP_W);
    wire [7:0]  a_xarg = fa(ua, A_XARG_LO, A_XARG_W);

    wire [3:0]  b_xs   = fb(ub, B_XS_LO, B_XS_W);
    wire [1:0]  b_ys   = fb(ub, B_YS_LO, B_YS_W);
    wire [4:0]  b_aop  = fb(ub, B_AOP_LO, B_AOP_W);
    wire        b_fl   = fb(ub, B_FL_LO, B_FL_W);
    wire        b_ma   = fb(ub, B_MA_LO, B_MA_W);
    wire [1:0]  b_mb   = fb(ub, B_MB_LO, B_MB_W);
    wire [2:0]  b_acc  = fb(ub, B_ACC_LO, B_ACC_W);
    wire [2:0]  b_xsh  = fb(ub, B_XSH_LO, B_XSH_W);
    wire [3:0]  b_out  = fb(ub, B_OUT_LO, B_OUT_W);
    // the divider's operation and quotient width as one code (isa.DV): 0 none, 1..4 D64 with 10/16/32/64
    // quotient bits, 5..7 D32 with 10/16/32
    wire [2:0]  b_dv   = fb(ub, B_DV_LO, B_DV_W);
    wire [1:0]  b_div  = b_dv == 3'd0 ? 2'(DIV_NONE) : b_dv >= 3'd5 ? 2'(DIV_D32) : 2'(DIV_D64);
    wire [1:0]  b_dqb  = b_dv >= 3'd5 ? 2'(b_dv - 3'd5) : 2'(b_dv - 3'd1);

    // Operand-stage decodes, registered from ub_n beside ub (so always the decode of ub): the X and Y
    // operand selects and the ALU operation one-hot, so ub's fields reach the ALU and R without a
    // decode (#491/#492: ROM b_q -> R, fzb). A sim check below holds od == odec(ub).
    // RO_LG: the logic unit, one LUT a bit: bit {x, y} of the truth table lgt (AND, OR, XOR, BIC, and PASSX with
    // the unused codes as x)
    localparam int RO_SUM = 0, RO_LG = 1, RO_SH = 2, RO_SX16 = 3, RO_SX11 = 4, RO_MAX = 5, RO_MIN = 6,
                   RO_SLT = 7, RO_MABS = 8, RO_K4 = 9;
    typedef struct packed {
        logic [15:0] xs;               // one-hot XS (ZERO and the unused codes: none)
        logic [2:0]  ys;               // one-hot YS (ZERO: none)
        logic        sub, rsub, shl, sar, fsh;
        logic        fls;              // fl_sort (below)
        logic [9:0]  ro;               // one-hot result select (RO_*)
        logic [3:0]  lgt;              // RO_LG's truth table, indexed {x, y}
    } odec_t;
    function automatic odec_t odec(input [B_W-1:0] w);
        logic [3:0] xs;
        logic [1:0] ys;
        logic [4:0] op;
        xs = fb(w, B_XS_LO, B_XS_W);
        ys = fb(w, B_YS_LO, B_YS_W);
        op = fb(w, B_AOP_LO, B_AOP_W);
        odec = '0;
        for (int k = 0; k < 16; k++) odec.xs[k] = xs == 4'(k) && k != XS_ZERO;
        for (int k = 0; k < 3; k++) odec.ys[k] = ys == 2'(k);
        odec.sub  = op != 5'(AOP_ADD);
        odec.rsub = op == 5'(AOP_RSUB);
        odec.shl  = op == 5'(AOP_SHL);
        odec.sar  = op == 5'(AOP_SAR);
        odec.fsh  = op == 5'(AOP_FSH);
        odec.fls  = USORT && (xs == 4'(XS_SBL) || xs == 4'(XS_SCT) || xs == 4'(XS_SNX) || xs == 4'(XS_SYB));
        case (op)
            5'(AOP_ADD), 5'(AOP_SUB), 5'(AOP_RSUB): odec.ro[RO_SUM] = 1'b1;
            5'(AOP_AND):  begin odec.ro[RO_LG] = 1'b1; odec.lgt = 4'b1000; end
            5'(AOP_OR):   begin odec.ro[RO_LG] = 1'b1; odec.lgt = 4'b1110; end
            5'(AOP_XOR):  begin odec.ro[RO_LG] = 1'b1; odec.lgt = 4'b0110; end
            5'(AOP_BIC):  begin odec.ro[RO_LG] = 1'b1; odec.lgt = 4'b0100; end
            5'(AOP_SHL), 5'(AOP_SHR), 5'(AOP_SAR), 5'(AOP_FSH): odec.ro[RO_SH] = 1'b1;
            5'(AOP_SX16): odec.ro[RO_SX16] = 1'b1;
            5'(AOP_SX11): odec.ro[RO_SX11] = 1'b1;
            5'(AOP_MAX):  odec.ro[RO_MAX] = 1'b1;
            5'(AOP_MIN):  odec.ro[RO_MIN] = 1'b1;
            5'(AOP_SLT):  odec.ro[RO_SLT] = 1'b1;
            5'(AOP_MABS): odec.ro[RO_MABS] = 1'b1;
            5'(AOP_K4):   odec.ro[RO_K4] = 1'b1;
            default:      begin odec.ro[RO_LG] = 1'b1; odec.lgt = 4'b1100; end
        endcase
    endfunction
    odec_t od;
    always_ff @(posedge clk) od <= odec(ub_n);

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    logic [31:0] P;                    // param of the last popped entry
    logic [5:0]  pi;                   // ExecParamCount (parameters collected)
    logic [5:0]  pi1;                  // pi + 1
    logic [10:0] xr1, xr2, xr3;        // index registers
    logic [5:0]  lc;
    logic [10:0] stk [8];
    logic [2:0]  ssp;
    logic        dirty;                // the clip matrix needs updating
    logic [8:0]  dp_r;
    logic [31:0] R;                    // ALU result
    logic        fz, fn, fc, flt;      // ALU flags
    // Z is not registered from the ALU: fl_p marks R as the result of the last flag-setting
    // instruction, and Z is then R == 0 (fz_h holds it after) (#491/#492: ROM b_q -> fzb)
    logic        fl_p, fz_h;
    assign fz = fl_p ? R == 32'd0 : fz_h;
    logic signed [63:0] acc;
    logic        a63, az, nfit;        // accumulator flags (registered)
    logic        div_busy;
    logic [31:0] div_q;
    logic [11:0] np_r;
    logic [12:0] nv_r;
    logic        box_r;
    logic [10:0] wa_o, wa_m;           // write address in O, M
    logic        we_o, we_m;
    logic [3:0]  out_m;
    logic [2:0]  sm_m;                 // USORT: the sort-table operation (xsh with out = KEY) in M
    logic [31:0] qa, qb;               // register-file read data (O)
    logic [31:0] at_q;                 // FF: the attribute latch named by xsh (O)
    logic [1:0]  at_m;                 // FF: TEXM's latch (the dispatcher's texture-mode test)
    logic [31:0] vx_q;                 // FF: the vector MAC lane named by xsh (O)
    logic [15:0] at_v [3];             // FF: CurVertex's latch (x, y, z)
    logic [2:0]  v_row;                // FF: the vector MAC's row of the instruction in O
    logic        v_opo;                // FF: a vector MAC step in O
    logic [31:0] vm0_q;                // FF: lane 0's row (the scalar MAC is lane 0)
    logic        ffw_m, fft_m, ffv_m;  // FF: the dispatcher's latch write in M (TEXCOORD, vertex; else COLOR)
    logic [31:0] ffd_m;
    logic [15:0] ffv_d [3];
    logic [31:0] s_bl, s_ct, s_nx, s_yb;   // USORT: sort-table read data as XS operands (below)
    wire         fl_sort = od.fls;
    wire         s_sign  = b_xs == 4'(XS_SBL) ? s_bl[31] : b_xs == 4'(XS_SNX) ? s_nx[31] : b_xs == 4'(XS_SYB) ? s_yb[31] : s_ct[31];

    assign dp = dp_r;
    assign npoly = np_r;
    assign nvert = nv_r;
    assign boxres = box_r;
    wire ev_q = e_avail;
    logic lu_busy;                     // LUNIT: the lighting unit is busy
    logic vf_busy;                     // VFIN: the vertex-finish unit is busy
    // PU (FF with LUNIT): the polygon unit (below, g_pu)
    localparam bit PU = FF && LUNIT;
    logic        pu_done;               // the vertex at PSTEP completes a polygon
    logic        pu_triv;               // PTRIV: the polygon is wholly outside one plane (clipstart 0)
    logic [10:0] pu_cur;                // the group of the vertex the next vertex command transforms
    logic [10:0] pu_x1, pu_x2, pu_x3;   // a completed polygon's slots 0..2 (its groups), for X1..X3
    logic [31:0] pu_q;                  // the unit's register named by the immediate (XS = ATR, xsh 7)

    // ------------------------------------------------------------------
    // I: sequencer
    // ------------------------------------------------------------------
    logic cond;
    always_comb begin
        case (a_cond)
            C_Z:        cond = fz;
            C_N:        cond = fn;
            C_C:        cond = fc;
            C_LT:       cond = flt;
            C_BIT:      cond = R[a_xarg[4:0]];
            C_A63:      cond = a63;
            C_AZ:       cond = az;
            C_NFIT:     cond = nfit;
            C_DBUSY:    cond = div_busy;
            C_OBUSY:    cond = po_valid && !po_ready;
            // a matrix or test read is served at NOENT only with no entry waiting: NOENT is also where a waiting
            // entry's hold sends the engine (FF's CurVertex hazard, LUNIT's busy unit), and a read served there
            // overtakes the commands before it (GXSTAT, the DS timing model, already reads idle): NSMB and HG
            // read the clip matrix mid-sequence after polling GXSTAT bit 27. !e_more, not !ev_q: with SPILL, ev_q (e_avail)
            // is 0 while executed entries still wait in the gather or SDRAM ring or were written < 2 clocks ago
            C_MREQ:     cond = mrd_req && !mrd_ack && !e_more;
            C_SWAPGO:   cond = swap_go;
            C_SORTBUSY: cond = sort_busy;
            C_DIRTY:    cond = dirty;
            C_DSR:      cond = a_xarg[1] ? DS_CLIPRED : a_xarg[0] ? DS_FARREJ : DS_STRIPCLIP;   // the DS rule named by the bit argument
            C_LBUSY:    cond = lu_busy;
            C_SDRAW:    cond = s_draw;
            C_PSTEP:    cond = PU && pu_done;
            C_PTRIV:    cond = PU && pu_triv;
            C_TEX3:     cond = at_m == 2'd3;
            C_VBUSY, C_VARM: cond = vf_busy;
            default:    cond = 1'b1;
        endcase
    end

    // DISP pops the head entry. A parameter of a multi-parameter command goes
    // to PARAM + pi through this instruction's own write slot (R = P); only
    // the entry that completes the command (ExecParamCount >= CmdNumParams)
    // reaches its handler, with all its parameters in place.
    // the entry's command byte is gx_ecode (gpu3d_gxu_pkg): {multi-parameter, 0, handler entry}, so no
    // command decode lies between the entry RAM and the control-store address (#519)
    wire [5:0] e_hidx  = e_data[37:32];
    wire [5:0] hnp     = gx_np(e_hidx);
    wire       mp      = e_data[39];
    wire       mp_last = pi1 >= hnp;
    // LUNIT: an entry waits while the lighting unit works, unless its command cannot change what it reads
    // FF: a vertex command waits while a register-file write to CurVertex is in flight (POS_TEST): the
    // dispatcher decodes it against CurVertex's latch
    wire ff_isv = e_hidx == FF_HV16 || e_hidx == FF_HV10 || e_hidx == FF_HVXY || e_hidx == FF_HVXZ ||
                  e_hidx == FF_HVYZ || e_hidx == FF_HVDF;
    wire ff_cvb = (we_o && wa_o >= FF_A_CURV && wa_o < FF_A_CURV + 11'd3) ||
                  (we_m && wa_m >= FF_A_CURV && wa_m < FF_A_CURV + 11'd3);
    // LUNIT early start: a NORMAL the lighting unit already took (lu_pre) dispatches while it works
    // (a speculative one once confirmed, the clock after the check: the check's compare stays off this path);
    // lu_pk_q: e_data is the peeked entry, not the head
    logic lu_pre, lu_pk_q;
    wire ev = ev_q && !(LUNIT && lu_busy && !LU_SAFE[e_hidx] && !lu_pre) && !(FF && ff_isv && ff_cvb) &&
              !(LUNIT && lu_pk_q);
    localparam logic [10:0] DPARAM = 11'd38;   // a plain DISP (ucode.py)
    localparam logic [10:0] RESET  = 11'd40;   // ucode.py
    localparam logic [10:0] PARAM  = 11'h080;  // collected parameters (ucode.py)
    // SMALL: the return stack in an MLAB, read combinationally as the registers were
    wire [10:0] stk_top;
    generate if (SMALL && STK_M10K) begin : g_stkm
        // a CALL writes ssp and a RET pops in the same clock as the MLAB's read; ssp only moves by them,
        // so the top a RET reads is the entry below ssp as this clock leaves it. A RET right after its
        // CALL would read the entry being written (no_rw_check: the simulation returns garbage)
        wire [2:0] ssp_n = rst ? 3'd0 : ssp + 3'(a_nx == NX_CALL) - 3'(a_nx == NX_RET);
        gpu3d_ram #(.W(11), .AW(3), .STYLE("M10K, no_rw_check")) u_stk (.clk, .we(!rst && a_nx == NX_CALL), .waddr(ssp),
                                            .wdata(upc + 11'd1), .raddr(ssp_n - 3'd1), .rdata(stk_top));
`ifndef SYNTHESIS
        // synthesis translate_off
        logic [10:0] stk_s;
        gpu3d_lram #(.W(11), .AW(3)) s_stk (.clk, .we(!rst && a_nx == NX_CALL), .waddr(ssp), .wdata(upc + 11'd1),
                                            .raddr(ssp - 3'd1), .rdata(stk_s));
        always_ff @(posedge clk)
            if (!rst && a_nx == NX_RET && stk_top != stk_s)
                $error("gpu3d_gxeng STK_M10K: RET at ssp %0d: M10K %03x, MLAB %03x", ssp, stk_top, stk_s);
        // synthesis translate_on
`endif
    end else if (SMALL) begin : g_stk
        gpu3d_lram #(.W(11), .AW(3)) u_stk (.clk, .we(!rst && a_nx == NX_CALL), .waddr(ssp), .wdata(upc + 11'd1),
                                            .raddr(ssp - 3'd1), .rdata(stk_top));
    end else begin : g_stkr
        assign stk_top = stk[ssp - 3'd1];
    end endgenerate
    wire pop     = a_nx == NX_DISP && ev;
    assign e_pop = pop;
    // FF: COLOR, and TEXCOORD in texture mode 0, go to the attribute latches in the DISP clock; the DISP stays
    // (no handler). TEXCOORD waits for its handler while a TEXM write is still in flight
    wire ff_tm_busy = (we_o && wa_o == FF_A_TEXM) || (we_m && wa_m == FF_A_TEXM);
    wire ff_col = FF && pop && !mp && e_hidx == FF_HCOLOR;
    wire ff_tex = FF && pop && !mp && e_hidx == FF_HTEXC && at_m == 2'd0 && !ff_tm_busy;
    // FF: a NORMAL outside texture mode 2 only starts the lighting unit: the DISP stays (no handler)
    wire ff_nrm = FF && pop && !mp && e_hidx == LU_HNORMAL && at_m != 2'd2 && !ff_tm_busy;
    // FF: a vertex command (VTX_16 at its second parameter) is decoded into CurVertex's latch and goes
    // straight to SubmitVertex (SUBV)
    wire ff_vtx = 1'b0;
    wire ff_hw  = ff_col || ff_tex || ff_vtx;
    // PU: a vertex command goes straight to the transform (SV1) with X1 set to its slot group, unless it must
    // wait for the lighting unit or the clip matrix, or a TEXM write is in flight (the transform tests TEXM's
    // latch): then to SUBV
    wire pu_fast = !lu_busy && !dirty && !ff_tm_busy;
    wire pu_step = PU && a_nx == NX_JC && a_cond == C_PSTEP;
    wire collect = pop && mp;
    always_comb begin
        case (a_nx)
            NX_JMP:  upc_n = a_tgt;
            NX_JC:   upc_n = cond ? a_tgt : upc + 11'd1;
            NX_JNC:  upc_n = cond ? upc + 11'd1 : a_tgt;
            NX_CALL: upc_n = a_tgt;
            NX_RET:  upc_n = stk_top;
            NX_DISP: upc_n = !ev ? a_tgt : ff_vtx ? (PU && pu_fast ? PU_A_SV1 : FF_A_SUBV) : (ff_col || ff_tex || ff_nrm) ? upc :
                             (mp && !mp_last) ? DPARAM : {5'd0, e_hidx};
            NX_DJNZ: upc_n = (lc != 6'd1) ? a_tgt : upc + 11'd1;
            default: upc_n = upc + 11'd1;
        endcase
        if (rst) upc_n = RESET;
    end
    logic lu_peek;                      // LUNIT: read the entry after the head (below)
    assign e_addr = dp_r + ((pop || lu_peek) ? 9'd1 : 9'd0);

    // register-file addresses: base + index register
    function automatic [10:0] xv(input [1:0] k);
        case (k)
            2'd1: xv = xr1;
            2'd2: xv = xr2;
            2'd3: xv = xr3;
            default: xv = 11'd0;
        endcase
    endfunction
    wire [10:0] rf_ra = a_ra + xv(a_rax);
    wire [10:0] rf_rb = a_rb + xv(a_rbx);
    wire [10:0] i_wa  = collect ? PARAM + {5'd0, pi} : a_wa + xv(a_wx);
    wire        i_we  = collect || a_we;
    // SETX: R; SETXI: the port-A address field; ADDX: the register plus a
    // signed 6-bit step; MOVX: another index register
    wire [10:0] x_new = (a_xop == X_SETX)  ? R[10:0] :
                        (a_xop == X_SETXI) ? a_ra :
                        (a_xop == X_ADDX)  ? xv(a_xarg[1:0]) + {{5{a_xarg[7]}}, a_xarg[7:2]} : xv(a_xarg[3:2]);

    always_ff @(posedge clk) begin
        if (rst) begin
            upc <= RESET; ssp <= 3'd0; dp_r <= 9'd0; P <= 32'd0; pi <= 6'd0; pi1 <= 6'd1;
            xr1 <= 11'd0; xr2 <= 11'd0; xr3 <= 11'd0; lc <= 6'd0; dirty <= 1'b1;
            we_o <= 1'b0;
        end else begin
            upc <= upc_n;
            if (a_nx == NX_CALL) begin if (!SMALL) stk[ssp] <= upc + 11'd1; ssp <= ssp + 3'd1; end
            if (a_nx == NX_RET) ssp <= ssp - 3'd1;
            if (a_nx == NX_DJNZ) lc <= lc - 6'd1;
            if (pop) begin
                dp_r <= dp_r + 9'd1;
                P <= e_data[31:0];
            end
            if (collect) begin pi <= mp_last ? 6'd0 : pi1; pi1 <= mp_last ? 6'd1 : pi1 + 6'd1; end
            case (a_xop)
                X_SETX, X_SETXI, X_ADDX, X_MOVX: case (a_xarg[1:0])
                    2'd1: xr1 <= x_new;
                    2'd2: xr2 <= x_new;
                    2'd3: xr3 <= x_new;
                    default: ;
                endcase
                X_LCI:   lc <= a_xarg[5:0];
                X_LCR:   lc <= R[5:0];
                X_DIRTY: if (!(LUNIT && a_xarg[1])) dirty <= a_xarg[0];   // LUNIT: xarg 2 opens lu_win (below)
                default: ;
            endcase
            // PU: the dispatcher's vertex sets X1 to its slot group; a completed polygon sets X1..X3 to its
            // slots 0..2 (after the step instruction's own X1 use)
            if (PU && ff_vtx) xr1 <= pu_cur;
            if (pu_step && pu_done) begin xr1 <= pu_x1; xr2 <= pu_x2; xr3 <= pu_x3; end
            we_o <= i_we;
        end
        wa_o <= i_wa;
    end

    assign idle = (a_nx == NX_DISP && !e_more || a_nx == NX_JNC && a_cond == C_SWAPGO && !swap_go) &&
                  ssp == 3'd0 && !we_o && !we_m && out_m == O_NONE && !lu_busy && !vf_busy;

    // ------------------------------------------------------------------
    // register file
    // ------------------------------------------------------------------
    // LUNIT: the lighting unit's CURCOL words go in cycles the engine doesn't write
    logic        lu_cw;
    logic [10:0] lu_cwa;
    logic [31:0] lu_cwd;
    // VFIN: the vertex-finish unit's words in cycles neither the engine nor LUNIT writes
    logic        vf_cw;
    logic [10:0] vf_cwa;
    logic [31:0] vf_cwd;
    wire         lu_w  = LUNIT && lu_cw && !we_m;
    wire         rf_we = we_m || (LUNIT && lu_cw) || (VFIN != 0 && vf_cw);
    // without VFIN, exactly the LUNIT form (and with LUNIT = 0 just wa_m / R): the address and data of
    // a cycle without a write are not don't-care to synthesis, so a third input left at 0 would gate R
    wire  [10:0] rf_wa = VFIN == 0 ? ((LUNIT && !we_m) ? lu_cwa : wa_m) : we_m ? wa_m : lu_w ? lu_cwa : vf_cwa;
    wire  [31:0] rf_wd = VFIN == 0 ? ((LUNIT && !we_m) ? lu_cwd : R)    : we_m ? R    : lu_w ? lu_cwd : vf_cwd;
    // FF: the attribute latches. Every register-file write to a latched word also writes its latch; the
    // dispatcher's COLOR / TEXCOORD go to the latches alone, in the M stage of their DISP (in order with
    // the writes before it). Readers of these words read the latches (XS = ATR; ucode.py ATR_ADDR)
    generate if (FF) begin : g_ff
        logic [4:0]  at_c [3];
        logic [15:0] at_t [2];
        // the command in O and M: 0 COLOR, 1 TEXCOORD, 2..7 VTX_16, 10, XY, XZ, YZ, DIFF; its parameter is P
        // in O (P holds the popped entry until the next pop), and the latch write is decoded in M
        logic        ffw_o;
        logic [2:0]  ffk_o, ffk_m;
        logic [31:0] vp0, vp1;          // ExecParams[0] and [1] (VTX_16), whatever entries filled them
        wire  [2:0]  ffk_n = ff_col ? 3'd0 : ff_tex ? 3'd1 : e_hidx == FF_HV16 ? 3'd2 : e_hidx == FF_HV10 ? 3'd3 :
                             e_hidx == FF_HVXY ? 3'd4 : e_hidx == FF_HVXZ ? 3'd5 : e_hidx == FF_HVYZ ? 3'd6 : 3'd7;
        assign fft_m = ffk_m == 3'd1;
        assign ffv_m = ffk_m >= 3'd2;
        // the vertex commands' CurVertex (ucode.py VTX16 ... VTXDIFF), against the latch (nothing else writes
        // CurVertex between the pop and M: a vertex command waits for register-file writes to it). PU: in O, from
        // P (the popped entry until the next pop), so the transform's first vector step (SV1, the clock after the
        // DISP) reads it in its O; a register-file write to CurVertex still in M then was in O at the pop (ff_cvb)
        wire [2:0]  ffk_v = PU ? ffk_o : ffk_m;
        wire [31:0] ffd_v = PU ? P : ffd_m;
        wire        ffv_w = PU ? ffw_o && ffk_o >= 3'd2 : ffw_m && ffv_m;
        always_comb begin
            for (int k = 0; k < 3; k++) ffv_d[k] = at_v[k];
            case (ffk_v)
                3'd2: begin ffv_d[0] = vp0[15:0]; ffv_d[1] = vp0[31:16]; ffv_d[2] = vp1[15:0]; end
                3'd3: for (int k = 0; k < 3; k++) ffv_d[k] = {ffd_v[10 * k +: 10], 6'd0};
                3'd4: begin ffv_d[0] = ffd_v[15:0]; ffv_d[1] = ffd_v[31:16]; end
                3'd5: begin ffv_d[0] = ffd_v[15:0]; ffv_d[2] = ffd_v[31:16]; end
                3'd6: begin ffv_d[1] = ffd_v[15:0]; ffv_d[2] = ffd_v[31:16]; end
                3'd7: for (int k = 0; k < 3; k++) ffv_d[k] = at_v[k] + {{6{ffd_v[10 * k + 9]}}, ffd_v[10 * k +: 10]};
                default: ;
            endcase
        end
        always_ff @(posedge clk) begin
            ffw_o <= !rst && ff_hw; ffk_o <= ffk_n;
            ffw_m <= !rst && ffw_o; ffk_m <= ffk_o; ffd_m <= P;
            if (collect && pi == 6'd0) vp0 <= e_data[31:0];
            if (collect && pi == 6'd1) vp1 <= e_data[31:0];
            if (rf_we) begin
                for (int k = 0; k < 3; k++) if (rf_wa == FF_A_CURV + 11'(k)) at_v[k] <= rf_wd[15:0];
                for (int k = 0; k < 3; k++) if (rf_wa == FF_A_CURCOL + 11'(k)) at_c[k] <= rf_wd[16:12];
                for (int k = 0; k < 2; k++) begin
                    if (rf_wa == FF_A_TEXC + 11'(k)) at_t[k] <= rf_wd[15:0];
                end
                if (rf_wa == FF_A_TEXM) at_m <= rf_wd[1:0];
            end
            if (ffv_w) begin
                for (int k = 0; k < 3; k++) at_v[k] <= ffv_d[k];
            end
            if (ffw_m && fft_m) begin
                at_t[0] <= ffd_m[15:0]; at_t[1] <= ffd_m[31:16];
            end else if (ffw_m && !ffv_m) begin
                at_c[0] <= ffd_m[4:0]; at_c[1] <= ffd_m[9:5]; at_c[2] <= ffd_m[14:10];
            end
        end
        // xsh: 0-2 CURCOL, 3-4 TEXC (ucode.py ATR_ADDR); RawTexCoords lives in the vector MAC's lanes (row 7);
        // PU: 7 the polygon unit's register named by the immediate (asm.py PU_XSH)
        always_comb case (b_xsh)
            3'd0:    at_q = {15'd0, at_c[0], 12'hFFF};
            3'd1:    at_q = {15'd0, at_c[1], 12'hFFF};
            3'd2:    at_q = {15'd0, at_c[2], 12'hFFF};
            3'd3:    at_q = {{16{at_t[0][15]}}, at_t[0]};
            3'd7:    at_q = PU ? pu_q : {{16{at_t[1][15]}}, at_t[1]};
            default: at_q = {{16{at_t[1][15]}}, at_t[1]};
        endcase
`ifndef SYNTHESIS
        // synthesis translate_off
        always_ff @(posedge clk) if (!rst && rf_we) begin
            for (int k = 0; k < 3; k++)
                // (0: the reset's register-file clear, RCLR, before RSTI writes the colour)
                if (rf_wa == FF_A_CURCOL + 11'(k) && rf_wd != {15'd0, rf_wd[16:12], 12'hFFF} && rf_wd != 32'd0)
                    $error("gpu3d_gxeng FF: CURCOL word %08x", rf_wd);
            for (int k = 0; k < 2; k++)
                if ((rf_wa == FF_A_TEXC + 11'(k) || rf_wa == FF_A_RAWTC + 11'(k)) && rf_wd != {{16{rf_wd[15]}}, rf_wd[15:0]})
                    $error("gpu3d_gxeng FF: texture coordinate word %08x", rf_wd);
            for (int k = 0; k < 3; k++)
                if (rf_wa == FF_A_CURV + 11'(k) && rf_wd != {{16{rf_wd[15]}}, rf_wd[15:0]})
                    $error("gpu3d_gxeng FF: CurVertex word %08x", rf_wd);
            if (rf_wa == FF_A_TEXM && rf_wd > 32'd3) $error("gpu3d_gxeng FF: TEXM %08x", rf_wd);
        end
        initial if (!(USORT && LUNIT && VFIN == 2)) $error("gpu3d_gxeng: FF needs USORT, LUNIT and VFIN 1");
        // synthesis translate_on
`endif
    end else begin : g_noff
        assign at_q = '0; assign at_m = '0;
        assign ffw_m = 1'b0; assign fft_m = 1'b0; assign ffv_m = 1'b0; assign ffd_m = '0;
        always_comb for (int k = 0; k < 3; k++) begin at_v[k] = '0; ffv_d[k] = '0; end
    end endgenerate

    gpu3d_ram #(.W(32), .AW(11)) u_rfa (.clk, .we(rf_we), .waddr(rf_wa), .wdata(rf_wd), .raddr(rf_ra), .rdata(qa));
    // port B only reads below 0x400 (the matrix stacks above are copied through port A), so
    // its copy is half as deep
    gpu3d_ram #(.W(32), .AW(10)) u_rfb (.clk, .we(rf_we && !rf_wa[10]), .waddr(rf_wa[9:0]), .wdata(rf_wd), .raddr(rf_rb[9:0]), .rdata(qb));
    // LUNIT early start (docs/geometry-engine.md): lu_win opens at VADV (dirty(2): the transform has read
    // CURCOL; nothing up to the next DISP writes what the unit reads) and closes at the next pop other than a
    // TEXCOORD (which writes nothing the unit reads). In it, an idle unit starts on a NORMAL at the FIFO head,
    // as its pop would; lu_pre marks that entry taken, so its pop neither starts the unit again nor waits for
    // it (the handler only does texture mode 2).
    // Speculation: at VADV, with a TEXCOORD at the head, the next clock reads the entry after it (lu_peek;
    // that clock is VADV + 1, never a DISP, and ev is held off while e_data is not the head). If it is a
    // NORMAL, the idle unit starts on it (lu_spec) but holds its CURCOL writes. The entry read may be stale
    // (not yet written), so the start is only checked once the TEXCOORD has popped and the real head is
    // valid: a NORMAL with the same parameter confirms it (lu_conf: from then on as lu_pre), anything else
    // aborts the unit, which has written nothing; that head then dispatches as without the early start
    logic        lu_win, lu_spec, lu_tp;
    logic [29:0] lu_nr;                 // the normal the unit works on (gpu3d_gxlight nr)
    wire  lu_hn    = ev_q && e_hidx == LU_HNORMAL && !mp;
    wire  lu_vadv  = LUNIT && a_xop == X_DIRTY && a_xarg[1];
    assign lu_peek = lu_vadv && ev_q && e_hidx == FF_HTEXC && !mp && !lu_busy && !lu_pre && !lu_spec;
    wire  lu_sst   = LUNIT && lu_pk_q && e_hidx == LU_HNORMAL && !mp;   // (lu_win is open: VADV opened it)
    wire  lu_chk   = LUNIT && lu_spec && lu_tp && ev_q && !lu_pk_q;
    wire  lu_conf  = lu_chk && lu_hn && e_data[29:0] == lu_nr;
    // (also when nothing follows the TEXCOORD: the engine must be able to go idle)
    wire  lu_abort = lu_chk && !lu_conf || LUNIT && lu_spec && lu_tp && !e_more;
    wire  lu_early = LUNIT && lu_win && lu_hn && !lu_pk_q && !lu_busy && !lu_pre && !lu_spec;
    // (a NORMAL cannot pop while a speculative start is unconfirmed: the unit is busy)
    wire  lu_start = lu_early || lu_sst || (pop && e_hidx == LU_HNORMAL && !lu_pre);
    always_ff @(posedge clk) begin
        if (rst || !LUNIT) begin
            lu_win <= 1'b0; lu_pre <= 1'b0; lu_spec <= 1'b0; lu_tp <= 1'b0; lu_pk_q <= 1'b0;
        end else begin
            lu_pk_q <= lu_peek;
            if (pop && !(e_hidx == FF_HTEXC && !mp)) lu_win <= 1'b0;
            else if (lu_vadv) lu_win <= 1'b1;
            if (pop) lu_pre <= 1'b0;
            else if (lu_early || lu_conf) lu_pre <= 1'b1;
            if (lu_conf || lu_abort) begin lu_spec <= 1'b0; lu_tp <= 1'b0; end
            else if (lu_sst) lu_spec <= 1'b1;
            else if (lu_spec && pop) lu_tp <= 1'b1;   // (the TEXCOORD)
        end
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    // nothing the engine writes while the window is open or an early-started NORMAL waits may be read by the
    // lighting unit (its snooped copies) or be CURCOL
    always_ff @(posedge clk)
        if (LUNIT && !rst && we_m && (lu_win || lu_pre) &&
            (wa_m[10:4] == LU_A_VEC[10:4] || wa_m == LU_A_CATTR || wa_m == LU_A_USETAB ||
             (wa_m >= LU_A_MEMI && wa_m < LU_A_MEMI + 11'd3) || (wa_m >= LU_A_CURCOL && wa_m < LU_A_CURCOL + 11'd3) ||
             wa_m[10:6] == LU_A_LIGHT[10:6] || wa_m[10:7] == LU_A_SHIN[10:7]))
            $error("gpu3d_gxeng LUNIT early start: a write to %03x in the window", wa_m);
    // synthesis translate_on
`endif
    generate if (LUNIT) begin : g_lu
        gpu3d_gxlight #(.A_VEC(LU_A_VEC), .A_CATTR(LU_A_CATTR), .A_USETAB(LU_A_USETAB), .A_MEMI(LU_A_MEMI),
                        .A_CURCOL(LU_A_CURCOL), .A_LIGHT(LU_A_LIGHT), .A_SHIN(LU_A_SHIN), .LDIR(LU_LDIR),
                        .LRECIP(LU_LRECIP), .LDL(LU_LDL), .LSL(LU_LSL), .LAL(LU_LAL)) u_light (
            .clk, .rst, .we(we_m), .wa(wa_m), .wd(R), .start(lu_start), .nrm(e_data[29:0]),
            .hold(lu_spec), .abort(lu_abort),
            .busy(lu_busy), .nr(lu_nr), .cw(lu_cw), .cwa(lu_cwa), .cwd(lu_cwd));
    end else begin : g_nolu
        assign lu_busy = 1'b0; assign lu_nr = '0; assign lu_cw = 1'b0; assign lu_cwa = '0; assign lu_cwd = '0;
    end endgenerate
    // VFIN: the read addresses of the data in O (qa, qb), for the unit's snoop
    generate if (VFIN != 0) begin : g_vf
        logic [10:0] ra_o;
        logic [9:0]  rb_o;
        always_ff @(posedge clk) begin ra_o <= rf_ra; rb_o <= rf_rb[9:0]; end
        gpu3d_gxvfin #(.A_KT(VF_A_KT), .A_KB(VF_A_KB), .A_WOR(VF_A_WOR), .A_DEG(VF_A_DEG), .A_IDX(VF_A_IDX),
                       .A_IDXB(VF_A_IDXB), .G_C(VF_G_C), .G_W(VF_G_W), .G_T(VF_G_T), .G_FX(VF_G_FX), .G_FY(VF_G_FY),
                       .G_W1(VF_G_W1), .BOUNDS(VFIN == 1)) u_vfin (
            .clk, .rst, .arm(a_nx == NX_JC && a_cond == C_VARM && !vf_busy), .we(we_m), .wa(wa_m), .wd(R), .ra_o, .qa, .rb_o, .qb,
            .wfree(!we_m && !lu_w),
            .busy(vf_busy), .cw(vf_cw), .cwa(vf_cwa), .cwd(vf_cwd));
    end else begin : g_novf
        assign vf_busy = 1'b0; assign vf_cw = 1'b0; assign vf_cwa = '0; assign vf_cwd = '0;
    end endgenerate
`ifndef SYNTHESIS
    // synthesis translate_off
    logic rb_hi_d;
    logic [10:0] rb_d, rb_pc;
    longint rb_cy = 0;
    always_ff @(posedge clk) begin
        rb_hi_d <= rf_rb[10]; rb_d <= rf_rb; rb_pc <= upc; rb_cy <= rb_cy + 1;
        if (!rst && rb_hi_d && (b_ys == YS_QB || b_mb == MB_QB)) $error("RF port B used for an address above 0x3FF (address %03x, read at upc %03x, clock %0d)", rb_d, rb_pc, rb_cy);
    end
    // synthesis translate_on
`endif

    // ------------------------------------------------------------------
    // O: operands and ALU
    // ------------------------------------------------------------------
    logic [31:0] accx, imm, xo, yo;
    logic [11:0] qv;                   // outcodes of the vertex group in X1 (below)
    always_comb begin
        // XSH is one-hot for S9, S12, S32 (isa.py): select by bit, no decode (#466: ROM b_q -> fzb)
        accx = ({32{b_xsh[0]}} & acc[40:9]) | ({32{b_xsh[1]}} & acc[43:12]) | ({32{b_xsh[2]}} & acc[63:32]) |
               ({32{b_xsh == 3'd0}} & acc[31:0]);
        imm = t_imm;
        // one-hot selects (od): an AND-OR, no decode
        xo = ({32{od.xs[XS_QA]}} & qa) | ({32{od.xs[XS_R]}} & R) | ({32{od.xs[XS_ACCX]}} & accx) |
             ({32{od.xs[XS_P]}} & P) | ({32{od.xs[XS_Q]}} & div_q) | ({32{od.xs[XS_ZDOT]}} & {8'd0, zerodot}) |
             ({32{od.xs[XS_MSEL]}} & {27'd0, mrd_sel}) | ({32{od.xs[XS_VOCW]}} & {26'd0, qv[5:0]}) |
             ({32{od.xs[XS_VOCS]}} & {26'd0, qv[11:6]});
        // SBL and SYB (sort RAM read data) only ever PASSX (asm.py checks): they join at the result
        // select below instead, off the adder and shifter (#677: -1.95 ns u_bl -> R)
        if (USORT) xo = xo | ({32{od.xs[XS_SCT]}} & s_ct) | ({32{od.xs[XS_SNX]}} & s_nx);
        if (FF) xo = xo | ({32{od.xs[XS_ATR]}} & at_q) | ({32{od.xs[XS_VXR]}} & vx_q);
        yo = ({32{od.ys[YS_QB]}} & qb) | ({32{od.ys[YS_R]}} & R) | ({32{od.ys[YS_IMM]}} & imm);
    end
    // one adder: X + Y (ADD), X - Y (SUB, MAX, MIN, flags), Y - X (RSUB)
    wire        sub_n = od.sub;   // and SLT: X - Y
    wire [31:0] ax    = od.rsub ? yo : xo;
    wire [31:0] ay    = od.rsub ? xo : yo;
    wire [32:0] sum   = {1'b0, ax} + {1'b0, sub_n ? ~ay : ay} + {32'd0, sub_n};
    wire        lt_s  = (ax[31] != ay[31]) ? ax[31] : sum[31];   // signed ax < ay
    // one shifter: right by Y[4:0] with zero or sign fill; left as a right
    // shift of the reversed operand
    // FSH: the low word of {Y, X} >> kreg (kreg: 0..32, set by K4); the big-normal cull of the
    // geometry microcode (ucode.py, CULLBIG) uses MABS, K4 and FSH
    logic [5:0]  kreg;
    wire  [31:0] mabs_h = yo ^ {32{yo[31]}};
    wire  [7:0]  k4_nz  = {|xo[31:28], |xo[27:24], |xo[23:20], |xo[19:16], |xo[15:12], |xo[11:8], |xo[7:4], |xo[3:0]};
    logic [5:0]  k4_k;
    always_comb begin
        k4_k = 6'd0;
        for (int i = 0; i < 8; i++) if (k4_nz[i]) k4_k = 6'(4 * (i + 1));
    end
    // one funnel, no reversal: the low word of {hi[30:0], lo} >> a, a = 0..31. SHL by n is that funnel at
    // a = 31 - n (~n) over {x[31:1], x[0], 0...}; FSH's kreg = 32 (K4: 0, 4, .., 32) is Y itself (sh32)
    logic [31:0] sh_lo, sh_res, sh_f;
    logic [30:0] sh_hi;
    logic [4:0]  sh_a;
    always_comb begin
        sh_hi  = od.fsh ? yo[30:0] : od.shl ? xo[31:1] : {31{od.sar && xo[31]}};
        sh_lo  = od.shl ? {xo[0], 31'd0} : xo;
        sh_a   = od.fsh ? kreg[4:0] : od.shl ? ~yo[4:0] : yo[4:0];
        sh_f   = 32'({sh_hi, sh_lo} >> sh_a);
        sh_res = (od.fsh && kreg[5]) ? yo : sh_f;
    end
    // the logic unit (RO_LG): bit {x, y} of od.lgt
    logic [31:0] lg_res;
    always_comb for (int k = 0; k < 32; k++) lg_res[k] = od.lgt[{xo[k], yo[k]}];
    logic [31:0] res;
    // one-hot result select (od.ro): ADD, SUB, RSUB the sum; SHL, SHR, SAR, FSH the shifter; AND, OR, XOR,
    // BIC, PASSX and the unused codes the logic unit
    // the compare lt_s (the end of the sum's carry chain, #842: u_rfa -> R) selects last, between the
    // MAX/MIN/SLT terms for either outcome, so it passes one LUT on its way to R
    wire [31:0] res_e = ({32{od.ro[RO_SUM]}} & sum[31:0]) | ({32{od.ro[RO_LG]}} & lg_res) |
                 ({32{od.ro[RO_SH]}} & sh_res) |
                 ({32{od.ro[RO_SX16]}} & {{16{xo[15]}}, xo[15:0]}) | ({32{od.ro[RO_SX11]}} & {{21{xo[10]}}, xo[10:0]}) |
                 ({32{od.ro[RO_MABS]}} & {mabs_h[30:0], xo[31] ^ yo[31]}) |
                 ({32{od.ro[RO_K4]}} & {26'd0, k4_k}) |
                 (USORT ? ({32{od.xs[XS_SBL]}} & s_bl) | ({32{od.xs[XS_SYB]}} & s_yb) : 32'd0);
    wire [31:0] res_l1 = ({32{od.ro[RO_MAX]}} & yo) | ({32{od.ro[RO_MIN]}} & xo) | {31'd0, od.ro[RO_SLT]};
    wire [31:0] res_l0 = ({32{od.ro[RO_MAX]}} & xo) | ({32{od.ro[RO_MIN]}} & yo);
    assign res = res_e | (lt_s ? res_l1 : res_l0);
    logic signed [31:0] ma, mb;
    logic signed [63:0] pr;
    logic [2:0] acc_m, acc_a;
    always_ff @(posedge clk) begin
        R <= res;
        if (od.ro[RO_K4]) kreg <= k4_k;
        fl_p <= b_fl && !fl_sort;
        fz_h <= fz;
        if (b_fl && !fl_sort) begin
            fn <= res[31];
            fc <= !sum[32];            // ax < ay unsigned (a subtraction's borrow)
            flt <= lt_s;
        end
        // USORT: a sort-table operand's flags (PASSX only) are tested for N alone (ucode.py SWALK, SMAN):
        // N straight from the table's sign, the other flags kept (#483: sort RAM -> fzb)
        if (b_fl && fl_sort) fn <= s_sign;
        // FF: the scalar MAC is the vector MAC's lane 0: a vector step multiplies lane 0's row
        ma <= (FF && v_opo) ? vm0_q : b_ma ? R : qa;
        // FF: MB3 (vector MAC) is CurVertex's latch by row, then 0x1000 (rows 3 and 7)
        mb <= (b_mb == MB_R) ? R : (b_mb == MB_IMM) ? imm :
              (FF && b_mb == MB_MB3) ? (v_row[1:0] == 2'd3 ? 32'h1000 : {{16{at_v[v_row[1:0]][15]}}, at_v[v_row[1:0]]}) : qb;
        pr <= ma * mb;
        if (rst) begin acc_m <= ACC_NONE; acc_a <= ACC_NONE; we_m <= 1'b0; out_m <= O_NONE; end
        else begin acc_m <= b_acc; acc_a <= acc_m; we_m <= we_o; out_m <= b_out; end
        sm_m <= b_xsh;
        wa_m <= wa_o;
    end

    // ------------------------------------------------------------------
    // outcodes of a transformed vertex: its position words leave the transform
    // with out = VPOS (x, y, z, then w; the write address names the group).
    // One adder works through the six sums comp - w and comp + w; the result
    // is two bits per plane, in the layout of OCV (x>w, y>w, z>w, x<-w, y<-w,
    // z<-w): outside at all, and outside by at least 7 (not for z > w), the
    // latter only when every coordinate is inside +-2^29 (ucode.py, "Trivial
    // reject"). Microcode reads them with XS = VOCW / VOCS, addressed by X1;
    // ready 8 clocks after the w word.
    // ------------------------------------------------------------------
    logic [31:0] vcx, vcy, vcz, vw;     // vcx..vcz: !SMALL (SMALL: x, y, z in an MLAB, u_vc)
    logic [2:0]  vg29;                  // SMALL: g29 of x, y, z as written
    logic [3:0]  vst;
    logic [4:0]  vg;
    logic        vok;
    logic [5:0]  vweak, vstrong;
    function automatic logic g29(input logic [31:0] c);
        g29 = c[31] == c[30] && c[30] == c[29];
    endfunction
    wire [3:0]  vi    = vst - 4'd1;                      // 0..5: x-w, x+w, y-w, y+w, z-w, z+w
    wire [31:0] vcomp;
    logic [31:0] vcomp_r;               // VC_M10K: u_vc's word, registered
    generate if (SMALL && VC_M10K) begin : g_vcm
        // vst one and two clocks on (as the always_ff below steps it: a w word in M starts it at 1, which
        // out_m, wa_m show one clock ahead as b_out, wa_o); the comparand is x, y, z by (vst - 1) / 2
        wire [3:0] vst1 = out_m == O_VPOS && wa_m[1:0] == 2'd3 ? 4'd1 : vst == 4'd0 || vst == 4'd7 ? 4'd0 : vst + 4'd1;
        wire [3:0] vst2 = b_out == 4'(O_VPOS) && wa_o[1:0] == 2'd3 ? 4'd1 : vst1 == 4'd0 || vst1 == 4'd7 ? 4'd0 : vst1 + 4'd1;
        wire [3:0] vi2  = vst2 - 4'd1;
        logic [31:0] vc_q;
        gpu3d_ram #(.W(32), .AW(2), .STYLE("M10K, no_rw_check")) u_vc (.clk, .we(!rst && out_m == O_VPOS && wa_m[1:0] != 2'd3),
                                           .waddr(wa_m[1:0]), .wdata(R), .raddr(vi2[2:1]), .rdata(vc_q));
        always_ff @(posedge clk) vcomp_r <= vc_q;
        assign vcomp = vcomp_r;
`ifndef SYNTHESIS
        // synthesis translate_off
        // the MLAB's read as it was, against the M10K word while the stepper uses it
        logic [31:0] vc_s;
        gpu3d_lram #(.W(32), .AW(2)) s_vc (.clk, .we(!rst && out_m == O_VPOS && wa_m[1:0] != 2'd3), .waddr(wa_m[1:0]),
                                           .wdata(R), .raddr(vi[2:1]), .rdata(vc_s));
        always_ff @(posedge clk)
            if (!rst && vst != 4'd0 && vst != 4'd7 && vcomp != vc_s)
                $error("gpu3d_gxeng VC_M10K: vst %0d: M10K %08x, MLAB %08x", vst, vcomp, vc_s);
        // synthesis translate_on
`endif
    end else if (SMALL) begin : g_vc
        gpu3d_lram #(.W(32), .AW(2)) u_vc (.clk, .we(!rst && out_m == O_VPOS && wa_m[1:0] != 2'd3), .waddr(wa_m[1:0]),
                                           .wdata(R), .raddr(vi[2:1]), .rdata(vcomp));
    end else begin : g_vcr
        assign vcomp = vi[2:1] == 2'd0 ? vcx : vi[2:1] == 2'd1 ? vcy : vcz;
    end endgenerate
    wire        vadd  = vi[0];
    wire [32:0] vr    = {vcomp[31], vcomp} + (vadd ? {vw[31], vw} : ~{vw[31], vw}) + {32'd0, !vadd};
    wire [32:0] vnr   = ~vr;
    wire        v_pw  = !vr[32] && vr[31:0] != 32'd0;           // comp > w
    wire        v_ps  = !vr[32] && (vr[31:3] != 29'd0 || vr[2:0] == 3'd7);
    wire        v_nw  = vr[32];                                  // comp < -w
    wire        v_ns  = vr[32] && (vnr[31:3] != 29'd0 || vnr[2:1] == 2'd3);
    wire        vwe   = vst == 4'd7;
    wire [5:0]  vweak_n   = vweak   | (vst != 4'd0 && vst != 4'd7 ? (vadd ? 6'(v_nw) << (3 + vi[2:1]) : 6'(v_pw) << vi[2:1]) : 6'd0);
    wire [5:0]  vstrong_n = vstrong | (vst != 4'd0 && vst != 4'd7 ? (vadd ? 6'(v_ns) << (3 + vi[2:1]) : (vi[2:1] == 2'd2 ? 6'd0 : 6'(v_ps) << vi[2:1])) : 6'd0);
`ifndef SYNTHESIS
    // synthesis translate_off
    // an outcode read of the group whose outcodes are still being computed (ready 8 clocks after its w word)
    always_ff @(posedge clk)
        if (!rst && (od.xs[XS_VOCW] || od.xs[XS_VOCS]) && vst != 4'd0 && xr1[8:4] == vg)
            $error("gpu3d_gxeng: outcodes of group %0d read before they are ready", vg);
    // synthesis translate_on
`endif
    gpu3d_ram #(.W(12), .AW(5), .STYLE(VOC_M10K ? "M10K" : "MLAB")) u_voc (.clk, .we(vwe), .waddr(vg),
                                         .wdata({vstrong & {6{vok}}, vweak}), .raddr(xr1[8:4]), .rdata(qv));
    always_ff @(posedge clk) begin
        if (rst) vst <= 4'd0;
        else begin
            if (vst != 4'd0) begin
                vweak <= vweak_n; vstrong <= vstrong_n;
                vst <= vst == 4'd7 ? 4'd0 : vst + 4'd1;
            end
            if (out_m == O_VPOS) case (wa_m[1:0])
                2'd0: begin if (!SMALL) vcx <= R; vg29[0] <= g29(R); end
                2'd1: begin if (!SMALL) vcy <= R; vg29[1] <= g29(R); end
                2'd2: begin if (!SMALL) vcz <= R; vg29[2] <= g29(R); end
                default: begin
                    vw <= R; vg <= wa_m[8:4]; vst <= 4'd1; vweak <= 6'd0; vstrong <= 6'd0;
                    vok <= (SMALL ? &vg29 : g29(vcx) && g29(vcy) && g29(vcz)) && g29(R);
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // PU: the polygon unit (docs/geometry-redesign.md "Polygon unit"; ucode.py PU). It keeps what the
    // microcode's VADV and SVSUB kept in the register file: VertexNumInPoly (vn), the slot order (s: slot ->
    // vertex group 0..3, TempVertexBuffer's swaps), NumConsecutivePolygons' parity (nc), with PolygonMode and
    // the last strip polygon's reuse flag snooped from the register-file writes (BEGIN, PREJ, COMMIT; the
    // reset's SLOT words). The transform's last instruction steps it (jc PSTEP): a completed polygon latches
    // its slots as SubmitPolygon sees them (pl: SVSUB's rotation before the call) and takes the rotation after
    // it at once. The outcodes of groups 0..3 are kept as the outcode unit writes them (u_voc's words); the
    // polygon's list (CULLOK: slots 0..3, or groups 4 and 5 then slots 2, 3 when the last strip polygon left its
    // two vertices there) gives OCM, SA and the trivial reject. Registers for the microcode (pu_q): 0-3 LA,
    // 4 LN, 5 CS, 6 OCM, 7 SA, 8 NCONS, 9 the next vertex's group (ucode.py PU_*)
    // ------------------------------------------------------------------
    generate if (PU) begin : g_pu
        logic [1:0]  pm, vn;
        logic        nc, lr, cs;
        logic [1:0]  s [4];
        logic [1:0]  pl [4];
        logic [11:0] oc [4];
        function automatic [10:0] gb(input [1:0] g);     // a group's base (ucode.py grp)
            gb = 11'h200 + {5'd0, g, 4'd0};
        endfunction
        wire        q4   = pm[0];                          // VLIM 4: quads
        assign pu_done   = vn == (q4 ? 2'd3 : 2'd2);
        // SVSUB: triangle strips swap slots 0/1 before an odd polygon (the parity before its toggle), quad strips
        // 2/3; after it, triangle strips hold slots (1, 2, 0) of the order before the swap (either parity), quad
        // strips (3, 2, 1, 0) of the swapped order
        wire        st   = pm == 2'd2, sq = pm == 2'd3;
        logic [1:0] pre [4], post [4];
        always_comb begin
            for (int k = 0; k < 4; k++) pre[k] = s[k];
            if (st && nc) begin pre[0] = s[1]; pre[1] = s[0]; end
            if (sq) begin pre[2] = s[3]; pre[3] = s[2]; end
            for (int k = 0; k < 4; k++) post[k] = pre[k];
            if (st) begin post[0] = s[1]; post[1] = s[2]; post[2] = s[0]; end
            if (sq) begin post[0] = pre[3]; post[1] = pre[2]; post[2] = pre[1]; post[3] = pre[0]; end
        end
        assign pu_cur = gb(s[vn]);
        assign pu_x1 = gb(pre[0]); assign pu_x2 = gb(pre[1]); assign pu_x3 = gb(pre[2]);
        // the list's outcodes: entries clipstart..LN - 1 (CULLOK, CR3)
        logic [5:0] ocm, sa;
        always_comb begin
            ocm = 6'd0; sa = 6'h3F;
            for (int k = 0; k < 4; k++)
                if ((k >= 2 || !cs) && (k < 3 || q4)) begin ocm = ocm | oc[pl[k]][5:0]; sa = sa & oc[pl[k]][11:6]; end
        end
        assign pu_triv = !cs && (sa & PU_TRIVM) != 6'd0;
        always_comb case (t_imm[3:0])
            4'd0:    pu_q = {21'd0, cs ? 11'h240 : gb(pl[0])};
            4'd1:    pu_q = {21'd0, cs ? 11'h250 : gb(pl[1])};
            4'd2:    pu_q = {21'd0, gb(pl[2])};
            4'd3:    pu_q = {21'd0, gb(pl[3])};
            4'd4:    pu_q = q4 ? 32'd4 : 32'd3;
            4'd5:    pu_q = {30'd0, cs, 1'b0};
            4'd6:    pu_q = {26'd0, ocm};
            4'd7:    pu_q = {26'd0, sa};
            4'd8:    pu_q = {31'd0, nc};
            default: pu_q = {21'd0, gb(s[vn])};
        endcase
        always_ff @(posedge clk) begin
            if (pu_step) begin
                if (pu_done) begin
                    vn <= pm[1] ? 2'd2 : 2'd0;
                    if (st) nc <= !nc;
                    cs <= lr;
                    for (int k = 0; k < 4; k++) begin pl[k] <= pre[k]; s[k] <= post[k]; end
                end else vn <= vn + 2'd1;
            end
            if (rf_we) begin
                if (rf_wa == PU_A_PMODE) pm <= rf_wd[1:0];
                if (rf_wa == PU_A_VNIP) vn <= rf_wd[1:0];
                if (rf_wa == PU_A_NCONS) nc <= rf_wd[0];
                if (rf_wa == PU_A_LSREUSE) lr <= rf_wd[0];
                for (int k = 0; k < 4; k++) if (rf_wa == PU_A_SLOT + 11'(k)) s[k] <= rf_wd[5:4];
            end
            if (vwe && vg < 5'd4) oc[vg[1:0]] <= {vstrong & {6{vok}}, vweak};
        end
`ifndef SYNTHESIS
        // synthesis translate_off
        always_ff @(posedge clk) if (!rst) begin
            // the trivial reject reads every list vertex's outcodes: the last vertex's must be written
            if (a_nx == NX_JC && a_cond == C_PTRIV && vst != 4'd0)
                $error("gpu3d_gxeng PU: PTRIV while the outcode unit works (group %0d)", vg);
            if (pu_step && rf_we && (rf_wa == PU_A_PMODE || rf_wa == PU_A_VNIP || rf_wa == PU_A_NCONS ||
                                     rf_wa == PU_A_LSREUSE || (rf_wa >= PU_A_SLOT && rf_wa < PU_A_SLOT + 11'd4)))
                $error("gpu3d_gxeng PU: a step with a write to %03x", rf_wa);
            if ((ff_vtx || pu_step && pu_done) && (a_xop == X_SETX || a_xop == X_SETXI || a_xop == X_ADDX || a_xop == X_MOVX))
                $error("gpu3d_gxeng PU: an index register set beside the unit's (upc %03x)", upc);
            if (rf_we && rf_wa >= PU_A_SLOT && rf_wa < PU_A_SLOT + 11'd4 && rf_wd != 32'(gb(rf_wd[5:4])) && rf_wd != 32'd0)
                $error("gpu3d_gxeng PU: SLOT word %08x", rf_wd);
            if (rf_we && rf_wa == PU_A_VNIP && rf_wd != 32'd0) $error("gpu3d_gxeng PU: VNIP word %08x", rf_wd);
        end
        // synthesis translate_on
`endif
    end else begin : g_nopu
        assign pu_done = 1'b0; assign pu_triv = 1'b0; assign pu_q = '0;
        assign pu_cur = '0; assign pu_x1 = '0; assign pu_x2 = '0; assign pu_x3 = '0;
    end endgenerate

    // divider: the accumulator (or its low 32 bits) over Y
    gpu3d_gxdiv #(.SMALL(SMALL), .R4(DIV_R4), .P2X(DIV_P2X)) u_div (.clk, .clk2(clk_2x), .rst, .start(b_div != DIV_NONE), .qb(b_dqb),
                       .num(b_div == DIV_D32 ? {32'd0, acc[31:0]} : acc), .den(yo),
                       .busy(div_busy), .q(div_q));

    // ------------------------------------------------------------------
    // A: accumulator
    // ------------------------------------------------------------------
    // one adder: acc + pr, acc - pr, or acc + the low 20 bits of pr
    wire        acc_sub = acc_a == ACC_SUB;
    wire [63:0] acc_opd = (acc_a == ACC_ADDM) ? {44'd0, pr[19:0]} : pr;
    wire [63:0] acc_sum = acc + (acc_sub ? ~acc_opd : acc_opd) + {63'd0, acc_sub};
    always_ff @(posedge clk) begin
        case (acc_a)
            ACC_LD:   acc <= pr;
            ACC_VLD, ACC_VLDT: if (FF) acc <= pr;
            ACC_VADD: if (FF) acc <= SMALL ? acc_sum : acc + pr;
            ACC_ADD:  acc <= SMALL ? acc_sum : acc + pr;
            ACC_SUB:  acc <= SMALL ? acc_sum : acc - pr;
            ACC_ADDM: acc <= SMALL ? acc_sum : acc + {44'd0, pr[19:0]};
            default: ;
        endcase
        a63 <= acc[63];
        az <= acc == 64'sd0;
        nfit <= acc[63:31] != {33{acc[63]}};
    end

    // FF: the vector MAC. Four lanes of 8 rows (MLAB), each times the scalar MAC's MB operand (16-bit signed:
    // CurVertex by row or 0x1000, MB3), accumulated in 44 bits (lanes 1-3; lane 0 is the scalar MAC). Rows 0-3: a clip-matrix column (written with
    // the register file's CLIP words, CLIP + 4 row + lane); lanes 0 and 1, rows 4-6: a texture-matrix column
    // (TEX + 4 (row - 4) + lane), row 7: RawTexCoords[lane] << 12 (with its word, or the dispatcher's
    // TEXCOORD). VLD starts at row 0, VLDT at row 4, VADD takes the next row; the stages are the scalar
    // MAC's (operands in O, product in M, sum in A), so a lane is read 3 after its last step (XS = VXR:
    // xsh 0-3 bits 12..43, 4-7 bits 24..39 sign-extended)
    generate if (FF) begin : g_vx
        wire        v_op = b_acc == 3'(ACC_VLD) || b_acc == 3'(ACC_VADD) || b_acc == 3'(ACC_VLDT);
        assign v_opo = v_op;
        logic [2:0] vcnt;
        assign v_row = b_acc == 3'(ACC_VLD) ? 3'd0 : b_acc == 3'(ACC_VLDT) ? 3'd4 : vcnt;
        logic signed [31:0] vm_q [4], vma [4];
        // lanes 1-3 keep bits 0..43 only: the readers take bits 12..43 and 24..39, which modulo 2^44
        // sums give exactly
        logic signed [43:0] vpr [4], vacc [4];
        assign vm0_q = vm_q[0];
        genvar vc;
        for (vc = 0; vc < 4; vc++) begin : g_lane
            wire rf_clip = rf_we && rf_wa[10:4] == FF_A_CLIP[10:4] && rf_wa[1:0] == 2'(vc);
            wire rf_tex  = vc < 2 && rf_we && rf_wa[10:4] == FF_A_TEX[10:4] && rf_wa[3:2] != 2'd3 && rf_wa[1:0] == 2'(vc);
            wire rf_raw  = vc < 2 && rf_we && rf_wa == FF_A_RAWTC + 11'(vc);
            wire hw_raw  = vc < 2 && ffw_m && fft_m;
            wire [15:0] hraw = ffd_m[16 * (vc % 2) +: 16];
            wire [2:0]  wa_l = (rf_raw || hw_raw) ? 3'd7 : {rf_tex, rf_wa[3:2]};
            wire [31:0] wd_l = hw_raw ? {{4{hraw[15]}}, hraw, 12'd0} : rf_raw ? {rf_wd[19:0], 12'd0} : rf_wd;
            gpu3d_lram #(.W(32), .AW(3)) u_vm (.clk, .we(rf_clip || rf_tex || rf_raw || hw_raw), .waddr(wa_l),
                                               .wdata(wd_l), .raddr(v_row), .rdata(vm_q[vc]));
`ifndef SYNTHESIS
            // synthesis translate_off
            always_ff @(posedge clk)
                if (!rst && hw_raw && (rf_clip || rf_tex || rf_raw)) $error("gpu3d_gxeng FF: lane %0d write conflict", vc);
            // synthesis translate_on
`endif
        end
        always_ff @(posedge clk) begin
            if (v_op) vcnt <= v_row + 3'd1;
            for (int c = 1; c < 4; c++) begin      // lane 0: the scalar MAC (ma, pr, acc)
                vma[c] <= vm_q[c];
                vpr[c] <= 44'(vma[c] * $signed(mb[15:0]));
                if (acc_a == 3'(ACC_VLD) || acc_a == 3'(ACC_VLDT)) vacc[c] <= vpr[c];
                else if (acc_a == 3'(ACC_VADD)) vacc[c] <= vacc[c] + vpr[c];
            end
        end
        wire [43:0] vsel = b_xsh[1:0] == 2'd0 ? acc[43:0] : vacc[b_xsh[1:0]];
        assign vx_q = b_xsh[2] ? {{16{vsel[39]}}, vsel[39:24]} : vsel[43:12];
`ifndef SYNTHESIS
        // synthesis translate_off
        always_ff @(posedge clk)
            if (!rst && (acc_m == 3'(ACC_VLD) || acc_m == 3'(ACC_VADD) || acc_m == 3'(ACC_VLDT)) && mb != {{16{mb[15]}}, mb[15:0]})
                $error("gpu3d_gxeng FF: vector MAC operand %08x beyond 16 bits", mb);
        // synthesis translate_on
`endif
    end else begin : g_novx
        assign vx_q = '0; assign v_row = '0; assign v_opo = 1'b0; assign vm0_q = '0;
    end endgenerate

    // ------------------------------------------------------------------
    // USORT: the sort tables (ucode.py, "the polygon sort"; isa.py SM), at M
    // with R. Bucket lists BL {tag, head} and counts CT {tag, count} by
    // bucket; next pointers NX and {t, ybot} YB by polygon. Reads and writes
    // take no address muxes: a read at R, a write at the address of the
    // table's last read (or the polygon count np).
    // ------------------------------------------------------------------
    generate if (USORT) begin : g_sort
        wire       smo  = !rst && out_m == O_KEY;
        wire       s_rb = smo && sm_m == 3'(SM_RB);
        wire       s_rp = smo && sm_m == 3'(SM_RP);
        wire       s_cm = smo && sm_m == 3'(SM_COMMIT);
        wire       s_so = smo && sm_m == 3'(SM_SOW);
        wire       s_wc = smo && (sm_m == 3'(SM_WCT) || sm_m == 3'(SM_SOW));
        wire       s_wb = smo && (sm_m == 3'(SM_WBL) || sm_m == 3'(SM_COMMIT));
        wire       s_sd = smo && sm_m == 3'(SM_SOD);
        logic        stag;
        logic [8:0]  ab, ac;
        logic [10:0] ap;
        logic [11:0] bl_q;
        logic [12:0] ct_q;
        logic [10:0] nx_q;
        logic [8:0]  yb_q;
        wire         bl_ok = bl_q[11] == stag;
        wire  [10:0] head  = bl_ok ? bl_q[10:0] : 11'h7FF;
        gpu3d_ram_re #(.W(12), .AW(9))  u_bl (.clk, .we(s_wb), .waddr(ab), .wdata({stag, np_r[10:0]}),
                                              .re(s_rb), .raddr({R[16], R[7:0]}), .rdata(bl_q));
        gpu3d_ram_re #(.W(13), .AW(9))  u_ct (.clk, .we(s_wc), .waddr(ac), .wdata({stag, R[11:0]}),
                                              .re(s_rb), .raddr({R[16], R[15:8]}), .rdata(ct_q));
        gpu3d_ram_re #(.W(11), .AW(11)) u_nx (.clk, .we(s_cm), .waddr(np_r[10:0]), .wdata(head),
                                              .re(s_rp), .raddr(R[10:0]), .rdata(nx_q));
        gpu3d_ram_re #(.W(9), .AW(11))  u_yb (.clk, .we(s_cm), .waddr(np_r[10:0]), .wdata(ac),
                                              .re(s_rp), .raddr(R[10:0]), .rdata(yb_q));
        assign s_bl = bl_ok ? {21'd0, bl_q[10:0]} : 32'hFFFFFFFF;
        assign s_ct = ct_q[12] == stag ? {20'd0, ct_q[11:0]} : 32'd0;
        // NX is read two instructions or more before the microcode uses SNX (SWB, SWE), and the table holds
        // its output until the next read: a register of it, end test included, gives the same value at
        // the same clock and takes the RAM's clock-to-out off the operand path (#461-#463: RAM -> fzb)
        logic [31:0] s_nx_r;
        always_ff @(posedge clk) s_nx_r <= &nx_q ? 32'hFFFFFFFF : {21'd0, nx_q};
        assign s_nx = s_nx_r;
        assign s_yb = {yb_q[8], 14'd0, yb_q[8], yb_q[7:0], 8'd0};
        always_ff @(posedge clk) begin
            so_we <= s_so; so_done <= s_sd && R[0];
            if (s_so) begin so_pos <= R[10:0]; so_idx <= ap; end
            if (s_rb) begin ab <= {R[16], R[7:0]}; ac <= {R[16], R[15:8]}; end
            if (s_rp) ap <= R[10:0];
            if (rst) stag <= 1'b0;
            else if (s_sd) stag <= !stag;
        end
    end else begin : g_nosort
        assign {s_bl, s_ct, s_nx, s_yb} = '0;
        assign {so_we, so_pos, so_idx, so_done} = '0;
    end endgenerate

`ifndef SYNTHESIS
    // the registered decodes are ub's (od, above)
    always_ff @(posedge clk)
        if (!rst && od != odec(ub)) $error("gpu3d_gxeng: operand decode od != odec(ub) (upc %03x)", upc);
    // the shifter takes kreg as K4 leaves it (0, 4, .., 32): bit 5 alone means 32
    always_ff @(posedge clk)
        if (!rst && od.ro[RO_SH] && od.fsh && kreg[5] && kreg[4:0] != 5'd0) $error("gpu3d_gxeng: FSH with kreg %0d", kreg);
    // fl_sort keeps Z, C and LT: no test may read them before other flags are set; and the N shortcut
    // holds for PASSX only
    logic fl_stale;
    always_ff @(posedge clk) begin
        if (rst) fl_stale <= 1'b0;
        else if (b_fl) fl_stale <= fl_sort;
        if (!rst && b_fl && fl_sort && b_aop != 5'(AOP_PASSX)) $error("gpu3d_gxeng: flags from a sort-table operand need PASSX");
        if (!rst && fl_stale && (a_nx == NX_JC || a_nx == NX_JNC) && (a_cond == C_Z || a_cond == C_C || a_cond == C_LT))
            $error("gpu3d_gxeng: Z/C/LT tested after a sort-table operand set the flags (upc %03x)", upc);
    end
`endif

    // ------------------------------------------------------------------
    // M: outputs
    // ------------------------------------------------------------------
    logic [31:0] o0, o1, o2, o3;
    assign po_data  = {o3, o2, o1, o0};
    assign po_wv    = !rst && out_m >= 4'(O_O0) && out_m <= 4'(O_O3);
    assign po_wk    = 2'(out_m - 4'(O_O0));
    assign po_wd    = R;
    assign mrd_data = R;
    assign mrd_cap  = out_m == O_MRES;
    assign po_index = np_r[10:0];
    assign ks_idx   = np_r[10:0];
    assign sort_n   = np_r;
    always_ff @(posedge clk) begin
        ks_we <= 1'b0; oc_valid <= 1'b0; ovf_set <= 1'b0; swap_ack <= 1'b0; sort_go <= 1'b0;
        test_done <= 1'b0; mrd_ack <= 1'b0;
        if (rst) begin
            po_valid <= 1'b0; np_r <= 12'd0; nv_r <= 13'd0; box_r <= 1'b0; sort_manual <= 1'b0;
        end else begin
            if (po_valid && po_ready) po_valid <= 1'b0;
            case (out_m)
                O_O0:    o0 <= R;
                O_O1:    o1 <= R;
                O_O2:    o2 <= R;
                O_O3:    o3 <= R;
                O_PUSHH: begin po_valid <= 1'b1; po_type <= 1'b0; end
                O_PUSHV: begin po_valid <= 1'b1; po_type <= 1'b1; end
                O_KEY:   if (!USORT) begin ks_we <= 1'b1; ks_key <= R[16:0]; end
                O_NPNV:  begin np_r <= R[11:0]; nv_r <= R[28:16]; end
                O_OC:    begin oc_valid <= 1'b1; oc_rej <= R[0]; oc_quad <= R[1]; end
                O_SWAP:  begin swap_ack <= 1'b1; sort_go <= 1'b1; sort_manual <= R[0]; end
                O_BOX:   box_r <= R[0];
                O_TDONE: test_done <= 1'b1;
                O_MRES:  mrd_ack <= 1'b1;
                O_OVF:   ovf_set <= 1'b1;
                default: ;
            endcase
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    // +swapmon: per swap, the clocks it waited on SDRAW and its sort output's length (first SOW to SOD)
    bit swm_on; int swm_w = 0, swm_n = 0, swm_t = -1, swm_c = 0;
    initial swm_on = $test$plusargs("swapmon");
    always_ff @(posedge clk) if (swm_on && !rst) begin
        swm_c++;
        if (a_nx == NX_JC && a_cond == C_SDRAW && s_draw) swm_w++;
        if (so_we && swm_t < 0) swm_t = swm_c;
        if (so_done) begin
            $display("swapmon swap %0d sdraw_wait %0d sort %0d", swm_n, swm_w, swm_t < 0 ? 0 : swm_c - swm_t);
            swm_n++; swm_w = 0; swm_t = -1;
        end
    end
    // synthesis translate_on
`endif
endmodule
