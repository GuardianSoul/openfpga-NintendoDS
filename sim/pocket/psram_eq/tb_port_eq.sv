// nds_psram_port against its version at REF (port_eq.sh): two
// nds_psram_port + psx_psram_pair (LIVE_REQ=1, as core_top_ds) stacks on
// cram_model chips under the same random clk_sys traffic; s_ack, s_rvalid and
// s_rdata must agree every cycle. Built from tb_psram_eq.sv (6cf07d8).
`timescale 1ps/1ps
`default_nettype none
module port_stack #(parameter integer REF = 0, parameter NAME = "s") (
    input wire clk_sys, clk_mem, clk_cram, rst_sys, rst_mem, mutant,
    input wire s_req, s_we,
    input wire [23:0] s_addr,
    input wire [31:0] s_wdata,
    input wire [3:0] s_be,
    output wire s_ack, s_rvalid,
    output wire [31:0] s_rdata,
    output wire init
);
    wire ps_valid, ps_write, ps_ready, ps_rsp, ps_clk_en;
    wire [24:0] ps_addr; wire [3:0] ps_half; wire [127:0] ps_wdata, ps_rdata, ps_raw; wire [15:0] ps_be;
    wire [127:0] wd = ps_wdata;
    generate if (REF) begin : g_ref
    nds_psram_port_ref port (.clk_sys, .clk_mem, .reset(rst_sys), .s_req, .s_we, .s_addr, .s_wdata, .s_be,
        .s_ack, .s_rvalid, .s_rdata, .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready),
        .req_addr(ps_addr), .req_halfwords(ps_half), .req_wdata(ps_wdata), .req_byte_en(ps_be),
        .rsp_valid(ps_rsp), .rsp_rdata(ps_rdata));
    end else begin : g_new
    nds_psram_port port (.clk_sys, .clk_mem, .reset(rst_sys), .s_req, .s_we, .s_addr, .s_wdata, .s_be,
        .s_ack, .s_rvalid, .s_rdata, .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready),
        .req_addr(ps_addr), .req_halfwords(ps_half), .req_wdata(ps_wdata), .req_byte_en(ps_be),
        .rsp_valid(ps_rsp), .rsp_rdata(ps_raw));   // the working copy reads rsp_raw, as core_top_ds
    end endgenerate
    wire [21:16] c0a, c1a; wire [15:0] c0dq, c1dq; wire c0w, c1w;
    wire c0adv, c1adv, c0cre, c1cre, c0ce0, c0ce1, c1ce0, c1ce1, c0oe, c1oe, c0we, c1we, c0ub, c0lb, c1ub, c1lb;
    psx_psram_pair #(.CLOCK_MHZ(100.541946), .PAIRED(1), .LIVE_REQ(1), .T_INIT(200)) pair (.clk(clk_mem), .reset(rst_mem),
        .initialized(init), .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready), .req_addr(ps_addr),
        .req_halfwords(ps_half), .req_wdata(wd), .req_byte_en(ps_be), .rsp_valid(ps_rsp), .rsp_ready(1'b1),
        .rsp_rdata(ps_rdata), .rsp_raw(ps_raw), .rsp_error(), .fill_valid(), .fill_word(), .fill_data(), .idle(), .chip_clk_en(ps_clk_en),
        .dbg_state(), .cram0_a(c0a), .cram1_a(c1a), .cram0_dq(c0dq), .cram1_dq(c1dq), .cram0_wait(c0w), .cram1_wait(c1w),
        .cram0_adv_n(c0adv), .cram1_adv_n(c1adv), .cram0_cre(c0cre), .cram1_cre(c1cre),
        .cram0_ce0_n(c0ce0), .cram0_ce1_n(c0ce1), .cram1_ce0_n(c1ce0), .cram1_ce1_n(c1ce1),
        .cram0_oe_n(c0oe), .cram1_oe_n(c1oe), .cram0_we_n(c0we), .cram1_we_n(c1we),
        .cram0_ub_n(c0ub), .cram0_lb_n(c0lb), .cram1_ub_n(c1ub), .cram1_lb_n(c1lb));
    wire [1:0] cclk;
    altddio_out #(.width(2)) ck (.datain_h({2{ps_clk_en}}), .datain_l(2'b0), .outclock(clk_cram), .dataout(cclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
    cram_model #(.NAME({NAME, "0"})) m0 (.sclk(clk_mem), .clk(cclk[0]), .a(c0a), .dq(c0dq), .wait_o(c0w),
        .adv_n(c0adv), .cre(c0cre), .ce0_n(c0ce0), .ce1_n(c0ce1), .oe_n(c0oe), .we_n(c0we), .ub_n(c0ub), .lb_n(c0lb));
    cram_model #(.NAME({NAME, "1"})) m1 (.sclk(clk_mem), .clk(cclk[1]), .a(c1a), .dq(c1dq), .wait_o(c1w),
        .adv_n(c1adv), .cre(c1cre), .ce0_n(c1ce0), .ce1_n(c1ce1), .oe_n(c1oe), .we_n(c1we), .ub_n(c1ub), .lb_n(c1lb));
endmodule

module tb_port_eq;
    reg clk_mem = 0, clk_sys = 0, clk_cram = 0;
    always #4973 clk_mem = !clk_mem;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    reg rst_sys = 1, rst_mem = 1, mutant = 0;
    reg s_req = 0, s_we = 0; reg [23:0] s_addr = 0; reg [31:0] s_wdata = 0; reg [3:0] s_be = 0;
    wire ack_r, rv_r, ack_n, rv_n, init_r, init_n; wire [31:0] rd_r, rd_n;
    port_stack #(.REF(1), .NAME("r")) ref_s (.clk_sys, .clk_mem, .clk_cram, .rst_sys, .rst_mem, .mutant(1'b0),
        .s_req, .s_we, .s_addr, .s_wdata, .s_be, .s_ack(ack_r), .s_rvalid(rv_r), .s_rdata(rd_r), .init(init_r));
    port_stack #(.REF(0), .NAME("n")) new_s (.clk_sys, .clk_mem, .clk_cram, .rst_sys, .rst_mem, .mutant,
        .s_req, .s_we, .s_addr, .s_wdata, .s_be, .s_ack(ack_n), .s_rvalid(rv_n), .s_rdata(rd_n), .init(init_n));
    integer seed = 1, reqs = 3000, bad = 0, nw = 0, nr = 0, nz = 0, gap;
    always @(posedge clk_sys) if (!rst_sys && {ack_n, rv_n, rd_n} !== {ack_r, rv_r, rd_r}) begin
        if (bad < 5) $display("  %0t: new ack %b rv %b rd %h, ref ack %b rv %b rd %h", $time, ack_n, rv_n, rd_n, ack_r, rv_r, rd_r);
        bad = bad + 1;
    end
    always @(posedge clk_sys) if (rv_r && rd_r != 0) nz = nz + 1;
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("reqs=%d", reqs));
        if ($test$plusargs("mutant")) mutant = 1;
        void'($urandom(seed));
        #100000; rst_mem = 0; @(posedge clk_sys); rst_sys = 0;
        wait (init_r && init_n);
        repeat (reqs) begin
            @(posedge clk_sys);
            s_req <= 1; s_we <= $urandom % 2; s_addr <= $urandom % 256;
            s_wdata <= $urandom; s_be <= ($urandom % 15) + 1;
            @(posedge clk_sys); while (!ack_r) @(posedge clk_sys);
            if (s_we) nw = nw + 1; else nr = nr + 1;
            s_req <= 0;
            gap = $urandom % 8; repeat (gap) @(posedge clk_sys);
        end
        repeat (200) @(posedge clk_sys);
        $display("%s: %0d writes, %0d reads, %0d nonzero read words, %0d mismatching cycles (seed %0d%s)",
                 bad ? "FAIL" : "PASS", nw, nr, nz, bad, seed, mutant ? ", mutant" : "");
        $finish;
    end
endmodule
`default_nettype wire
