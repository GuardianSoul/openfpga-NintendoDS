// Equivalence of nds_controls with the gestures (A/B/X/Y in Touch Mode at
// their defaults: A Touch, B/X/Y Button) against the version before them
// (nds_controls_old, the pen at the cursor), under random keys, sticks,
// controller types and frame pulses. Run by sim/pocket_ds/controls_eq.py.
`timescale 1ns/1ps
module tb_controls_eq;
    reg clk = 0, reset = 1;
    always #5 clk = !clk;
    reg [15:0] keys = 0;
    reg [3:0] ctype = 1;
    reg [31:0] joy = 32'h8080_8080;
    reg frame = 0;
    reg [1:0] csel = 0, speed = 1;
    wire [1:0] lo, ln;
    wire to, tn, co, cn, po, pn;
    wire [7:0] xo, yo, xn, yn, pxn, pyn;
    wire [15:0] ko, kn;
    nds_controls_old ref_ (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .touch_btn(2'd0), .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(lo), .touch(to), .cursor(co), .pen(po), .cur_x(xo), .cur_y(yo), .ds_keys(ko));
    nds_controls dut (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .gest(12'h001), .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(ln), .touch(tn), .cursor(cn), .pen(pn), .cur_x(xn), .cur_y(yn), .pen_x(pxn), .pen_y(pyn), .ds_keys(kn));
    longint n = 0, errors = 0, pens = 0, touches = 0;
    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        repeat (3000000) begin
            @(negedge clk);
            // keys change rarely (a press lasts frames), SELECT a little more often, the sticks now and then
            if ($urandom % 64 == 0) keys[$urandom % 16] ^= 1;
            if ($urandom % 400 == 0) keys = 0;
            if ($urandom % 20000 == 0) ctype = $urandom % 2 ? 4'h3 : 4'h1;
            if ($urandom % 3000 == 0) joy = $urandom;
            if ($urandom % 50000 == 0) begin csel = $urandom; speed = $urandom % 3; end
            if ($urandom % 3000 == 0) reset = 1; else reset = 0;
            frame = $urandom % 40 == 0;
            @(posedge clk); #1;
            n++;
            pens += pn; touches += tn;
            if ({lo, to, co, po, xo, yo, ko, xo, yo} !== {ln, tn, cn, pn, xn, yn, kn, pxn, pyn}) begin
                errors++;
                if (errors < 5) $display("DIFF at %0d: layout %0d/%0d touch %b/%b cursor %b/%b pen %b/%b x %0d/%0d y %0d/%0d keys %h/%h pen_xy %0d,%0d",
                    n, lo, ln, to, tn, co, cn, po, pn, xo, xn, yo, yn, ko, kn, pxn, pyn);
            end
        end
        $display("%0d cycles, %0d with touch mode, %0d with the pen down", n, touches, pens);
        if (errors == 0 && touches > 0 && pens > 0) $display("EQUIVALENT"); else $display("NOT EQUIVALENT (%0d)", errors);
        $finish;
    end
endmodule
