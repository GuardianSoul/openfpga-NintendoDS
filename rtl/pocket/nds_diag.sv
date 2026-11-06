// SPDX-License-Identifier: MIT
// The diagnostics recorder of the NDSDiag core (core_top_ds DIAG, docs/diag.md), on clk_sys.
//
// Per-clock events (ev: a clock count or an event count, +1 in each clock it is high) are summed into 32-bit
// accumulators without a 32-bit adder per event: each event has a 6-bit counter, and one scanner visits one
// event per clock (period NE <= 63), adding its counter into the event's accumulator in an MLAB and restarting
// it. At each DS frame (frame, a pulse) the accumulators are copied into a record as the scanner passes them, so
// every event is sampled at the same scanner offset in every frame and the host's differences between records
// are exact frame totals. The record also holds NV values (val: the last frame's values, stable for a frame).
//
// Histograms, cumulative 32-bit bins in MLABs (read-modify-write; an update waits at most one clock for the
// dump, which reads in clocks without one): NH latency histograms of 16 bins (h_v/h_bin: the tap computes the
// bin), NL line histograms of 32 bins of 8 lines (l_v/l_line).
//
// SDRAM layout (words from BASE_W, 512 KiB; written through w_req/w_addr/w_data/w_ack, one word at a time):
//   0x00000  header, 16 words (rewritten every second, last): "NDG1", 1, {NE, NV, NH, NL}, CONFIG, frames
//            recorded, seconds recorded, frame slots, second slots, the next frame slot, the next second slot
//   0x00040  latency histograms, NH x 16
//   0x00100  line histograms, NL x 32 (8 lines a bin)
//   0x00400  per-second records, SEC_SLOTS x 64 (every SEC_EVERY'th frame record also lands here)
//   0x04400  per-frame records, FRAME_SLOTS x 64: {frame number, NE accumulators, NV values, 0...}
// The histograms and the header follow each per-second record.
`default_nettype none
module nds_diag #(
    parameter integer NE = 40,               // one-bit events (+1 in a clock)
    parameter integer N2 = 8,                // two-bit events after them (+0..3 in a clock: clk_mem counts, docs/diag.md); NE + N2 <= 63
    parameter integer NV = 6,                // values, NE + NV <= 63
    parameter integer NH = 4,                // latency histograms (16 bins)
    parameter integer NL = 2,                // line histograms (32 bins of 8 lines); 0: none (the ports keep one unused bit)
    parameter integer HW = 28,               // histogram bin width (268M samples a bin)
    parameter [23:0] BASE_W = 24'h10_0000,   // SDRAM word address of the log
    parameter integer SEC_SLOTS = 256,
    parameter integer FRAME_SLOTS = 1776,
    parameter integer SEC_EVERY = 60,
    parameter integer GAP = 32,              // clocks between log writes (each SDRAM write can delay a client's
                                             // request behind it: back to back they made a 2D line late, kh-menu)
    parameter [31:0] CONFIG = 32'd0          // the build's options, for the host (docs/diag.md)
) (
    input wire clk, rst,
    input wire frame,
    input wire [NE-1:0] ev,
    input wire [N2*2-1:0] ev2,
    input wire [NV*32-1:0] val,
    input wire [NH-1:0] h_v,
    input wire [NH*4-1:0] h_bin,
    input wire [(NL > 0 ? NL : 1)-1:0] l_v,
    input wire [(NL > 0 ? NL : 1)*9-1:0] l_line,
    output reg w_req = 0,
    output reg [23:0] w_addr = 0,
    output reg [31:0] w_data = 0,
    input wire w_ack
);
    localparam [23:0] HDR = 24'h0, HIST = 24'h40, LHIST = 24'h100, SECR = 24'h400, FRR = 24'h4400;
    localparam integer LB = 32;              // line histogram bins: lines 8b..8b+7 (lines 256-262, VBlank, in the last)
    wire wr_take;                           // the writer takes the frame record (below)
    localparam [2:0] W_IDLE = 0, W_FRAME = 1, W_SEC = 2, W_HIST = 3, W_LHIST = 4, W_HDR = 5;
    reg [2:0] ws = W_IDLE;
    reg clr = 1;                            // clearing the histograms after reset (below)
    reg [9:0] clr_i = 0;

    // ---------------- accumulators ----------------
    // NT events in all; a counter gains at most 3 a clock over a scanner period of NT < 64 clocks: 7 bits
    localparam integer NT = NE + N2;
    reg [7:0] c [0:NT-1];
    reg [5:0] scan = 0;
    (* ramstyle = "MLAB, no_rw_check" *) reg [31:0] acc [0:63];
    wire [31:0] sum = acc[scan] + {24'd0, c[scan]};
    integer k;
    initial for (k = 0; k < NT; k = k + 1) c[k] = 0;
    function automatic [1:0] inc(input integer i);
        inc = i < NE ? {1'b0, ev[i]} : ev2[(i - NE) * 2 +: 2];
    endfunction
    always @(posedge clk) begin
        for (k = 0; k < NT; k = k + 1)
            c[k] <= (scan == k) ? {6'd0, inc(k)} : c[k] + {6'd0, inc(k)};
        acc[scan] <= rst ? 32'd0 : sum;
        scan <= scan == NT - 1 ? 6'd0 : scan + 1'b1;
    end

    // ---------------- the frame record ----------------
    // snapshot: from the frame pulse, NT clocks copy sum into rec[1 + scan], then NV clocks copy the values
    // into rec[1 + NT + j] (captured at the frame: the paced writer reaches them thousands of clocks later)
    (* ramstyle = "MLAB, no_rw_check" *) reg [31:0] rec [0:63];
    reg [6:0] wi = 0;                       // the writer's word in the record / header (below)
    wire [31:0] rec_q = rec[wi[5:0]];       // (the record's MLAB: one read port, at wi)
    reg [5:0] snap_n = 0;                   // events still to copy (0: idle)
    reg [3:0] snap_v = 0;                   // values still to copy
    reg [31:0] fno = 0;                     // frames recorded
    reg rec_ready = 0;                      // a complete record waits for the writer
    always @(posedge clk) begin
        if (snap_n != 0) begin
            rec[6'd1 + scan] <= sum;
            snap_n <= snap_n - 1'b1;
            if (snap_n == 1) snap_v <= NV[3:0];
        end else if (snap_v != 0) begin
            rec[6'(1 + NT + NV) - snap_v] <= val[(NV - snap_v) * 32 +: 32];
            snap_v <= snap_v - 1'b1;
            if (snap_v == 1) rec_ready <= 1;
        end
        if (rst) begin snap_n <= 0; snap_v <= 0; rec_ready <= 0; fno <= 0; end
        else if (frame && snap_n == 0 && snap_v == 0 && !rec_ready) begin snap_n <= NT[5:0]; fno <= fno + 1'b1; end
        else if (wr_take) rec_ready <= 0;
    end

    // ---------------- histograms ----------------
    // one MLAB per histogram, updated in the clock its event comes; the dump reads one histogram at a time
    // (d_h, d_l), and an update meeting the dump's read waits one clock (one waiting update per histogram; one
    // arriving while that one waits is lost and counted in hlost, header word 10: the taps' events are block
    // completions or lines, several clocks apart)
    reg dump_h = 0, dump_l = 0;            // the writer reads histogram d_hn / line histogram d_ln this clock
    reg dump2 = 0;                          // the word asked for the clock before is at h_q / l_q
    reg [9:0] d_ix = 0;
    reg [3:0] d_hn = 0;
    reg [1:0] d_ln = 0;
    reg [15:0] hlost = 0;
    wire [31:0] h_qd [NH];
    wire [31:0] l_qd [NL > 0 ? NL : 1];
    wire [NH-1:0] h_lost;
    wire [(NL > 0 ? NL : 1)-1:0] l_lost;
    genvar g;
    // each histogram: one registered read address ra (the bin being counted, or the dump's word), its MLAB read
    // asynchronously at ra and written back +1 in the next clock (cnt), or read for the dump (h_qd)
    generate for (g = 0; g < NH; g = g + 1) begin : g_h
        reg p = 0, cnt = 0;                 // an event waiting (bin pb); count the word at ra this clock
        reg [3:0] pb = 0, ra = 0;
        wire rd = dump_h && d_hn == g;      // the writer asks for word d_ix (ra next clock)
        wire [HW-1:0] q;
        gpu3d_lram #(.W(HW), .AW(4)) u_m (.clk, .we(clr || cnt), .waddr(clr ? clr_i[3:0] : ra),   // MLAB
            .wdata(clr ? {HW{1'b0}} : q + 1'b1), .raddr(ra), .rdata(q));
        assign h_qd[g] = {{(32 - HW){1'b0}}, q};
        assign h_lost[g] = h_v[g] && p && rd;
        always @(posedge clk) begin
            cnt <= 0;
            if (rst) p <= 0;
            else if (rd) begin ra <= d_ix[3:0]; if (h_v[g] && !p) begin p <= 1; pb <= h_bin[g*4 +: 4]; end end
            else if (p) begin ra <= pb; cnt <= 1; p <= h_v[g]; pb <= h_bin[g*4 +: 4]; end
            else if (h_v[g]) begin ra <= h_bin[g*4 +: 4]; cnt <= 1; end
        end
    end endgenerate
    generate if (NL == 0) begin : g_nol
        assign l_qd[0] = 32'd0; assign l_lost = 1'b0;
    end endgenerate
    generate for (g = 0; g < NL; g = g + 1) begin : g_l
        reg p = 0, cnt = 0;
        reg [4:0] pb = 0, ra = 0;
        wire rd = dump_l && d_ln == g;
        wire [4:0] ln = l_line[g*9 + 8] ? 5'd31 : l_line[g*9+3 +: 5];   // 8 lines a bin
        wire [HW-1:0] q;
        gpu3d_lram #(.W(HW), .AW(5)) u_m (.clk, .we(clr || cnt), .waddr(clr ? clr_i[4:0] : ra),
            .wdata(clr ? {HW{1'b0}} : q + 1'b1), .raddr(ra), .rdata(q));
        assign l_qd[g] = {{(32 - HW){1'b0}}, q};
        assign l_lost[g] = l_v[g] && p && rd;
        always @(posedge clk) begin
            cnt <= 0;
            if (rst) p <= 0;
            else if (rd) begin ra <= d_ix[4:0]; if (l_v[g] && !p) begin p <= 1; pb <= ln; end end
            else if (p) begin ra <= pb; cnt <= 1; p <= l_v[g]; pb <= ln; end
            else if (l_v[g]) begin ra <= ln; cnt <= 1; end
        end
    end endgenerate
    always @(posedge clk) if (rst) hlost <= 0; else if (|h_lost || |l_lost) hlost <= hlost + 1'b1;
    wire [31:0] h_q = h_qd[d_hn];
    wire [31:0] l_q = l_qd[d_ln];
    // clear the histograms after reset (the SDRAM keeps nothing across power-up): LB clocks
    always @(posedge clk) begin
        if (rst) begin clr <= 1; clr_i <= 0; end
        else if (clr) begin clr_i <= clr_i + 1'b1; if (clr_i == LB - 1) clr <= 0; end
    end

    // ---------------- the writer ----------------
    // a frame record (64 words) into the frame ring; every SEC_EVERY'th also into the second ring, then the
    // histograms and the header
    reg [10:0] fslot = 0;
    reg [8:0] sslot = 0;
    reg [31:0] secs = 0;
    reg [5:0] sec_f = 0;
    reg sec_due = 0;
    assign wr_take = ws == W_IDLE && rec_ready && !w_req && !clr;
    // the record's word wi: frame number, accumulators, values, zeros
    function automatic [31:0] rec_word(input [6:0] i);
        if (i == 0) rec_word = fno;
        else if (i <= NT) rec_word = rec_q;
        else if (i <= NT + NV) rec_word = rec_q;
        else rec_word = 32'd0;
    endfunction
    function automatic [31:0] hdr_word(input [6:0] i);
        case (i)
            7'd0: hdr_word = 32'h3147_444E;                  // "NDG1"
            7'd1: hdr_word = 32'd1;
            7'd2: hdr_word = {8'(NT), 8'(NV), 8'(NH), 8'(NL)};
            7'd3: hdr_word = CONFIG;
            7'd4: hdr_word = fno;
            7'd5: hdr_word = secs;
            7'd6: hdr_word = FRAME_SLOTS;
            7'd7: hdr_word = SEC_SLOTS;
            7'd8: hdr_word = {21'd0, fslot};
            7'd9: hdr_word = {23'd0, sslot};
            7'd10: hdr_word = {16'd0, hlost};
            default: hdr_word = 32'd0;
        endcase
    endfunction
    reg [5:0] gap = 0;                      // clocks left before the next write may start (GAP)
    wire w_free = !w_req && gap == 0;
    reg [31:0] wbuf = 0;                    // a histogram word read in a free clock
    reg wbuf_v = 0;
    always @(posedge clk) begin
        dump_h <= 0; dump_l <= 0; dump2 <= dump_h || dump_l;
        if (w_req && w_ack) begin w_req <= 0; gap <= GAP[5:0]; end
        else if (gap != 0) gap <= gap - 1'b1;
        if (rst) begin
            ws <= W_IDLE; w_req <= 0; fslot <= 0; sslot <= 0; secs <= 0; sec_f <= 0; sec_due <= 0; wbuf_v <= 0;
        end else case (ws)
            W_IDLE: if (wr_take) begin
                ws <= W_FRAME; wi <= 0;
                if (sec_f == SEC_EVERY - 1) begin sec_f <= 0; sec_due <= 1; end else sec_f <= sec_f + 1'b1;
            end
            W_FRAME, W_SEC: if (w_free) begin
                if (wi == 64) begin
                    wi <= 0;
                    if (ws == W_FRAME) begin
                        fslot <= fslot == FRAME_SLOTS - 1 ? 11'd0 : fslot + 1'b1;
                        if (sec_due) ws <= W_SEC; else ws <= W_IDLE;
                    end else begin
                        sec_due <= 0; secs <= secs + 1'b1;
                        sslot <= sslot == SEC_SLOTS - 1 ? 9'd0 : sslot + 1'b1;
                        ws <= W_HIST; d_ix <= 0; d_hn <= 0; d_ln <= 0; wbuf_v <= 0;
                    end
                end else begin
                    w_req <= 1; w_data <= rec_word(wi);
                    w_addr <= BASE_W + (ws == W_FRAME ? FRR + {fslot, 6'd0} : SECR + {sslot, 6'd0}) + wi;
                    wi <= wi + 1'b1;
                end
            end
            // histograms: read a word in a clock the updates leave free (dump_h/_l steals the read when no
            // update is served), then write it
            // histograms: one clock reading the word (dump_h/_l: that histogram's update waits), then its write
            W_HIST, W_LHIST: begin
                if (!wbuf_v) begin
                    if (ws == W_HIST) dump_h <= 1; else dump_l <= 1;
                    wbuf_v <= 1;
                end
                if (dump2) wbuf <= ws == W_HIST ? h_q : l_q;      // ra took d_ix the clock before
                if (wbuf_v && !dump_h && !dump_l && !dump2 && w_free) begin
                    w_req <= 1; w_data <= wbuf;
                    w_addr <= BASE_W + (ws == W_HIST ? HIST + {d_hn, 4'd0} : LHIST + d_ln * LB) + d_ix;
                    wbuf_v <= 0;
                    if (ws == W_HIST) begin
                        if (d_ix == 15) begin
                            d_ix <= 0;
                            if (d_hn == NH - 1) begin d_hn <= 0; ws <= NL == 0 ? W_HDR : W_LHIST; wi <= 0; end else d_hn <= d_hn + 1'b1;
                        end else d_ix <= d_ix + 1'b1;
                    end else begin
                        if (d_ix == LB - 1) begin
                            d_ix <= 0;
                            if (d_ln == NL - 1) begin d_ln <= 0; ws <= W_HDR; wi <= 0; end else d_ln <= d_ln + 1'b1;
                        end else d_ix <= d_ix + 1'b1;
                    end
                end
            end
            W_HDR: if (w_free) begin
                if (wi == 16) ws <= W_IDLE;
                else begin w_req <= 1; w_data <= hdr_word(wi); w_addr <= BASE_W + HDR + wi; wi <= wi + 1'b1; end
            end
            default: ws <= W_IDLE;
        endcase
    end
endmodule
`default_nettype wire
