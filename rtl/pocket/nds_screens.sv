// SPDX-License-Identifier: MIT
// DS screens to the APF scaler (docs/phase1-foundation.md, "Video"), on
// clk_bus; the outputs change every second clock and are taken by clk_vid =
// clk_bus / 2 (same PLL, edges aligned) as one pixel per clock.
//
// The DS draws line n of both screens during DS line n (2,130 bus clocks; 263
// lines per frame, 59.83 Hz). Here a test pattern generator stands in for the
// 2D engines: during bus clocks 4..515 of DS line n < 192 it makes the 256
// pixels of each screen (RGB555).
//
// Every layout's frame starts (VS with the HS) at DS line 1; the live screen's
// line m goes out during DS line m+1 from a two-line buffer.
// Layouts (SELECT+R, plan.md "Controls and screen layouts"):
//   stacked (default), scaler slot 0, 256 x 384: the top screen goes out live
//     (DS lines 1-192). The bottom screen is written to SDRAM (BUF_W, 128
//     words per line, about 5.9 MB/s) as it is drawn and sent from there
//     during the DS's vertical blank: 192 short lines of 786 bus clocks (393
//     pixel clocks) from DS line 193, ending inside DS line 0. A two-line ring
//     is fetched one line ahead (another 5.9 MB/s). Both halves of a frame
//     come from the same DS frame.
//   top only / bottom only, slot 1, 256 x 192: that screen alone, live. No SDRAM.
// HS is one pixel clock at each line start; DE covers 256 pixels; RGB is zero
// outside DE except the pixel clock after DE falls, which carries the APF
// "set scaler slot" word (RGB[23:13] slot, as openfpga-PlayStation's psx_apf_video).
// The pattern side takes the layout at DS line 0, the output side at DS line
// 1 (with VS), so a switch never changes a frame half way.
`default_nettype none
module nds_screens #(parameter [23:0] BUF_W = 24'h38_0000) (
    input wire clk, reset,
    input wire [1:0] layout_in,
    // pattern inputs (display only)
    input wire [15:0] boxes,
    input wire [9:0] prog_a, prog_b,        // 0..512
    input wire touch, pen,
    input wire [7:0] cur_x, cur_y,
    input wire [15:0] keys,
    output reg [5:0] log_addr = 0,
    input wire [31:0] log_data,             // one clock after log_addr
    input wire [47:0] log_rows,             // eight 6-bit log indices, row 0 in [5:0]
    output wire frame_pulse,
    // SDRAM: stacked-layout bottom-screen writes (single words) and reads (quads)
    output reg w_valid = 0,
    output reg [23:0] w_addr = 0,
    output reg [31:0] w_data = 0,
    input wire w_ready,
    output reg r_valid = 0,
    output reg [23:0] r_addr = 0,
    input wire r_ready,
    input wire r_rvalid,
    input wire [31:0] r_rdata,
    output reg [15:0] underruns = 0,        // buffered lines not fetched in time
    output reg [15:0] late = 0,             // buffered lines whose SDRAM write started late
    output reg [1:0] layout = 0,
    // video, valid for two clocks each
    output reg [23:0] rgb = 0,
    output reg de = 0, hs = 0, vs = 0
);
    // ---------------- DS raster ----------------
    reg [11:0] bc = 0;
    reg [8:0] dl = 0;
    reg [7:0] frame = 0;
    reg [1:0] gen_layout = 0;
    always @(posedge clk) begin
        if (reset) begin bc <= 0; dl <= 0; end
        else if (bc == 12'd2129) begin
            bc <= 0;
            if (dl == 9'd262) begin dl <= 0; frame <= frame + 1'b1; end
            else dl <= dl + 1'b1;
        end else bc <= bc + 1'b1;
        if (bc == 0 && dl == 0) gen_layout <= layout_in;
        if (bc == 0 && dl == 1) layout <= gen_layout;
    end
    assign frame_pulse = bc == 0 && dl == 0;

    // ---------------- test pattern (the 2D engines' stand-in) ----------------
    wire gen = dl < 192 && bc >= 4 && bc < 516;
    wire [8:0] p = bc[8:0] - 9'd4;
    wire scr = p[8];                        // 0 top, 1 bottom
    wire [7:0] x = p[7:0];
    wire [7:0] n = dl[7:0];
    always @(posedge clk) log_addr <= log_rows[n[5:3]*6 +: 6];
    function automatic [14:0] rgb15(input [23:0] c);
        rgb15 = {c[23:19], c[15:11], c[7:3]};
    endfunction
    function automatic [14:0] state_colour(input [1:0] s);
        case (s)
            2'd0: state_colour = rgb15(24'h505050);
            2'd1: state_colour = rgb15(24'hF0E020);
            2'd2: state_colour = rgb15(24'h20E040);
            default: state_colour = rgb15(24'hF02020);
        endcase
    endfunction
    function automatic [14:0] bar_colour(input [2:0] i);
        case (i)
            3'd0: bar_colour = 15'h7FFF;
            3'd1: bar_colour = rgb15(24'hFFFF00);
            3'd2: bar_colour = rgb15(24'h00FFFF);
            3'd3: bar_colour = rgb15(24'h00FF00);
            3'd4: bar_colour = rgb15(24'hFF00FF);
            3'd5: bar_colour = rgb15(24'hFF0000);
            3'd6: bar_colour = rgb15(24'h0000FF);
            default: bar_colour = 15'h0000;
        endcase
    endfunction
    wire [7:0] dx = x - cur_x, dy = n - cur_y;
    wire near_x = dx < 6 || dx > 250, near_y = dy < 6 || dy > 250;
    wire cursor = touch && ((x == cur_x && near_y) || (n == cur_y && near_x));
    wire [7:0] sq = x - frame;
    reg [14:0] pix;
    always @* begin
        pix = 15'h0000;
        if (x == 0 || x == 255 || n == 0 || n == 191) pix = 15'h7FFF;
        else if (!scr) begin
            if (n >= 2 && n < 18) begin
                if (x[4:0] >= 3 && x[4:0] < 29) pix = state_colour(boxes[x[7:5]*2 +: 2]);
            end else if (n >= 20 && n < 26) pix = {1'b0, x} < prog_a[9:1] ? 15'h7FFF : rgb15(24'h303030);
            else if (n >= 26 && n < 32) pix = {1'b0, x} < prog_b[9:1] ? 15'h7FFF : rgb15(24'h303030);
            else if (n >= 36 && n < 124) pix = (n >= 72 && n < 88 && sq < 16) ? rgb15(24'hFF8000) : bar_colour(x[7:5]);
            else if (n >= 128) begin
                if (n[2:0] < 6 && x[2:0] >= 1 && !(x[4:3] == 2'b00 && x[2:0] < 3))
                    pix = log_data[5'd31 - x[7:3]] ? 15'h7FFF : rgb15(24'h383838);
            end
        end else begin
            pix = (x[4:0] == 0 || n[4:0] == 0) ? rgb15(24'h808080) : {x[7:3], x[7:3], x[7:3]};
            if (n >= 4 && n < 12) begin
                if (x >= 8 && x < 40) pix = layout == 0 ? rgb15(24'h20E040) : rgb15(24'h204020);
                else if (x >= 48 && x < 80) pix = layout == 1 ? rgb15(24'h20E040) : rgb15(24'h204020);
                else if (x >= 88 && x < 120) pix = layout == 2 ? rgb15(24'h20E040) : rgb15(24'h204020);
                else if (x >= 136 && x < 168) pix = touch ? rgb15(24'h20E0E0) : rgb15(24'h204040);
                else if (x >= 176 && x < 208) pix = pen ? 15'h7FFF : rgb15(24'h404040);
            end else if (n >= 16 && n < 22) begin
                if (x[3:0] >= 2) pix = keys[4'd15 - x[7:4]] ? 15'h7FFF : rgb15(24'h383838);
            end else if (n >= 150 && n < 166 && sq < 16) pix = rgb15(24'h0040FF);
            if (cursor) pix = pen ? rgb15(24'hFFFF00) : rgb15(24'hFF2020);
        end
    end

    // live screen: two lines (line m in half m[0])
    reg [14:0] live [0:511];
    wire live_scr = gen_layout == 2'd2;      // bottom only: the bottom screen; else the top
    always @(posedge clk) if (gen && scr == live_scr) live[{n[0], x}] <= pix;

    // ---------------- stacked: bottom screen to SDRAM ----------------
    reg [31:0] stage [0:255];               // two lines of 128 words
    reg [14:0] even_pix = 0;
    always @(posedge clk) begin
        if (gen && scr) begin
            if (!x[0]) even_pix <= pix;
            else stage[{n[0], x[7:1]}] <= {1'b0, pix, 1'b0, even_pix};
        end
    end
    reg [31:0] stage_q = 0;
    reg [7:0] w_line = 0, w_next = 0;
    reg [6:0] wi = 0;
    reg w_busy = 0, w_pend = 0, w_rd = 0;
    always @(posedge clk) stage_q <= stage[{w_line[0], wi}];
    always @(posedge clk) begin
        if (w_ready) w_valid <= 0;
        if (reset) begin w_busy <= 0; w_pend <= 0; w_valid <= 0; end
        else begin
            if (gen_layout == 0 && dl < 192 && bc == 12'd516) begin
                if (w_busy) begin w_pend <= 1; w_next <= n; late <= late + 1'b1; end
                else begin w_busy <= 1; w_line <= n; wi <= 0; w_rd <= 1; end
            end
            if (w_busy) begin
                if (w_rd) w_rd <= 0;                        // stage_q follows {w_line, wi}
                else if (!w_valid) begin
                    w_valid <= 1; w_addr <= BUF_W + {9'b0, w_line, 7'b0} + {17'b0, wi}; w_data <= stage_q;
                end else if (w_ready) begin
                    if (wi == 7'd127) begin
                        if (w_pend) begin w_pend <= 0; w_line <= w_next; wi <= 0; w_rd <= 1; end
                        else w_busy <= 0;
                    end else begin wi <= wi + 1'b1; w_rd <= 1; end
                end
            end
        end
    end

    // ---------------- stacked: bottom screen from SDRAM ----------------
    reg [31:0] ring [0:255];                // two lines of 128 words
    reg [7:0] f_line = 0, ready_line = 8'hFF;
    reg [4:0] fq = 0;
    reg [1:0] fw = 0;
    reg fetching = 0;
    reg obuf = 0;
    reg [7:0] k = 0;
    reg [9:0] lc = 0;
    wire buf_start = obuf && lc == 0;
    always @(posedge clk) begin
        if (r_ready) r_valid <= 0;
        if (r_rvalid) begin
            ring[{f_line[0], fq, fw}] <= r_rdata;
            fw <= fw + 1'b1;
            if (fw == 2'd3) begin
                if (fq == 5'd31) begin fetching <= 0; ready_line <= f_line; end
                else begin fq <= fq + 1'b1; r_valid <= 1; r_addr <= r_addr + 24'd4; end
            end
        end
        if (reset) begin fetching <= 0; r_valid <= 0; ready_line <= 8'hFF; end
        else if ((layout == 0 && dl == 9'd192 && bc == 0) || (buf_start && k != 8'd191)) begin
            // line 0 before the top half starts, then line k+1 while line k shows
            f_line <= buf_start ? k + 1'b1 : 8'd0; fq <= 0; fw <= 0; fetching <= 1;
            r_valid <= 1; r_addr <= BUF_W + {9'b0, buf_start ? k + 1'b1 : 8'd0, 7'b0};
        end
        if (buf_start && (fetching || ready_line != k)) underruns <= underruns + 1'b1;
    end
    always @(posedge clk) begin
        if (reset) begin obuf <= 0; k <= 0; lc <= 0; end
        else if (layout == 0 && dl == 9'd193 && bc == 0) begin obuf <= 1; k <= 0; lc <= 0; end
        else if (obuf) begin
            if (lc == 10'd785) begin
                lc <= 0;
                if (k == 8'd191) obuf <= 0; else k <= k + 1'b1;
            end else lc <= lc + 1'b1;
        end
    end

    // ---------------- output ----------------
    wire live_line = dl >= 1 && dl <= 192;
    wire [7:0] m = dl[7:0] - 1'b1;
    wire buf_de = obuf && lc >= 120 && lc < 632;
    wire [8:0] buf_x = lc[9:1] - 9'd60;
    wire live_de = live_line && bc >= 200 && bc < 712;
    wire [8:0] live_x = bc[9:1] - 9'd100;
    wire de0 = buf_de || live_de;
    wire hs0 = (obuf && lc < 2) || (bc < 2 && (layout != 0 || live_line));
    wire vs0 = dl == 1 && bc < 2;
    wire slot0 = (obuf && (lc == 632 || lc == 633)) || (live_line && (bc == 712 || bc == 713));
    reg [31:0] ring_q = 0;
    reg [14:0] live_q = 0;
    reg de1 = 0, hs1 = 0, vs1 = 0, slot1 = 0, buf1 = 0, buf1s = 0, half1 = 0;
    always @(posedge clk) begin
        ring_q <= ring[{k[0], buf_x[7:1]}];
        live_q <= live[{m[0], live_x[7:0]}];
        de1 <= de0; hs1 <= hs0; vs1 <= vs0; slot1 <= slot0; buf1 <= buf_de; buf1s <= obuf; half1 <= buf_x[0];
        de <= de1; hs <= hs1; vs <= vs1;
        if (de1) begin
            reg [14:0] c;
            c = buf1 ? (half1 ? ring_q[30:16] : ring_q[14:0]) : live_q;
            rgb <= {c[14:10], c[14:12], c[9:5], c[9:7], c[4:0], c[4:2]};
        end else rgb <= slot1 ? {10'd0, layout != 0 && !buf1s, 13'b0} : 24'h0;
    end
endmodule
`default_nettype wire
