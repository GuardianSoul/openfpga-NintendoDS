// nds_psram_port 32-byte blocks (s_n8) through psx_psram_pair on cram models,
// against a reference image: random word reads/writes and block
// reads/writes over a 512-byte window (sim/pocket/psram_eq/port_blk.sh).
//   +seed=N +reqs=N
`timescale 1ps/1ps
`default_nettype none
module blk_stack #(parameter NAME = "s") (
    input wire clk_sys, clk_mem, clk_cram, rst_sys, rst_mem, mutant,
    input wire s_req, s_we,
    input wire [23:0] s_addr,
    input wire [31:0] s_wdata,
    input wire [3:0] s_be,
    input wire s_n8,
    output wire s_ack, s_rvalid, s_wnext,
    output wire [31:0] s_rdata,
    output wire init
);
    wire ps_valid, ps_write, ps_ready, ps_rsp, ps_clk_en;
    wire [24:0] ps_addr; wire [3:0] ps_half; wire [127:0] ps_wdata, ps_rdata, ps_raw; wire [15:0] ps_be;
    wire [127:0] wd = ps_wdata;
    nds_psram_port port (.clk_sys, .clk_mem, .reset(rst_sys), .s_req, .s_we, .s_addr, .s_wdata, .s_be,
        .s_ack, .s_rvalid, .s_rdata, .s_n8, .s_wnext, .req_valid(ps_valid), .req_write(ps_write), .req_ready(ps_ready),
        .req_addr(ps_addr), .req_halfwords(ps_half), .req_wdata(ps_wdata), .req_byte_en(ps_be),
        .rsp_valid(ps_rsp), .rsp_rdata(ps_raw));
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

module tb_port_blk;
    reg clk_mem = 0, clk_sys = 0, clk_cram = 0;
    always #4973 clk_mem = !clk_mem;
    initial begin #14919; forever begin clk_sys = 1; #7460; clk_sys = 0; #7459; end end
    always @(clk_mem) clk_cram <= #6838 clk_mem;
    reg rst_sys = 1, rst_mem = 1;
    reg s_req = 0, s_we = 0, s_n8 = 0; reg [23:0] s_addr = 0; reg [31:0] s_wdata = 0; reg [3:0] s_be = 0;
    wire ack, rv, wnext, init; wire [31:0] rd;
    blk_stack #(.NAME("b")) st (.clk_sys, .clk_mem, .clk_cram, .rst_sys, .rst_mem, .mutant(1'b0),
        .s_req, .s_we, .s_addr, .s_wdata, .s_be, .s_n8, .s_ack(ack), .s_rvalid(rv), .s_wnext(wnext), .s_rdata(rd), .init);
    reg [31:0] img [0:127];
    reg [31:0] bw [0:7];
    integer seed = 1, reqs = 3000, bad = 0, nw = 0, nr = 0, nbw = 0, nbr = 0, k, got, i;
    // a block write's feed: the next word the cycle after each s_wnext
    integer bk = 0;
    always @(posedge clk_sys) if (s_req && s_n8 && s_we && wnext) begin bk = bk + 1; s_wdata <= bw[bk < 8 ? bk : 7]; end
    // read words
    integer rk = 0; reg [6:0] ra; reg rblk = 0;
    always @(posedge clk_sys) if (rv) begin
        if (rd !== img[rblk ? {ra[6:3], 3'd0} + rk : {ra[6:2], 2'd0} + rk]) begin bad = bad + 1;
            if (bad < 8) $display("%0t read %h word %0d: %h, expected %h", $time, ra, rk, rd, img[rblk ? {ra[6:3], 3'd0} + rk : {ra[6:2], 2'd0} + rk]); end
        rk = rk + 1;
    end
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("reqs=%d", reqs));
        void'($urandom(seed));
        for (i = 0; i < 128; i = i + 1) img[i] = 0;
        #100000; rst_mem = 0; @(posedge clk_sys); rst_sys = 0;
        wait (init);
        // the window starts zeroed
        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk_sys); s_req <= 1; s_we <= 1; s_n8 <= 0; s_addr <= i; s_wdata <= 0; s_be <= 4'hF;
            @(posedge clk_sys); while (!ack) @(posedge clk_sys); s_req <= 0;
        end
        repeat (reqs) begin
            integer r;
            r = $urandom % 4;
            @(posedge clk_sys);
            ra = $urandom;
            if (r == 0) begin            // word write
                s_req <= 1; s_we <= 1; s_n8 <= 0; s_addr <= ra; s_wdata <= $urandom; s_be <= 4'hF;
                @(posedge clk_sys); while (!ack) @(posedge clk_sys); img[ra] = s_wdata; nw = nw + 1;
            end else if (r == 1) begin   // word read
                rk = 0; rblk = 0;
                s_req <= 1; s_we <= 0; s_n8 <= 0; s_addr <= ra; s_be <= 4'hF;
                @(posedge clk_sys); while (!ack) @(posedge clk_sys); s_req <= 0;
                while (rk < 4) @(posedge clk_sys); nr = nr + 1;
            end else if (r == 2) begin   // block write
                for (i = 0; i < 8; i = i + 1) bw[i] = $urandom;
                bk = 0;
                s_req <= 1; s_we <= 1; s_n8 <= 1; s_addr <= {ra[6:3], 3'd0}; s_wdata <= bw[0]; s_be <= 4'hF;
                @(posedge clk_sys); while (!ack) @(posedge clk_sys);
                if (bk != 8) begin bad = bad + 1; $display("block write took %0d words", bk); end
                for (i = 0; i < 8; i = i + 1) img[{ra[6:3], 3'd0} + i] = bw[i]; nbw = nbw + 1;
            end else begin               // block read
                rk = 0; rblk = 1;
                s_req <= 1; s_we <= 0; s_n8 <= 1; s_addr <= {ra[6:3], 3'd0}; s_be <= 4'hF;
                @(posedge clk_sys); while (!ack) @(posedge clk_sys); s_req <= 0;
                while (rk < 8) @(posedge clk_sys); nbr = nbr + 1;
            end
            s_req <= 0; s_n8 <= 0;
            // a word read's 4 words are the aligned 16 bytes: only word ra is checked
        end
        repeat (200) @(posedge clk_sys);
        $display("%s: %0d word writes, %0d word reads, %0d block writes, %0d block reads, %0d errors (seed %0d)",
                 bad ? "FAIL" : "PASS", nw, nr, nbw, nbr, bad, seed);
        $finish;
    end
endmodule
`default_nettype wire
