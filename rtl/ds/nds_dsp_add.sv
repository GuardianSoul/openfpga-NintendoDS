// An adder in a DSP block (Cyclone V "sum of two 18x18" mode): s = a*one + b*one.
// `one` is a register that powers up 1 and is never written; marked preserve,
// Quartus keeps it as a register and cannot fold the multiplies away, so the
// add lands in one DSP block instead of a carry chain. RTL simulation honours
// the power-up value, so the result is a + b in simulation as in the device
// (sim/ds/tb_dsp_add.sv, make dspadd-test).
// Measured (nds-fit #713/#714, eight registered 18-bit adders, 67 MHz): one DSP
// block per adder, about -9.5 ALMs per adder (297 -> 221 ALMs, 152 -> 0 ALUTs),
// register to register about 3.5 ns through the block (slack 10.3 -> 11.4 ns).
// For adders of up to 18 bits with slack; the device has 66 DSP blocks.
// SIGNED = 1: two's complement operands (not yet fit-measured).
module nds_dsp_add #(
    parameter int W      = 18,          // operand width, 1..18
    parameter bit SIGNED = 1'b0
) (
    input  logic         clk,           // only for the `one` register
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    output logic [W:0]   s              // a + b, one bit wider
);
    (* preserve *) logic [1:0] one = 2'b01;
    always_ff @(posedge clk) one <= one;
    generate if (SIGNED) begin : g_s
        (* multstyle = "dsp" *) logic signed [W+2:0] pa, pb;
        assign pa = $signed(a) * $signed({1'b0, one});
        assign pb = $signed(b) * $signed({1'b0, one});
        wire signed [W+2:0] sum = pa + pb;
        assign s = sum[W:0];
    end else begin : g_u
        (* multstyle = "dsp" *) logic [W+2:0] pa, pb;
        assign pa = {2'b00, a} * {1'b0, one};
        assign pb = {2'b00, b} * {1'b0, one};
        wire [W+2:0] sum = pa + pb;
        assign s = sum[W:0];
    end endgenerate
endmodule
