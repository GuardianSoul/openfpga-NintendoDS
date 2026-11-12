// SPDX-License-Identifier: MIT
// DS screens to the APF scaler for the DS core (docs/phase2-integration.md,
// "Video"), on clk_sys (67.03 MHz). Phase 1's nds_screens with the test
// pattern replaced by the 2D engine's pixel stream.
//
// The 2D engine draws line n of both engines from the HBlank of DS line n,
// for up to one DS line (rtl/ds/nds_disp.sv), so line n is complete by the
// HBlank of line n+1. Every layout's frame starts at DS line 2 with VS, an
// HS four pixel clocks later and one black lead line (the APF scaler drops
// the first DE line after VS); the live screen's line m goes out during DS
// line m+3, from a four-line buffer. A black pad line ends every frame:
// the scaler needs an even number of DE lines per frame (openfpga-PlayStation
// EVEN_LINES: with an odd count it leaves part of a top row unwritten, the
// old red line and the random first-line pixels on #217), and the lead line
// plus 384 or 192 is odd.
// Layouts (SELECT+R, plan.md "Controls and screen layouts"):
//   stacked (default), scaler slot 0, 256 x 384: the top screen goes out live
//     (DS lines 3-194). The bottom screen's lines are written to SDRAM
//     (BUF_W, 128 words per line) when they are complete and sent from there
//     during the vertical blank: 192 short lines of 1,400 clocks (350 pixel
//     clocks) from DS line 195, then the pad line, ending inside DS line 259. A two-line ring is
//     fetched one line ahead with 16-byte reads.
//   top only / bottom only, slot 1, 256 x 192: that screen alone, live.
// The top screen is engine A if POWCNT1 bit 15 is set, else engine B
// (taken at DS line 0). In touch mode the cursor is drawn into the bottom
// screen's pixels as they arrive.
// Output: one pixel per four clk_sys (clk_vid = clk_sys / 4, same PLL): the
// outputs change once every four clocks, on the clk_sys edge midway between
// two clk_vid edges (vid_t, a clk_vid toggle, sampled here: it changes on the
// first clk_sys edge after a clk_vid edge, so the outputs change on the
// second), so core_top_ds's clk_vid output registers take each value two
// clk_sys clocks after it changes and two before the next (scripts/
// build_ds.sh: a 2-clock setup window and no same-edge hold race; #578's
// -0.573 ns hold on rgb[4] -> o_rgb[4] came from the free-running phase).
// HS is one pixel clock at each line start; DE covers 256 pixels; RGB is zero outside DE except the pixel clock after DE falls,
// which carries the APF "set scaler slot" word (RGB[23:13] = slot).
`default_nettype none
module nds_video #(parameter [23:0] BUF_W = 24'h38_0000) (
    input wire clk, reset,
    input wire vid_t,                       // toggles on every clk_vid edge (the output phase)
    input wire [1:0] layout_in,
    input wire [1:0] rotation,              // Core Setting "Rotation": 0 off, 1 left, 2 right (scaler slots 2/3
                                            // stacked, 4/5 one screen: package.py's rotated video.json modes)
    input wire touch, pen,
    input wire [7:0] cur_x, cur_y,
    // the DS
    input wire px_valid, px_eng,
    input wire [7:0] px_line, px_x,
    input wire [17:0] px_rgb,
    input wire line_start,
    input wire [8:0] vcount,
    input wire swap,                        // POWCNT1 bit 15
    output wire frame_pulse,                // one clock at DS line 0
    // SDRAM: bottom-screen writes (single words) and reads (quads), request held until ack
    output reg w_req = 0,
    output wire [23:0] w_addr,
    output wire [31:0] w_data,
    input wire w_ack,
    output reg r_req = 0,
    output wire [23:0] r_addr,
    input wire r_ack,
    input wire r_rvalid,
    input wire [31:0] r_rdata,
    output reg [15:0] underruns = 0,
    output reg [1:0] layout = 0,
    // video, valid for four clocks each
    output reg [23:0] rgb = 0,
    output reg de = 0, hs = 0, vs = 0
);
    // ---------------- DS raster (from the DS's own line starts) ----------------
    reg [12:0] hc = 0;                      // clk_sys clocks into the DS line (0..4259)
    reg [8:0] dl = 0;
    reg top_a = 0;                          // engine A is the top screen at line 0 (NDS_SWAP_LINE0_MUT: the frame's)
    reg [1:0] gen_layout = 0;
    always @(posedge clk) begin
        if (line_start) begin hc <= 0; dl <= vcount; end
        else if (hc != 13'h1FFF) hc <= hc + 1'b1;
        if (line_start && vcount == 0) begin gen_layout <= layout_in; top_a <= swap; end
        if (line_start && vcount == 2) layout <= gen_layout;
        if (reset) begin hc <= 0; dl <= 0; end
    end
    assign frame_pulse = line_start && vcount == 0;

    // ---------------- pixels in ----------------
    // px_eng: 0 engine A, 1 engine B (nds_disp). POWCNT1 bit 15 puts engine A
    // on the upper screen (#72/#87 had the mapping inverted). It applies per
    // scanline, as on the DS (hwref swapline v1: a write in line n routes line
    // n and the lines after it; one in line 0 the whole frame): a line takes
    // the bit as it is at its first pixel (nds_disp draws line n in line n's
    // HBlank, both engines' pixels tagged px_line) and keeps it for that line
    // on both screens (the live one and the SDRAM bottom buffer)
    reg [7:0] sw_line = 8'hFF;              // the line whose bit is held
    reg sw_held = 0;
    wire sw_new = px_valid && px_line != sw_line;
`ifdef NDS_SWAP_LINE0_MUT
    wire top_l = top_a;                     // (mutation: the frame's bit, latched at line 0, as before)
`else
    wire top_l = sw_new ? swap : sw_held;
`endif
    always @(posedge clk) if (sw_new) begin sw_line <= px_line; sw_held <= swap; end
    wire bot_px = px_eng == top_l;
    wire live_eng = gen_layout == 2'd2 ? top_l : !top_l;     // the engine the live screen shows
    wire [7:0] dx = px_x - cur_x, dy = px_line - cur_y;
    wire near_x = dx < 6 || dx > 250, near_y = dy < 6 || dy > 250;
    wire cursor = touch && bot_px && ((px_x == cur_x && near_y) || (px_line == cur_y && near_x));
    wire [17:0] pix = cursor ? (pen ? 18'h00FFF : 18'h0003F) : px_rgb;     // yellow / red

    // live screen: four lines
    reg [17:0] live [0:1023];
    always @(posedge clk) if (px_valid && px_eng == live_eng) live[{px_line[1:0], px_x}] <= pix;

    // ---------------- stacked: bottom screen to SDRAM ----------------
    // two-line stage of RGB565 pairs; a line is written once its x = 255 is in
    reg [31:0] stage [0:255];
    reg [15:0] even_pix = 0;
    wire [15:0] p565 = {pix[5:1], pix[11:6], pix[17:13]};
    reg [7:0] w_line = 0, w_next = 0;
    reg [6:0] wi = 0;
    reg w_busy = 0, w_pend = 0, w_rd = 0;
    reg [31:0] stage_q = 0;
    // a request's address and data are its counters' and the stage RAM's output, held until it's taken
    // (the buffer's base has no bits below the line: no adders)
    assign w_addr = {BUF_W[23:15], w_line, wi};
    assign w_data = stage_q;
    always @(posedge clk) begin
        if (px_valid && bot_px) begin
            if (!px_x[0]) even_pix <= p565;
            else stage[{px_line[0], px_x[7:1]}] <= {p565, even_pix};
        end
        stage_q <= stage[{w_line[0], wi}];
    end
    always @(posedge clk) begin
        if (w_ack) w_req <= 0;
        if (reset) begin w_busy <= 0; w_pend <= 0; w_req <= 0; end
        else begin
            if (gen_layout == 0 && px_valid && bot_px && px_x == 8'd255) begin
                if (w_busy) begin w_pend <= 1; w_next <= px_line; end
                else begin w_busy <= 1; w_line <= px_line; wi <= 0; w_rd <= 1; end
            end
            if (w_busy) begin
                if (w_rd) w_rd <= 0;                        // stage_q follows {w_line, wi}
                else if (!w_req) begin
                    w_req <= 1;
                end else if (w_ack) begin
                    if (wi == 7'd127) begin
                        if (w_pend) begin w_pend <= 0; w_line <= w_next; wi <= 0; w_rd <= 1; end
                        else w_busy <= 0;
                    end else begin wi <= wi + 1'b1; w_rd <= 1; end
                end
            end
        end
    end

    // ---------------- stacked: bottom screen from SDRAM ----------------
    reg [31:0] ring [0:255];
    reg [7:0] f_line = 0, ready_line = 8'hFF;
    reg [4:0] fq = 0;
    reg [1:0] fw = 0;
    reg fetching = 0;
    reg obuf = 0;
    reg [7:0] k = 0;
    reg [11:0] lc = 0;                      // clk_sys clocks into a short line (0..1399)
    wire buf_start = obuf && lc == 0;
    assign r_addr = {BUF_W[23:15], f_line, fq, 2'b00};
    always @(posedge clk) begin
        if (r_ack) r_req <= 0;
        if (r_rvalid) begin
            ring[{f_line[0], fq, fw}] <= r_rdata;
            fw <= fw + 1'b1;
            if (fw == 2'd3) begin
                if (fq == 5'd31) begin fetching <= 0; ready_line <= f_line; end
                else begin fq <= fq + 1'b1; r_req <= 1; end
            end
        end
        if (reset) begin fetching <= 0; r_req <= 0; ready_line <= 8'hFF; end
        else if ((layout == 0 && line_start && vcount == 9'd194) || (buf_start && k < 8'd191)) begin
            // line 0 before the bottom half starts, then line k+1 while line k shows
            f_line <= buf_start ? k + 1'b1 : 8'd0; fq <= 0; fw <= 0; fetching <= 1;
            r_req <= 1;
        end
        if (buf_start && k != 8'd192 && (fetching || ready_line != k)) underruns <= underruns + 1'b1;
    end
    always @(posedge clk) begin
        if (reset) begin obuf <= 0; k <= 0; lc <= 0; end
        else if (layout == 0 && line_start && vcount == 9'd195) begin obuf <= 1; k <= 0; lc <= 0; end
        else if (obuf) begin
            if (lc == 12'd1399) begin
                lc <= 0;
                if (k == 8'd192) obuf <= 0; else k <= k + 1'b1;                // 192: the pad line
            end else lc <= lc + 1'b1;
        end
    end

    // ---------------- output (one pixel per four clocks) ----------------
    reg vt_s = 0, vt_d = 0;
    always @(posedge clk) begin vt_s <= vid_t; vt_d <= vt_s; end
    wire ph = vt_s != vt_d;                 // the clock after the one that saw a clk_vid edge
    wire live_line = dl >= 3 && dl <= 194;
    wire [7:0] m = dl[7:0] - 8'd3;
    wire buf_de = obuf && lc >= 240 && lc < 1264;
    wire [8:0] buf_x = lc[10:2] - 9'd60;
    wire live_de = live_line && hc >= 400 && hc < 1424;
    wire [8:0] live_x = hc[10:2] - 9'd100;
    // VS on DS line 2, its HS four pixels later (APF: HS at least 3 clocks
    // after VS; on the same clock openfpga-PlayStation saw a stray row above the
    // picture), then one black lead DE line: the APF scaler drops the first
    // DE line after VS (openfpga-PlayStation LEAD_LINE), and without it the top row was
    // lost and a coloured row showed at the top (#65 green, #72/#87 red)
    wire lead_line = dl == 2;
    wire pad_line = layout != 0 && dl == 195;           // single layouts; stacked pads with k == 192
    wire pad_de = pad_line && hc >= 400 && hc < 1424;
    wire lead_de = lead_line && hc >= 400 && hc < 1424;
    wire de0 = buf_de || live_de || lead_de || pad_de;
    wire hs0 = (obuf && lc < 4) || (lead_line ? hc >= 16 && hc < 20 : hc < 4 && (layout != 0 || live_line));
    wire vs0 = lead_line && hc < 4;
    wire slot0 = (obuf && lc >= 1264 && lc < 1268) || ((live_line || lead_line || pad_line) && hc >= 1424 && hc < 1428);
    reg [31:0] ring_q = 0;
    reg [17:0] live_q = 0;
    reg de1 = 0, hs1 = 0, vs1 = 0, slot1 = 0, buf1 = 0, buf1s = 0, half1 = 0, lead1 = 0;
    // the scaler slot word's slot: stacked 0, one screen 1; rotated (2026-10-28: all layouts) stacked
    // 2 (left) and 3 (right), one screen 4 (left) and 5 (right)
    wire one = layout != 0 && !buf1s;
    wire [2:0] slot_n = rotation == 2'd1 ? (one ? 3'd4 : 3'd2) : rotation == 2'd2 ? (one ? 3'd5 : 3'd3) : {2'b00, one};
    always @(posedge clk) begin
        ring_q <= ring[{k[0], buf_x[7:1]}];
        live_q <= live[{m[1:0], live_x[7:0]}];
        de1 <= de0; hs1 <= hs0; vs1 <= vs0; slot1 <= slot0; buf1 <= buf_de; buf1s <= obuf; half1 <= buf_x[0];
        lead1 <= lead_de || pad_de || (buf_de && k == 8'd192);
        if (ph) begin
            de <= de1; hs <= hs1; vs <= vs1;
            if (de1) begin
                if (lead1) rgb <= 24'h0;
                else if (buf1) begin
                    reg [15:0] c;
                    c = half1 ? ring_q[31:16] : ring_q[15:0];
                    rgb <= {c[15:11], c[15:13], c[10:5], c[10:9], c[4:0], c[4:2]};
                end else
                    rgb <= {live_q[5:0], live_q[5:4], live_q[11:6], live_q[11:10], live_q[17:12], live_q[17:16]};
            // de is the previous emitted level until this nonblocking update.
            // Reset may truncate a row before slot1: its falling edge still
            // needs the current slot, or the external scaler selects slot 0.
            end else rgb <= (slot1 || de) ? {8'd0, slot_n, 13'b0} : 24'h0;
        end
    end
endmodule
`default_nettype wire
