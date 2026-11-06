// arm9_mem's MEM1 dirty bits: the M10K form (one write address, read a clock ahead at the tag's address, a write in the read's
// clock from a register) against the flops it replaced. Random store hits and line clears, never in one clock (arm9_mem's
// simulation checks that), and every set read: the bits must agree.
//   Build with -DMUT=n; n != 0 is a deliberate bug, which must fail
`timescale 1ns/1ps
`ifndef MUT
`define MUT 0
`endif
module tb_dirt_eq;
  localparam int DSB = 8, WAYS = 2;
  logic clk = 0; always #1 clk = !clk;
  logic dirt_s = 0, dirt_c = 0, wd_way = 0, vway = 0;
  logic [DSB-1:0] w_set = 0, dset = 0, dset_n = 0;
  logic [WAYS-1:0] q_new = 0, bv = 0; logic bd = 0;
  logic old_m [0:WAYS-1][0:(1<<DSB)-1], new_m [0:WAYS-1][0:(1<<DSB)-1];
  wire [DSB-1:0] dirt_wa = `MUT == 1 ? dset : dirt_s ? w_set : dset;
  longint n = 0, errs = 0, sets = 0, clears = 0, reads1 = 0;
  initial for (int g = 0; g < WAYS; g++) for (int i = 0; i < (1<<DSB); i++) begin old_m[g][i] = 0; new_m[g][i] = 0; end
  always @(posedge clk) begin
    for (int g = 0; g < WAYS; g++) begin
      automatic logic we = (dirt_s && wd_way == 1'(g)) || (`MUT != 2 && !dirt_s && dirt_c && vway == 1'(g));
      if (dirt_s && wd_way == 1'(g)) old_m[g][w_set] <= 1'b1;
      else if (dirt_c && vway == 1'(g)) old_m[g][dset] <= 1'b0;
      if (we) new_m[g][dirt_wa] <= `MUT == 3 ? 1'b1 : dirt_s;
      q_new[g] <= new_m[g][dset_n];
      bv[g] <= `MUT != 4 && we && dirt_wa == dset_n;
    end
    bd <= dirt_s;
    for (int g = 0; g < WAYS; g++) begin
      automatic logic got = bv[g] ? bd : q_new[g];
      if (n > 2 && old_m[g][dset] !== got) begin
        errs <= errs + 1;
        if (errs < 3) $display("DIFF clk %0d way %0d set %0d: old %b new %b", n, g, dset, old_m[g][dset], got);
      end
      if (old_m[g][dset]) reads1 <= reads1 + 1;
    end
    n <= n + 1;
    begin
      automatic int unsigned r = $urandom;
      dirt_s <= r[1:0] == 2'd0;
      dirt_c <= r[1:0] != 2'd0 && r[3:2] == 2'd0;
      wd_way <= r[4]; vway <= r[5];
      w_set <= r[20] ? r[13:6] : {6'd0, r[7:6]};    // (a few sets often, so bits are set and then cleared)
      dset <= dset_n; dset_n <= r[21] ? r[29:22] : {6'd0, r[23:22]};
      if (r[1:0] == 2'd0) sets <= sets + 1;
      if (r[1:0] != 2'd0 && r[3:2] == 2'd0) clears <= clears + 1;
    end
    if (n == 3000000) begin
      $display("%0d clocks, %0d store hits, %0d line clears, %0d dirty reads, %0d differences", n, sets, clears, reads1, errs);
      if (errs != 0) $display("TEST FAILED"); else $display("TEST PASSED");
      $finish;
    end
  end
endmodule
