// SPDX-License-Identifier: MIT
// nds_controls with stick/cursor/idle processing in SERV firmware.
// Hardware keeps the pad, DS keys, and layout/touch edges: sampling those
// edges only once per frame loses repeated taps and changes which face
// combos are enabled during a simultaneous layout change. The decisions
// below are adapted directly from nds_controls, including settings priority.
// Cursor/stick updates follow at the next DS frame (sw/scpu/cache.c).
// External registers (nds_cart_scpu registers 16-31):
//   read 16: synchronised stick word (22 bits, as nds_controls)
//   read 17: {settings_pending, frame_pending, type[3:0], layout[1:0],
//             touch_btn[1:0], speed[1:0], layout_set[1:0], combo_sel[1:0],
//             touch_started, touch_on, combos[5:0], 4'd0, keys[3:0]}
//   read 18: buttons[15:0]
//   write 16: [8:5] stick D-pad, [1] cursor, [0] analog controller;
//             [9] frame done, [10] settings done, [11] touch-start consumed
//   write 17: {cur_y[7:0], cur_x[7:0]}
// New events win over simultaneous acknowledgements.
`default_nettype none
module nds_controls_fw (
    input wire clk, reset,
    input wire [15:0] apf_keys,
    input wire [3:0] apf_type,
    input wire [31:0] apf_joy,
    input wire frame,
    input wire [1:0] combo_sel,
    input wire [1:0] touch_btn,
    input wire [1:0] speed,
    input wire [1:0] layout_set,
    input wire set_new,
    output reg [1:0] layout = 0,
    output wire touch,
    output wire cursor,
    output wire pen,
    output reg [7:0] cur_x = 8'd128,
    output reg [7:0] cur_y = 8'd96,
    output wire [15:0] ds_keys,
    // SERV's external registers (nds_cart_scpu)
    input wire x_we,
    input wire [3:0] x_addr,
    input wire [31:0] x_wdata,
    output wire [31:0] x_rdata,
    output wire x_ev                        // a DS frame or new settings: the firmware's turn
);
    localparam R3 = 13;
    wire top_only = layout == 2'd1;
    wire [15:0] buttons;
    wire [5:0] combos;
    psx_pocket_pad pad (.clk1x(clk), .reset_n(!reset), .apf_keys(apf_keys),
        .combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}}),
        .dpad_combo_enable(1'b0), .buttons(buttons), .combos(combos), .dpad_combos(), .docked());
    (* async_reg = "true" *) reg [3:0] ty1 = 0, ty2 = 0;
    (* async_reg = "true" *) reg [21:0] jy1 = 0, jy2 = 0;
    reg [3:0] sdir = 0;
    reg touch_on = 0, cur_v = 0, ana = 0, frame_p = 0, set_p = 0;
    reg [2:0] cmb_d = 0;                   // {prev, next, touch}, as nds_controls
    reg [1:0] layout_q = 0;
    reg touch_started = 0;
    wire c_prev = combos[0], c_next = combos[1], c_touch = |combos[5:2];
    always @(posedge clk) begin
        ty1 <= apf_type; ty2 <= ty1;
        jy1 <= {|apf_joy[10:8], |apf_joy[2:0], apf_joy[31:27], apf_joy[23:19], apf_joy[15:11], apf_joy[7:3]};
        jy2 <= jy1;
        if (x_we && x_addr == 4'd0) begin
            sdir <= x_wdata[8:5]; cur_v <= x_wdata[1]; ana <= x_wdata[0];
            if (x_wdata[11]) touch_started <= 0;
            if (x_wdata[9]) frame_p <= 0;
            if (x_wdata[10]) set_p <= 0;
        end
        if (x_we && x_addr == 4'd1) begin cur_y <= x_wdata[15:8]; cur_x <= x_wdata[7:0]; end
        cmb_d <= {c_prev, c_next, c_touch};
        if (set_new) layout_q <= layout_set;
        if (set_new && layout_set != layout_q) layout <= layout_set == 2'd3 ? 2'd0 : layout_set;
        else if (c_next && !cmb_d[1]) layout <= layout == 2'd2 ? 2'd0 : layout + 1'b1;
        else if (c_prev && !cmb_d[2]) layout <= layout == 2'd0 ? 2'd2 : layout - 1'b1;
        if (c_touch && !cmb_d[0]) begin
            touch_on <= !touch_on;
            if (!touch_on) touch_started <= 1;
        end
        if (frame) frame_p <= 1;
        if (set_new) set_p <= 1;
        if (reset) begin
            cmb_d <= 0; layout_q <= 0; touch_started <= 0; sdir <= 0; layout <= 0; touch_on <= 0; cur_v <= 0; ana <= 0; cur_x <= 8'd128; cur_y <= 8'd96; frame_p <= 0; set_p <= 0;
        end
    end
    wire [15:0] keys = buttons | {12'd0, sdir};
    assign touch = touch_on && !top_only;
    assign cursor = cur_v && !top_only;
    assign pen = (touch && keys[4 + touch_btn]) || (ana && !top_only && buttons[R3]);
    assign ds_keys = touch ? keys & ~(16'h000F | (16'h0010 << touch_btn)) : keys;
    assign x_ev = frame_p || set_p;
    assign x_rdata = x_addr == 4'd0 ? {10'd0, jy2} :
                     x_addr == 4'd1 ? {set_p, frame_p, ty2, layout, touch_btn, speed, layout_set, combo_sel, touch_started, touch_on, combos, 4'd0, keys[3:0]} :
                     {16'd0, buttons};
endmodule
`default_nettype wire
