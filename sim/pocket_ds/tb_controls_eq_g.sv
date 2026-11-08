// Equivalence of nds_controls against an earlier version with the same ports
// (nds_controls_old), with the gestures on: random A/B/X/Y in Touch Mode
// settings, keys, sticks, controller types, speeds and frame pulses, every
// output compared on every clock, pen_x/pen_y included. Run by
// sim/pocket_ds/controls_eq.py when the old version has the gestures.
`timescale 1ns/1ps
module tb_controls_eq;
    reg clk = 0, reset = 1;
    always #5 clk = !clk;
    reg [15:0] keys = 0;
    reg [3:0] ctype = 1;
    reg [31:0] joy = 32'h8080_8080;
    reg frame = 0;
    reg [1:0] csel = 0, speed = 1;
    reg [11:0] gest = 12'h001;
    wire [1:0] lo, ln;
    wire to, tn, co, cn, po, pn;
    wire [7:0] xo, yo, xn, yn, pxo, pyo, pxn, pyn;
    wire [15:0] ko, kn;
    nds_controls_old ref_ (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .gest, .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(lo), .touch(to), .cursor(co), .pen(po), .cur_x(xo), .cur_y(yo), .pen_x(pxo), .pen_y(pyo), .ds_keys(ko));
    nds_controls dut (.clk, .reset, .apf_keys(keys), .apf_type(ctype), .apf_joy(joy), .frame,
        .combo_sel(csel), .gest, .speed, .layout_set(2'd0), .set_new(1'b0),
        .layout(ln), .touch(tn), .cursor(cn), .pen(pn), .cur_x(xn), .cur_y(yn), .pen_x(pxn), .pen_y(pyn), .ds_keys(kn));
    longint n = 0, errors = 0, pens = 0, touches = 0, moved = 0, clamped = 0;
    reg [7:0] px_q = 0;
    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        repeat (4000000) begin
            @(negedge clk);
            // face buttons and the D-pad change often enough for gestures to start, run and repeat while held
            if ($urandom % 48 == 0) keys[$urandom % 16] ^= 1;
            if ($urandom % 2000 == 0) keys = 0;
            if ($urandom % 20000 == 0) ctype = $urandom % 2 ? 4'h3 : 4'h1;
            if ($urandom % 3000 == 0) joy = $urandom;
            if ($urandom % 50000 == 0) begin csel = $urandom % 2 ? 2'd0 : $urandom; speed = $urandom % 3; end
            if ($urandom % 20000 == 0) gest = $urandom;
            if ($urandom % 30000 == 0) reset = 1; else reset = 0;
            // frame: one clk_bus pulse per DS frame (core_top_ds frame_b), never on two clocks in a row; the
            // shared add (nds_controls q_x/q_y) relies on that
            frame = !frame && $urandom % 40 == 0;
            @(posedge clk); #1;
            n++;
            pens += pn; touches += tn;
            moved += pxn != xn;
            clamped += pn && (pxn == 0 || pxn == 255 || pyn == 0 || pyn == 191);
            if ({lo, to, co, po, xo, yo, ko, pxo, pyo} !== {ln, tn, cn, pn, xn, yn, kn, pxn, pyn}) begin
                errors++;
                if (errors < 5) $display("DIFF at %0d: layout %0d/%0d touch %b/%b cursor %b/%b pen %b/%b x %0d/%0d y %0d/%0d keys %h/%h pen_x %0d/%0d pen_y %0d/%0d",
                    n, lo, ln, to, tn, co, cn, po, pn, xo, xn, yo, yn, ko, kn, pxo, pxn, pyo, pyn);
            end
        end
        $display("%0d cycles, %0d with touch mode, %0d with the pen down, %0d with a gesture point off the cursor, %0d pen-down at an edge",
            n, touches, pens, moved, clamped);
        if (errors == 0 && touches > 0 && pens > 0 && moved > 0 && clamped > 0) $display("EQUIVALENT"); else $display("NOT EQUIVALENT (%0d)", errors);
        $finish;
    end
endmodule
