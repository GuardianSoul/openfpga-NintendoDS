// a1-a3 lockstep (docs/gx-area-map.md, sim only: gpu3d_geom with GX_A123_EQ). Each step's module runs beside the
// step before it on the same inputs, every output compared at every clock:
//   a1: gpu3d_gxeng_r1 (a1) against gpu3d_gxeng_r0 (base e553da725)
//   a3: u_eng (a3) against gpu3d_gxeng_r1; the test word geom takes against r1's tst_res
//   a2: u_front (a2) against gpu3d_gxfront_r0 (base)
// The references are open loop (driven by the DUT's inputs), so any difference shows at the clock it starts.
`define A123_ENG(inst, mod) \
    logic        inst``_e_pop, inst``_swap_ack, inst``_oc_valid, inst``_oc_rej, inst``_oc_quad, inst``_boxres, inst``_test_done, inst``_ovf_set; \
    logic [8:0]  inst``_e_addr, inst``_dp; \
    logic [11:0] inst``_npoly; logic [12:0] inst``_nvert; \
    logic        inst``_mrd_ack, inst``_mrd_cap; logic [31:0] inst``_mrd_data; logic [191:0] inst``_tst_res; \
    logic        inst``_po_valid, inst``_po_type, inst``_po_wv; logic [127:0] inst``_po_data; logic [10:0] inst``_po_index; \
    logic [1:0]  inst``_po_wk; logic [31:0] inst``_po_wd; \
    logic        inst``_ks_we, inst``_sort_go, inst``_sort_manual; logic [10:0] inst``_ks_idx; logic [16:0] inst``_ks_key; logic [11:0] inst``_sort_n; \
    logic        inst``_so_we, inst``_so_done; logic [10:0] inst``_so_pos, inst``_so_idx; logic [10:0] inst``_dbg_upc; logic inst``_idle; \
    mod #(.SMALL(SMALL), .DIV_R4(DIV_R4), .DIV_P2X(DIV_P2X), .DS_STRIPCLIP(DS_STRIPCLIP), .DS_FARREJ(DS_FARREJ), .DS_CLIPRED(DS_CLIPRED), .USORT(USORT), .LUNIT(LUNIT), .VFIN(VFIN), .FF(FF), .PAR(GX_PAR), \
          .VC_M10K(ENG_TM10K), .STK_M10K(ENG_M10K), .VOC_M10K(ENG_TM10K)) inst ( \
        .clk, .clk_2x, .rst, .e_addr(inst``_e_addr), .e_data, .mx, .e_avail, .e_pop(inst``_e_pop), .e_more, .dp(inst``_dp), .zerodot, \
        .swap_go, .swap_ack(inst``_swap_ack), .oc_valid(inst``_oc_valid), .oc_rej(inst``_oc_rej), .oc_quad(inst``_oc_quad), \
        .boxres(inst``_boxres), .test_done(inst``_test_done), .npoly(inst``_npoly), .nvert(inst``_nvert), .ovf_set(inst``_ovf_set), \
        .mrd_req, .mrd_sel, .mrd_ack(inst``_mrd_ack), .mrd_data(inst``_mrd_data), .mrd_cap(inst``_mrd_cap), .tst_res(inst``_tst_res), \
        .po_valid(inst``_po_valid), .po_ready, .s_draw, .po_type(inst``_po_type), .po_data(inst``_po_data), .po_index(inst``_po_index), \
        .po_wv(inst``_po_wv), .po_wk(inst``_po_wk), .po_wd(inst``_po_wd), \
        .ks_we(inst``_ks_we), .ks_idx(inst``_ks_idx), .ks_key(inst``_ks_key), .sort_go(inst``_sort_go), .sort_manual(inst``_sort_manual), \
        .sort_n(inst``_sort_n), .sort_busy, .so_we(inst``_so_we), .so_pos(inst``_so_pos), .so_idx(inst``_so_idx), .so_done(inst``_so_done), \
        .dbg_upc(inst``_dbg_upc), .idle(inst``_idle)); \
    wire [599:0] inst``_ov = {inst``_e_addr, inst``_e_pop, inst``_dp, inst``_swap_ack, inst``_oc_valid, inst``_oc_rej, inst``_oc_quad, \
        inst``_boxres, inst``_test_done, inst``_npoly, inst``_nvert, inst``_ovf_set, inst``_mrd_ack, inst``_mrd_data, inst``_mrd_cap, \
        inst``_po_valid, inst``_po_type, inst``_po_data, inst``_po_index, inst``_po_wv, inst``_po_wk, inst``_po_wd, \
        inst``_ks_we, inst``_ks_idx, inst``_ks_key, inst``_sort_go, inst``_sort_manual, inst``_sort_n, \
        inst``_so_we, inst``_so_pos, inst``_so_idx, inst``_so_done, inst``_dbg_upc, inst``_idle};
    `A123_ENG(u_eng_r0, gpu3d_gxeng_r0)
    `A123_ENG(u_eng_r1, gpu3d_gxeng_r1)
    wire [599:0] u_eng_ov = {e_addr, e_pop, dp, swap_ack, oc_valid, oc_rej, oc_quad, boxres, test_done, npoly, nvert, ovf_set,
        mrd_ack, mrd_data, mrd_cap, po_valid, po_type, po_data, po_index, po_wv, po_wk, po_wd,
        ks_we, ks_idx, ks_key, sort_go, sort_manual, sort_n, e_so_we, e_so_pos, e_so_idx, e_so_done, dbg_upc, dbg_idle};
    // the front's DS-visible and engine-side outputs
    logic        f0_wr_wait, f0_flush_req, f0_irq, f0_dma_low, f0_gx_stall, f0_test_exec, f0_dbg_stall, f0_dbg_apply, f0_dg_full, f0_dg_exec;
    logic [31:0] f0_gxstat; logic [23:0] f0_zerodot; logic [39:0] f0_e_data; logic [8:0] f0_mx; logic [12:0] f0_dg_used;
    logic        f0_e_avail, f0_e_more, f0_sp_wreq, f0_sp_rreq; logic [23:0] f0_sp_waddr, f0_sp_raddr; logic [31:0] f0_sp_wdata;
    gpu3d_gxfront_r0 #(.GAT_FE(GAT_FE), .CHEAP(GX_CHEAP), .PRE(1'b1), .SPILL(SPILL), .SP_ON(SP_ON), .GATH16(GATH16), .SP_AW(SP_AW)) u_front_r0 (
        .clk, .rst, .tick, .geom_en, .vblank,
        .wr_req, .wr_be(io_be), .wr_addr(io_addr), .wr_data(io_wdata), .wr_pre, .wr_wait(f0_wr_wait),
        .gxstat(f0_gxstat), .zerodot(f0_zerodot), .flush_req(f0_flush_req), .irq(f0_irq), .dma_low(f0_dma_low), .gx_stall(f0_gx_stall),
        .e_addr, .e_data(f0_e_data), .mx(f0_mx), .dp,
        .oc_valid, .oc_rej, .oc_quad, .test_exec(f0_test_exec),
        .dbg_stall(f0_dbg_stall), .dbg_apply(f0_dbg_apply), .dg_full(f0_dg_full), .dg_used(f0_dg_used), .dg_exec(f0_dg_exec),
        .e_avail(f0_e_avail), .e_pop, .e_more(f0_e_more), .sp_wreq(f0_sp_wreq), .sp_waddr(f0_sp_waddr), .sp_wdata(f0_sp_wdata),
        .sp_wack(f_wack), .sp_wdrained(f_wdrained), .sp_rreq(f0_sp_rreq), .sp_raddr(f0_sp_raddr),
        .sp_rack(f_rack), .sp_rvalid(f_rvalid), .sp_rdata(f_rdata));
    wire [255:0] f0_ov = {f0_wr_wait, f0_gxstat, f0_zerodot, f0_flush_req, f0_irq, f0_dma_low, f0_gx_stall, f0_e_data, f0_mx, f0_test_exec,
        f0_dbg_stall, f0_dbg_apply, f0_dg_full, f0_dg_used, f0_dg_exec, f0_e_avail, f0_e_more, f0_sp_wreq, f0_sp_waddr, f0_sp_wdata,
        f0_sp_rreq, f0_sp_raddr};
    wire [255:0] f_ov = {io_wait, gxstat, zerodot, flush_req, irq_gxfifo, dma_gx_low, gx_stall, e_data, mx, test_exec,
        dbg_stall, dbg_apply, dg_full, diag_used, dg_exec, e_avail, e_more, sp_wreq, sp_waddr, sp_wdata, sp_rreq, sp_raddr};
    longint a123_cy = 0, a123_m1 = 0, a123_m2 = 0, a123_m3 = 0, a123_t3 = 0;
    always_ff @(posedge clk) begin
        a123_cy <= a123_cy + 1;
        if (!rst) begin
            if (u_eng_r1_ov != u_eng_r0_ov || u_eng_r1_tst_res != u_eng_r0_tst_res) begin
                a123_m1 <= a123_m1 + 1;
                if (a123_m1 < 10) $display("A123EQ a1 differs at clock %0d: r1 %h r0 %h", a123_cy, u_eng_r1_ov, u_eng_r0_ov);
            end
            if (u_eng_ov != u_eng_r1_ov) begin
                a123_m3 <= a123_m3 + 1;
                if (a123_m3 < 10) $display("A123EQ a3 differs at clock %0d: a3 %h r1 %h", a123_cy, u_eng_ov, u_eng_r1_ov);
            end
            if (PTEST && mrd_pend && mrd_tst && tpend == 4'd0) begin
                a123_t3 <= a123_t3 + 1;
                if (tst_q != u_eng_r1_tst_res[32 * tst_ra +: 32]) begin
                    a123_m3 <= a123_m3 + 1;
                    $display("A123EQ a3 test word %0d differs at clock %0d: %08x / %08x", tst_ra, a123_cy, tst_q, u_eng_r1_tst_res[32 * tst_ra +: 32]);
                end
            end
            if (f_ov != f0_ov) begin
                a123_m2 <= a123_m2 + 1;
                if (a123_m2 < 10) $display("A123EQ a2 differs at clock %0d: a2 %h r0 %h", a123_cy, f_ov, f0_ov);
            end
        end
    end
    // the running totals at each VBlank (tb_geom does not call final); a run's last line is its result
    logic a123_vb = 1'b0;
    always_ff @(posedge clk) begin
        a123_vb <= vblank;
        if (vblank && !a123_vb)
            $display("A123EQ clocks %0d: a1 %0d, a2 %0d, a3 %0d differing clocks; %0d test-word reads", a123_cy, a123_m1, a123_m2, a123_m3, a123_t3);
    end
    final $display("A123EQ clocks %0d: a1 %0d, a2 %0d, a3 %0d differing clocks; %0d test-word reads", a123_cy, a123_m1, a123_m2, a123_m3, a123_t3);
`undef A123_ENG
`ifdef A123_DBG
    always_ff @(posedge clk) if (a123_cy >= `A123_DBG - 30 && a123_cy <= `A123_DBG)
        $display("DBG %0d wr_req %b wr_wait %b/%b wdata %08x | a2 act %b up %b nc %0d w %08x p %0d pc %0d tp %0d st_n %0d st_w %0d upb %b | r0 act %b up %b nc %0d cur %08x pc %0d tp %0d st_n %0d st_w %0d upb %b",
                 a123_cy, wr_req, io_wait, f0_wr_wait, io_wdata, u_front.act, u_front.up, u_front.pk_nc, u_front.pk_w, u_front.pk_p, u_front.pk_pc, u_front.pk_tp, u_front.st_n, u_front.st_w, u_front.pk_upb,
                 u_front_r0.act, u_front_r0.up, u_front_r0.pk_nc, u_front_r0.pk_cur, u_front_r0.pk_pc, u_front_r0.pk_tp, u_front_r0.st_n, u_front_r0.st_w, u_front_r0.pk_upb);
`endif
