// Small asynchronous FIFO (gray-coded pointers, two-flop synchronisers),
// registers only. Written in clock w, read in clock r: r_v says an entry is
// at the head, r_take removes it. The writer must not write when full; the
// one user here (cpu_domain) writes at most once per clk_sys cycle and reads
// every clk_cpu cycle, so it never fills (a simulation check says so).
module cdc_fifo #(
  parameter int W  = 8,
  parameter int AB = 3                  // log2 depth
) (
  input  logic         w_clk,
  input  logic         w_rst,
  input  logic         w_en,
  input  logic [W-1:0] w_d,
  input  logic         r_clk,
  input  logic         r_rst,
  output logic         r_v,
  output logic [W-1:0] r_d,
  input  logic         r_take
);
  logic [W-1:0] mem [0:(1<<AB)-1];
  logic [AB:0]  wp, rp, wg, rg, wg_r0, wg_r1, rg_w0, rg_w1;

  function automatic logic [AB:0] g2b(input logic [AB:0] g);
    logic [AB:0] b;
    b[AB] = g[AB];
    for (int i = AB - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  always_ff @(posedge w_clk) begin
    rg_w0 <= rg; rg_w1 <= rg_w0;
    if (w_rst) begin wp <= '0; wg <= '0; end
    else if (w_en) begin
      mem[wp[AB-1:0]] <= w_d;
      wp <= wp + 1'b1;
      wg <= (wp + 1'b1) ^ ((wp + 1'b1) >> 1);
    end
  end
`ifndef ALTERA_RESERVED_QIS
  // simulation: the writer never meets a full FIFO
  always_ff @(posedge w_clk)
    if (!w_rst && w_en && (wp - g2b(rg_w1)) == (AB+1)'(1 << AB))
      $display("cdc_fifo: written while full (an entry is lost)");
`endif

  always_ff @(posedge r_clk) begin
    wg_r0 <= wg; wg_r1 <= wg_r0;
    if (r_rst) begin rp <= '0; rg <= '0; end
    else if (r_take && r_v) begin
      rp <= rp + 1'b1;
      rg <= (rp + 1'b1) ^ ((rp + 1'b1) >> 1);
    end
  end
  assign r_v = g2b(wg_r1) != rp;
  assign r_d = mem[rp[AB-1:0]];
endmodule
