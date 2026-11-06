// SPDX-License-Identifier: MIT
// 640x480 status screen for the SD probe (docs/sd-probe.md "Reading the
// screen"). Timing as openfpga-PlayStation's psx_test_pattern, which runs on hardware.
//   rows   0- 95: overall: blue waiting, yellow running, green done, red failed;
//                 orange while any command has run past the probe's timeout
//   rows 128-223: eight boxes. First the start-up load: gray nothing yet,
//                 yellow loading, green loaded, red no data arrived. Then one
//                 per read case (7): gray pending, yellow running, green
//                 finished without APF errors, red an APF error
//   rows 256-287: progress bar (records written)
//   rows 448-479: animated strip (the picture is live)
// Inputs come from the bridge clock; they change slowly and are only shown,
// so two-flop samples are enough (constrained as false paths).
`default_nettype none
module sd_probe_screen (
    input wire clk, reset,
    input wire [1:0] state,
    input wire [13:0] case_state,
    input wire [1:0] load_state,
    input wire stuck,
    input wire [9:0] progress,       // bar width in pixels, 0..640
    output wire [23:0] rgb,
    output wire de, hs, vs
);
    reg [9:0] x = 0, y = 0;
    (* async_reg = "true" *) reg [28:0] status_meta = 0;
    reg [28:0] status_sync = 0;
    always @(posedge clk) begin
        status_meta <= {load_state, progress, stuck, case_state, state};
        status_sync <= status_meta;
    end
    wire [1:0] st = status_sync[1:0];
    wire [13:0] cst = status_sync[15:2];
    wire stk = status_sync[16];
    wire [9:0] bar = status_sync[26:17];
    wire [1:0] lst = status_sync[28:27];

    always @(posedge clk) begin
        if (reset) begin x <= 0; y <= 0; end
        else if (x == 799) begin x <= 0; y <= y == 524 ? 10'd0 : y + 1'b1; end
        else x <= x + 1'b1;
    end
    // 640x480, 800x525 totals, positive APF frame/line pulses.
    assign de = x < 640 && y < 480;
    assign hs = x >= 656 && x < 752;
    assign vs = y >= 490 && y < 492;

    function automatic [23:0] state_colour(input [1:0] s);
        case (s)
            2'd0: state_colour = 24'h2080FF;
            2'd1: state_colour = 24'hFFFF20;
            2'd2: state_colour = 24'h20FF40;
            default: state_colour = 24'hFF2020;
        endcase
    endfunction
    function automatic [23:0] case_colour(input [1:0] s);
        case (s)
            2'd0: case_colour = 24'h606060;
            2'd1: case_colour = 24'hFFFF20;
            2'd2: case_colour = 24'h20FF40;
            default: case_colour = 24'hFF2020;
        endcase
    endfunction

    // boxes: 70 wide on a 78-pixel pitch, starting at x=10
    reg [3:0] box = 0;
    reg [6:0] box_x = 0;
    reg in_box = 0;
    always @* begin
        box = 0; box_x = 0; in_box = 0;
        if (x >= 10 && x < 640) begin
            box = (x - 10) / 78;
            box_x = (x - 10) % 78;
            in_box = box < 8 && box_x < 70;
        end
    end
    reg [1:0] box_state;
    always @* case (box)
        4'd0: box_state = lst;
        4'd1: box_state = cst[1:0];
        4'd2: box_state = cst[3:2];
        4'd3: box_state = cst[5:4];
        4'd4: box_state = cst[7:6];
        4'd5: box_state = cst[9:8];
        4'd6: box_state = cst[11:10];
        default: box_state = cst[13:12];
    endcase

    reg [7:0] animation = 0;
    always @(posedge clk) if (x == 0 && y == 0) animation <= animation + 1'b1;

    reg [23:0] pixel;
    always @* begin
        pixel = 24'h000000;
        if (y < 96) pixel = stk && st == 2'd1 ? 24'hFF8000 : state_colour(st);
        else if (y >= 128 && y < 224) begin if (in_box) pixel = case_colour(box_state); end
        else if (y >= 256 && y < 288) pixel = x < bar ? 24'hFFFFFF : 24'h303030;
        else if (y >= 448) pixel = {animation, animation, animation};
    end
    assign rgb = de ? pixel : 24'h000000;
endmodule
`default_nettype wire
