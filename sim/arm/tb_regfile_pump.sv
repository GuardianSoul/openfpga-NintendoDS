`timescale 1ns/100ps
// arm_regfile PUMP = 1 against the plain three-block form, every clk cycle: random writes
// and reads on all three ports, rd0..rd2 compared one cycle after the address, except where a
// port reads the address written in that cycle (don't-care; arm_core bypasses it). With
// +mut=1 the middle-cycle detector is inverted (ra0/ra1 swapped): the bench must fail.
module tb_regfile_pump;
  logic clk = 1'b1, clk2 = 1'b1;       // both rise at 5, 15, ...: clk2 also rises at 10, 20, ...
  always #5 clk = ~clk;
  always #2.5 clk2 = ~clk2;
  logic        we;
  logic [5:0]  wa, ra0, ra1, ra2;
  logic [31:0] wd;
  logic [31:0] p0, p1, p2, q0, q1, q2;
  arm_regfile #(.PUMP(1'b1)) dp (.clk, .clk2, .we, .wa, .wd, .ra0, .ra1, .ra2, .rd0(p0), .rd1(p1), .rd2(p2));
  arm_regfile #(.PUMP(1'b0)) dq (.clk, .clk2, .we, .wa, .wd, .ra0, .ra1, .ra2, .rd0(q0), .rd1(q1), .rd2(q2));
  int          n = 0, bad = 0, seed, cycles = 0;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    we = 0; wa = 0; wd = 0; ra0 = 0; ra1 = 0; ra2 = 0;
    repeat (40000) begin
      @(negedge clk);                      // inputs change away from the edges
      we  = $urandom_range(0, 3) != 0;
      wa  = $urandom_range(0, 63);
      wd  = $urandom;
      ra0 = $urandom_range(0, 3) == 0 ? wa : $urandom_range(0, 63);
      ra1 = $urandom_range(0, 3) == 0 ? wa : $urandom_range(0, 63);
      ra2 = $urandom_range(0, 3) == 0 ? wa : $urandom_range(0, 63);
    end
    $display("regfile pump: %0d cycles, %0d mismatches -> %s", n, bad, bad == 0 ? "PASS" : "FAIL");
    $finish;
  end
  // the data one cycle after the edge that sampled the addresses, just before the next edge
  always @(posedge clk) begin
    bit s0, s1, s2;
    s0 = we && ra0 == wa; s1 = we && ra1 == wa; s2 = we && ra2 == wa;
    #9.9;
    n++;
    if ((!s0 && p0 !== q0) || (!s1 && p1 !== q1) || (!s2 && p2 !== q2)) begin
      bad++;
      if (bad < 5) $display("MISMATCH cycle %0d: rd %h %h %h vs %h %h %h", n, p0, p1, p2, q0, q1, q2);
    end
  end
endmodule
