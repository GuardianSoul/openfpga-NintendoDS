// Register file for both contexts: 2 x 32 physical registers (31 used each),
// one write port and three synchronous read ports. Each read port is its own
// 64x32 simple dual-port RAM, so the whole file maps to three M10Ks (default:
// the read address is registered inside the block) or twelve MLABs
// (RAM_STYLE). Reads that hit the address written in the same cycle return
// don't-care data; arm_core bypasses that case.
module arm_regfile #(
  parameter RAM_STYLE = "M10K"
) (
  input  logic        clk,
  input  logic        we,
  input  logic [5:0]  wa,
  input  logic [31:0] wd,
  input  logic [5:0]  ra0, ra1, ra2,
  output logic [31:0] rd0, rd1, rd2
);
  (* ramstyle = RAM_STYLE *) logic [31:0] m0 [0:63];
  (* ramstyle = RAM_STYLE *) logic [31:0] m1 [0:63];
  (* ramstyle = RAM_STYLE *) logic [31:0] m2 [0:63];

  always_ff @(posedge clk) begin
    if (we) begin
      m0[wa] <= wd;
      m1[wa] <= wd;
      m2[wa] <= wd;
    end
    rd0 <= m0[ra0];
    rd1 <= m1[ra1];
    rd2 <= m2[ra2];
  end
endmodule
