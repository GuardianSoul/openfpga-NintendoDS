// nds_diag_xmem: random clk_mem events (100 MHz) crossed to clk_sys (67 MHz); after a quiet stretch the sum of
// the clk_sys increments must equal the events, per event line. diag.sh runs it.
`timescale 1ns/1ps
module tb_diag_xmem;
    localparam integer N = 8;
    logic clk_mem = 0, clk_sys = 0, rst = 1;
    always #5 clk_mem = !clk_mem;
    always #7.46 clk_sys = !clk_sys;
    logic [N-1:0] ev = 0;
    wire [N*2-1:0] inc;
    nds_diag_xmem #(.N(N)) dut (.clk_mem, .clk_sys, .rst_sys(rst), .ev_mem(ev), .inc);
    longint unsigned sent [N], got [N];
    int dens [N];
    bit quiet = 0;
    always @(posedge clk_mem) for (int k = 0; k < N; k++) if (ev[k]) sent[k]++;
    always @(posedge clk_sys) if (!rst) for (int k = 0; k < N; k++) got[k] += inc[k*2 +: 2];
    initial begin
        int seed, errors;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        for (int k = 0; k < N; k++) begin dens[k] = $urandom % 101; sent[k] = 0; got[k] = 0; end
        dens[0] = 100;                                     // every clock: the worst burst
        repeat (20) @(posedge clk_sys); rst <= 0;
        fork
            forever begin @(posedge clk_mem); for (int k = 0; k < N; k++) ev[k] <= !quiet && ($urandom % 100) < dens[k]; end
            begin repeat (200000) @(posedge clk_mem); quiet = 1; repeat (100) @(posedge clk_sys); end
        join_any
        errors = 0;
        for (int k = 0; k < N; k++) if (sent[k] != got[k]) begin errors++; $display("ERROR event %0d: %0d sent, %0d counted", k, sent[k], got[k]); end
        $display("diag_xmem: %0d events on line 0, %0d errors", sent[0], errors);
        if (errors == 0 && sent[0] > 1000) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
