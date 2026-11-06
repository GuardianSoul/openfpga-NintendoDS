// SPDX-License-Identifier: MIT
// Pocket controls of the DS core (plan.md, "Controls and screen layouts",
// the maintainer 2026-10-23), on clk_bus.
//
// openfpga-PlayStation's SELECT combos (rtl/pocket/psx_pocket_pad_combo.sv, its timers in DS frames,
// module psx_pocket_pad) with L, R, Y, A, X and B enabled: while SELECT is
// held, those keys are held back from the game and reported as combos (so the
// A/B/X/Y press that toggles touch mode never reaches the game); a short
// SELECT tap still reaches the game as a pulse, and SELECT held alone passes
// through. The DS has its own L, R and SELECT, which reach the game outside
// combos.
// Core Settings (tools/ds/settings.py) choose:
//   SELECT + L/R      On: SELECT+L previous layout, SELECT+R next layout
//   SELECT + A/B/X/Y  On: SELECT + A/B/X/Y touch mode (2026-10-28: two
//                     switches since #746; Off, those buttons reach the game
//                     with SELECT)
//   Cursor Speed   1, 3 or 6 pixels per frame
//   A/B/X/Y in Touch Mode  what each face button does in touch mode (gest)
// layout_set (a layout chosen from the menu, applied at once) has no menu
// entry since #217: core_top_ds ties it to none.
// Layouts: stacked -> top only -> bottom only -> stacked (SELECT+R; SELECT+L
// the other way round). Touch mode (SELECT + A/B/X/Y): the D-pad moves a
// cursor over the bottom screen (clamped to 256 x 192); each face button is,
// by its gest setting, a game button (Button: reaches the game), the pen at
// the cursor (Touch: down while held, A's default) or a gesture drawn from
// the cursor (2026-11-06, for TWEWY's psychs and Ranger's captures).
// The D-pad and the buttons that touch don't reach the game.
// Gestures: a press starts one at the next DS frame (none while another
// runs); the pen is down at one point per frame and goes up after the last
// (pen_x/pen_y, clamped to the screen; the cursor stays where it is):
//   Circle / Big Circle  radius 24 / 48 px, 16 points clockwise from the
//                        top, again while the button is held (Ranger's loops)
//   Swipe Up/Left/Down/Right  96 px from the cursor in 12 frames (13 points, 8 px
//                        apart; TWEWY's Pyrokinesis casts nothing from 48 px)
// Top only (2026-10-28): the normal controls. No touch, cursor or pen;
// SELECT + A/B/X/Y are no combos there (the button reaches the game); only
// SELECT+L/R still change the layout. Touch mode's state is kept and applies
// again when a layout with the bottom screen returns.
// A docked analog controller (APF type 3 in cont1_key[31:28]; other types
// carry no stick values, so the sticks are ignored, the maintainer 2026-10-28):
//   left stick: the D-pad, OR'd with it (thresholds 0x40/0xC0, released at
//               0x58/0xA8: hysteresis)
//   right stick: moves the cursor without touch mode, (deflection - 32) / 8
//               pixels a frame (up to 11) beyond a dead zone of 32
//   R3 (the right stick pressed): the pen at the cursor
// The cursor shows (cursor) in touch mode or with an analog controller while
// it moved, the pen went down or touch mode was switched on in the last 180
// DS frames (3 s), never in top only.
// ds_keys is the pad as the game sees it, in APF bit order.
`default_nettype none
module nds_controls (
    input wire clk, reset,
    input wire [15:0] apf_keys,             // cont1_key[15:0], any clock (synchronised inside)
    input wire [3:0] apf_type,              // cont1_key[31:28], any clock
    input wire [31:0] apf_joy,              // cont1_joy {RY, RX, LY, LX}, any clock
    input wire frame,                       // one pulse per DS frame
    input wire [1:0] combo_sel,             // off: [0] SELECT + L/R, [1] SELECT + A/B/X/Y
    input wire [11:0] gest,                 // {Y, X, B, A} in touch mode: 0 Button, 1 Touch, 2 Circle,
                                            // 3 Big Circle, 4-7 Swipe Up, Left, Down, Right
    input wire [1:0] speed,                 // 0 slow, 1 normal, 2 fast
    input wire [1:0] layout_set,            // Screen Layout
    input wire set_new,                     // pulse: the settings above changed
    output reg [1:0] layout = 0,            // 0 stacked, 1 top only, 2 bottom only
    output wire touch,                      // touch mode, in effect (not in top only)
    output wire cursor,                     // draw the cursor
    output wire pen,
    output reg [7:0] cur_x = 8'd128,
    output reg [7:0] cur_y = 8'd96,
    output wire [7:0] pen_x, pen_y,         // where the pen touches: the cursor, or a gesture's point
    output wire [15:0] ds_keys
);
    localparam UP = 0, DOWN = 1, LEFT = 2, RIGHT = 3, R3 = 13;
    wire top_only = layout == 2'd1;
    wire [15:0] buttons;
    wire [5:0] combos;
    psx_pocket_pad pad (.clk1x(clk), .reset_n(!reset), .apf_keys(apf_keys), .tick(frame),
        .combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}}),
        .dpad_combo_enable(1'b0), .buttons(buttons), .combos(combos), .dpad_combos(), .docked());
    // combos: [0] SELECT + L, [1] SELECT + R, [2] Y, [3] A, [4] X, [5] B
    wire c_prev  = combos[0];
    wire c_next  = combos[1];
    wire c_touch = |combos[5:2];
    // the analog controller: its type, and the sticks sampled once a DS frame (they move at most once a millisecond,
    // so a sample caught mid-update is one frame's cursor step at worst; the D-pad's stick up to a frame later).
    // Only each axis's top five bits ({RY, RX, LY, LX}[7:3]) are kept, and for the left stick whether its low three
    // are nonzero: the D-pad thresholds (exact) and the cursor rate need no more (area, 2026-10-28)
    (* async_reg = "true" *) reg ana1 = 0, ana = 0;
    reg [21:0] joy = {2'b00, {4{5'h10}}};
    always @(posedge clk) begin
        ana1 <= apf_type == 4'h3; ana <= ana1;
        if (frame) joy <= {|apf_joy[10:8], |apf_joy[2:0], apf_joy[31:27], apf_joy[23:19], apf_joy[15:11], apf_joy[7:3]};
    end
    wire [4:0] lx = joy[4:0], ly = joy[9:5], rx = joy[14:10], ry = joy[19:15];   // value / 8
    wire lx_f = joy[20], ly_f = joy[21];                                            // value % 8 != 0
    reg [3:0] sdir = 0;                     // the left stick as the D-pad (up, down, left, right)
    // pressed below 0x40 / above 0xC0, released from 0x58 / at 0xA8 and below (v > 8k: v/8 > k, or v/8 = k
    // with low bits)
    always @(posedge clk)
        if (reset || !ana) sdir <= 0;
        else begin
            sdir[UP]    <= sdir[UP]    ? ly < 5'd11 : ly < 5'd8;
            sdir[DOWN]  <= sdir[DOWN]  ? ly > 5'd21 || ly == 5'd21 && ly_f : ly > 5'd24 || ly == 5'd24 && ly_f;
            sdir[LEFT]  <= sdir[LEFT]  ? lx < 5'd11 : lx < 5'd8;
            sdir[RIGHT] <= sdir[RIGHT] ? lx > 5'd21 || lx == 5'd21 && lx_f : lx > 5'd24 || lx == 5'd24 && lx_f;
        end
    wire [15:0] keys = buttons | {12'd0, sdir};
    // the right stick: pixels a frame beyond the dead zone of 32, (deflection - 32) / 8 in steps of 8
    function automatic [3:0] rate(input [4:0] v);
        reg [3:0] m;
        m = v[4] ? v[3:0] : ~v[3:0];        // deflection / 8 (one's complement below the centre)
        rate = m > 4'd4 ? m - 4'd4 : 4'd0;
    endfunction
    wire [3:0] rsx = rate(rx), rsy = rate(ry);
    wire stick_move = ana && !top_only && (rsx != 0 || rsy != 0);
    wire pen_ana = ana && !top_only && buttons[R3];
    reg touch_on = 0;                       // touch mode as toggled (kept through top only)
    assign touch = touch_on && !top_only;
    wire [7:0] step = speed == 2'd0 ? 8'd1 : speed == 2'd2 ? 8'd6 : 8'd3;
    reg [2:0] combo_d = 0;
    reg [1:0] layout_q = 0;                 // the menu's layout last applied
    reg [7:0] idle = 8'd180;                // DS frames since the cursor was last used (180: hidden)
    wire moving = touch && |keys[3:0];
    // the cursor's step a frame and its direction: the D-pad's (touch mode) or the right stick's; one add and
    // clamp per axis serves both (they never move it in the same frame), a zero step leaves it
    wire [7:0] sy = touch ? (keys[UP] || keys[DOWN] ? step : 8'd0) : {4'd0, rsy};
    wire [7:0] sx = touch ? (keys[LEFT] || keys[RIGHT] ? step : 8'd0) : {4'd0, rsx};
    wire sy_neg = touch ? keys[UP] : !ry[4];
    wire sx_neg = touch ? keys[LEFT] : !rx[4];
    always @(posedge clk) begin
        combo_d <= {c_prev, c_next, c_touch};
        if (reset) begin
            layout <= 0; layout_q <= 0; touch_on <= 0; cur_x <= 8'd128; cur_y <= 8'd96; idle <= 8'd180;
        end else begin
            if (set_new) layout_q <= layout_set;
            if (set_new && layout_set != layout_q) layout <= layout_set == 2'd3 ? 2'd0 : layout_set;
            else if (c_next && !combo_d[1]) layout <= layout == 2'd2 ? 2'd0 : layout + 1'b1;
            else if (c_prev && !combo_d[2]) layout <= layout == 2'd0 ? 2'd2 : layout - 1'b1;
            if (c_touch && !combo_d[0]) touch_on <= !touch_on;
            if (c_touch && !combo_d[0] && !touch_on) idle <= 0;
            else if (frame) idle <= moving || stick_move || pen ? 8'd0 : idle == 8'd180 ? idle : idle + 1'b1;
            if (frame && (touch || stick_move)) begin
                cur_y <= sy_neg ? (cur_y < sy ? 8'd0 : cur_y - sy) : (cur_y > 8'd191 - sy ? 8'd191 : cur_y + sy);
                cur_x <= sx_neg ? (cur_x < sx ? 8'd0 : cur_x - sx) : (cur_x > 8'd255 - sx ? 8'd255 : cur_x + sx);
            end
        end
    end
    // gestures: the face buttons as the frame before (a press is a new one), the gesture running, its kind and
    // button and its point (step)
    wire [3:0] fb = keys[7:4];              // A, B, X, Y
    reg [3:0] fb_q = 0;
    reg g_act = 0;
    reg [2:0] g_kind = 0;
    reg [1:0] g_btn = 0;
    reg [3:0] g_step = 0;
    wire [3:0] g_on, g_pen, g_gest;         // the button doesn't reach the game; is the pen; draws a gesture
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gb
            assign g_on[gi] = gest[3 * gi +: 3] != 3'd0;
            assign g_pen[gi] = gest[3 * gi +: 3] == 3'd1;
            assign g_gest[gi] = gest[3 * gi + 1] || gest[3 * gi + 2];
        end
    endgenerate
    wire [3:0] g_new = fb & ~fb_q & g_gest;
    wire [1:0] g_sel = g_new[0] ? 2'd0 : g_new[1] ? 2'd1 : g_new[2] ? 2'd2 : 2'd3;
    wire g_circle = !g_kind[2];
    wire g_big = g_circle && g_kind[0];
    wire g_end = g_step == (g_circle ? 4'd15 : 4'd12);   // the last point
    always @(posedge clk)
        if (reset || !touch) begin
            g_act <= 0; fb_q <= 4'hF;       // (a button held as touch mode starts draws nothing)
        end else if (frame) begin
            fb_q <= fb;
            if (g_act) begin
                g_step <= g_end ? 4'd0 : g_step + 1'b1;    // (a circle's repeat starts at its first point)
                if (g_end) g_act <= g_circle && fb[g_btn];
            end else if (|g_new) begin
                g_act <= 1; g_kind <= gest[3 * g_sel +: 3]; g_btn <= g_sel; g_step <= 0;
            end
        end
    // the point's offset from the cursor, a sixteenth of a turn apart, for x at the step and for y (-cos) a
    // quarter turn further on: Circle 2 round(12 sin), Big Circle round(48 sin) (the maintainer: Circle the 24 px Big
    // Circle was, Big Circle twice that, a loop in 16 frames for both: 32 points was too slow; about 19 px a
    // frame, and Ranger still captures); a swipe's 8 px a step
    function automatic signed [4:0] sin12(input [3:0] k);
        reg [4:0] m;
        case (k[2:0])
            3'd0: m = 5'd0; 3'd1: m = 5'd5; 3'd2: m = 5'd8; 3'd3: m = 5'd11;
            3'd4: m = 5'd12; 3'd5: m = 5'd11; 3'd6: m = 5'd8; default: m = 5'd5;
        endcase
        sin12 = k[3] ? -m : m;
    endfunction
    function automatic signed [6:0] sin48(input [3:0] k);
        reg [6:0] m;
        case (k[2:0])
            3'd0: m = 7'd0; 3'd1: m = 7'd18; 3'd2: m = 7'd34; 3'd3: m = 7'd44;
            3'd4: m = 7'd48; 3'd5: m = 7'd44; 3'd6: m = 7'd34; default: m = 7'd18;
        endcase
        sin48 = k[3] ? -m : m;
    endfunction
    wire signed [5:0] s_x = {sin12(g_step), 1'b0}, s_y = {sin12(g_step + 4'd4), 1'b0};
    wire signed [7:0] c_x = g_big ? sin48(g_step) : s_x;
    wire signed [7:0] c_y = g_big ? sin48(g_step + 4'd4) : s_y;
    wire [7:0] sw = {1'b0, g_step[3:0], 3'b000};            // step * 8 (up to 96)
    wire signed [7:0] sw_s = g_kind[1] ? sw : -sw;           // Down/Right +, Up/Left -
    wire signed [7:0] dx = g_circle ? c_x : g_kind[0] ? sw_s : 8'sd0;
    wire signed [7:0] dy = g_circle ? -c_y : g_kind[0] ? 8'sd0 : sw_s;
    wire signed [9:0] px = $signed({2'b00, cur_x}) + dx, py = $signed({2'b00, cur_y}) + dy;
    // the point, clamped to the screen, through a register here: pen_x/pen_y reach the DS on clk_sys, so the
    // adds stay off that crossing; the pen goes down with it, a clock after the gesture starts (g_vis)
    reg [7:0] g_x = 0, g_y = 0;
    reg g_vis = 0;
    always @(posedge clk) begin
        g_x <= px[9] ? 8'd0 : px[8] ? 8'd255 : px[7:0];
        g_y <= py[9] ? 8'd0 : py > 10'sd191 ? 8'd191 : py[7:0];
        g_vis <= g_act && touch;
    end
    assign pen_x = g_vis ? g_x : cur_x;
    assign pen_y = g_vis ? g_y : cur_y;
    assign cursor = !top_only && (touch || ana) && idle != 8'd180;
    assign pen = (touch && (|(fb & g_pen) || g_vis)) || pen_ana;
    assign ds_keys = touch ? keys & ~{8'd0, g_on, 4'hF} : keys;
endmodule
`default_nettype wire
