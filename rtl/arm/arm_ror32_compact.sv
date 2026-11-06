// Source-only prototype: no production caller until owner agreement and proof.
// Five fixed rotate/mux levels. No clock, storage, DSP or service arbitration.
module arm_ror32_compact (
  input logic [31:0] value,
  input logic [4:0] amount,
  output logic [31:0] result
);
  wire [31:0] stage [0:5];
  assign stage[0] = value;
  genvar level;
  generate
  for (level = 0; level < 5; level++) begin : g_rotate
    localparam integer DISTANCE = 1 << level;
    assign stage[level+1] = amount[level]
      ? {stage[level][DISTANCE-1:0], stage[level][31:DISTANCE]}
      : stage[level];
  end
  endgenerate
  assign result = stage[5];
endmodule
