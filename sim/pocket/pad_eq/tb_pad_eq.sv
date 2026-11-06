// psx_pocket_pad with its timers on a tick, against the clock-counting version (REF) with the same times: a tick
// every 2^K clocks and REF's bit widths K larger. Keys change just after a tick, so both timers count alike; every output
// is compared just before each tick, with random SELECT holds around the brush, tap and hold windows.
`timescale 1ns/1ps
module tb_pad_eq;
    localparam int K = 6;
    logic clk = 0; always #5 clk = !clk;
    logic reset_n = 0;
    logic [15:0] keys = 0;
    logic [K-1:0] div = 0;
    wire tick = &div;
    always @(posedge clk) div <= div + 1'b1;
    wire [15:0] b_n, b_r; wire [5:0] c_n, c_r;
    psx_pocket_pad u_new (.clk1x(clk), .reset_n, .apf_keys(keys), .tick, .combo_enable(6'h3F), .dpad_combo_enable(1'b0),
        .buttons(b_n), .combos(c_n), .dpad_combos(), .docked());
    psx_pocket_pad_ref #(.HOLD_BITS(6 + K), .TAP_BITS(3 + K), .BRUSH_BITS(1 + K)) u_ref (.clk1x(clk), .reset_n, .apf_keys(keys),
        .combo_enable(6'h3F), .dpad_combo_enable(1'b0), .buttons(b_r), .combos(c_r), .dpad_combos(), .docked());
    longint ticks = 0, bad = 0, tap_n = 0, passed_n = 0, combos_n = 0;
    int unsigned rs = 32'd12345;
    function automatic int rnd(int m); rs = rs * 32'd1664525 + 32'd1013904223; return (rs >> 8) % m; endfunction
    // a press pattern: SELECT held for a chosen number of ticks, maybe with a combo key, then a gap
    int left = 0, sel_left = 0;
    logic fall = 0;
    // (a release a clock past the tick's phase: REF's count of N ticks' clocks is then N * 2^K, not one short)
    always @(negedge clk) if (fall && div == 3) begin keys[14] <= 1'b0; keys[13:4] <= 10'd0; fall <= 1'b0; end
    always @(negedge clk) if (reset_n && div == 2) begin
        // (two clocks of synchroniser: keys seen just after the tick)
        if (sel_left == 0 && left == 0) begin
            keys[14] <= 1'b1;
            case (rnd(5)) 0: sel_left <= rnd(4); 1: sel_left <= 1 + rnd(3); 2: sel_left <= 55 + rnd(20); default: sel_left <= 2 + rnd(30); endcase
            if (rnd(3) == 0) keys[13:4] <= 10'(1 << rnd(6));
        end else if (sel_left > 0) begin
            sel_left <= sel_left - 1;
            if (sel_left == 1) begin fall <= 1'b1; left <= rnd(12); end
            else if (rnd(16) == 0) keys[3:0] <= 4'(rnd(16));
        end else left <= left - 1;
    end
    always @(negedge clk) if (reset_n && tick) begin
        ticks++;
        if (b_n[14] && !keys[14]) tap_n++;
        if (b_n[14] && keys[14]) passed_n++;
        if (c_n != 0) combos_n++;
        if (b_n !== b_r || c_n !== c_r) begin bad++; if (bad <= 5) $display("tick %0d: buttons %h/%h combos %h/%h keys %h", ticks, b_n, b_r, c_n, c_r, keys); end
    end
    initial begin
        repeat (4) @(negedge clk); reset_n = 1;
        wait (ticks == 400000);
        $display("%s: %0d ticks, %0d differing; tap %0d, passed %0d, combos %0d", bad == 0 && tap_n > 0 && passed_n > 0 && combos_n > 0 ? "EQUIVALENT" : "DIFFER", ticks, bad, tap_n, passed_n, combos_n);
        $finish;
    end
endmodule
