// The front as fitted in nds-fit #67 (e24bf06), for the equivalence check of
// later versions (GEOM_EQ in gpu3d_geom.sv; sim/gpu3d/geom.mk). Not for synthesis.
// NDS geometry engine front (docs/geometry-engine.md): the GX FIFO, GXSTAT
// and melonDS's command-timing model (GPU3D::Run/ExecuteCommand/AddCycles,
// references/melonDS/src/GPU3D.cpp), evaluated once per DS system cycle.
//
// Writes: the packed FIFO port (0x400-0x43F, WriteToGXFIFO's unpacking)
// and the command ports (0x440-0x5CB) take 32-bit writes. A write becomes
// up to four entries in a staging buffer; they go into the entry RAM, then
// are counted into melonDS's 4-entry PIPE and 256-entry FIFO in the second
// cycle of a tick, after that cycle's step and before the next tick's Run.
// An entry that does not fit stays staged and holds the bus (melonDS's
// stall queue and CPU stall); it is counted when a refill frees space.
//
// The model: each tick is melonDS's Run() for one system cycle. Step A (the
// tick cycle) decrements CycleCount and executes the PIPE head or runs
// FinishWork; step B (the next cycle) executes a second entry if the first
// left CycleCount <= 0. Every entry costs at least one cycle, so a Run never
// needs a third step. The model only tracks what timing and GXSTAT need;
// the engine (gpu3d_gxeng) runs the same entries behind it, up to `mx`.
//
// One thing flows back from the engine: whether each submitted polygon was
// rejected and whether it became a quad, which sets the polygon pipeline.
// The model counts the cycles since the submission and resolves the
// pipeline when the engine answers. It waits only where melonDS reads the
// pipeline: the next vertex slot, a stalling command, the busy bit.
module gpu3d_gxfront_ref (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,          // ends a 33.51 MHz system cycle
    input  logic        geom_en,       // POWCNT1 bit 3 (GeometryEnabled)
    input  logic        vblank,        // GPU3D::VBlank
    // writes, word address within 0x4000400..0x40007FF
    input  logic        wr_req,
    input  logic [3:0]  wr_be,
    input  logic [9:2]  wr_addr,
    input  logic [31:0] wr_data,
    output logic        wr_wait,
    // GXSTAT (0x600) without the engine's bits 0/1; DISP_1DOT_DEPTH
    output logic [31:0] gxstat,
    output logic [23:0] zerodot,
    output logic        flush_req,     // FlushRequest
    output logic        irq,           // GX FIFO IRQ condition (GXSTAT 31:30)
    output logic        dma_low,       // FIFO under half full (DMA mode 7)
    output logic        gx_stall,      // staged entries wait for FIFO space (melonDS GXFIFOStall)
    // entry RAM read port for the engine
    input  logic [8:0]  e_addr,
    output logic [39:0] e_data,        // {cmd, param}, the cycle after e_addr
    output logic [8:0]  mx,            // next entry the model executes
    input  logic [8:0]  dp,            // next entry the engine runs
    output logic        sp_clr,        // GXSTAT bit 15 written: proj/tex stack
    output logic [8:0]  sp_clr_at,     //   pointers to 0 before this entry
    // polygon outcomes from the engine, in submission order
    input  logic        oc_valid,
    input  logic        oc_rej,
    input  logic        oc_quad,
    output logic        test_exec,     // a BOX/POS/VEC_TEST completed in the model
    // test bench
    output logic        dbg_stall,     // the model waits for an outcome
    output logic        dbg_apply      // staged entries were counted this cycle
);
    // CmdNumParams
    function automatic [5:0] nparams(input [7:0] c);
        case (c)
            8'h10, 8'h12, 8'h13, 8'h14, 8'h20, 8'h21, 8'h22, 8'h24, 8'h25,
            8'h26, 8'h27, 8'h28, 8'h29, 8'h2A, 8'h2B, 8'h30, 8'h31, 8'h32, 8'h33,
            8'h40, 8'h50, 8'h60, 8'h72: nparams = 6'd1;
            8'h16, 8'h18: nparams = 6'd16;
            8'h17, 8'h19: nparams = 6'd12;
            8'h1A: nparams = 6'd9;
            8'h1B, 8'h1C, 8'h70: nparams = 6'd3;
            8'h23, 8'h71: nparams = 6'd2;
            8'h34: nparams = 6'd32;
            default: nparams = 6'd0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // staging: one bus write -> up to four entries (WriteToGXFIFO)
    // ------------------------------------------------------------------
    logic [2:0]  pk_nc;                // NumCommands
    logic [31:0] pk_cur;               // CurCommand
    logic [5:0]  pk_pc, pk_tp;         // ParamCount, TotalParams
    logic [2:0]  st_n, st_w, st_a;     // staged, written to RAM, counted
    logic [7:0]  st_cmd [4];
    logic [31:0] st_param;             // all entries of one write carry its word
    wire         st_busy = st_n != 3'd0;

    logic [2:0]  u_n;
    logic [7:0]  u_cmd [4];
    logic [2:0]  u_nc;
    logic [31:0] u_cur;
    logic [5:0]  u_pc, u_tp;
    wire         w_fifo = wr_req && wr_be == 4'hF && !wr_addr[9] && wr_addr[8:2] < 7'h73 && geom_en;
    wire         w_pack = wr_addr[8:6] == 3'b000;          // 0x400-0x43F
    always_comb begin
        logic [2:0]  nc;
        logic [31:0] cur;
        logic [5:0]  pc, tp;
        logic        done;
        u_n = 3'd0;
        for (int k = 0; k < 4; k++) u_cmd[k] = 8'h00;
        nc = pk_nc; cur = pk_cur; pc = pk_pc; tp = pk_tp; done = 1'b0;
        if (!w_pack) begin
            u_n = 3'd1;
            u_cmd[0] = {1'b0, wr_addr[8:2]};
            done = 1'b1;
        end else if (nc == 3'd0) begin
            nc = 3'd4; cur = wr_data; pc = 6'd0; tp = nparams(wr_data[7:0]);
            if (tp != 6'd0) done = 1'b1;
        end else
            pc = pc + 6'd1;
        for (int it = 0; it < 4; it++) begin
            if (!done) begin
                if (cur[7:0] != 8'h00 || (nc == 3'd4 && cur == 32'd0)) begin
                    u_cmd[u_n[1:0]] = cur[7:0];
                    u_n = u_n + 3'd1;
                end
                if (pc >= tp) begin
                    cur = {8'h00, cur[31:8]};
                    nc = nc - 3'd1;
                    if (nc == 3'd0) done = 1'b1;
                    else begin pc = 6'd0; tp = nparams(cur[7:0]); end
                end
                if (!done && pc < tp) done = 1'b1;
            end
        end
        u_nc = nc; u_cur = cur; u_pc = pc; u_tp = tp;
    end
    // a FIFO write completes once its entries are counted (as melonDS's
    // synchronous Write32), so a following GXSTAT read sees it
    wire   st_done = st_busy && st_a == st_n && st_w == st_n;
    assign wr_wait = w_fifo && !st_done && !(!st_busy && u_n == 3'd0);

    // ------------------------------------------------------------------
    // entry RAM {cmd, param} for the engine, narrow copy for the model
    // ------------------------------------------------------------------
    logic [8:0]  wr;
    logic [8:0]  mx_n;                 // mx next cycle (narrow RAM address)
    logic [13:0] hd;                   // narrow[mx]: {cmd, param[5:0]}
    wire  [8:0]  used = wr - dp;
    wire         ram_we = st_busy && st_w != st_n && used != 9'd511;
    wire  [39:0] ram_wd = {st_cmd[st_w[1:0]], st_param};
    gpu3d_ram #(.W(40), .AW(9)) u_ent (
        .clk, .we(ram_we), .waddr(wr), .wdata(ram_wd), .raddr(e_addr), .rdata(e_data));
    gpu3d_ram #(.W(14), .AW(9)) u_nar (
        .clk, .we(ram_we), .waddr(wr), .wdata({ram_wd[39:32], ram_wd[5:0]}), .raddr(mx_n), .rdata(hd));

    // ------------------------------------------------------------------
    // model state
    // ------------------------------------------------------------------
    typedef struct packed {
        logic signed [15:0] cyc;       // CycleCount
        logic [2:0] vp, np;            // VertexPipeline, NormalPipeline
        logic [5:0] pp;                // PolygonPipeline
        logic [3:0] vsc;               // VertexSlotCounter
        logic [4:0] vsf;               // VertexSlotsFree
        logic       pend;              // a submitted polygon's outcome is unknown
        logic [5:0] pend_e;            //   cycles since (saturating)
    } tm_t;
    tm_t         tm;
    logic        pend_strip;
    logic [1:0]  oc_skip;              // outcomes of polygons a later submission superseded
    logic [8:0]  f;                    // CmdFIFO level
    logic [2:0]  p;                    // CmdPIPE level
    logic [1:0]  mmode;                // MatrixMode
    logic [3:0]  pattr_l, cattr_l;     // light enables of PolygonAttr / CurPolygonAttr
    logic [1:0]  pmode;                // PolygonMode
    logic [2:0]  vnip;                 // VertexNumInPoly
    logic        ncons_odd;            // NumConsecutivePolygons & 1
    logic [5:0]  xpc;                  // ExecParamCount
    logic        flush;
    logic        busy, b14, b0, b15;
    logic [8:0]  npush, ntest;         // NumPushPopCommands, NumTestCommands
    logic [5:0]  psp;                  // PosMatrixStackPointer
    logic        jsp, tsp;             // Proj/Tex stack pointers
    logic [1:0]  irqm;
    logic [23:0] zdot;
    logic        phase;                // 1 in the cycle after the tick (step B)
    assign flush_req = flush;
    assign zerodot = zdot;

    // AddCycles(num)
    function automatic tm_t addc(input tm_t s, input [9:0] num);
        tm_t r;
        logic [6:0] v;
        r = s;
        r.cyc = s.cyc + $signed({6'd0, num});
        r.vp = ({7'd0, s.vp} > num) ? s.vp - num[2:0] : 3'd0;
        if (s.pend)
            r.pend_e = ({4'd0, s.pend_e} + num > 10'd63) ? 6'd63 : s.pend_e + num[5:0];
        else if (s.pp != 6'd0) begin
            if ({4'd0, s.pp} > num) begin
                r.pp = s.pp - num[5:0];
                v = {3'd0, s.vsc} + num[6:0];                // <= 44
                if (v > 7'd36)      begin r.vsc = 4'(v - 7'd36); r.vsf = s.vsf >> 4; end
                else if (v > 7'd27) begin r.vsc = 4'(v - 7'd27); r.vsf = s.vsf >> 3; end
                else if (v > 7'd18) begin r.vsc = 4'(v - 7'd18); r.vsf = s.vsf >> 2; end
                else if (v > 7'd9)  begin r.vsc = 4'(v - 7'd9);  r.vsf = s.vsf >> 1; end
                else                      r.vsc = v[3:0];
            end else begin
                r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
            end
        end
        addc = r;
    endfunction

    // NextVertexSlot, closed form: after iteration k the cycles added are
    // num1 + 9(k-1), num1 = 10 - VertexSlotCounter; iteration k expires the
    // pipeline if PolygonPipeline <= that, else takes slot k if it is free.
    function automatic tm_t nvs(input tm_t s);
        tm_t r;
        logic [5:0] t [1:5];
        logic [2:0] k;
        logic       ex;
        logic [5:0] fr;                // VertexSlotsFree, with a zero bit 5 for the expiry-only iteration
        r = s;
        fr = {1'b0, s.vsf};
        for (int i = 1; i <= 5; i++) t[i] = 6'(10 - s.vsc) + 6'(9 * (i - 1));
        k = 3'd5; ex = 1'b1;
        for (int i = 5; i >= 1; i--) begin
            if (s.pp <= t[i])             begin k = 3'(i); ex = 1'b1; end
            else if (fr[i])               begin k = 3'(i); ex = 1'b0; end
        end
        r.cyc = s.cyc + $signed({10'd0, t[k]});
        r.vp = ({3'd0, s.vp} > t[k]) ? s.vp - t[k][2:0] : 3'd0;
        if (ex) begin
            r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
        end else begin
            r.pp = s.pp - t[k];
            r.vsc = 4'd1;
            r.vsf = (s.vsf >> k) & 5'b11110;
        end
        nvs = r;
    endfunction

    // StallPolygonPipeline(delay, nonstalldelay)
    function automatic tm_t stallpp(input tm_t s, input [3:0] delay, input [2:0] nsd);
        tm_t r;
        if (s.pp != 6'd0) begin
            r = s;
            r.cyc = s.cyc + $signed({10'd0, s.pp}) + $signed({12'd0, delay});
            r.vp = 3'd0; r.np = 3'd0; r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
        end else if (s.vp > nsd)
            r = addc(s, {7'd0, s.vp - nsd} + 10'd1);
        else
            r = addc(s, {7'd0, s.np} + 10'd1);
        stallpp = r;
    endfunction

    // the outcome arrives: the polygon pipeline `pend_e` cycles after
    // SubmitPolygon set it (rejected 8, triangle 26, quad 35)
    function automatic tm_t resolve(input tm_t s, input rej, input quad, input strip);
        tm_t r;
        logic [5:0] pp0, e;
        logic [4:0] vsf0;
        r = s;
        e = s.pend_e;
        if (rej)       begin pp0 = 6'd8;  vsf0 = 5'b11110; end
        else if (quad) begin pp0 = 6'd35; vsf0 = strip ? 5'b11100 : 5'b11110; end
        else           begin pp0 = 6'd26; vsf0 = strip ? 5'b01000 : 5'b01110; end
        r.pend = 1'b0;
        if (e >= pp0) begin
            r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
        end else begin
            r.pp = pp0 - e;
            if (e >= 6'd27)      begin r.vsc = 4'(e - 6'd26); r.vsf = vsf0 >> 3; end
            else if (e >= 6'd18) begin r.vsc = 4'(e - 6'd17); r.vsf = vsf0 >> 2; end
            else if (e >= 6'd9)  begin r.vsc = 4'(e - 6'd8);  r.vsf = vsf0 >> 1; end
            else                 begin r.vsc = 4'(e + 6'd1);  r.vsf = vsf0;      end
        end
        resolve = r;
    endfunction

    // ------------------------------------------------------------------
    // one execution of the PIPE head (GPU3D::ExecuteCommand's timing)
    // ------------------------------------------------------------------
    tm_t         s0, s_ex;
    wire  [7:0]  hc = hd[13:6];
    wire  [5:0]  hparam = hd[5:0];
    wire  [5:0]  hnp = nparams(hc);
    logic        x_needpp, x_submit, x_sub;
    // the head entry reads the polygon pipeline (VertexPipelineSubmitCmd or a stall)
    wire         h_needpp = (hnp <= 6'd1) ? (hc >= 8'h24 && hc <= 8'h28) || hc == 8'h32 || hc == 8'h40
                                          : (xpc == 6'd0) && (hc == 8'h23 || hc == 8'h70);
    logic [2:0]  x_vnip;
    logic        x_ncons;
    logic [5:0]  x_xpc;
    logic [1:0]  x_mmode, x_pmode;
    logic [3:0]  x_pattr, x_cattr;
    logic        x_flush, x_b15;
    logic [5:0]  x_psp;
    logic        x_jsp, x_tsp, x_pushpop;
    logic [1:0]  x_ntest;
    // The execution is one pre-step (StallPolygonPipeline's pipeline branch,
    // or NextVertexSlot), then one AddCycles of the cycles the command adds
    // in total, which also serves FinishWork. melonDS's successive
    // AddCycles calls combine: AddCycles(a); AddCycles(b) == AddCycles(a + b).
    logic [9:0]  x_num;                // AddCycles of this step
    logic        x_pre_pp;             // stall branch with a polygon pipeline: zero it
    logic        x_nvs;                // NextVertexSlot first
    logic        x_vp4;                // SubmitVertex: VertexPipeline = 7 before AddCycles(3)
    logic [3:0]  x_delay;
    logic [2:0]  x_np;                 // NormalPipeline afterwards
    always_comb begin
        logic [9:0] lights, d6, d8, base;
        x_needpp = 1'b0; x_submit = 1'b0; x_sub = 1'b0;
        x_vnip = vnip; x_ncons = ncons_odd; x_xpc = xpc;
        x_mmode = mmode; x_pmode = pmode; x_pattr = pattr_l; x_cattr = cattr_l;
        x_flush = flush; x_b15 = b15; x_psp = psp; x_jsp = jsp; x_tsp = tsp;
        x_pushpop = 1'b0; x_ntest = 2'd0;
        x_num = 10'd0; x_pre_pp = 1'b0; x_nvs = 1'b0; x_vp4 = 1'b0; x_delay = 4'd0; x_np = 3'd0;
        lights = 10'(cattr_l[0]) + 10'(cattr_l[1]) + 10'(cattr_l[2]) + 10'(cattr_l[3]);
        base = {7'd0, s0.np} + 10'd1;                                     // Delayed4
        d6 = (s0.vp > 3'd2) ? {7'd0, s0.vp} - 10'd1 : base;               // Delayed6
        d8 = (s0.vp > 3'd0) ? {7'd0, s0.vp} + 10'd1 : base;               // Delayed8
        if (hnp <= 6'd1) begin
            case (hc)
                8'h10: begin x_num = base; x_mmode = hparam[1:0]; end
                8'h11: begin
                    x_num = base + 10'd16; x_pushpop = 1'b1;
                    if (mmode == 2'd0)      begin if (jsp) x_b15 = 1'b1; x_jsp = ~jsp; end
                    else if (mmode == 2'd3) begin if (tsp) x_b15 = 1'b1; x_tsp = ~tsp; end
                    else begin if (psp > 6'd30) x_b15 = 1'b1; x_psp = psp + 6'd1; end
                end
                8'h12: begin
                    x_num = base + ((mmode == 2'd3) ? 10'd17 : 10'd35); x_pushpop = 1'b1;
                    if (mmode == 2'd0)      begin if (!jsp) x_b15 = 1'b1; x_jsp = ~jsp; end
                    else if (mmode == 2'd3) begin if (!tsp) x_b15 = 1'b1; x_tsp = ~tsp; end
                    else begin x_psp = psp - hparam; if (x_psp > 6'd30) x_b15 = 1'b1; end
                end
                8'h13: begin
                    x_num = base + 10'd16;
                    if ((mmode == 2'd1 || mmode == 2'd2) && hparam[4:0] == 5'd31) x_b15 = 1'b1;
                end
                8'h14: begin
                    x_num = base + ((mmode == 2'd3) ? 10'd17 : 10'd35);
                    if ((mmode == 2'd1 || mmode == 2'd2) && hparam[4:0] == 5'd31) x_b15 = 1'b1;
                end
                8'h15: x_num = base + ((mmode == 2'd3) ? 10'd0 : 10'd18);
                8'h20: x_num = d6;
                8'h30, 8'h31: x_num = d6 + 10'd3;
                8'h72: begin x_num = d6 + 10'd4; x_ntest = 2'd1; end
                8'h21: begin x_num = base + ((lights == 10'd0) ? 10'd1 : lights); x_np = 3'd7; end   // CalculateLighting
                8'h24, 8'h25, 8'h26, 8'h27, 8'h28: begin x_needpp = 1'b1; x_submit = 1'b1; end
                8'h29: begin x_num = d8; x_pattr = hparam[3:0]; end
                8'h2A, 8'h2B, 8'h41, 8'h60: x_num = d8;
                8'h33: x_num = d8 + 10'd1;
                8'h32: begin x_needpp = 1'b1; x_pre_pp = s0.pp != 6'd0; x_delay = 4'd9;
                             x_num = ((s0.pp != 6'd0) ? 10'd0 : (s0.vp > 3'd2) ? {7'd0, s0.vp} - 10'd1 : base) + 10'd5; end
                8'h40: begin
                    x_needpp = 1'b1; x_pre_pp = s0.pp != 6'd0; x_delay = 4'd1;
                    x_num = (s0.pp != 6'd0) ? 10'd0 : (s0.vp > 3'd0) ? {7'd0, s0.vp} + 10'd1 : base;
                    x_pmode = hparam[1:0]; x_vnip = 3'd0; x_ncons = 1'b0; x_cattr = pattr_l;
                end
                8'h50: x_flush = 1'b1;
                default: x_num = base;
            endcase
        end else begin
            x_xpc = xpc + 6'd1;
            if (x_xpc == 6'd1) begin
                case (hc)
                    8'h23: x_needpp = 1'b1;
                    8'h34, 8'h71: x_num = d8;
                    8'h70: begin x_needpp = 1'b1; x_pre_pp = s0.pp != 6'd0; x_delay = 4'd11;
                                 x_num = (s0.pp != 6'd0) ? 10'd0 : (s0.vp > 3'd0) ? {7'd0, s0.vp} + 10'd1 : base; end
                    default: x_num = base;
                endcase
            end else begin
                x_num = 10'd1;
                x_np = s0.np;
                if (x_xpc >= hnp) begin
                    x_xpc = 6'd0;
                    case (hc)
                        8'h16: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd10 : 10'd18);
                        8'h17: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd7  : 10'd18);
                        8'h18: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd17 : (mmode == 2'd2) ? 10'd49 : 10'd19);
                        8'h19: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd21 : (mmode == 2'd2) ? 10'd53 : 10'd23);
                        8'h1A: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd24 : (mmode == 2'd2) ? 10'd56 : 10'd26);
                        8'h1B: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd30 : 10'd32);
                        8'h1C: x_num = 10'd1 + ((mmode == 2'd3) ? 10'd30 : (mmode == 2'd2) ? 10'd62 : 10'd32);
                        8'h23: begin x_submit = 1'b1; x_np = 3'd0; end
                        8'h71: begin x_num = 10'd6; x_ntest = 2'd2; end
                        8'h70: begin x_num = 10'd255; x_ntest = 2'd3; end
                        default: ;
                    endcase
                end
            end
        end
        // VertexPipelineSubmitCmd: the next vertex slot, or AddCycles(1)
        if (x_needpp && (x_submit || hc == 8'h23)) begin
            if (!s0.vsf[0]) x_nvs = 1'b1; else x_num = x_num + 10'd1;
        end
        // SubmitVertex: VertexPipeline = 7, AddCycles(3)
        if (x_submit) begin
            x_vnip = vnip + 3'd1;
            case (pmode)
                2'd0: if (x_vnip == 3'd3) begin x_vnip = 3'd0; x_sub = 1'b1; end
                2'd1: if (x_vnip == 3'd4) begin x_vnip = 3'd0; x_sub = 1'b1; end
                2'd2: if (ncons_odd || x_vnip == 3'd3) begin x_vnip = 3'd2; x_sub = 1'b1; end
                default: if (x_vnip == 3'd4) begin x_vnip = 3'd2; x_sub = 1'b1; end
            endcase
            if (x_sub) x_ncons = ~ncons_odd;
            x_num = x_num + 10'd3;
            x_vp4 = 1'b1;
        end
    end
    // ------------------------------------------------------------------
    // the step of this cycle
    // ------------------------------------------------------------------
    logic run_skip, do_exec, do_fin;
    tm_t  s_fin, s_next;
    always_comb begin
        tm_t t;
        t = tm;
        if (oc_valid && t.pend && oc_skip == 2'd0) t = resolve(t, oc_rej, oc_quad, pend_strip);
        run_skip = !geom_en || flush || (p == 3'd0 && !busy);
        // time stands still while the head waits for an outcome (no debt)
        if (tick && !run_skip && !(t.cyc <= 16'sd1 && p != 3'd0 && h_needpp && t.pend)) t.cyc = t.cyc - 16'sd1;
        s0 = t;
    end
    tm_t s_pre, s_add;
    always_comb begin
        logic [9:0] c, n;
        // step A in the tick cycle, step B in the next one
        do_exec = !run_skip && (tick || phase) && s0.cyc <= 16'sd0 && p != 3'd0 &&
                  !(h_needpp && s0.pend);
        do_fin  = !run_skip && (tick || phase) && s0.cyc <= 16'sd0 && p == 3'd0;
        c = 10'(-s0.cyc);                 // FinishWork(-CycleCount), 0..1
        // pre-step
        s_pre = s0;
        if (x_nvs) s_pre = nvs(s0);
        else if (x_pre_pp) begin
            s_pre.cyc = s0.cyc + $signed({10'd0, s0.pp}) + $signed({12'd0, x_delay});
            s_pre.vp = 3'd0; s_pre.np = 3'd0; s_pre.pp = 6'd0; s_pre.vsc = 4'd0; s_pre.vsf = 5'd1;
        end
        // the one AddCycles
        n = do_exec ? x_num : c;
        s_add = addc(do_exec ? s_pre : s0, n);
        // execution results
        s_ex = s_add;
        s_ex.np = (x_needpp && (x_submit || hc == 8'h23) || x_pre_pp) ? 3'd0 : x_np;
        if (x_vp4) s_ex.vp = 3'd4;
        if (x_sub) begin s_ex.pend = 1'b1; s_ex.pend_e = 6'd3; s_ex.cyc = s_pre.cyc + $signed({6'd0, x_num}); end
        if (x_flush) begin
            s_ex = s0;
            s_ex.cyc = 16'sd325; s_ex.vp = 3'd0; s_ex.np = 3'd0; s_ex.pp = 6'd0; s_ex.vsc = 4'd0; s_ex.vsf = 5'd1;
        end
        // FinishWork
        s_fin = s_add;
        s_fin.np = (s0.np > c[2:0]) ? s0.np - c[2:0] : 3'd0;
        s_fin.cyc = 16'sd0;
        s_next = do_exec ? s_ex : do_fin ? s_fin : s0;
    end
    assign mx_n = mx + (do_exec ? 9'd1 : 9'd0);
    assign dbg_stall = !run_skip && (tick || phase) && s0.cyc <= 16'sd0 && p != 3'd0 && h_needpp && s0.pend;

    // staged entries counted this cycle: step B, or a refill freed space
    logic count_now;
    always_comb count_now = st_busy && st_a != st_w && (phase || (do_exec && f == 9'd256));
    assign dbg_apply = count_now;

    always_ff @(posedge clk) begin
        if (rst) begin
            tm <= '0; tm.vsf <= 5'd1;
            pend_strip <= 1'b0; oc_skip <= 2'd0; f <= 9'd0; p <= 3'd0;
            mmode <= 2'd0; pattr_l <= 4'd0; cattr_l <= 4'd0; pmode <= 2'd0; vnip <= 3'd0;
            ncons_odd <= 1'b0; xpc <= 6'd0; flush <= 1'b0;
            busy <= 1'b0; b14 <= 1'b0; b0 <= 1'b0; b15 <= 1'b0; npush <= 9'd0; ntest <= 9'd0;
            psp <= 6'd0; jsp <= 1'b0; tsp <= 1'b0; irqm <= 2'd0; zdot <= 24'hFFFFFF;
            phase <= 1'b0; mx <= 9'd0; wr <= 9'd0;
            pk_nc <= 3'd0; pk_cur <= 32'd0; pk_pc <= 6'd0; pk_tp <= 6'd0;
            st_n <= 3'd0; st_w <= 3'd0; st_a <= 3'd0; st_param <= 32'd0;
            sp_clr <= 1'b0; sp_clr_at <= 9'd0;
            for (int k = 0; k < 4; k++) st_cmd[k] <= 8'h00;
        end else begin
            logic [8:0] fv, npv, ntv;
            logic [2:0] pv, sa;
            logic       bz, c14, c0;
            phase <= tick;
            tm <= s_next;
            if (do_exec && x_sub && s0.pend) oc_skip <= oc_skip + 2'd1 - ((oc_valid && oc_skip != 2'd0) ? 2'd1 : 2'd0);
            else if (oc_valid && oc_skip != 2'd0) oc_skip <= oc_skip - 2'd1;
            fv = f; pv = p; npv = npush; ntv = ntest; bz = busy; c14 = b14; c0 = b0; sa = st_a;
            // melonDS clears bits 14/0 before each ExecuteCommand and at the end of Run
            if (do_exec || do_fin) begin
                if (npv == 9'd0) c14 = 1'b0;
                if (ntv == 9'd0) c0 = 1'b0;
            end
            if (do_exec) begin
                vnip <= x_vnip; ncons_odd <= x_ncons; xpc <= x_xpc; mmode <= x_mmode; pmode <= x_pmode;
                pattr_l <= x_pattr; cattr_l <= x_cattr; flush <= x_flush;
                b15 <= x_b15; psp <= x_psp; jsp <= x_jsp; tsp <= x_tsp;
                if (x_sub) pend_strip <= pmode[1];
                // a submission while one is pending (VTX_16 completed by a parameter
                // another command started): SubmitPolygon overwrote that pipeline
                if (x_pushpop) npv = npv - 9'd1;
                ntv = ntv - {7'd0, x_ntest};
                // CmdFIFORead: pop, refill to 4 when 2 or fewer are left
                pv = pv - 3'd1;
                if (pv <= 3'd2 && fv != 9'd0) begin
                    if (fv == 9'd1) begin pv = pv + 3'd1; fv = 9'd0; end
                    else begin pv = pv + 3'd2; fv = fv - 9'd2; end
                end
                mx <= mx + 9'd1;
            end
            if (do_fin && s_fin.vp == 3'd0 && s_fin.np == 3'd0 && s_fin.pp == 6'd0 && !s_fin.pend)
                bz = 1'b0;
            // CmdFIFOWrite for the staged entries that are in the RAM
            if (count_now) begin
                for (int k = 0; k < 4; k++) begin
                    if (3'(k) == sa && sa != st_w && fv != 9'd256) begin
                        if (fv == 9'd0 && pv != 3'd4) pv = pv + 3'd1;
                        else fv = fv + 9'd1;
                        bz = 1'b1;
                        if (st_cmd[k] == 8'h11 || st_cmd[k] == 8'h12) begin c14 = 1'b1; npv = npv + 9'd1; end
                        if (st_cmd[k] == 8'h70 || st_cmd[k] == 8'h71 || st_cmd[k] == 8'h72) begin c0 = 1'b1; ntv = ntv + 9'd1; end
                        sa = sa + 3'd1;
                    end
                end
            end
            f <= fv; p <= pv; npush <= npv; ntest <= ntv; busy <= bz; b14 <= c14; b0 <= c0;
            st_a <= sa;

            // staging: accept a write when empty, free it when all are counted
            if (!st_busy && w_fifo) begin
                st_n <= u_n; st_w <= 3'd0; st_a <= 3'd0; st_param <= wr_data;
                for (int k = 0; k < 4; k++) st_cmd[k] <= u_cmd[k];
                if (w_pack) begin pk_nc <= u_nc; pk_cur <= u_cur; pk_pc <= u_pc; pk_tp <= u_tp; end
                // a packed word that only sets up its command (parameters follow) stages nothing
                if (u_n == 3'd0) st_n <= 3'd0;
            end else if (st_done) st_n <= 3'd0;
            if (ram_we) begin st_w <= st_w + 3'd1; wr <= wr + 9'd1; end

            // GXSTAT (0x600) and DISP_1DOT_DEPTH (0x610)
            sp_clr <= 1'b0;
            if (wr_req && geom_en && wr_addr[9] && wr_addr[8:2] == 7'h00) begin
                if (wr_be[1] && wr_data[15]) begin
                    b15 <= 1'b0; jsp <= 1'b0; tsp <= 1'b0;
                    sp_clr <= 1'b1; sp_clr_at <= mx_n;
                end
                if (wr_be[3]) irqm <= wr_data[31:30];
            end
            if (wr_req && geom_en && wr_addr[9] && wr_addr[8:2] == 7'h04 && wr_be[1:0] == 2'b11)
                zdot <= {wr_data[14:0], 9'h1FF};
            if (vblank && geom_en) flush <= 1'b0;
        end
    end

    assign gxstat = {irqm, 2'b00, busy, f == 9'd0, f < 9'd128, f, b15, b14, jsp, psp[4:0], 6'd0, 1'b0, b0};
    assign irq = (irqm == 2'd1 && f < 9'd128) || (irqm == 2'd2 && f == 9'd0);
    assign dma_low = f < 9'd128;
    assign gx_stall = st_busy && st_a != st_n && (f == 9'd256 || used == 9'd511);
    assign test_exec = do_exec && x_ntest != 2'd0;
endmodule
