// SPDX-License-Identifier: MIT
// Clock-domain crossings for the Phase 1 shell (docs/phase1-foundation.md).
//
// nds_bundle_cdc: one multi-bit value from clock a to clock b. send (a) copies
//   data into a held register and flips a request toggle; b sees the toggle
//   through two flops, copies the held register (stable since before the
//   toggle) and pulses recv, then flips the acknowledge back. busy (a) stays
//   high until the acknowledge returns, so the held register never changes
//   while b may sample it. The held register to b's copy is a false path.
//   SOURCE_HOLDS = 1: no copies at all (APF shell trim). For a sender that
//   keeps a_data unchanged from send until b has finished with it (a
//   protocol guarantee, e.g. the ROM cache's fetch command, which changes only
//   after the host's marker for it returns); b_data is a_data itself, stable
//   for two b clocks before recv. Only the toggles cross.
// nds_dcfifo: dual-clock first-word-fall-through FIFO, Gray-coded pointers
//   through two flops each way, storage written in wclk and read with a
//   registered (synchronous) read in rclk, so it infers block RAM. The
//   sticky overflow flag has a reset: without one Quartus made it a constant 1
//   (#55, "power-up don't care").
`default_nettype none

module nds_sync #(parameter integer W = 1) (
    input wire clk,
    input wire [W-1:0] d,
    output wire [W-1:0] q
);
    (* async_reg = "true" *) reg [W-1:0] s0 = 0, s1 = 0;
    always @(posedge clk) begin s0 <= d; s1 <= s0; end
    assign q = s1;
endmodule

module nds_bundle_cdc #(parameter integer W = 32, parameter bit SOURCE_HOLDS = 0) (
    input wire a_clk,
    input wire a_send,              // ignored while a_busy
    input wire [W-1:0] a_data,
    output wire a_busy,
    input wire b_clk,
    output reg b_recv = 0,          // one b_clk pulse, b_data valid from then on
    output wire [W-1:0] b_data
);
    reg req = 0, b_ack = 0, b_seen = 0;
    wire ack_a, req_b;
    nds_sync s_req (.clk(b_clk), .d(req), .q(req_b));
    nds_sync s_ack (.clk(a_clk), .d(b_ack), .q(ack_a));
    assign a_busy = req != ack_a;
    always @(posedge a_clk) if (a_send && !a_busy) req <= !req;
    always @(posedge b_clk) begin
        b_recv <= 0;
        if (req_b != b_seen) begin b_seen <= req_b; b_ack <= req_b; b_recv <= 1; end
    end
    generate if (SOURCE_HOLDS) begin : g_view
        assign b_data = a_data;
    end else begin : g_copy
        reg [W-1:0] held = 0, b_q = 0;
        always @(posedge a_clk) if (a_send && !a_busy) held <= a_data;
        always @(posedge b_clk) if (req_b != b_seen) b_q <= held;
        assign b_data = b_q;
    end endgenerate
endmodule

module nds_dcfifo #(parameter integer W = 32, parameter integer A = 4) (
    input wire wclk,
    input wire wreset,                      // clears overflow (wclk)
    input wire wr,                  // dropped (and overflow set) when full
    input wire [W-1:0] wdata,
    output wire full,
    output wire wempty,             // (wclk) every word written has been popped (rd); a few clocks late
    output wire [A:0] wfill,        // (wclk) words written and not yet popped; a few clocks high
    output reg overflow = 0,        // sticky
    input wire rclk,
    input wire rd,                  // pop the head; only while valid
    output wire valid,
    output reg [W-1:0] rdata = 0
);
    function automatic [A:0] gray(input [A:0] b);
        gray = b ^ (b >> 1);
    endfunction
    reg [W-1:0] mem [0:(1<<A)-1];
    reg [A:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
    // words popped (rd), Gray-coded to wclk: wempty (rgray counts loads into
    // rdata, ahead of the pop)
    reg [A:0] pbin = 0, pgray = 0;
    wire [A:0] pgray_w;
    nds_sync #(.W(A+1)) s_p2w (.clk(wclk), .d(pgray), .q(pgray_w));
    assign wempty = wgray == pgray_w;
    reg [A:0] pbin_w;
    always @* begin
        pbin_w[A] = pgray_w[A];
        for (integer i = A - 1; i >= 0; i = i - 1) pbin_w[i] = pbin_w[i + 1] ^ pgray_w[i];
    end
    assign wfill = wbin - pbin_w;
    wire [A:0] rgray_w, wgray_r;
    nds_sync #(.W(A+1)) s_r2w (.clk(wclk), .d(rgray), .q(rgray_w));
    nds_sync #(.W(A+1)) s_w2r (.clk(rclk), .d(wgray), .q(wgray_r));
    assign full = wgray == {~rgray_w[A:A-1], rgray_w[A-2:0]};
    always @(posedge wclk) begin
        if (wr && !full) begin
            mem[wbin[A-1:0]] <= wdata;
            wbin <= wbin + 1'b1;
            wgray <= gray(wbin + 1'b1);
        end
        if (wreset) overflow <= 0;
        else if (wr && full) overflow <= 1;
    end
    // Read side: out_v marks rdata as the head. The RAM read is registered.
    reg out_v = 0;
    assign valid = out_v;
    wire stored = rgray != wgray_r;
    wire load = stored && (!out_v || rd);
    always @(posedge rclk) begin
        if (load) begin
            rdata <= mem[rbin[A-1:0]];
            rbin <= rbin + 1'b1;
            rgray <= gray(rbin + 1'b1);
            out_v <= 1;
        end else if (rd) out_v <= 0;
        if (rd && out_v) begin pbin <= pbin + 1'b1; pgray <= gray(pbin + 1'b1); end
    end
endmodule
`default_nettype wire
