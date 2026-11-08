// NDS geometry engine (docs/geometry-engine.md): the GX FIFO, GXSTAT and
// melonDS's command timing (gpu3d_gxfront), the microcoded datapath that
// runs the commands (gpu3d_gxeng) and the polygon sort at the swap
// (gpu3d_gxsort). Bit-exact against melonDS's GPU3D.cpp.
//
// Register port, 0x4000400..0x40007FF (word address bits 9:2):
//   writes: 0x400-0x43F packed commands, 0x440-0x5CB command ports (32-bit
//           only), 0x600 GXSTAT, 0x610 DISP_1DOT_DEPTH. A write holds io_wait
//           while the GX FIFO is full (melonDS's stall).
//   reads:  0x600 GXSTAT, 0x604 polygon/vertex counts, 0x620-0x62C
//           POS_TEST, 0x630/0x634 VEC_TEST, 0x640-0x67C clip matrix,
//           0x680-0x6A0 vector matrix. Data and io_ack the cycle after the
//           request, or later for the register-file reads (which wait for
//           the engine to run every entry the timing model has executed).
// Polygon records leave in submission order (po_*: a header beat, then the
// vertex beats, gpu3d_raster's ps_* layout); at the swap the render order
// follows as (position, polygon index) pairs (so_*).
module gpu3d_geom #(
    parameter bit SMALL = 1'b1,        // see gpu3d_gxeng
    parameter bit DS_STRIPCLIP = 1'b1, // see gpu3d_gxeng
    parameter bit DS_FARREJ = 1'b1,    // see gpu3d_gxeng
    parameter bit DS_CLIPRED = 1'b1,   // see gpu3d_gxeng
    parameter bit GX_CHEAP = 1'b1,     // gpu3d_gxfront CHEAP: GX cheap timing (2026-10-25); 0: melonDS's timing
    parameter bit DIV_R4 = 1'b1,       // gpu3d_gxeng: the divider two quotient bits per clock (#576/#577: +22 ALMs)
    parameter bit DIV_P2X = 1'b1,      // gpu3d_gxeng: those two bits from one subtractor on clk_2x (gpu3d_gxdiv P2X; clk_2x must run)
    parameter bit USORT = 1'b1,        // see gpu3d_gxeng: 1 sorts in the engine's microcode, no gpu3d_gxsort
    parameter bit LUNIT = 1'b0,        // see gpu3d_gxeng: 1 adds the lighting unit gpu3d_gxlight (with USORT)
    parameter int VFIN = 0,            // see gpu3d_gxeng: 1 adds the vertex-finish unit gpu3d_gxvfin (with LUNIT), 2 its lite form
    parameter bit FF = 1'b0,           // see gpu3d_gxeng: the geometry redesign (with USORT, without LUNIT and VFIN)
    parameter bit ENG_M10K = 1'b1,     // gpu3d_gxeng VC_M10K, STK_M10K, VOC_M10K: its three MLAB tables in M10K (+3 blocks, -4 MLAB LABs)
    parameter bit ENG_TM10K = ENG_M10K,   // ... the VC and VOC tables alone (0: MLAB, -2 M10K; STK_M10K stays with ENG_M10K: gpu3d_gxeng's DICT needs it)
    parameter bit GX_PRE = 1'b0,       // 1: io_wpre is gpu3d_gxpre(io_wdata), registered with it (nds_gpu3d); 0: decoded here
    parameter bit SPILL = 1'b0,        // see gpu3d_gxfront: entries beyond the on-chip 512 spill to SDRAM (sp_* ports)
    parameter int SP_ON = 512,         // see gpu3d_gxfront (tests: fewer, to spill often)
    parameter bit GATH16 = 1'b0,       // see gpu3d_gxfront
    parameter int SP_AW = 12,          // see gpu3d_gxfront
    parameter bit SP_SIM = 1'b0        // tests (tb_geom): a behavioural SDRAM on the sp_* ports, with varying latency
) (
    input  logic         clk,
    input  logic         clk_2x,        // DIV_P2X: 2 x clk, rising with it
    input  logic         rst,
    input  logic         tick,          // ends a 33.51 MHz system cycle
    input  logic         geom_en,       // POWCNT1 bit 3
    input  logic         vblank,        // GPU3D::VBlank
    // register port
    input  logic         io_req,
    input  logic         io_we,
    input  logic [3:0]   io_be,
    input  logic [9:2]   io_addr,
    input  logic [31:0]  io_wdata,
    input  logic [20:0]  io_wpre,       // GX_PRE: gpu3d_gxpre(io_wdata), registered with it
    output logic [31:0]  io_rdata,
    output logic         io_ack,
    output logic         io_wait,
    // to the system
    output logic         irq_gxfifo,    // GX FIFO IRQ condition
    output logic         dma_gx_low,    // FIFO under half full (DMA mode 7)
    output logic         gx_stall,      // a write waits for FIFO space (CPU and DMA stall)
    output logic         ovf_set,       // DISP3DCNT bit 13 (polygon/vertex RAM overflow)
    // polygon records
    output logic         po_valid,
    input  logic         po_ready,
    input  logic         s_draw,        // the store draws a frame from its on-chip lists (a late swap waits)
    output logic         po_type,
    output logic [127:0] po_data,
    output logic [10:0]  po_index,
    output logic         po_wv,         // po_data's words as they are written (see gpu3d_gxeng)
    output logic [1:0]   po_wk,
    output logic [31:0]  po_wd,
    // render order at a swap
    output logic         so_we,
    output logic [10:0]  so_pos,
    output logic [10:0]  so_idx,
    output logic         so_done,
    output logic [11:0]  so_count,
    output logic         sw_busy,       // a swap taken at a VBlank that the engine has not reached, or its sort output not ended
    output logic         sw_take,       // the model takes a swap at this VBlank (the DS's own: the engine may sort it later)
    // test bench
    output logic         dbg_stall,
    output logic         dbg_apply,
    output logic [10:0]  dbg_upc,
    output logic         dbg_flush,
    output logic         dbg_idle,
    output logic [31:0]  dbg_gxstat,
    output logic [11:0]  dbg_npoly,
    output logic [12:0]  dbg_nvert,
    // diagnostics (docs/diag.md): {model executes an entry, GX write stall with the DS FIFO not full
    // (the engine behind), with it full}, entry-RAM entries in use
    output logic [2:0]   diag_ev,
    output logic [12:0]  diag_used,
    output logic         dbg_eq_bad,    // GEOM_EQ: the reference front disagrees
    // SPILL: the GX entry spill's SDRAM ports (nds_gpu3d shares the 3D line ring's)
    output logic         sp_wreq,
    output logic [23:0]  sp_waddr,
    output logic [31:0]  sp_wdata,
    input  logic         sp_wack,
    input  logic         sp_wdrained,
    output logic         sp_rreq,
    output logic [23:0]  sp_raddr,
    input  logic         sp_rack,
    input  logic         sp_rvalid,
    input  logic [31:0]  sp_rdata
);
    // ---- front
    logic [3:0]  tpend;
    logic [8:0]  e_addr, mx, dp;
    logic        dg_full, dg_exec;    // diagnostics from the front
    logic [39:0] e_data;
    logic        oc_valid, oc_rej, oc_quad, flush_req, test_exec;
    logic [31:0] gxstat;
    logic [23:0] zerodot;
    wire         wr_req = io_req && io_we;
    // the front's packed-word decode of a new word (its PRE input): from the caller's register (GX_PRE),
    // or here (the test bench), the same either way
    logic [20:0] wr_pre;
    generate if (GX_PRE) begin : g_wpre
        assign wr_pre = io_wpre;
    end else begin : g_wpred
        gpu3d_gxpre u_pre (.d(io_wdata), .pre(wr_pre));
    end endgenerate
    logic        e_avail, e_pop, e_more;
    logic        f_wack, f_rack, f_rvalid, f_wdrained;
    logic [31:0] f_rdata;
    gpu3d_gxfront #(.CHEAP(GX_CHEAP), .PRE(1'b1), .SPILL(SPILL), .SP_ON(SP_ON), .GATH16(GATH16), .SP_AW(SP_AW)) u_front (
        .clk, .rst, .tick, .geom_en, .vblank,
        .wr_req, .wr_be(io_be), .wr_addr(io_addr), .wr_data(io_wdata), .wr_pre, .wr_wait(io_wait),
        .gxstat, .zerodot, .flush_req, .irq(irq_gxfifo), .dma_low(dma_gx_low), .gx_stall,
        .e_addr, .e_data, .mx, .dp,
        .oc_valid, .oc_rej, .oc_quad, .test_exec,
        .dbg_stall, .dbg_apply, .dg_full(dg_full), .dg_used(diag_used), .dg_exec(dg_exec),
        .e_avail, .e_pop, .e_more, .sp_wreq, .sp_waddr, .sp_wdata, .sp_wack(f_wack), .sp_wdrained(f_wdrained), .sp_rreq, .sp_raddr,
        .sp_rack(f_rack), .sp_rvalid(f_rvalid), .sp_rdata(f_rdata));
    generate if (SP_SIM) begin : g_spsim
        // a behavioural SDRAM for tb_geom: a write word acked after 1-4 clocks, a block read acked after 2-9
        // clocks, then its 8 words with gaps (LFSR). As the Pocket's write chain, an acked word reaches the
        // SDRAM later (a 64-word queue drained one word in 8 clocks on average): a read before f_wdrained returns the old data.
        logic [31:0] sm [0:65535];
        logic [47:0] wq [0:63];
        logic [5:0]  wqh, wqt;
        logic [6:0]  wqn;
        assign f_wdrained = wqn == '0 && !f_wack;
        logic [15:0] lf;
        logic [3:0]  wcnt, rcnt;
        logic [2:0]  rk;
        logic        rbusy;
        logic [23:0] ra;
        always_ff @(posedge clk) begin
            lf <= rst ? 16'hACE1 : {lf[14:0], lf[15] ^ lf[13] ^ lf[12] ^ lf[10]};
            f_wack <= 1'b0; f_rack <= 1'b0; f_rvalid <= 1'b0;
            if (rst) begin wcnt <= '0; rcnt <= '0; rbusy <= 1'b0; wqh <= '0; wqt <= '0; wqn <= '0; end
            else begin
                if (wqn != '0 && lf[8:6] == '0) begin sm[wq[wqh][47:32]] <= wq[wqh][31:0]; wqh <= wqh + 6'd1; end
                wqn <= wqn + 7'(f_wack) - 7'(wqn != '0 && lf[8:6] == '0);
                if (sp_wreq && !f_wack && wqn < 7'd63) begin
                    if (wcnt == '0) wcnt <= 4'(lf[1:0]) + 4'd1;
                    else if (wcnt == 4'd1) begin f_wack <= 1'b1; wq[wqt] <= {sp_waddr[15:0], sp_wdata}; wqt <= wqt + 6'd1; wcnt <= '0; end
                    else wcnt <= wcnt - 4'd1;
                end
                if (sp_rreq && !rbusy && !f_rack) begin
                    if (rcnt == '0) rcnt <= 4'(lf[4:2]) + 4'd2;
                    else if (rcnt == 4'd1) begin f_rack <= 1'b1; rbusy <= 1'b1; ra <= sp_raddr; rk <= '0; rcnt <= '0; end
                    else rcnt <= rcnt - 4'd1;
                end
                if (rbusy && lf[5]) begin
                    f_rvalid <= 1'b1; f_rdata <= sm[ra[15:0] + 16'(rk)]; rk <= rk + 3'd1;
                    if (rk == 3'd7) rbusy <= 1'b0;
                end
            end
        end
    end else begin : g_spext
        assign f_wdrained = sp_wdrained;
        assign f_wack = sp_wack; assign f_rack = sp_rack; assign f_rvalid = sp_rvalid; assign f_rdata = sp_rdata;
    end endgenerate

`ifdef GEOM_EQ
    // equivalence check (simulation only): the front of nds-fit #67 on the same inputs
    logic [31:0] r_gxstat;
    logic [23:0] r_zerodot;
    logic [39:0] r_e_data;
    logic [8:0]  r_mx, r_spa;
    logic        r_wait, r_flush, r_irq, r_dlow, r_stall, r_spc, r_oc, r_te, r_ds, r_da;
    gpu3d_gxfront_ref u_fref (
        .clk, .rst, .tick, .geom_en, .vblank,
        .wr_req, .wr_be(io_be), .wr_addr(io_addr), .wr_data(io_wdata), .wr_wait(r_wait),
        .gxstat(r_gxstat), .zerodot(r_zerodot), .flush_req(r_flush), .irq(r_irq), .dma_low(r_dlow), .gx_stall(r_stall),
        .e_addr, .e_data(r_e_data), .mx(r_mx), .dp, .sp_clr(r_spc), .sp_clr_at(r_spa),
        .oc_valid, .oc_rej, .oc_quad, .test_exec(r_te),
        .dbg_stall(r_ds), .dbg_apply(r_da));
    // the reference front stores the raw command byte; this front stores its dispatch code
    wire  [39:0] r_e_code = {gpu3d_gxu_pkg::gx_ecode(r_e_data[39:32]), r_e_data[31:0]};
    assign dbg_eq_bad = r_gxstat != gxstat || r_zerodot != zerodot || r_e_code != e_data || r_mx != mx ||
                        r_wait != io_wait || r_flush != flush_req || r_irq != irq_gxfifo || r_dlow != dma_gx_low ||
                        r_stall != gx_stall || r_te != test_exec || r_ds != dbg_stall;
`else
    assign dbg_eq_bad = 1'b0;
`endif

    // ---- swap: VBlank with a flush pending, until the engine has swapped
    // swaps the model has taken at a VBlank and the engine has not yet done: counted, since the model can
    // run up to 511 entries ahead of the engine (GX_CHEAP) and so past a second SWAP and VBlank
    logic swap_go, swap_ack;
    logic [3:0] swap_n;
    wire  swap_in_v = vblank && geom_en && flush_req;
    assign sw_take = swap_in_v;
    wire  swap_in;
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    // +swaplate=N (tests): a swap taken at the VBlank reaches the engine N clocks later, so its sort output
    // can fall into the next frame's drawing (the late-swap case: the engine waits on SDRAW)
    int sl_n = 0, sl_t = -1;
    initial if (!$value$plusargs("swaplate=%d", sl_n)) sl_n = 0;
    always_ff @(posedge clk)
        if (rst) sl_t <= -1;
        else if (swap_in_v && sl_n > 0) sl_t <= sl_n;
        else if (sl_t >= 0) sl_t <= sl_t - 1;
    assign swap_in = sl_n > 0 ? sl_t == 0 : swap_in_v;
    // synthesis translate_on
`else
    assign swap_in = swap_in_v;
`endif
    always_ff @(posedge clk) begin
        if (rst) swap_n <= 4'd0;
        else swap_n <= swap_n + ((swap_in && swap_n != 4'd15) ? 4'd1 : 4'd0) - (swap_ack ? 4'd1 : 4'd0);
    end
    assign swap_go = swap_n != 4'd0;
    // sw_busy: from the VBlank that takes a swap until its sort output ends (swap_ack starts the engine's swap:
    // its prefix sums, the late-swap wait, the walk); nds_gpu3d holds the frame start for it
    logic sw_sort;
    always_ff @(posedge clk) sw_sort <= !rst && (swap_ack || (sw_sort && !so_done));
    assign sw_busy = swap_go || sw_sort;

    // ---- engine
    logic        boxres, test_done, mrd_req, mrd_ack, mrd_cap;
    logic [4:0]  mrd_sel;
    logic [31:0] mrd_data;
    logic [11:0] npoly;
    logic [12:0] nvert;
    logic        ks_we, sort_go, sort_manual, sort_busy;
    logic [10:0] ks_idx;
    logic [16:0] ks_key;
    logic [11:0] sort_n;
    logic        e_so_we, e_so_done;
    logic [10:0] e_so_pos, e_so_idx;
    gpu3d_gxeng #(.SMALL(SMALL), .DIV_R4(DIV_R4), .DIV_P2X(DIV_P2X), .DS_STRIPCLIP(DS_STRIPCLIP), .DS_FARREJ(DS_FARREJ), .DS_CLIPRED(DS_CLIPRED), .USORT(USORT), .LUNIT(LUNIT), .VFIN(VFIN), .FF(FF),
                  .VC_M10K(ENG_TM10K), .STK_M10K(ENG_M10K), .VOC_M10K(ENG_TM10K)) u_eng (
        .clk, .clk_2x, .rst, .e_addr, .e_data, .mx, .e_avail, .e_pop, .e_more, .dp, .zerodot,
        .swap_go, .swap_ack, .oc_valid, .oc_rej, .oc_quad,
        .boxres, .test_done, .npoly, .nvert, .ovf_set,
        .mrd_req, .mrd_sel, .mrd_ack, .mrd_data, .mrd_cap,
        .po_valid, .po_ready, .s_draw, .po_type, .po_data, .po_index, .po_wv, .po_wk, .po_wd,
        .ks_we, .ks_idx, .ks_key, .sort_go, .sort_manual, .sort_n, .sort_busy,
        .so_we(e_so_we), .so_pos(e_so_pos), .so_idx(e_so_idx), .so_done(e_so_done),
        .dbg_upc, .idle(dbg_idle));

    // ---- sort
    generate if (USORT) begin : g_usort
        assign sort_busy = 1'b0;
        assign {so_we, so_pos, so_idx, so_done} = {e_so_we, e_so_pos, e_so_idx, e_so_done};
    end else begin : g_sort
        gpu3d_gxsort u_sort (
            .clk, .rst, .ks_we, .ks_idx, .ks_key, .go(sort_go), .manual(sort_manual), .n(sort_n),
            .busy(sort_busy), .so_we, .so_pos, .so_idx, .so_done);
    end endgenerate
    always_ff @(posedge clk) if (sort_go) so_count <= sort_n;

    assign dbg_flush = flush_req;
    assign diag_ev = {dg_exec, gx_stall && !dg_full, gx_stall && dg_full};
    assign dbg_npoly = npoly;
    assign dbg_nvert = nvert;
    assign dbg_gxstat = {gxstat[31:2], boxres, gxstat[0] || tpend != 4'd0};

    // ---- tests in flight: from the model's execution to the engine's result
    always_ff @(posedge clk) begin
        if (rst) tpend <= 4'd0;
        else tpend <= tpend + (test_exec ? 4'd1 : 4'd0) - (test_done ? 4'd1 : 4'd0);
    end

`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // +gxmon: per frame (VBlank to VBlank), clocks of: the CPU's GX write stall because the DS's 256-entry
    // FIFO is full (as on the DS), because the entry RAM is full while the DS's FIFO isn't (the engine
    // behind: backpressure the DS doesn't have); the engine idle; the engine held by the store (po_ready)
    bit gm_on;
    initial gm_on = $test$plusargs("gxmon");
    longint gm_ds, gm_eng, gm_idle, gm_po, gm_cy;
    int gm_used;
    always_ff @(posedge clk) if (gm_on && !rst) begin
        gm_cy <= gm_cy + 1;
        if (gx_stall && u_front.f == 9'd256) gm_ds <= gm_ds + 1;
        if (gx_stall && u_front.f != 9'd256) gm_eng <= gm_eng + 1;
        if (dbg_idle) gm_idle <= gm_idle + 1;
        if (po_valid && !po_ready) gm_po <= gm_po + 1;
        if (int'(u_front.used) > gm_used) gm_used <= int'(u_front.used);
        if (vblank) begin
            $display("gxmon: stall ds %0d engine %0d | engine idle %0d store-held %0d | entries max %0d | of %0d",
                     gm_ds, gm_eng, gm_idle, gm_po, gm_used, gm_cy);
            gm_ds <= 0; gm_eng <= 0; gm_idle <= 0; gm_po <= 0; gm_used <= 0; gm_cy <= 0;
        end
    end
`endif
    // ---- reads
    wire       rd_req = io_req && !io_we;
    wire [9:0] ra = {io_addr, 2'b00};
    logic      mrd_pend;
    always_comb begin
        if (ra >= 10'h240 && ra < 10'h280)      mrd_sel = 5'(ra[5:2]);              // clip matrix
        else if (ra >= 10'h280 && ra < 10'h2A4) mrd_sel = 5'd16 + 5'(ra[5:2]);      // vector matrix
        else if (ra >= 10'h220 && ra < 10'h230) mrd_sel = 5'd25 + 5'(ra[3:2]);      // POS_TEST
        else                                    mrd_sel = 5'd29 + 5'(ra[2]);         // VEC_TEST
    end
    wire is_mrd = ra >= 10'h220 && ra < 10'h2A4 && !(ra >= 10'h238 && ra < 10'h240);
    assign mrd_req = mrd_pend;
    always_ff @(posedge clk) begin
        io_ack <= 1'b0;
        if (rst) mrd_pend <= 1'b0;
        else if (mrd_pend) begin
            if (mrd_cap) io_rdata <= mrd_data;      // the engine's result, a clock before its ack
            if (mrd_ack) begin mrd_pend <= 1'b0; io_ack <= 1'b1; end
        end else if (rd_req) begin
            if (geom_en && is_mrd) mrd_pend <= 1'b1;
            else begin
                io_ack <= 1'b1;
                case (ra)
                    10'h200: io_rdata <= {gxstat[31:2], boxres, gxstat[0] || tpend != 4'd0};
                    10'h204: io_rdata <= {3'd0, nvert, 4'd0, npoly};
                    default: io_rdata <= 32'd0;
                endcase
            end
        end else if (io_req && io_we && !io_wait) io_ack <= 1'b1;
    end
endmodule
