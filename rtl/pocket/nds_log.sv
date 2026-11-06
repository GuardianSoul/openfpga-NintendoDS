// SPDX-License-Identifier: MIT
// The Phase 1 result log (docs/phase1-foundation.md, "Log"): 128 words on
// clk_74a, saved by the Pocket from bridge 0x40000000 when the core quits and
// shown in part on screen.
//
// nds_status_stream (any clock) sends its N words one at a time, as
// {index, word}, through an nds_bundle_cdc, over and over. nds_log writes
// those and its own clk_74a words (round robin, one per free clock) into two
// copies of a 128 x 32 RAM: one read on clk_74a for the bridge, one on the
// video (bus) clock. A stream word is at most one round (a few microseconds) old.
`default_nettype none

module nds_status_stream #(parameter integer N = 16, parameter [6:0] BASE = 7'd0) (
    input wire clk,
    input wire [N*32-1:0] words,
    input wire busy,
    output reg send = 0,
    output reg [38:0] data = 0
);
    reg [6:0] i = 0;
    always @(posedge clk) begin
        send <= 0;
        if (!busy && !send) begin
            send <= 1;
            data <= {BASE + i, words[i*32 +: 32]};
            i <= i == N - 1 ? 7'd0 : i + 1'b1;
        end
    end
endmodule

module nds_log #(parameter integer NLOCAL = 24) (
    input wire clk,
    input wire [NLOCAL*32-1:0] local_words, // indices 0..NLOCAL-1
    input wire b_recv,
    input wire [38:0] b_data,
    input wire m_recv,
    input wire [38:0] m_data,
    input wire [6:0] rd_addr,
    output reg [31:0] rd_data = 0,          // one clock after rd_addr
    input wire vclk,
    input wire [6:0] v_addr,
    output reg [31:0] v_data = 0
);
    reg [31:0] ram_b [0:127];
    reg [31:0] ram_v [0:127];
    integer k;
    initial for (k = 0; k < 128; k = k + 1) begin ram_b[k] = 0; ram_v[k] = 0; end
    reg b_pend = 0, m_pend = 0;
    reg [38:0] b_hold = 0, m_hold = 0;
    reg [6:0] li = 0;
    reg we = 0;
    reg [6:0] wa = 0;
    reg [31:0] wd = 0;
    always @(posedge clk) begin
        if (b_recv) begin b_pend <= 1; b_hold <= b_data; end
        if (m_recv) begin m_pend <= 1; m_hold <= m_data; end
        we <= 1;
        if (b_pend) begin wa <= b_hold[38:32]; wd <= b_hold[31:0]; b_pend <= b_recv; end
        else if (m_pend) begin wa <= m_hold[38:32]; wd <= m_hold[31:0]; m_pend <= m_recv; end
        else begin
            wa <= li; wd <= local_words[li*32 +: 32];
            li <= li == NLOCAL - 1 ? 7'd0 : li + 1'b1;
        end
        if (we) begin ram_b[wa] <= wd; ram_v[wa] <= wd; end
        rd_data <= ram_b[rd_addr];
    end
    always @(posedge vclk) v_data <= ram_v[v_addr];
endmodule
`default_nettype wire
