// nds_audio_interp: samples every 2,048 clocks (in_pre a clock before the data,
// as nds_top's); the output must reach each new sample's value by the end of
// its period and be halfway between two samples at half the period. Run by
// sim/pocket_ds/audio_test.py.
`timescale 1ns/1ps
module tb_audio_interp;
    reg clk = 0; always #1 clk = !clk;
    reg in_pre = 0, hold = 0; reg signed [15:0] in_l = 0, in_r = 0;
    wire signed [15:0] out_l, out_r;
    nds_audio_interp dut (.clk, .in_pre, .hold, .in_l, .in_r, .out_l, .out_r);
    integer errs = 0, n;
    reg signed [15:0] seq [0:8];
    task automatic sample(input signed [15:0] v);
        @(posedge clk) in_pre <= 1;
        @(posedge clk) begin in_pre <= 0; in_l <= v; in_r <= -v - 16'sd1; end
        @(posedge clk);
    endtask
    function automatic integer absd(input integer a, input integer b); absd = a > b ? a - b : b - a; endfunction
    initial begin
        seq[0]=0; seq[1]=32767; seq[2]=-32768; seq[3]=1000; seq[4]=1000; seq[5]=-5; seq[6]=20000; seq[7]=-20000; seq[8]=10000;
        for (n = 0; n < 9; n++) begin
            sample(seq[n]);
            repeat (1021) @(posedge clk);
            // half the period: between the previous sample and this one
            if (n > 0 && absd(out_l, (seq[n-1] + seq[n]) / 2) > absd(seq[n], seq[n-1]) * 4 / 2048 + 2) begin errs++; $display("ERROR half %0d: %0d", n, out_l); end
            if (n > 0 && absd(out_r, (-seq[n-1] - 1 - seq[n] - 1) / 2) > absd(seq[n], seq[n-1]) * 4 / 2048 + 2) begin errs++; $display("ERROR half R %0d: %0d", n, out_r); end
            repeat (1024) @(posedge clk);
            // the end of the period: at the new sample (within the last steps)
            if (n > 0 && absd(out_l, seq[n]) > absd(seq[n], seq[n-1]) * 4 / 2048 + 2) begin errs++; $display("ERROR end %0d: %0d vs %0d", n, out_l, seq[n]); end
        end
        // a late sample: the output holds the newest
        repeat (6000) @(posedge clk);
        if (out_l != seq[8]) begin errs++; $display("ERROR hold: %0d", out_l); end
        if (errs) $display("TEST FAILED"); else $display("TEST PASSED");
        $finish;
    end
endmodule
