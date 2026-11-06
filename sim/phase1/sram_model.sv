// SPDX-License-Identifier: MIT
// Asynchronous SRAM (128K x 16, no chip select) for the Phase 1 test.
// Simulation only. Reads: DQ shows the addressed word once both the address
// and OE# have been stable for T_AA ns, a garbled word before that (not X:
// the 2-state simulator may optimise an X away). The model tracks that age
// at every falling edge of clk (half a core clock before the core's input
// register samples), which stands in for a continuous access time.
// Writes: the word is stored when WE# rises, with the data and byte lanes
// last sampled on a falling clk edge while WE# was low; a WE# pulse shorter than T_WP stores the
// data inverted.
`timescale 1ns/1ps
`default_nettype none
module sram_model #(parameter real T_AA = 55.0, parameter real T_WP = 40.0) (
    input wire clk,                         // the controller's clock
    input wire [16:0] a,
    inout wire [15:0] dq,
    input wire oe_n, we_n, ub_n, lb_n
);
    reg [15:0] mem [0:(1<<17)-1];
    integer i;
    initial for (i = 0; i < (1<<17); i = i + 1) mem[i] = i[15:0] ^ 16'hC3A5;
    // Age of the address and OE#: they change on rising clk edges, so a change
    // seen at a falling edge is half a period old.
    realtime age = 0, last = 0;
    reg [16:0] pa = 0;
    reg poe = 1;
    reg [15:0] dout = 0;
    always @(negedge clk) begin
        if (a != pa || oe_n != poe) age = ($realtime - last) / 2.0;
        else age = age + ($realtime - last);
        last = $realtime; pa = a; poe = oe_n;
        dout <= age >= T_AA ? mem[a] : ~mem[a] ^ 16'h0F0F;
    end
    assign dq = (!oe_n && we_n) ? dout : 16'bz;
    reg [15:0] wdata = 0;
    reg [1:0] wbe = 0;
    realtime t_we = 0;
    always @(negedge we_n) t_we = $realtime;
    // data and lanes sampled on falling clk edges while WE# is low (2-state safe)
    always @(negedge clk)
        if (!we_n) begin wdata <= dq; wbe <= {!ub_n, !lb_n}; end
    always @(posedge we_n) begin
        reg [15:0] d;
        d = ($realtime - t_we < T_WP) ? ~wdata : wdata;
        if (wbe[0]) mem[a][7:0] = d[7:0];
        if (wbe[1]) mem[a][15:8] = d[15:8];
    end
endmodule
`default_nettype wire
