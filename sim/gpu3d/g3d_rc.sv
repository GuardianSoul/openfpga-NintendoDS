// tb_gpu3d --rcache (simulation only): gpu3d_raster with nds_gpu3d's real
// texture/palette caches (nds_g3d_cache, taken from rtl/ds/nds_gpu3d.sv at
// build time) and its block port mux (a copy of nds_gpu3d's: keep the two
// the same), so the model's texel timing is the core's. The testbench serves
// the block port (t_*: SP_TEX / SP_TPAL in t_blk[17:15], the 32-byte block in
// [13:0], four 64-bit beats in acknowledge order). tex_* / pal_* are outputs
// for the testbench's measurements only.
module g3d_rc #(
    parameter int TXD = 0,
    parameter int PXD = 0,
    parameter bit FPSKIP = 0,
    parameter bit TRU = 0,
    parameter bit TRUL = 0,
    parameter bit FPCLR = 0,
    parameter int TL = 6,
    parameter int PL = 4,
    parameter bit TC_FAST = 0,
    parameter bit TC_MIF2 = 0,
    parameter int TC_WAYS = 1,
    parameter bit V2 = 0,         // nds_g3d_cache2 (texture)
    parameter bit PV2 = V2,       // ... palette
    parameter int V2W = 1,        // ... texture ways (nds_g3d_cache2 WAYS)
    parameter bit TSH = 1,        // ... one tag controller for the ways (nds_g3d_cache2 TSHARE)
    parameter bit PSCAN = 1,      // ... its scanner
    parameter bit NXB = 0,        // gpu3d_raster NXB
    parameter bit VREG = 0,
    parameter bit DSHARE = 0,
    parameter bit LB2 = 0,        // gpu3d_raster LB2
    parameter bit LOV = 0,        // gpu3d_raster LOV
    parameter bit EDIV4 = 0,      // gpu3d_raster EDIV4
    parameter bit EDGE2 = 0,      // gpu3d_raster EDGE2
    parameter bit EP2 = 0,        // gpu3d_raster EP2
    parameter bit FDB = 0,        // gpu3d_raster FDB
    parameter bit SPO = 0,        // gpu3d_raster SPO
    parameter int SPO_SL = 4,     // ... its slots
    parameter bit SPOG = 0,       // gpu3d_raster SPOG
    parameter int SPOG_N = 2,     // ... stages per group
    parameter int NF = 2,         // nds_gpu3d TC_NF
    // the raster's features (nds_gpu3d FEAT_*: the card's G3D_AA, G3D_FOG, ...; 0 with --feat-off for the golden)
    parameter bit FEAT_AA = 1, FEAT_EDGE = 1, FEAT_FOG = 1, FEAT_ATEST = 1, FEAT_TOON = 1, FEAT_SHADOW = 1, FEAT_LOWER = 1,
    parameter bit TR3 = 0,        // nds_gpu3d TR3 (with FEAT_EDGE = 0)
    parameter bit PF = 0          // nds_g3d_cache2 PF (prefetch hints from the testbench: pf_v, pf_a)
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [15:0]  dispcnt,
    input  logic [4:0]   alpharef,
    input  logic [31:0]  clear_attr1,
    input  logic [14:0]  clear_depth,
    input  logic [20:0]  fog_color,
    input  logic [14:0]  fog_offset,
    input  logic         tbl_we,
    input  logic [1:0]   tbl_sel,
    input  logic [4:0]   tbl_addr,
    input  logic [14:0]  tbl_data,
    input  logic         frame_start,
    output logic         busy,
    output logic         frame_done,
    output logic         ps_line_req,
    output logic [7:0]   ps_line_y,
    input  logic         ps_valid,
    output logic         ps_ready,
    input  logic [1:0]   ps_type,
    input  logic [127:0] ps_data,
    output logic         tex_req,
    output logic [18:0]  tex_addr,
    output logic         tex_valid,
    output logic         pal_req,
    output logic [16:0]  pal_addr,
    output logic         pal_valid,
    output logic         t_req,
    output logic [17:0]  t_blk,
    input  logic         t_ack,
    input  logic         t_rvalid,
    input  logic [63:0]  t_rdata,
    output logic         px_valid,
    output logic [7:0]   px_x,
    output logic [7:0]   px_y,
    output logic [22:0]  px_color,
    output logic [2:0]   dbg_phase,
    input  logic         pf_v,
    input  logic [18:0]  pf_a,
    output logic         dbg_span,
    output logic         dbg_pixel
);
    localparam logic [2:0] SP_TEX = 3'd5, SP_TPAL = 3'd6;   // gpu2d_pkg
    logic [15:0] tex_data, pal_data;
    gpu3d_raster #(.AREA(0), .TXD(TXD), .PXD(PXD), .FPSKIP(FPSKIP), .TRU(TRU), .TRUL(TRUL), .FPCLR(FPCLR), .NXB(NXB), .VREG(VREG), .DSHARE(DSHARE), .LB2(LB2), .LOV(LOV), .EDIV4(EDIV4), .EDGE2(EDGE2), .EP2(EP2), .FDB(FDB), .SPO(SPO), .SPO_SL(SPO_SL), .SPOG(SPOG), .SPOG_N(SPOG_N),
                   .FEAT_AA(FEAT_AA), .FEAT_EDGE(FEAT_EDGE), .FEAT_FOG(FEAT_FOG), .FEAT_ATEST(FEAT_ATEST), .FEAT_TOON(FEAT_TOON),
                   .FEAT_SHADOW(FEAT_SHADOW), .FEAT_LOWER(FEAT_LOWER), .TR3(TR3 && !FEAT_EDGE && !LB2)) u_raster (
        .clk, .rst, .dispcnt, .alpharef, .clear_attr1, .clear_depth, .fog_color, .fog_offset,
        .tbl_we, .tbl_sel, .tbl_addr, .tbl_data,
        .frame_start, .busy, .frame_done, .px_hold(1'b0), .fp_line(), .fp_act(), .r_go(),
        .ll_rd(1'b0), .ll_slot(2'd0), .ll_x(8'd0), .ll_ack(), .ll_q(),
        .ps_line_req, .ps_line_y, .ps_valid, .ps_ready, .ps_type, .ps_data,
        .tex_req, .tex_addr, .tex_inval(1'b0), .tex_valid, .tex_data,
        .pal_req, .pal_addr, .pal_valid, .pal_data,
        .px_valid, .px_x, .px_y, .px_color, .dbg_phase, .dbg_span, .dbg_pixel);

    logic        tc_req, pc_req, tc_ack, pc_ack, tc_rv, pc_rv;
    logic [13:0] tc_blk, pc_blk;
    localparam int CQL = TXD == 0 || 2 * (TXD + 3) <= 16 ? 4 : 5;
    generate if (V2) begin : g_v2
        nds_g3d_cache2 #(.AW(19), .LW(TL), .QL(CQL), .NF(NF), .PF(PF), .WAYS(V2W), .TSHARE(TSH)) u_tc (.clk, .clk2(1'b0), .rst, .flush(1'b0), .pf_v, .pf_a,
            .req(tex_req), .addr(tex_addr), .valid(tex_valid), .data(tex_data),
            .b_req(tc_req), .b_blk(tc_blk), .b_ack(tc_ack), .b_rvalid(tc_rv), .b_rdata(t_rdata));
    end else begin : g_v1
        nds_g3d_cache #(.AW(19), .LW(TL), .FAST(TC_FAST), .MIF2(TC_MIF2), .WAYS(TC_WAYS), .QL(CQL)) u_tc (.clk, .rst, .flush(1'b0),
            .req(tex_req), .addr(tex_addr), .valid(tex_valid), .data(tex_data),
            .b_req(tc_req), .b_blk(tc_blk), .b_ack(tc_ack), .b_rvalid(tc_rv), .b_rdata(t_rdata));
    end endgenerate
    generate if (PV2) begin : g_p2
        nds_g3d_cache2 #(.AW(17), .LW(PL), .QL(CQL), .SCAN(PSCAN)) u_pc (.clk, .clk2(1'b0), .rst, .flush(1'b0), .pf_v(1'b0), .pf_a('0),
            .req(pal_req), .addr(pal_addr), .valid(pal_valid), .data(pal_data),
            .b_req(pc_req), .b_blk(pc_blk), .b_ack(pc_ack), .b_rvalid(pc_rv), .b_rdata(t_rdata));
    end else begin : g_p1
        nds_g3d_cache #(.AW(17), .LW(PL), .FAST(1), .MIF2(1), .QL(CQL)) u_pc (.clk, .rst, .flush(1'b0),
            .req(pal_req), .addr(pal_addr), .valid(pal_valid), .data(pal_data),
            .b_req(pc_req), .b_blk(pc_blk), .b_ack(pc_ack), .b_rvalid(pc_rv), .b_rdata(t_rdata));
    end endgenerate
    // nds_gpu3d's block port mux (as there, V2 is TC_V2)
    localparam int TNF = V2 ? (NF > 2 ? NF : 2) : TC_MIF2 ? 2 : 1;
    logic [3:0] t_n;
    logic [TNF > 1 ? TNF - 1 : 1:0] t_ownq;
    logic [1:0] t_beat;
    wire  t_pick = tc_req ? 1'b0 : 1'b1;
    wire  t_last = t_rvalid && t_beat == 2'd3;
    assign t_req  = (t_n < 4'(TNF)) && (tc_req || pc_req);
    assign t_blk  = t_pick ? {SP_TPAL, 1'b0, pc_blk} : {SP_TEX, 1'b0, tc_blk};
    assign tc_ack = t_ack && !t_pick;
    assign pc_ack = t_ack && t_pick;
    assign tc_rv  = t_rvalid && !t_ownq[0];
    assign pc_rv  = t_rvalid && t_ownq[0];
    always_ff @(posedge clk) begin
        if (rst) begin t_n <= 4'd0; t_beat <= 2'd0; end
        else begin
            if (t_rvalid) t_beat <= t_beat + 2'd1;
            t_n <= t_n + (t_ack ? 4'd1 : 4'd0) - (t_last ? 4'd1 : 4'd0);
            if (t_last) t_ownq <= t_ownq >> 1;
            if (t_ack) t_ownq[t_n - 4'(t_last)] <= t_pick;
        end
    end
    generate if (V2) begin : g_cnt2
        longint c_go, c_q, c_req, c_need, c_two, c_wait, c_look, c_miss_lb, c_miss_ln, c_miss_ow, c_miss_hit, c_free, c_ack1, c_rv, c_rvf, c_tn2, c_tq;
        always_ff @(posedge clk) if (!rst) begin
            c_go += 64'(g_v2.u_tc.s_go); c_q += 64'(g_v2.u_tc.s_q); c_req += 64'(g_v2.u_tc.s_req); c_free += 64'(g_v2.u_tc.s_free);
            c_need += 64'(g_v2.u_tc.st == 2); c_wait += 64'(g_v2.u_tc.st == 3); c_look += 64'(g_v2.u_tc.st == 1);
            c_two += 64'(g_v2.u_tc.f_v == 2'b11);
            c_ack1 += 64'(tc_ack && g_v2.u_tc.f_v[0]); c_rv += 64'(g_v2.u_tc.r_v); c_rvf += 64'(g_v2.u_tc.r_v && g_v2.u_tc.f_v[0]); c_tn2 += 64'(t_n == 2'd2); c_tq += 64'(tc_req && !t_req);
            if (g_v2.u_tc.s_q) begin
                if (g_v2.u_tc.s_hit) c_miss_hit++;
                else if (g_v2.u_tc.onway(g_v2.u_tc.sa[18:5])) c_miss_ow++;
                else if (g_v2.u_tc.sa[12:5] == g_v2.u_tc.line) c_miss_ln++;
                else if (g_v2.u_tc.lbusy(g_v2.u_tc.sa[12:5])) c_miss_lb++;
            end
        end
        final $display("v2 tex: s_go %0d s_q %0d (hit %0d onway %0d headline %0d linebusy %0d) s_req %0d free %0d | look %0d need %0d wait %0d two-in-flight %0d | ack-with-one %0d r_v %0d r_v-with-one %0d port-two %0d tc_req-held %0d",
                       c_go, c_q, c_miss_hit, c_miss_ow, c_miss_ln, c_miss_lb, c_req, c_free, c_look, c_need, c_wait, c_two, c_ack1, c_rv, c_rvf, c_tn2, c_tq);
    end endgenerate
    // texture / palette requests repeating the last one's address (reuse potential)
    longint tq_all = 0, tq_rep = 0, tq_rep2 = 0, pq_all = 0, pq_rep = 0;
    logic [18:0] t_l1 = '1, t_l2 = '1;
    logic [16:0] p_l1 = '1;
    always_ff @(posedge clk) if (!rst) begin
        if (u_raster.tex_req) begin
            tq_all++;
            if (u_raster.tex_addr == t_l1) tq_rep++;
            else if (u_raster.tex_addr == t_l2) tq_rep2++;
            t_l2 <= t_l1; t_l1 <= u_raster.tex_addr;
        end
        if (u_raster.pal_req) begin
            pq_all++;
            if (u_raster.pal_addr == p_l1) pq_rep++;
            p_l1 <= u_raster.pal_addr;
        end
    end
    final $display("reuse: tex %0d, same as last %0d, as the one before %0d | pal %0d, same as last %0d", tq_all, tq_rep, tq_rep2, pq_all, pq_rep);
    // the edge unit: cycles by state (gpu3d_edge xs) and edges started, printed at the end
    longint ex_n [0:40];
    longint ex_edges = 0;
    always_ff @(posedge clk) if (!rst) begin
        ex_n[5'(u_raster.u_front.u_edge.xs)]++;
        if (u_raster.u_front.u_edge.xs == 0 && u_raster.u_front.u_edge.start) ex_edges++;
        // the unit idle, by what the next edge waits for: 20 its results not taken (e_res),
        // 21 the bank (input stage), 22 neither (between the two sides), 23 front-wide edge-bound phase
        if (u_raster.u_front.u_edge.xs == 0 && !u_raster.u_front.u_edge.start) begin
            if (u_raster.u_front.e_res) ex_n[20]++;
            else if (!u_raster.u_front.bk_full) begin ex_n[21]++; ex_n[24 + 5'(u_raster.u_front.st)]++; end
            else ex_n[22]++;
        end
    end
    // EP2's stage 2 (u_edgeb): cycles by state
    longint ex2_n [0:31];
    generate if (EP2) begin : g_ex2
        always_ff @(posedge clk) if (!rst) ex2_n[5'(u_raster.u_front.g_ep2.u_edgeb.xs)]++;
        final begin
            $write("edge stage 2 states:");
            for (int i = 0; i < 32; i++) if (ex2_n[i] != 0) $write(" %0d:%0d", i, ex2_n[i]);
            $display("");
        end
    end endgenerate
    // stage 1's X_H (the perspective factor's division): cycles waiting for the
    // divider (the span stage has it), for stage 2 (ho_ready), both (left; PP2: right)
    longint xh_n [0:5];
    initial for (int i = 0; i < 6; i++) xh_n[i] = 0;
    always_ff @(posedge clk) if (!rst) begin
        if (u_raster.u_front.u_edge.xs == 11 && u_raster.u_front.u_edge.mw) begin
            if (!u_raster.u_front.e_dv_gnt && !u_raster.u_front.a_ho_rdy) xh_n[2]++;
            else if (!u_raster.u_front.e_dv_gnt) xh_n[0]++;
            else if (!u_raster.u_front.a_ho_rdy) xh_n[1]++;
        end
        if (EDGE2 && EP2 && u_raster.u_front.u_edge.xs == 11 && !u_raster.u_front.a_ho_rdy) begin
            if (u_raster.u_front.lcn == 3) xh_n[3]++; else if (u_raster.u_front.eu_bb) xh_n[4]++; else xh_n[5]++;
        end
    end
    final $display("X_H waits (left): divider %0d, stage 2 %0d, both %0d | not ready: queue full %0d, stage 2 busy %0d, other %0d",
                   xh_n[0], xh_n[1], xh_n[2], xh_n[3], xh_n[4], xh_n[5]);
    // PP2: cycles by {lcn, rcn} (the result queues), and the right pipeline's states
    generate if (EDGE2 && EP2) begin : g_pq
        longint q_n [0:15], r1_n [0:31], r2_n [0:31], ss_n [0:31];
        initial for (int i = 0; i < 32; i++) begin r1_n[i] = 0; r2_n[i] = 0; ss_n[i] = 0; if (i < 16) q_n[i] = 0; end
        always_ff @(posedge clk) if (!rst) begin
            q_n[{u_raster.u_front.lcn, u_raster.u_front.rcn}]++;
            ss_n[5'(u_raster.u_front.ss)]++;
            r1_n[5'(u_raster.u_front.g_pp2.u_edge2a.xs)]++;
            r2_n[5'(u_raster.u_front.g_pp2.u_edge2b.xs)]++;
        end
        final begin
            $write("queues {lcn,rcn}:"); for (int i = 0; i < 16; i++) if (q_n[i] != 0) $write(" %0d%0d:%0d", i / 4, i % 4, q_n[i]); $display("");
            $write("right stage 1:"); for (int i = 0; i < 32; i++) if (r1_n[i] != 0) $write(" %0d:%0d", i, r1_n[i]); $display("");
            $write("span stage (ss):"); for (int i = 0; i < 32; i++) if (ss_n[i] != 0) $write(" %0d:%0d", i, ss_n[i]); $display("");
            $write("right stage 2:"); for (int i = 0; i < 32; i++) if (r2_n[i] != 0) $write(" %0d:%0d", i, r2_n[i]); $display("");
        end
    end endgenerate
    // the walker each cycle: 0 a pixel in, 1 ghost in, 2 stalled (wait17/19), 3 stalled (other),
    // 4 span bubble (next span ready, P0-P13 busy), 5 starved (no span), 6 waiting with a span of nothing
    longint wk_n [0:7];
    longint st_n [0:7];   // stalls: wait17, wait19, hold15, take/hold17, take19, hz20, other
    always_ff @(posedge clk) if (!rst) begin
        if (u_raster.wk_act) begin
            if (u_raster.adv) wk_n[u_raster.wk_ghost ? 1 : 0]++;
            else wk_n[(u_raster.wait17 || u_raster.wait19) ? 2 : 3]++;
            if (!u_raster.adv) begin
                if (u_raster.wait17) st_n[0]++; else if (u_raster.wait19) st_n[1]++;
                else if (u_raster.hold15) st_n[2]++; else if (u_raster.take17 || u_raster.hold17) st_n[3]++;
                else if (u_raster.take19) st_n[4]++; else if (u_raster.hz20) st_n[5]++; else st_n[6]++;
            end
        end else if (u_raster.nx_full && u_raster.early_busy) wk_n[4]++;
        else if (!u_raster.nx_full) wk_n[5]++;
        else wk_n[6]++;
    end
    // the final pass: cycles running, and in F_5 waiting for the write port (clear)
    longint fp_run_n = 0, fp_wait_n = 0, fp_px_n = 0;
    always_ff @(posedge clk) if (!rst) begin
        if (u_raster.u_fpass.fst != u_raster.u_fpass.F_IDLE) fp_run_n++;
        if (u_raster.u_fpass.fst == u_raster.u_fpass.F_5 && u_raster.u_fpass.fp_clr_req && !u_raster.fp_clr_ack) fp_wait_n++;
        if (u_raster.u_fpass.px_valid) fp_px_n++;
    end
    final $display("final pass: running %0d, F_5 waiting for the write port %0d, pixels %0d", fp_run_n, fp_wait_n, fp_px_n);
    final $display("stalls: wait17 %0d wait19 %0d hold15 %0d take/hold17 %0d take19 %0d hz20 %0d other %0d", st_n[0], st_n[1], st_n[2], st_n[3], st_n[4], st_n[5], st_n[6]);
    final $display("walker: px %0d ghost %0d tex-wait %0d other-stall %0d span-bubble %0d starved %0d other %0d", wk_n[0], wk_n[1], wk_n[2], wk_n[3], wk_n[4], wk_n[5], wk_n[6]);
    final begin
        $write("edge states (edges %0d):", ex_edges);
        for (int i = 0; i < 41; i++) $write(" %0d:%0d", i, ex_n[i]);
        $display("");
    end
    generate if (!V2) begin : g_cnt
    // per cache: cycles by state while it has requests (C_IDLE, C_LOOK hit / miss, C_REQ, C_FILL, C_PFW), printed at the end
    longint cs_t [0:6], cs_p [0:6];
    always_ff @(posedge clk) if (!rst) begin
        if (g_v1.u_tc.n != 0) cs_t[g_v1.u_tc.st == 1 ? (g_v1.u_tc.hit ? 1 : 5) : g_v1.u_tc.st == 0 ? 0 : 32'(g_v1.u_tc.st)]++;
        else cs_t[6]++;
        if (g_p1.u_pc.n != 0) cs_p[g_p1.u_pc.st == 1 ? (g_p1.u_pc.hit ? 1 : 5) : g_p1.u_pc.st == 0 ? 0 : 32'(g_p1.u_pc.st)]++;
        else cs_p[6]++;
    end
    final begin
        $display("rc tex: idle %0d look-hit %0d req %0d fill %0d pfw %0d look-miss %0d empty %0d", cs_t[0], cs_t[1], cs_t[2], cs_t[3], cs_t[4], cs_t[5], cs_t[6]);
        $display("rc pal: idle %0d look-hit %0d req %0d fill %0d pfw %0d look-miss %0d empty %0d", cs_p[0], cs_p[1], cs_p[2], cs_p[3], cs_p[4], cs_p[5], cs_p[6]);
    end
    end endgenerate
endmodule
