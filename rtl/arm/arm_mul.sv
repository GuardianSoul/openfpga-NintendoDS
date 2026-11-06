// 33x33 signed multiplier for both contexts, on DSP blocks, three cycles:
//   cycle 0  operands registered (end of the uop's E2)
//   cycle 1  four 17x17 partial products, the two middle ones summed
//            (DSP "sum of two" mode), registered
//   cycle 2  final add, product registered per context
// The context's next uop reads the product in its E3, one cycle after that.
// One product register per context, because a long multiply reads it twice.
// The two product registers rotate with the contexts: `prod` always holds the
// product of the context now in E3 (fixed latency, so a new product always
// lands there), and no context-select mux is needed. hold (arm_core solo: one
// context in every stage) keeps the product instead of rotating it.
module arm_mul (
  input  logic        clk,
  input  logic        start,
  input  logic        hold,
  input  logic        wy,       // SMULWy/SMLAWy: keep bits 47:16
  input  logic [32:0] a,
  input  logic [32:0] b,
  output logic [63:0] prod
);
  logic signed [16:0] ah, bh;
  logic        [15:0] al, bl;
  logic               v0, w0, v1, w1;
  logic        [63:0] other;

  always_ff @(posedge clk) begin
    v0 <= start;
    w0 <= wy;
    if (start) begin
      ah <= a[32:16];
      al <= a[15:0];
      bh <= b[32:16];
      bl <= b[15:0];
    end
  end

  logic signed [33:0] p_hh, p_hl, p_lh;
  logic        [31:0] p_ll;
  assign p_hh = ah * bh;
  assign p_hl = ah * $signed({1'b0, bl});
  assign p_lh = $signed({1'b0, al}) * bh;
  assign p_ll = al * bl;

  logic signed [33:0] r_hh;
  logic signed [34:0] r_mid;
  logic        [31:0] r_ll;

  always_ff @(posedge clk) begin
    v1 <= v0;
    w1 <= w0;
    r_hh  <= p_hh;
    r_ll  <= p_ll;
    r_mid <= {p_hl[33], p_hl} + {p_lh[33], p_lh};
  end

  logic signed [65:0] p;
  assign p = $signed({r_hh, r_ll}) + ($signed(r_mid) <<< 16);

  always_ff @(posedge clk) begin
    other <= prod;
    prod  <= v1 ? (w1 ? {{14{p[65]}}, p[65:16]} : p[63:0]) : hold ? prod : other;
  end
endmodule
