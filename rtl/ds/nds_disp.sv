// Display controller (docs/phase2-integration.md, "Display"): DS line
// timing, DISPSTAT/VCOUNT for both CPUs, the 2D engines' register file with
// melonDS's per-line updates, and the line sequencer of the shared 2D engine
// (rtl/gpu2d). Runs at 67.03 MHz: a DS line is 355 dots x 6 = 2,130 system
// clocks = 4,260 clocks here, 263 lines a frame.
//
// Timing (melonDS GPU::StartScanline / StartHBlank, in system clocks):
//   0     line start: VCOUNT advances (or takes a written value), HBlank flag
//         clears, windows' vertical state (UpdateWindows), VBlank at 192
//         (flag, IRQ, DMA, capture end), VBlank end at 262, display-start
//         DMA for VCOUNT 2..193, VCOUNT match
//   1584  HBlank: flag, then the line's register work: PreDraw, the drawing
//         of line VCOUNT (< 192) from the registers as they are now, OBJs of
//         the next line, PostDraw; HBlank DMA (VCOUNT < 192) and IRQ.
// Drawing here means: copy each engine's line state into the 2D engine and
// start its jobs (BG of line n for A then B; OBJs of line n+1 beside them).
// The jobs run for up to one line, so line n's pixels come out during the
// next line. If the engine is still busy at the next HBlank (slow VRAM),
// that HBlank's register work waits for it; a line whose HBlank comes while
// an earlier one still waits is not drawn (its register updates still run).
//
// AR_RAM keeps DISPCNT, BGnCNT, WINCNT, BLDCNT/BLDALPHA/BLDY and
// MASTER_BRIGHT in an M10K (u_ar, a second copy u_rb for CPU reads) instead
// of flip-flops. They are read only by the state copy (Q_LOAD, one word a
// clock, as u_pr) and the CPU, both a clock after the address, so nothing
// moves in time; the bits the line sequencer tests (DISPCNT[14:7], BG2CNT
// and BG3CNT bit 6) are kept as flip-flop shadows.
module nds_disp
    import gpu2d_pkg::*;
#(
    parameter bit AR_RAM = 1,
    parameter bit WST_RF = 1,         // gpu2d: per-pass state words read from its register file
    parameter int TEX_IDXW = 6,       // gpu2d: log2 blocks in the BG texel cache
    parameter bit MOSAIC   = 1,       // 0: no BG/OBJ mosaic (fit setting): MOSAIC reads as size 0
    parameter bit OAM_CPU  = 0,       // gpu2d OAM_CPU: CPU OAM reads through the 2D engine's OAM
    parameter bit TAG_MLAB = 0,       // gpu2d: ext-palette cache tags in the data words (no tag RAM)
    // HURRY_AT: the BG job is near its line's deadline once it has run this
    // many clocks (of the 4,260 a line has): hurry2d asks the SDRAM bus to
    // serve its blocks before other ports' and to end a write chain early
    // (capture writes and texel blocks otherwise delay it: mkds-intro-cut's
    // late lines). 0: never
    parameter int HURRY_AT = 0
) (
    input  logic        vram_wr,        // VRAM or VRAMCNT written (the 2D engine's caches)
    // 3D layer (nds_gpu3d): engine A's BG job for l3d_line reads x = l3d_raddr
    output logic        l3d_go,
    output logic [7:0]  l3d_line,
    output logic [7:0]  l3d_raddr,
    input  logic [31:0] l3d_rdata,
    input  logic        clk,
    input  logic        rst,
    // I/O: engine registers (ARM9 0x000-0x06F, 0x1000-0x106F) and
    // DISPSTAT/VCOUNT (both CPUs); data the cycle after io_req
    input  logic        io_req,
    input  logic        io_cpu,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [12:2] io_addr,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    input  logic [15:0] powcnt1,
    input  logic [3:0]  lcdc_ab,        // banks A-D mapped to LCDC (capture, VRAM display)
    // events
    output logic [8:0]  vcount,
    output logic        line_start,     // pulse at clock 0 of each line
    output logic [1:0]  irq_vblank,     // pulses per CPU (9, 7)
    output logic [1:0]  irq_hblank,
    output logic [1:0]  irq_vcount,
    output logic        dma_vblank,     // pulse: VBlank DMA (both CPUs)
    output logic        dma_hblank,     // ARM9 HBlank DMA
    output logic        dma_dstart,     // ARM9 display-start DMA
    output logic        dma_dstop,      // stop display-start DMA (line 194)
    output logic        dma_mmstop,     // stop main-memory-display DMA (line 192)
    output logic        frame_start,    // pulse at line 0 (3D stub, video)
    // the 2D engine's VRAM block port and capture writes
    output logic        vr_req,
    output blk_t        vr_blk,
    input  logic        vr_ack,
    input  logic        vr_rvalid,
    input  logic [63:0] vr_rdata,
    output logic        cap_we,
    output logic [17:0] cap_addr,
    output logic [15:0] cap_data,
    input  logic        cap_ready,
    // palette and OAM writes from the fabric
    input  logic        pal_we,
    input  logic        oam_we,
    input  logic [8:0]  po_waddr,
    input  logic [31:0] po_wdata,
    input  logic [3:0]  po_be,
    output logic [31:0] pal_cq,         // the CPU's palette read (gpu2d u_pal0)
    input  logic        oam_cre,        // OAM_CPU: the CPU's OAM read (gpu2d)
    output logic        oam_cgnt,
    output logic [31:0] oam_cq,
    // pixels: engine, line, x, 18-bit colour (r[5:0] g[11:6] b[17:12])
    output logic        px_valid,
    output logic        px_eng,
    output logic [7:0]  px_line,
    output logic [7:0]  px_x,
    output logic [17:0] px_rgb,
    output logic        stat_late,      // a line was not drawn (pulse)
    output logic        hurry2d,        // the BG job has run HURRY_AT clocks and is still busy
    // NDSDiag (docs/diag.md): plain outputs, pruned when unconnected
    output wire  [4:0]  diag_d_ev,      // per clock: late line, BG stall, OBJ stall, block request, first capture of a line
    output wire  [15:0] diag_d_bgmax,   // most bg_busy clocks in a line of the last frame
    output wire         diag_v_start,   // a block request accepted
    output wire         diag_v_stop,    // its first data word (in order)
    output wire         diag_l2d_v,     // a late line, and the line it was for
    output wire  [8:0]  diag_l2d_line
);
    // HBlank (DISPSTAT flag, IRQ, HBlank DMA, the 2D line's register
    // snapshot) at 1,608 bus clocks after the line starts: hwref run 22
    // (lat2d) puts the DS's flag 22-26 bus clocks after melonDS's 1,584
    // (48 + 256 x 6), which this core followed until then
    localparam int LINE = 4260, HBL = 3216;

    // ---------------------------------------------------------------- timing
    logic [12:0] hc;
    logic [8:0]  vc;
    logic [15:0] dstat [2];         // DISPSTAT per CPU
    logic [8:0]  vmatch [2];
    wire         t_line = hc == 13'd0;
    wire         t_hbl  = hc == HBL[12:0];

    // ---------------------------------------------------------------- registers (per engine)
    logic [31:0] dispcnt  [2];
    logic [15:0] bgcnt    [2][4];
    // BGxRef (stepped by PostDraw): nds_disp_refs (MLABs), below
    logic [31:0] ref_cq, ref_sq, ref_cw, ref_pw;
    logic        ref_cwe, ref_pwe;
    // (BGxRefReload and BGxRefInternal are in u_pr)
    logic [7:0]  win0     [2][4];   // Win0Coords: x1, x2, y1, y2
    logic [7:0]  win1     [2][4];
    logic [7:0]  wincnt   [2][4];
    logic [3:0]  bgmos    [2][2];   // BGMosaicSize
    logic [3:0]  objmos   [2][2];
    logic [13:0] bldcnt   [2];
    logic [12:0] bldalpha [2];      // as written (& 0x1F1F)
    logic [4:0]  eva [2], evb [2], evy [2];
    logic [15:0] mbright  [2];
    logic [31:0] capcnt;
    logic        cap_enable;
    // AR_RAM: the sequencer's bits of DISPCNT ([14:7]) and BG2/3CNT (bit 6)
    logic [7:0]  dsh      [2];
    logic [1:0]  bg6      [2];
    // per-line state
    logic [5:0]  dlatch   [2][2];   // DispCntLatch bits 7..12 (forced blank, OBJ)
    // the layer enables (DISPCNT 8..12) as the DS latches them: sampled at the
    // line boundary (hwref run 23 bgon_fine: a write anywhere in line n counts
    // for line n), then two HBlank stages, so a layer enabled in line n shows
    // on line n + 3 (melonDS: from HBlank, two stages)
    logic [5:1]  bgln     [2];
    logic [5:1]  bge      [2][2];
    logic [4:0]  layer_en [2];
    logic        obj_en   [2];
    logic        fblank   [2];
    logic [1:0]  w0act [2], w1act [2];
    logic [3:0]  bgmosy [2], bgmosymax [2], objmosy [2];
    logic        bgmoslatch [2], objmoslatch [2];
    logic [8:0]  bgmosline [2];
    logic [8:0]  objmosline [2];

    wire en0 = powcnt1[1];
    wire en1 = powcnt1[9];
    function automatic logic eng_en(input logic e);
        return e ? en1 : en0;
    endfunction
    function automatic logic [14:7] dc_seq(input logic x);
        return AR_RAM ? dsh[x] : dispcnt[x][14:7];
    endfunction
    function automatic logic dc_bit(input logic x, input int b);
        logic [14:7] d;
        d = dc_seq(x);
        return d[b];
    endfunction
    function automatic logic bgc6(input logic x, input logic i);
        return AR_RAM ? bg6[x][i] : bgcnt[x][2+i][6];
    endfunction

    // ---------------------------------------------------------------- I/O
    wire        e  = io_addr[12];
    wire [4:0]  w  = io_addr[6:2];
    wire        wr = io_req && io_we;
    function automatic logic [15:0] m16(input logic [15:0] o, input logic [31:0] d, input logic [3:0] b, input logic hi);
        logic [15:0] r;
        r = o;
        if (hi) begin
            if (b[2]) r[7:0]  = d[23:16];
            if (b[3]) r[15:8] = d[31:24];
        end else begin
            if (b[0]) r[7:0]  = d[7:0];
            if (b[1]) r[15:8] = d[15:8];
        end
        return r;
    endfunction
    // affine reference write: halfword or word only (melonDS has no byte form)
    function automatic logic [31:0] refw(input logic [31:0] o, input logic [31:0] d, input logic [3:0] b);
        logic [31:0] r;
        r = o;
        if (b[1:0] == 2'b11) r[15:0] = d[15:0];
        if (b[3:2] == 2'b11) r[31:16] = {{4{d[27]}}, d[27:16]};
        return r;
    endfunction
    wire hw_lo = io_be[1:0] == 2'b11;
    wire hw_hi = io_be[3:2] == 2'b11;

    // Scroll offsets, affine parameters (write-only for the CPU) and the
    // affine reference copies in a RAM:
    //   {e, 00, i}      {BGiVOFS, BGiHOFS}
    //   {e, 010, i}     {PC, PA} of BG 2+i (read by the line's state copy)
    //   {e, 011, i}     {PD, PB} of BG 2+i (stepped into the reference point)
    //   {e, 10, i, y}   BGxRefInternal (X, Y) of BG 2+i, copied at line start
    //   {e, 11, i, y}   BGxRefReload, written with the reference point
    // An affine parameter word (PA/PB or PC/PD) writes both of its BG's
    // words: the second half one cycle later (pw_*). Cleared after reset.
    logic [3:0]  pr_we, pw_be;
    logic [4:0]  pr_wa, pr_ra, pw_a, sq_wa;
    logic [31:0] pr_wd, pr_q, pw_d, sq_wd;
    logic        pw_v, sq_we, sq_ok;
    logic [5:0]  pr_cl;
    nds_sdp_ram #(.AW(5)) u_pr (.clk, .we(pr_we), .waddr(pr_wa), .wdata(pr_wd), .raddr(pr_ra), .rdata(pr_q));
    wire pr_io = wr && !io_cpu && eng_en(e);
    always_comb begin
        pr_we = 4'd0; pr_wa = {e, 2'b00, w[1:0]}; pr_wd = io_wdata; sq_ok = 1'b0;
        if (pr_cl != 6'd0) begin pr_we = 4'hF; pr_wa = 5'(pr_cl - 6'd1); pr_wd = 32'd0; end
        else if (pw_v) begin pr_we = pw_be; pr_wa = pw_a; pr_wd = pw_d; end
        else if (pr_io && w >= 5'h04 && w <= 5'h07) pr_we = io_be;
        else if (pr_io && (w == 5'h08 || w == 5'h0C)) begin          // PA (PB follows)
            pr_we = {2'b00, hw_lo, hw_lo}; pr_wa = {e, 3'b010, w[2]}; pr_wd = {16'd0, io_wdata[15:0]};
        end else if (pr_io && (w == 5'h09 || w == 5'h0D)) begin     // PC (PD follows)
            pr_we = {hw_lo, hw_lo, 2'b00}; pr_wa = {e, 3'b010, w[2]}; pr_wd = {io_wdata[15:0], 16'd0};
        end else if (pr_io && (w == 5'h0A || w == 5'h0B || w == 5'h0E || w == 5'h0F) && (hw_lo || hw_hi)) begin
            // the reload copy: the reference point as this write leaves it
            pr_we = 4'hF; pr_wa = {e, 2'b11, w[2], w[0]};
            pr_wd = ref_cw;
        end else if (sq_we) begin pr_we = 4'hF; pr_wa = sq_wa; pr_wd = sq_wd; sq_ok = 1'b1; end
    end
    always_ff @(posedge clk) begin
        if (rst) begin pr_cl <= 6'd32; pw_v <= 1'b0; end
        else begin
            if (pr_cl != 6'd0) pr_cl <= pr_cl - 6'd1;
            pw_v <= 1'b0;
            if (pr_io && (w == 5'h08 || w == 5'h0C || w == 5'h09 || w == 5'h0D)) begin
                pw_v <= hw_hi; pw_a <= {e, 3'b011, w[2]};
                pw_be <= w[0] ? {2'b11, 2'b00} : {2'b00, 2'b11};
                pw_d <= w[0] ? {io_wdata[31:16], 16'd0} : {16'd0, io_wdata[31:16]};
            end
        end
    end

    // (AR_RAM) u_ar: per engine {e, k}: 0 DISPCNT, 1 BG1CNT:BG0CNT,
    // 2 BG3CNT:BG2CNT, 3 WINCNT, 4 BLDALPHA:BLDCNT (as read back), 5
    // {MASTER_BRIGHT, BLDY as written}; u_rb is the same for CPU reads
    logic [3:0]  ar_we;
    logic [4:0]  ar_wa, ar_ra, rb_ra;
    logic [31:0] ar_wd, ar_q, rb_q;
    logic        rb_sel, rb_hi;
    always_comb begin
        ar_we = 4'd0; ar_wa = {e, 4'd0}; ar_wd = io_wdata;
        if (wr && !io_cpu) begin
            if (w == 5'h00) begin ar_we = io_be; if (e) ar_wd = io_wdata & 32'hC0B1FFF7; end
            else if (w == 5'h1B) begin
                ar_we = {io_be[1:0], 2'b00}; ar_wa = {e, 4'd5};
                ar_wd = {io_wdata[15:14], 6'd0, 3'd0, io_wdata[4:0], 16'd0};
            end else if (eng_en(e)) case (w)
                5'h02: begin ar_we = io_be; ar_wa = {e, 4'd1}; end
                5'h03: begin ar_we = io_be; ar_wa = {e, 4'd2}; end
                5'h12: begin ar_we = io_be; ar_wa = {e, 4'd3}; end
                5'h14: begin ar_we = io_be; ar_wa = {e, 4'd4}; ar_wd = io_wdata & 32'h1F1F3FFF; end
                5'h15: begin ar_we = {3'd0, io_be[0]}; ar_wa = {e, 4'd5}; ar_wd = {27'd0, io_wdata[4:0]}; end
                default: ;
            endcase
        end
        if (!AR_RAM) ar_we = 4'd0;
        case (w)
            5'h02:   rb_ra = {e, 4'd1};
            5'h03:   rb_ra = {e, 4'd2};
            5'h12:   rb_ra = {e, 4'd3};
            5'h14:   rb_ra = {e, 4'd4};
            5'h1B:   rb_ra = {e, 4'd5};
            default: rb_ra = {e, 4'd0};
        endcase
    end
    // M10K: a read of the address written at the same edge gives the old
    // data (as the flip-flops did: a CPU write in the cycle Q_LOAD reads that
    // word)
    generate if (AR_RAM) begin : g_ar
        nds_sdp_ram #(.AW(5)) u_ar (.clk, .we(ar_we), .waddr(ar_wa), .wdata(ar_wd), .raddr(ar_ra), .rdata(ar_q));
        nds_sdp_ram #(.AW(5)) u_rb (.clk, .we(ar_we), .waddr(ar_wa), .wdata(ar_wd), .raddr(rb_ra), .rdata(rb_q));
    end else begin : g_noar
        assign ar_q = 32'd0;
        assign rb_q = 32'd0;
    end endgenerate

    logic [31:0] io_r;
    assign io_rdata = rb_sel ? (rb_hi ? {16'd0, rb_q[31:16]} : rb_q) : io_r;
    always_ff @(posedge clk) begin
        logic [31:0] r;
        r = 32'd0;
        rb_sel <= AR_RAM && io_req && !io_we && !io_cpu
                  && (w == 5'h00 || w == 5'h02 || w == 5'h03 || w == 5'h12 || w == 5'h14 || w == 5'h1B);
        rb_hi <= w == 5'h1B;
        if (io_req && !io_we) begin
            if (w == 5'h01) r = io_cpu ? {7'd0, vc, dstat[1]} : (e ? 32'd0 : {7'd0, vc, dstat[0]});
            else if (!io_cpu) case (w)
                5'h00: r = AR_RAM ? 32'd0 : dispcnt[e];     // (AR_RAM: u_rb)
                5'h02: r = AR_RAM ? 32'd0 : {bgcnt[e][1], bgcnt[e][0]};
                5'h03: r = AR_RAM ? 32'd0 : {bgcnt[e][3], bgcnt[e][2]};
                5'h12: r = AR_RAM ? 32'd0 : {wincnt[e][3], wincnt[e][2], wincnt[e][1], wincnt[e][0]};
                5'h14: r = AR_RAM ? 32'd0 : {3'd0, bldalpha[e], 2'd0, bldcnt[e]};
                5'h19: r = e ? 32'd0 : capcnt;
                5'h1B: r = AR_RAM ? 32'd0 : {16'd0, mbright[e]};
                default: r = 32'd0;
            endcase
        end
        io_r <= r;
    end

    // ---------------------------------------------------------------- line sequencer state
    typedef enum logic [2:0] { Q_IDLE, Q_WAIT, Q_PRE, Q_LOAD, Q_RUN, Q_POST } q_t;
    logic        ld_v, ld_eng;          // state word read last cycle (u_pr answers now)
    logic [4:0]  ld_word;
    logic [31:0] ld_d;
    logic [3:0]  pk;                    // Q_POST: step being applied + 1
    logic [2:0]  pk_b;
    logic        pk_ph;                 // Q_POST: second clock of a step (no write: the refs' port is free for a CPU write)
    logic [3:0]  pc;                    // Q_PRE: reference copy step + 1
    logic [3:0]  pc_m;                  // Q_PRE: {x, i} BGs whose reference is copied this line
    q_t          q;
    logic        q_eng;
    logic [4:0]  q_word;
    logic [8:0]  q_line;
    logic        q_draw, q_reset, q_pend, q_pend_draw;
    logic        q_late;                // this line's BG was skipped (late): its OBJ jobs still run
    logic [8:0]  q_pend_line;
    logic        bg_busy, obj_busy, bg_done, obj_done;
    logic        g_bg_stall, g_obj_stall;   // gpu2d miss stalls (NDSDiag)
    // the state word goes to the 2D engine the clock its RAM data arrives (no
    // register stage: the engine is idle through Q_LOAD and reads none of it
    // before its jobs start)
    logic        st_we, st_eng;
    logic [4:0]  st_addr;
    logic [31:0] st_data;
    assign st_we   = ld_v;
    assign st_eng  = ld_eng;
    assign st_addr = ld_word;
    logic        bg_start, obj_start, bg_eng, obj_eng, bg_slot, obj_slot;
    logic [7:0]  bg_line, obj_line;
    logic [1:0]  jobs_left;         // BG jobs to start (A, B)
    logic [1:0]  ojobs_left;
    // ---- the affine reference points {x, i, y}, stepped by PostDraw
    // (nds_disp_refs: MLABs; read and written as the registers were)
    // a CPU write of BGxX/BGxY (0x0A/0x0B/0x0E/0x0F), merged into the
    // reference as it is now (the u_pr reload copy gets the same value)
    assign ref_cwe = !rst && pr_io && (w == 5'h0A || w == 5'h0B || w == 5'h0E || w == 5'h0F) && (hw_lo || hw_hi);
    assign ref_cw  = refw(ref_cq, io_wdata, io_be);
    // Q_POST step {x, i, y} (pk_b): the reload word at a frame's start, else
    // += PB / PD as u_pr gives it
    assign ref_pwe = !rst && q == Q_POST && pk != 4'd0 && !pk_ph && eng_en(pk_b[2]) && layer_en[pk_b[2]][2+pk_b[1]];
    assign ref_pw  = q_reset ? pr_q : ref_sq + (pk_b[0] ? {{16{pr_q[31]}}, pr_q[31:16]} : {{16{pr_q[15]}}, pr_q[15:0]});
    // Q_POST writes every other clock, so a CPU write (always >= 2 clocks
    // apart) waits at most one clock: one queue entry is enough
    nds_disp_refs #(.QD(1)) u_refs (.clk, .rst,
        .c_a({e, w[2], w[0]}), .c_q(ref_cq), .c_we(ref_cwe), .c_wd(ref_cw),
        .s_a(q == Q_POST ? pk_b : 3'(pc - 4'd1)), .s_q(ref_sq),
        .p_we(ref_pwe), .p_a(pk_b), .p_wd(ref_pw));

    // u_pr's read address: the state copy (Q_LOAD) or Q_POST's {PD, PB}
    always_comb begin
        // Q_POST step {x, i, y}: the reload word at a frame's start, else {PD, PB}
        if (q == Q_POST) pr_ra = q_reset ? {pk[2], 2'b11, pk[1], pk[0]} : {pk[2], 3'b011, pk[1]};
        else if (q_word == 5'd11 || q_word == 5'd12) pr_ra = {q_eng, 3'b010, q_word == 5'd12};
        else if (q_word >= 5'd7 && q_word <= 5'd10) pr_ra = {q_eng, 2'b10, 2'(q_word - 5'd7)};
        else pr_ra = {q_eng, 2'b00, 2'(q_word - 5'd3)};
    end
    always_comb
        case (q_word)
            5'd1:    ar_ra = {q_eng, 4'd1};
            5'd2:    ar_ra = {q_eng, 4'd2};
            5'd15:   ar_ra = {q_eng, 4'd3};
            5'd18:   ar_ra = {q_eng, 4'd4};
            5'd19:   ar_ra = {q_eng, 4'd5};
            default: ar_ra = {q_eng, 4'd0};
        endcase
    // Q_PRE step {x, i, y}: BGxRefInternal <- BGxRef
    always_comb begin
        logic [2:0] st;
        st = 3'(pc - 4'd1);
        sq_we = q == Q_PRE && pc != 4'd0 && pc_m[st[2:1]];
        sq_wa = {st[2], 2'b10, st[1], st[0]};
        sq_wd = ref_sq;
    end

    // state words for engine x
    function automatic logic ar_word(input logic [4:0] a);
        return AR_RAM && (a <= 5'd2 || a == 5'd15 || a == 5'd18 || a == 5'd19);
    endfunction
    function automatic logic [31:0] sword(input logic x, input logic [4:0] a);
        if (ar_word(a)) return 32'd0;     // from u_ar
        case (a)
            5'd0:  return dispcnt[x];
            5'd1:  return {bgcnt[x][1], bgcnt[x][0]};
            5'd2:  return {bgcnt[x][3], bgcnt[x][2]};
            5'd3, 5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11, 5'd12: return 32'd0;   // from u_pr
            5'd13: return {win0[x][3], win0[x][2], win0[x][1], win0[x][0]};
            5'd14: return {win1[x][3], win1[x][2], win1[x][1], win1[x][0]};
            5'd15: return {wincnt[x][3], wincnt[x][2], wincnt[x][1], wincnt[x][0]};
            5'd16: return {12'd0, objmos[x][0], bgmos[x][0], w1act[x], w0act[x], layer_en[x], obj_en[x], fblank[x], eng_en(x)};
            5'd17: return MOSAIC ? {8'd0, objmosline[x][7:0], 7'd0, bgmosline[x]} : 32'd0;
            5'd18: return {3'd0, bldalpha[x], 2'd0, bldcnt[x]};
            5'd19: return {mbright[x], 11'd0, evy[x]};
            5'd20: return capcnt;
            default: return {27'd0, cap_enable, lcdc_ab};
        endcase
    endfunction
    assign st_data = (ld_word >= 5'd3 && ld_word <= 5'd12) ? pr_q    // words 3-12: u_pr
                   : ar_word(ld_word) ? ar_q : ld_d;

    // ---------------------------------------------------------------- main
    always_ff @(posedge clk) begin
        irq_vblank <= 2'b00; irq_hblank <= 2'b00; irq_vcount <= 2'b00;
        dma_vblank <= 1'b0; dma_hblank <= 1'b0; dma_dstart <= 1'b0; dma_dstop <= 1'b0; dma_mmstop <= 1'b0;
        frame_start <= 1'b0; line_start <= 1'b0; stat_late <= 1'b0;
        bg_start <= 1'b0; obj_start <= 1'b0;
        ld_v <= 1'b0;
        if (rst) begin
            pk <= 4'd0; pc <= 4'd0; pk_ph <= 1'b0;
            hc <= 13'd0; vc <= 9'd0;
            dstat[0] <= 16'd0; dstat[1] <= 16'd0; vmatch[0] <= 9'd0; vmatch[1] <= 9'd0;
            capcnt <= 32'd0; cap_enable <= 1'b0;
            q <= Q_IDLE; q_pend <= 1'b0;
            for (int x = 0; x < 2; x++) begin
                dispcnt[x] <= 32'd0; bldcnt[x] <= 14'd0; bldalpha[x] <= 13'd0;
                dsh[x] <= 8'd0; bg6[x] <= 2'd0;
                eva[x] <= 5'd16; evb[x] <= 5'd0; evy[x] <= 5'd0; mbright[x] <= 16'd0;
                for (int i = 0; i < 4; i++) begin
                    bgcnt[x][i] <= 16'd0;
                    win0[x][i] <= 8'd0; win1[x][i] <= 8'd0; wincnt[x][i] <= 8'd0;
                end
                for (int i = 0; i < 2; i++) begin
                    // (the reference points: u_refs clears them)
                    bgmos[x][i] <= 4'd0; objmos[x][i] <= 4'd0;
                end
                for (int i = 0; i < 2; i++) begin dlatch[x][i] <= 6'd0; bge[x][i] <= 5'd0; end
                bgln[x] <= 5'd0;
                layer_en[x] <= 5'd0; obj_en[x] <= 1'b0; fblank[x] <= 1'b0;
                w0act[x] <= 2'd0; w1act[x] <= 2'd0;
                bgmosy[x] <= 4'd0; bgmosymax[x] <= 4'd0; objmosy[x] <= 4'd0;
                bgmoslatch[x] <= 1'b1; objmoslatch[x] <= 1'b1;
                bgmosline[x] <= 9'd0; objmosline[x] <= 9'd0;
            end
        end else begin
            // ---- raster
            hc <= hc == LINE[12:0] - 13'd1 ? 13'd0 : hc + 13'd1;
            if (t_line) begin
                logic [8:0] nv;
                line_start <= 1'b1;
                // (VCOUNT writes, for consoles synchronising over wireless, are not kept: docs/ds-rules.md)
                nv = (vc == 9'd262) ? 9'd0 : vc + 9'd1;
                dstat[0][1] <= 1'b0; dstat[1][1] <= 1'b0;
                for (int x = 0; x < 2; x++) begin
                    logic [14:7] d;
                    d = dc_seq(x[0]);
                    bgln[x] <= d[12:8];
                end
                // UpdateWindows (on the new count, before a VCOUNT write applies)
                for (int x = 0; x < 2; x++) if (eng_en(x)) begin
                    if (nv[7:0] == win0[x][3]) w0act[x][0] <= 1'b0;
                    else if (nv[7:0] == win0[x][2]) w0act[x][0] <= 1'b1;
                    if (nv[7:0] == win1[x][3]) w1act[x][0] <= 1'b0;
                    else if (nv[7:0] == win1[x][2]) w1act[x][0] <= 1'b1;
                end
                if (nv >= 9'd2 && nv < 9'd194) dma_dstart <= 1'b1;
                else if (nv == 9'd194) dma_dstop <= 1'b1;
                if (nv == 9'd0) begin
                    frame_start <= 1'b1;
                    if (capcnt[31]) cap_enable <= 1'b1;
                end else if (nv == 9'd192) begin
                    for (int c = 0; c < 2; c++) if (!dstat[c][0]) begin
                        dstat[c][0] <= 1'b1;
                        if (dstat[c][3]) irq_vblank[c] <= 1'b1;
                    end
                    dma_vblank <= 1'b1; dma_mmstop <= 1'b1;
                    if (cap_enable) begin capcnt[31] <= 1'b0; cap_enable <= 1'b0; end
                end else if (nv == 9'd262) begin
                    dstat[0][0] <= 1'b0; dstat[1][0] <= 1'b0;
                end
                vc <= nv;
                for (int c = 0; c < 2; c++) begin
                    if (nv == vmatch[c]) begin
                        if (!dstat[c][2]) begin
                            dstat[c][2] <= 1'b1;
                            if (dstat[c][5]) irq_vcount[c] <= 1'b1;
                        end
                    end else dstat[c][2] <= 1'b0;
                end
            end
            if (t_hbl) begin
                dstat[0][1] <= 1'b1; dstat[1][1] <= 1'b1;
                if (dstat[0][4]) irq_hblank[0] <= 1'b1;
                if (dstat[1][4]) irq_hblank[1] <= 1'b1;
                if (vc < 9'd192) dma_hblank <= 1'b1;
            end

            // ---- I/O writes
            if (wr) begin
                if (w == 5'h01) begin
                    // DISPSTAT (bits 0-2, 6 read-only) and VCOUNT (applied at the next line)
                    if (io_cpu || !e) begin
                        logic c;
                        logic [15:0] ns;
                        c = io_cpu;
                        ns = dstat[c];
                        if (io_be[0]) ns[7:0]  = {io_wdata[7], dstat[c][6], io_wdata[5:3], dstat[c][2:0]};
                        if (io_be[1]) ns[15:8] = io_wdata[15:8];
                        dstat[c] <= ns;
                        vmatch[c] <= {ns[7], ns[15:8]};
                    end
                end else if (!io_cpu) begin
                    // DISPCNT always; the rest only while the engine is powered
                    if (w == 5'h00) begin
                        logic [31:0] d;
                        d = dispcnt[e];
                        for (int b = 0; b < 4; b++) if (io_be[b]) d[b*8 +: 8] = io_wdata[b*8 +: 8];
                        if (!AR_RAM) dispcnt[e] <= e ? (d & 32'hC0B1FFF7) : d;
                        if (io_be[0]) dsh[e][0] <= io_wdata[7];
                        if (io_be[1]) dsh[e][7:1] <= io_wdata[14:8];
                    end else if (w == 5'h19 && !e) begin
                        if (io_be[0]) capcnt[7:0]   <= io_wdata[7:0] & 8'h1F;
                        if (io_be[1]) capcnt[15:8]  <= io_wdata[15:8] & 8'h1F;
                        if (io_be[2]) capcnt[23:16] <= io_wdata[23:16] & 8'h3F;
                        if (io_be[3]) capcnt[31:24] <= io_wdata[31:24] & 8'hEF;
                    end else if (w == 5'h1B) begin
                        if (io_be[0] && !AR_RAM) mbright[e][7:0]  <= {3'd0, io_wdata[4:0]};
                        if (io_be[1] && !AR_RAM) mbright[e][15:8] <= {io_wdata[15:14], 6'd0};
                    end else if (eng_en(e)) case (w)
                        5'h02: if (!AR_RAM) begin bgcnt[e][0] <= m16(bgcnt[e][0], io_wdata, io_be, 0); bgcnt[e][1] <= m16(bgcnt[e][1], io_wdata, io_be, 1); end
                        5'h03: begin
                            if (!AR_RAM) begin bgcnt[e][2] <= m16(bgcnt[e][2], io_wdata, io_be, 0); bgcnt[e][3] <= m16(bgcnt[e][3], io_wdata, io_be, 1); end
                            if (io_be[0]) bg6[e][0] <= io_wdata[6];
                            if (io_be[2]) bg6[e][1] <= io_wdata[22];
                        end
                        // 0x04-0x07, 0x08/0x09/0x0C/0x0D: u_pr
                        // 0x0A/0x0B/0x0E/0x0F: the reference points (u_refs; reload copy: u_pr)
                        5'h10: begin
                            if (io_be[0]) win0[e][1] <= io_wdata[7:0];
                            if (io_be[1]) win0[e][0] <= io_wdata[15:8];
                            if (io_be[2]) win1[e][1] <= io_wdata[23:16];
                            if (io_be[3]) win1[e][0] <= io_wdata[31:24];
                        end
                        5'h11: begin
                            if (io_be[0]) win0[e][3] <= io_wdata[7:0];
                            if (io_be[1]) win0[e][2] <= io_wdata[15:8];
                            if (io_be[2]) win1[e][3] <= io_wdata[23:16];
                            if (io_be[3]) win1[e][2] <= io_wdata[31:24];
                        end
                        5'h12: if (!AR_RAM) for (int b = 0; b < 4; b++) if (io_be[b]) wincnt[e][b] <= io_wdata[b*8 +: 8];
                        5'h13: begin
                            if (io_be[0] && MOSAIC) begin bgmos[e][0] <= io_wdata[3:0]; bgmos[e][1] <= io_wdata[7:4]; end
                            if (io_be[1] && MOSAIC) begin objmos[e][0] <= io_wdata[11:8]; objmos[e][1] <= io_wdata[15:12]; end
                        end
                        5'h14: if (!AR_RAM) begin
                            if (io_be[0]) bldcnt[e][7:0] <= io_wdata[7:0];
                            if (io_be[1]) bldcnt[e][13:8] <= io_wdata[13:8];
                            if (io_be[2]) begin
                                bldalpha[e][4:0] <= io_wdata[20:16];
                                eva[e] <= io_wdata[20:16] > 5'd16 ? 5'd16 : io_wdata[20:16];
                            end
                            if (io_be[3]) begin
                                bldalpha[e][12:8] <= io_wdata[28:24];
                                evb[e] <= io_wdata[28:24] > 5'd16 ? 5'd16 : io_wdata[28:24];
                            end
                        end
                        5'h15: if (io_be[0] && !AR_RAM) evy[e] <= io_wdata[4:0] > 5'd16 ? 5'd16 : io_wdata[4:0];
                        default: ;
                    endcase
                end
            end

            // ---- line sequencer
            case (q)
                Q_IDLE: if (q_pend) begin
                    q_pend <= 1'b0;
                    q_line <= q_pend_line;
                    q_reset <= q_pend_line == 9'd262;
                    // draw only if the engine is free now; else just update
                    q_draw <= q_pend_draw;
                    q_late <= 1'b0;
                    q <= Q_WAIT;
                end
                Q_WAIT: begin
                    if (!bg_busy && !obj_busy && !bg_start && !obj_start) q <= Q_PRE;
                    else if (q_pend) begin q_draw <= 1'b0; q_late <= q_draw; stat_late <= 1'b1; q <= Q_PRE; end
                end
                Q_PRE: begin
                    // UpdateRegistersPreDraw for both engines; then (pc 1-8)
                    // BGxRefInternal <- BGxRef into u_pr for the BGs chosen
                    // now (pc_m), a step waiting while the CPU writes u_pr
                    if (pc != 4'd0) begin
                        if (!sq_we || sq_ok) pc <= pc + 4'd1;
                        if (pc == 4'd8 && (!sq_we || sq_ok)) begin
                            pc <= 4'd0;
                            q_eng <= 1'b0; q_word <= 5'd0;
                            // a late line skips its BG jobs (line n keeps its old
                            // pixels) but not the OBJ jobs of line n+1: skipping those
                            // drew line n+1 with no OBJs at all (#218/#222, NSMB menu)
                            q <= q_draw ? Q_LOAD : q_late ? Q_RUN : Q_POST;
                            if (!q_draw) begin
                                jobs_left <= 2'd0;
                                ojobs_left <= q_late && (q_line < 9'd191 || q_line == 9'd262) ? 2'd2 : 2'd0;
                            end
                        end
                    end else begin
                    pc <= 4'd1;
                    for (int x = 0; x < 2; x++) begin
                        for (int i = 0; i < 2; i++) pc_m[{x[0], i[0]}] <= eng_en(x) && (!MOSAIC || !bgc6(x[0], i[0]) || bgmoslatch[x]);
                    end
                    for (int x = 0; x < 2; x++) if (eng_en(x)) begin
                        logic [5:0] l1, l2;
                        logic [14:7] dc;
                        dc = dc_seq(x[0]);
                        l2 = dlatch[x][1];
                        l1 = dlatch[x][0];
                        dlatch[x][1] <= l1;
                        dlatch[x][0] <= dc[12:7];
                        // a layer enable shows three lines after the line it was
                        // written in (DS, hwref runs 22/23; melonDS two from HBlank);
                        // a disable applies at once, as before
                        bge[x][1] <= bge[x][0];
                        bge[x][0] <= bgln[x];
                        layer_en[x] <= bge[x][1] & dc[12:8];
                        obj_en[x] <= l1[5] & dc[12];
                        fblank[x] <= l2[0] | dc[7];
                        if (bgmoslatch[x]) bgmosline[x] <= q_line;
                        if (dc[12]) begin
                            if (q_reset || objmosy[x] == objmos[x][1]) begin
                                objmosy[x] <= 4'd0; objmoslatch[x] <= 1'b1;
                                objmosline[x] <= q_reset ? 9'd0 : q_line + 9'd1;
                            end else begin
                                objmosy[x] <= objmosy[x] + 4'd1; objmoslatch[x] <= 1'b0;
                            end
                        end else if (objmoslatch[x]) objmosline[x] <= q_reset ? 9'd0 : q_line + 9'd1;
                    end
                    end
                end
                Q_LOAD: begin
                    // u_pr answers next cycle: the word is written then (ld_*)
                    ld_v <= 1'b1; ld_eng <= q_eng; ld_word <= q_word; ld_d <= sword(q_eng, q_word);
                    if (q_word == 5'd21 || (q_word == 5'd19 && q_eng == 1'b0)) begin
                        if (q_eng) q <= Q_RUN;
                        else begin q_eng <= 1'b1; q_word <= 5'd0; end
                    end else q_word <= q_word + 5'd1;
                    jobs_left <= (q_line < 9'd192) ? 2'd2 : 2'd0;
                    ojobs_left <= (q_line < 9'd191 || q_line == 9'd262) ? 2'd2 : 2'd0;
                end
                Q_RUN: begin
                    // BG of line n: A then B; OBJ of line n+1 (0 at line 262): A then B
                    if (!bg_busy && !bg_start && jobs_left != 2'd0) begin
                        bg_start <= 1'b1; bg_eng <= jobs_left == 2'd1; bg_line <= q_line[7:0]; bg_slot <= q_line[0];
                        jobs_left <= jobs_left - 2'd1;
                    end
                    // (late: line n-1's BG composite reads and clears the OBJ slot
                    // line n+1 writes, so its OBJ jobs wait for that BG to finish)
                    if (!obj_busy && !obj_start && ojobs_left != 2'd0 && !(q_late && (bg_busy || bg_start))) begin
                        logic [7:0] ol;
                        ol = q_line == 9'd262 ? 8'd0 : q_line[7:0] + 8'd1;
                        obj_start <= 1'b1; obj_eng <= ojobs_left == 2'd1; obj_line <= ol; obj_slot <= ol[0];
                        ojobs_left <= ojobs_left - 2'd1;
                    end
                    if (jobs_left == 2'd0 && ojobs_left == 2'd0) q <= Q_POST;
                end
                default: begin   // Q_POST: UpdateRegistersPostDraw, window carry
                    // the reference points, one coordinate per cycle {x, i, y}
                    // as u_pr gives the word read the cycle before: the
                    // reload copy at a frame's start, else {PD, PB}
                    if (pk != 4'd0) begin
                        logic x, i, y;
                        x = pk_b[2]; i = pk_b[1]; y = pk_b[0];
                        // (the step itself: u_refs, p_we)
                    end
                    // each step takes two clocks: the write on the first (pk_ph 0),
                    // the advance on the second
                    pk_ph <= !pk_ph;
                    if (pk_ph) begin
                        pk_b <= pk[2:0]; pk <= pk + 4'd1;
                        if (pk == 4'd8) begin pk <= 4'd0; q <= Q_IDLE; end
                    end
                    if (pk == 4'd0 && pk_ph)
                    for (int x = 0; x < 2; x++) if (eng_en(x)) begin
                        if (q_reset || bgmosy[x] == bgmosymax[x]) begin
                            bgmosymax[x] <= bgmos[x][1]; bgmosy[x] <= 4'd0; bgmoslatch[x] <= 1'b1;
                        end else begin
                            bgmosy[x] <= bgmosy[x] + 4'd1; bgmoslatch[x] <= 1'b0;
                        end
                        // the horizontal window state the drawn line leaves behind
                        if (q_draw && q_line < 9'd192 && !fblank[x]) begin
                            if (dc_bit(x[0], 13)) w0act[x][1] <= win0[x][0] > win0[x][1];
                            if (dc_bit(x[0], 14)) w1act[x][1] <= win1[x][0] > win1[x][1];
                        end
                    end
                end
            endcase

            // queue this HBlank's register work (after the sequencer, so a
            // new HBlank wins over the one Q_IDLE takes this cycle)
            if (t_hbl) begin
                if (q_pend && q != Q_IDLE) stat_late <= 1'b1;
                q_pend <= 1'b1;
                q_pend_line <= vc;
                q_pend_draw <= vc < 9'd192 || vc == 9'd262;
            end
        end
    end
    assign vcount = vc;

    // ---------------------------------------------------------------- 2D engine
    logic        out_valid, out_eng;
    logic [7:0]  out_x;
    logic [17:0] out_rgb;
    logic [7:0]  fifo_raddr;
    // PERSIST: the 2D engine keeps its VRAM block caches across lines until
    // VRAM or VRAMCNT is written (a 4-bit tile block serves eight lines)
    gpu2d #(.PERSIST(1), .OAM_CPU(OAM_CPU), .WST_RF(WST_RF), .TEX_IDXW(TEX_IDXW), .MOSAIC(MOSAIC), .TAG_MLAB(TAG_MLAB)) u_gpu2d (
        .clk, .rst, .vram_wr,
        .st_we, .st_eng, .st_addr, .st_data,
        .pal_we, .pal_waddr(po_waddr), .pal_wdata(po_wdata), .pal_be(po_be), .pal_cq,
        .oam_cre, .oam_cra(po_waddr), .oam_cgnt, .oam_cq,
        .oam_we, .oam_waddr(po_waddr), .oam_wdata(po_wdata), .oam_be(po_be),
        .bg_start, .bg_eng, .bg_line, .bg_slot, .bg_busy, .bg_done,
        .obj_start, .obj_eng, .obj_line, .obj_slot, .obj_busy, .obj_done,
        .vr_req, .vr_blk, .vr_ack, .vr_rvalid, .vr_rdata,
        .cap_we, .cap_addr, .cap_data, .cap_ready,
        .l3d_raddr, .l3d_rdata, .fifo_raddr, .fifo_rdata(16'd0),
        .out_valid, .out_eng, .out_x, .out_rgb,
        .stat_bg_stall(g_bg_stall), .stat_obj_stall(g_obj_stall));

    // the line being drawn, for the pixel stream
    logic [7:0] draw_line;
    always_ff @(posedge clk) if (bg_start) draw_line <= bg_line;
    assign l3d_go = bg_start && !bg_eng;
    always_ff @(posedge clk) if (l3d_go) l3d_line <= bg_line;
    assign px_valid = out_valid;
    assign px_eng   = out_eng;
    assign px_line  = draw_line;
    assign px_x     = out_x;
    assign px_rgb   = out_rgb;

    // ---------------------------------------------------------------- NDSDiag
    logic [1:0]  dg_beat;              // beat of the block being answered (4 a block)
    logic        dg_cap_line;          // a pixel was captured this line
    logic [15:0] dg_busy, dg_max, dg_held;
    always_ff @(posedge clk) begin
        if (rst) begin dg_beat <= 2'd0; dg_cap_line <= 1'b0; dg_busy <= 16'd0; dg_max <= 16'd0; dg_held <= 16'd0; end
        else begin
            if (vr_rvalid) dg_beat <= dg_beat + 2'd1;
            if (line_start) dg_cap_line <= 1'b0; else if (cap_we) dg_cap_line <= 1'b1;
            if (line_start) begin
                dg_busy <= 16'(bg_busy);
                if (dg_busy > dg_max) dg_max <= dg_busy;
                if (frame_start) begin dg_held <= dg_busy > dg_max ? dg_busy : dg_max; dg_max <= 16'd0; end
            end else if (bg_busy && dg_busy != 16'hFFFF) dg_busy <= dg_busy + 16'd1;
        end
    end
    // HURRY_AT: the BG job's clocks so far (saturating)
    logic [12:0] hz_n;
    always_ff @(posedge clk) begin
        if (rst || !bg_busy) hz_n <= 13'd0;
        else if (hz_n != 13'h1FFF) hz_n <= hz_n + 13'd1;
        hurry2d <= HURRY_AT != 0 && !rst && bg_busy && hz_n >= 13'(HURRY_AT);
    end
    assign diag_v_start  = vr_req && vr_ack;
    assign diag_v_stop   = vr_rvalid && dg_beat == 2'd0;
    assign diag_d_ev     = {cap_we && !dg_cap_line && !line_start, diag_v_start, g_obj_stall, g_bg_stall, stat_late};
    assign diag_d_bgmax  = dg_held;
    assign diag_l2d_v    = stat_late;
    assign diag_l2d_line = q_line;
endmodule
