// Engine lockstep against a base commit (sim only: gpu3d_geom with GX_A123_EQ and this directory first on the
// include path; sim/gpu3d/eng_eq/build.sh). gpu3d_gxeng_r0 is the base's gpu3d_gxeng, renamed; it runs open loop
// beside u_eng on the same inputs, and every output, the test-result word included, is compared at every clock.
    logic        r0_e_pop, r0_swap_ack, r0_oc_valid, r0_oc_rej, r0_oc_quad, r0_boxres, r0_test_done, r0_ovf_set;
    logic [8:0]  r0_e_addr, r0_dp;
    logic [11:0] r0_npoly; logic [12:0] r0_nvert;
    logic        r0_mrd_ack, r0_mrd_cap; logic [31:0] r0_mrd_data, r0_tst_q;
    logic        r0_po_valid, r0_po_type, r0_po_wv; logic [127:0] r0_po_data; logic [10:0] r0_po_index;
    logic [1:0]  r0_po_wk; logic [31:0] r0_po_wd;
    logic        r0_ks_we, r0_sort_go, r0_sort_manual; logic [10:0] r0_ks_idx; logic [16:0] r0_ks_key; logic [11:0] r0_sort_n;
    logic        r0_so_we, r0_so_done; logic [10:0] r0_so_pos, r0_so_idx; logic [10:0] r0_dbg_upc; logic r0_idle;
    gpu3d_gxeng_r0 #(.SMALL(SMALL), .DIV_R4(DIV_R4), .DIV_P2X(DIV_P2X), .DS_STRIPCLIP(DS_STRIPCLIP), .DS_FARREJ(DS_FARREJ), .DS_CLIPRED(DS_CLIPRED),
                     .USORT(USORT), .LUNIT(LUNIT), .VFIN(VFIN), .FF(FF), .FF_VTX(FF_VTX), .PAR(GX_PAR),
                     .VC_M10K(ENG_TM10K), .STK_M10K(ENG_M10K), .VOC_M10K(ENG_TM10K)) u_eng_r0 (
        .clk, .clk_2x, .rst, .e_addr(r0_e_addr), .e_data, .mx, .e_avail, .e_pop(r0_e_pop), .e_more, .dp(r0_dp), .zerodot,
        .swap_go, .swap_ack(r0_swap_ack), .oc_valid(r0_oc_valid), .oc_rej(r0_oc_rej), .oc_quad(r0_oc_quad),
        .boxres(r0_boxres), .test_done(r0_test_done), .npoly(r0_npoly), .nvert(r0_nvert), .ovf_set(r0_ovf_set),
        .mrd_req, .mrd_sel, .mrd_ack(r0_mrd_ack), .mrd_data(r0_mrd_data), .mrd_cap(r0_mrd_cap), .tst_ra, .tst_q(r0_tst_q),
        .po_valid(r0_po_valid), .po_ready, .s_draw, .po_type(r0_po_type), .po_data(r0_po_data), .po_index(r0_po_index),
        .po_wv(r0_po_wv), .po_wk(r0_po_wk), .po_wd(r0_po_wd),
        .ks_we(r0_ks_we), .ks_idx(r0_ks_idx), .ks_key(r0_ks_key), .sort_go(r0_sort_go), .sort_manual(r0_sort_manual),
        .sort_n(r0_sort_n), .sort_busy, .so_we(r0_so_we), .so_pos(r0_so_pos), .so_idx(r0_so_idx), .so_done(r0_so_done),
        .dbg_upc(r0_dbg_upc), .idle(r0_idle));
    wire [639:0] r0_ov = {r0_e_addr, r0_e_pop, r0_dp, r0_swap_ack, r0_oc_valid, r0_oc_rej, r0_oc_quad, r0_boxres, r0_test_done,
        r0_npoly, r0_nvert, r0_ovf_set, r0_mrd_ack, r0_mrd_data, r0_mrd_cap, r0_tst_q, r0_po_valid, r0_po_type, r0_po_data, r0_po_index,
        r0_po_wv, r0_po_wk, r0_po_wd, r0_ks_we, r0_ks_idx, r0_ks_key, r0_sort_go, r0_sort_manual, r0_sort_n,
        r0_so_we, r0_so_pos, r0_so_idx, r0_so_done, r0_dbg_upc, r0_idle};
    wire [639:0] e_ov = {e_addr, e_pop, dp, swap_ack, oc_valid, oc_rej, oc_quad, boxres, test_done,
        npoly, nvert, ovf_set, mrd_ack, mrd_data, mrd_cap, tst_q, po_valid, po_type, po_data, po_index,
        po_wv, po_wk, po_wd, ks_we, ks_idx, ks_key, sort_go, sort_manual, sort_n,
        e_so_we, e_so_pos, e_so_idx, e_so_done, dbg_upc, dbg_idle};
    longint eq_cy = 0, eq_m = 0, eq_po = 0;
    always_ff @(posedge clk) begin
        eq_cy <= eq_cy + 1;
        if (!rst) begin
            if (po_valid && po_ready) eq_po <= eq_po + 1;
            if (e_ov != r0_ov) begin
                eq_m <= eq_m + 1;
                if (eq_m < 10) $display("ENGEQ differs at clock %0d: new %h base %h", eq_cy, e_ov, r0_ov);
            end
        end
    end
    logic eq_vb = 1'b0;
    always_ff @(posedge clk) begin
        eq_vb <= vblank;
        if (vblank && !eq_vb) $display("ENGEQ clocks %0d: %0d differing clocks; %0d records out", eq_cy, eq_m, eq_po);
    end
    final $display("ENGEQ clocks %0d: %0d differing clocks; %0d records out", eq_cy, eq_m, eq_po);
