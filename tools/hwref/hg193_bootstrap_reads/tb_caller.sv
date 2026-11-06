`timescale 1ns/1ps
`include "predicate.svh"
module tb_caller;
 logic clk=0,memclk=0,cramclk=0,rst=1;
 always #7.4595 clk=!clk;
 always #4.973 memclk=!memclk;
 always @(memclk)cramclk<=#6.838 memclk;
 logic i_req=0,d_req=0,d_we=0;logic[31:0]i_addr=32'h023091bc,d_addr=32'h04000130;
 wire[31:0]i_rdata,d_rdata,b_addr,b_wdata,b_rdata;wire i_ok,d_ok,b_req,b_we,b_n8,b_ldm,b_ack;
 wire[6:0]b_meta;wire[3:0]b_be,b_tmr;logic[11:0]keys=0;
 wire initialized,idle;wire[79:0]pins;integer reads,writes;
 arm9_mem #(.WAYS(4),.BURST(1),.SLOW(1),.EVB(1),.EVBW(1),.OPT(461366243)) u_mem9(
 .clk,.rst,.cpu_solo(1'b1),.cpu_hold(),.i_req,.i_priv(1'b1),.i_addr,.i_rdata,.i_ok,.i_abort(),
 .d_req,.d_block(1'b0),.d_ldm_meta(7'd0),.d_we,.d_priv(1'b1),.d_be(4'hf),.d_addr,.d_wdata(32'd0),.d_kill(1'b0),
 .cp_req(1'b0),.cp_we(1'b0),.cp_op(16'd0),.cp_wdata(32'd0),.d_rdata_f(d_rdata),.d_ok,.d_abort(),
 .io_replay_owned(),.d_wait(),.hivecs(),.b_n8,.b_ldm_meta(b_meta),.b_ldm,.b_wnext(1'b0),.dg_fill(),
 .b_req,.b_we,.b_addr,.b_wdata,.b_be,.b_tmr,.b_ack,.b_rdata);
 lane_ownership #(.SERVICE(3)) dut(.clk_sys(clk),.clk_mem(memclk),.clk_cram(cramclk),.rst_sys(rst),.rst_mem(rst),
 .a9_req(b_req),.a9_we(b_we),.a9_n8(b_n8),.a9_ldm(b_ldm),.a9_ldm_meta(b_meta),.a9_addr(b_addr),.a9_wdata(b_wdata),.a9_be(b_be),.a9_ack(b_ack),.a9_rvalid(),.a9_rdata(b_rdata),
 .a7_req(1'b0),.a7_we(1'b0),.a7_addr(32'd0),.a7_wdata(32'd0),.a7_ack(),
 .dm_req(1'b0),.dm_we(1'b0),.dm_addr(32'd0),.dm_wdata(32'd0),.dm_ack(),
 .sn_req(1'b0),.sn_we(1'b0),.sn_addr(32'd0),.sn_wdata(32'd0),.sn_ack(),.keys,.initialized,.idle,.pins,.reads,.writes);
`define HG_READ_MEM u_mem9
`define HG_READ_FAB dut.u_fab
`define HG_READ_ARB dut.u_arb
`define HG_READ_PHY dut.u_phy
`define HG_READ_CLK clk
`define HG_READ_RST rst
`define HG_READ_FETCH_PC i_addr
`define HG_READ_DOMAIN_MATCH (b_req===dut.u_fab.a9_req && b_addr===dut.u_fab.a9_addr && b_we===dut.u_fab.a9_we && b_ack===dut.u_fab.a9_ack)
`include "caller.svh"
 int tail_checks=0;
 always @(negedge clk)if(!rst && hg_read_physical_v && hg_read_physical_returned>0)begin
  assert(hg193_read_transport_known())else $fatal(1,"actual physical quad owner/credit not associated");
  tail_checks++;
 end
 initial begin
  #1;dut.chips.m0.mem[32'hc246f]=16'he3b0;dut.chips.m1.mem[32'hc246f]=16'he1dd;
  repeat(12)@(negedge clk);rst=0;wait(initialized);repeat(8)@(negedge clk);
  // Drive actual mem9/fabric/arbiter/PSRAM/paired-chip route, no supplied owner tuples.
  @(negedge clk);i_req=1;
  wait(dut.u_fab.st==dut.u_fab.S_FILL && hg_read_physical_v);
  @(negedge clk);
  if($test$plusargs("forbidden_owner"))force dut.u_fab.mst=2;
  hg193_actual_read_diagnostics();
  assert(hg193_read_transport_known())else $fatal(1,"ACTUAL_FORBIDDEN_OWNER_OR_ASSOCIATION_REJECTED");
  wait(i_ok);@(negedge clk);i_req=0;
  assert(u_mem9.ibuf_v && u_mem9.ibuf_d==32'he1dde3b0)else $fatal(1,"instruction response mismatch");
  assert(hg193_read_transport_known());
  // Original KEYINPUT sample precedes release; retained rbuf survives edge.
  d_req=1;
  wait(u_mem9.rbuf_v);@(negedge clk);d_req=0;
  assert(u_mem9.rbuf_d==32'h3ff && hg_read_key_data==32'h3ff && hg193_read_transport_known())
   else $fatal(1,"pre-release KEYINPUT sample lost");
  keys=12'h3ff;
  assert(u_mem9.rbuf_d==32'h3ff && hg_read_d_done_d==32'h3ff);
  // Consume by ordinary WB replay, then perform a distinct later accepted read.
  @(negedge clk);d_req=1;repeat(3)@(negedge clk);d_req=0;
  wait(!u_mem9.rbuf_v);repeat(4)@(negedge clk);d_req=1;
  wait(u_mem9.rbuf_v);@(negedge clk);d_req=0;
  assert(u_mem9.rbuf_d==0 && hg_read_key_data==0 && hg_read_d_done_d==0 && hg193_read_transport_known())
   else $fatal(1,"post-release distinct sample not preserved");
  assert(!hg193_actual_caller_defaultoff(0,1,1,1) && hg193_actual_caller_defaultoff(1,1,1,1));
  assert(tail_checks>=3 && reads==1);
  $display("ACTUAL_CALLER_PASS tail_checks%0d physical_reads%0d KEYINPUT_3ff_cross_release_then_new0 default0",tail_checks,reads);
  $finish;
 end
 initial begin #1000000;$fatal(1,"actual caller timeout");end
endmodule
