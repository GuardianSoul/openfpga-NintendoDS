// SPDX-License-Identifier: MIT
// Two clk_bus clients of nds_sdram's c_* contract on one nds_sdram_bport (docs/budget-3d.md H2): client A
// (the ROM cache) and client B (the save's write-back at quit, single-word reads only). The port belongs to
// one client at a time; A's requests pass straight through (same clock, same signals as its own port), and
// the port turns to the other client only when its owner requests nothing and has no read words still due
// (words can come before a request's c_ready, so they are counted per request: + n at its c_ready, - 1 a
// word). B waits while A is busy; A waits for B's single reads only while the save is read back.
`default_nettype none
module nds_bport_share (
    input wire clk, reset,
    // client A
    input wire a_valid, a_write, a_quad,
    input wire [23:0] a_addr,
    input wire [31:0] a_wdata,
    input wire [3:0] a_be,
    output wire a_ready, a_rvalid,
    // client B (reads of one word)
    input wire b_valid,
    input wire [23:0] b_addr,
    output wire b_ready, b_rvalid,
    // the port
    output wire c_valid, c_write, c_quad,
    output wire [23:0] c_addr,
    output wire [31:0] c_wdata,
    output wire [3:0] c_be,
    input wire c_ready, r_valid
);
    reg own_b = 0;                          // B owns the port
    reg signed [4:0] due = 0;               // read words still due to the owner
    wire idle_a = !a_valid && due == 0 && !c_ready;
    wire idle_b = !b_valid && due == 0 && !c_ready;
    always @(posedge clk) begin
        if (reset) begin own_b <= 0; due <= 0; end
        else begin
            due <= due + (c_ready && !c_write ? (own_b ? 5'sd1 : a_quad ? 5'sd4 : 5'sd1) : 5'sd0) - (r_valid ? 5'sd1 : 5'sd0);
            if (!own_b && idle_a && b_valid) own_b <= 1;
            else if (own_b && idle_b) own_b <= 0;
        end
    end
    assign c_valid = own_b ? b_valid : a_valid;
    assign c_write = own_b ? 1'b0 : a_write;
    assign c_quad = own_b ? 1'b0 : a_quad;
    assign c_addr = own_b ? b_addr : a_addr;
    assign c_wdata = a_wdata;               // (B only reads)
    assign c_be = a_be;
    assign a_ready = c_ready && !own_b;
    assign b_ready = c_ready && own_b;
    assign a_rvalid = r_valid && !own_b;
    assign b_rvalid = r_valid && own_b;
endmodule
`default_nettype wire
