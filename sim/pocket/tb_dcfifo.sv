// nds_dcfifo: wempty against the words actually written and popped, random
// rates on unrelated clocks (sim/pocket/dcfifo_test.sh). At every wclk edge,
// wempty must mean every word written so far has been popped; the data must
// come out in order. +seed=N +n=N
`timescale 1ns/1ps
`default_nettype none
module tb_dcfifo;
    reg wclk = 0, rclk = 0;
    real wp = 7.46, rp = 4.97;              // clk_sys, clk_mem
    always #(wp / 2) wclk = !wclk;
    always #(rp / 2) rclk = !rclk;
    reg wr = 0, rd = 0;
    reg [31:0] wdata = 0;
    wire full, wempty, valid;
    wire [31:0] rdata;
    nds_dcfifo #(.W(32), .A(4)) dut (.wclk, .wreset(1'b0), .wr, .wdata, .full, .wempty, .overflow(),
        .rclk, .rd, .valid, .rdata);
    longint nw = 0, np = 0, bad = 0, nchk = 0;
    integer seed = 1, n = 200000, wrate = 50, rrate = 50;
    // write side: random bursts
    always @(posedge wclk) begin
        if (wempty && np != nw) begin bad++; if (bad < 8) $display("%0t wempty with %0d words unpopped", $time, nw - np); end
        if (wempty) nchk++;
        if (wr && !full) begin nw++; end
        wr <= ($urandom % 100) < wrate;
        wdata <= nw;                        // (nw already counts this edge's write)
    end
    // read side: pops at a random rate, data in order
    longint exp = 0;
    always @(posedge rclk) begin
        if (rd && valid) begin
            if (rdata !== exp[31:0]) begin bad++; if (bad < 8) $display("%0t read %0d, expected %0d", $time, rdata, exp); end
            exp++; np++;
        end
        rd <= ($urandom % 100) < rrate;
    end
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("n=%d", n));
        void'($urandom(seed));
        repeat (n) begin
            @(posedge wclk);
            if ($urandom % 5000 == 0) begin wrate = $urandom % 101; rrate = $urandom % 101; end
        end
        $display("%s: %0d written, %0d popped, wempty seen %0d times, %0d errors (seed %0d)", bad ? "FAIL" : "PASS", nw, np, nchk, bad, seed);
        $finish;
    end
endmodule
`default_nettype wire
