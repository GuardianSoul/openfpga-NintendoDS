// nds_psram against nds_psram_port + psx_psram_pair (h1_eq.sh,
// docs/psram-ds.md): the same random clk_sys traffic (word writes with byte
// enables, 16-byte reads, 32-byte block reads) into both, each on its own two
// cram_model chips; s_ack, s_rvalid and s_rdata must agree on every clk_sys
// edge, and every chip pin (A, DQ, ADV#, CRE, CE#, OE#, WE#, UB#/LB#) and
// the chip clock enable on every clk_mem edge.
`timescale 1ps/1ps
`default_nettype none
module h1_chips #(parameter NAME = "s") (
    input wire clk_mem, clk_cram, clk_en,
    input wire [21:16] c0a, c1a, inout wire [15:0] c0dq, c1dq, output wire c0w, c1w,
    input wire c0adv, c1adv, c0cre, c1cre, c0ce0, c0ce1, c1ce0, c1ce1, c0oe, c1oe, c0we, c1we, c0ub, c0lb, c1ub, c1lb);
    wire [1:0] cclk;
    altddio_out #(.width(2)) ck (.datain_h({2{clk_en}}), .datain_l(2'b0), .outclock(clk_cram), .dataout(cclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
    cram_model #(.NAME({NAME, "0"})) m0 (.sclk(clk_mem), .clk(cclk[0]), .a(c0a), .dq(c0dq), .wait_o(c0w),
        .adv_n(c0adv), .cre(c0cre), .ce0_n(c0ce0), .ce1_n(c0ce1), .oe_n(c0oe), .we_n(c0we), .ub_n(c0ub), .lb_n(c0lb));
    cram_model #(.NAME({NAME, "1"})) m1 (.sclk(clk_mem), .clk(cclk[1]), .a(c1a), .dq(c1dq), .wait_o(c1w),
        .adv_n(c1adv), .cre(c1cre), .ce0_n(c1ce0), .ce1_n(c1ce1), .oe_n(c1oe), .we_n(c1we), .ub_n(c1ub), .lb_n(c1lb));
endmodule

module tb_h1_eq;
    reg clk_mem = 0, clk_sys = 0, clk_cram = 0;
    always #4973 clk_mem = !clk_mem;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    reg rst_sys = 1, rst_mem = 1;
    reg s_req = 0, s_we = 0, s_n8 = 0; reg [23:0] s_addr = 0; reg [31:0] s_wdata = 0; reg [3:0] s_be = 0;

    // ---- reference: nds_psram_port + psx_psram_pair, as core_top_ds wires them
    wire ack_r, rv_r, init_r, cke_r; wire [31:0] rd_r;
    wire ps_valid, ps_write, ps_ready, ps_rsp; wire [24:0] ps_addr; wire [3:0] ps_half;
    wire [127:0] ps_wdata, ps_raw; wire [15:0] ps_be;
    wire [21:16] r0a, r1a; wire [15:0] r0dq, r1dq; wire r0w, r1w;
    wire r0adv, r1adv, r0cre, r1cre, r0ce0, r0ce1, r1ce0, r1ce1, r0oe, r1oe, r0we, r1we, r0ub, r0lb, r1ub, r1lb;
    nds_psram_port port (.clk_sys, .clk_mem, .reset(rst_sys), .s_req, .s_we, .s_addr, .s_wdata, .s_be,
        .s_ack(ack_r), .s_rvalid(rv_r), .s_rdata(rd_r), .s_n8, .s_wnext(),
        .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready), .req_addr(ps_addr), .req_halfwords(ps_half),
        .req_wdata(ps_wdata), .req_byte_en(ps_be), .rsp_valid(ps_rsp), .rsp_rdata(ps_raw));
    psx_psram_pair #(.CLOCK_MHZ(100.541946), .PAIRED(1), .LIVE_REQ(1), .T_INIT(200)) pair (.clk(clk_mem), .reset(rst_mem),
        .initialized(init_r), .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready), .req_addr(ps_addr),
        .req_halfwords(ps_half), .req_wdata(ps_wdata), .req_byte_en(ps_be), .rsp_valid(ps_rsp), .rsp_ready(1'b1),
        .rsp_rdata(), .rsp_raw(ps_raw), .rsp_error(), .fill_valid(), .fill_word(), .fill_data(), .idle(), .chip_clk_en(cke_r),
        .dbg_state(), .cram0_a(r0a), .cram1_a(r1a), .cram0_dq(r0dq), .cram1_dq(r1dq), .cram0_wait(r0w), .cram1_wait(r1w),
        .cram0_adv_n(r0adv), .cram1_adv_n(r1adv), .cram0_cre(r0cre), .cram1_cre(r1cre),
        .cram0_ce0_n(r0ce0), .cram0_ce1_n(r0ce1), .cram1_ce0_n(r1ce0), .cram1_ce1_n(r1ce1),
        .cram0_oe_n(r0oe), .cram1_oe_n(r1oe), .cram0_we_n(r0we), .cram1_we_n(r1we),
        .cram0_ub_n(r0ub), .cram0_lb_n(r0lb), .cram1_ub_n(r1ub), .cram1_lb_n(r1lb));
    h1_chips #(.NAME("r")) rc (.clk_mem, .clk_cram, .clk_en(cke_r), .c0a(r0a), .c1a(r1a), .c0dq(r0dq), .c1dq(r1dq),
        .c0w(r0w), .c1w(r1w), .c0adv(r0adv), .c1adv(r1adv), .c0cre(r0cre), .c1cre(r1cre), .c0ce0(r0ce0), .c0ce1(r0ce1),
        .c1ce0(r1ce0), .c1ce1(r1ce1), .c0oe(r0oe), .c1oe(r1oe), .c0we(r0we), .c1we(r1we), .c0ub(r0ub), .c0lb(r0lb),
        .c1ub(r1ub), .c1lb(r1lb));

    // ---- new: nds_psram
    wire ack_n, rv_n, init_n, cke_n; wire [31:0] rd_n;
    wire [21:16] n0a, n1a; wire [15:0] n0dq, n1dq; wire n0w, n1w;
    wire n0adv, n1adv, n0cre, n1cre, n0ce0, n0ce1, n1ce0, n1ce1, n0oe, n1oe, n0we, n1we, n0ub, n0lb, n1ub, n1lb;
    nds_psram #(.T_INIT(200)) dut (.clk_sys, .clk_mem, .reset_sys(rst_sys), .reset_mem(rst_mem), .initialized(init_n),
        .s_req, .s_we, .s_addr, .s_wdata, .s_be, .s_ack(ack_n), .s_rvalid(rv_n), .s_rdata(rd_n), .s_n8, .s_wnext(),
        .chip_clk_en(cke_n), .cram0_a(n0a), .cram1_a(n1a), .cram0_dq(n0dq), .cram1_dq(n1dq), .cram0_wait(n0w), .cram1_wait(n1w),
        .cram0_adv_n(n0adv), .cram1_adv_n(n1adv), .cram0_cre(n0cre), .cram1_cre(n1cre),
        .cram0_ce0_n(n0ce0), .cram0_ce1_n(n0ce1), .cram1_ce0_n(n1ce0), .cram1_ce1_n(n1ce1),
        .cram0_oe_n(n0oe), .cram1_oe_n(n1oe), .cram0_we_n(n0we), .cram1_we_n(n1we),
        .cram0_ub_n(n0ub), .cram0_lb_n(n0lb), .cram1_ub_n(n1ub), .cram1_lb_n(n1lb));
    h1_chips #(.NAME("n")) nc (.clk_mem, .clk_cram, .clk_en(cke_n), .c0a(n0a), .c1a(n1a), .c0dq(n0dq), .c1dq(n1dq),
        .c0w(n0w), .c1w(n1w), .c0adv(n0adv), .c1adv(n1adv), .c0cre(n0cre), .c1cre(n1cre), .c0ce0(n0ce0), .c0ce1(n0ce1),
        .c1ce0(n1ce0), .c1ce1(n1ce1), .c0oe(n0oe), .c1oe(n1oe), .c0we(n0we), .c1we(n1we), .c0ub(n0ub), .c0lb(n0lb),
        .c1ub(n1ub), .c1lb(n1lb));

    wire [79:0] pins_r = {cke_r, r0a, r1a, r0dq, r1dq, r0adv, r1adv, r0cre, r1cre, r0ce0, r0ce1, r1ce0, r1ce1,
                          r0oe, r1oe, r0we, r1we, r0ub, r0lb, r1ub, r1lb};
    wire [79:0] pins_n = {cke_n, n0a, n1a, n0dq, n1dq, n0adv, n1adv, n0cre, n1cre, n0ce0, n0ce1, n1ce0, n1ce1,
                          n0oe, n1oe, n0we, n1we, n0ub, n0lb, n1ub, n1lb};
    integer seed = 1, reqs = 3000, bad_s = 0, bad_p = 0, nw = 0, nr = 0, nb = 0, nz = 0, gap;
    always @(posedge clk_sys) if (!rst_sys && {ack_n, rv_n, rd_n} !== {ack_r, rv_r, rd_r}) begin
        if (bad_s < 5) $display("  %0t: new ack %b rv %b rd %h, ref ack %b rv %b rd %h", $time, ack_n, rv_n, rd_n, ack_r, rv_r, rd_r);
        bad_s = bad_s + 1;
    end
    always @(posedge clk_mem) if (!rst_mem && pins_n !== pins_r) begin
        if (bad_p < 5) $display("  %0t: pins new %h ref %h", $time, pins_n, pins_r);
        bad_p = bad_p + 1;
    end
    always @(posedge clk_sys) if (rv_r && rd_r != 0) nz = nz + 1;
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("reqs=%d", reqs));
        void'($urandom(seed));
        #100000; rst_mem = 0; @(posedge clk_sys); rst_sys = 0;
        wait (init_r && init_n);
        repeat (reqs) begin
            @(posedge clk_sys);
            s_req <= 1; s_we <= $urandom % 2; s_n8 <= 0;
            // addresses: mostly a small window (reads see the writes), some anywhere in die 0
            s_addr <= ($urandom % 4 == 0) ? {3'd0, 21'($urandom)} : 24'($urandom % 512);
            s_wdata <= $urandom; s_be <= $urandom % 16;
            if ($urandom % 4 == 0) begin s_we <= 0; s_n8 <= 1; end
            @(posedge clk_sys); while (!ack_r) @(posedge clk_sys);
            if (s_n8) nb = nb + 1; else if (s_we) nw = nw + 1; else nr = nr + 1;
            s_req <= 0;
            gap = $urandom % 3 == 0 ? 0 : $urandom % 12; repeat (gap) @(posedge clk_sys);
        end
        repeat (400) @(posedge clk_sys);
        $display("%s: %0d writes, %0d reads, %0d block reads, %0d nonzero read words, %0d / %0d mismatching sys / mem cycles (seed %0d)",
                 (bad_s || bad_p) ? "FAIL" : "PASS", nw, nr, nb, nz, bad_s, bad_p, seed);
        $finish;
    end
endmodule
`default_nettype wire
