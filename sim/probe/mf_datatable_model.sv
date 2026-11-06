`timescale 1ns/1ps
// Simulation stand-in for the APF ID/size table RAM (altsyncram in
// rtl/apf/mf_datatable.v): two clocks of read latency, the slower
// of the plausible configurations.
module mf_datatable (
    input wire [9:0] address_a, address_b,
    input wire clock_a, clock_b,
    input wire [31:0] data_a, data_b,
    input wire wren_a, wren_b,
    output reg [31:0] q_a = 0, q_b = 0
);
    reg [31:0] m[0:1023];
    reg [9:0] ra = 0, rb = 0;
    initial for (integer i = 0; i < 1024; i++) m[i] = 0;
    always @(posedge clock_a) begin if (wren_a) m[address_a] <= data_a; ra <= address_a; q_a <= m[ra]; end
    always @(posedge clock_b) begin if (wren_b) m[address_b] <= data_b; rb <= address_b; q_b <= m[rb]; end
endmodule
