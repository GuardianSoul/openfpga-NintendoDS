`timescale 1ns/1ps
`include "predicate.svh"
`include "matcher.svh"
module tb_scoped;
 bit running=1;
 logic clk=0,memclk=0,cramclk=0,rst=1;
 always #7.4595 if(running)clk=!clk;
 always #4.973 if(running)memclk=!memclk;
 always @(memclk)if(running)cramclk<=#6.838 memclk;
 logic i_req=0,d_req=0,d_we=0;logic[31:0]i_addr=32'h023091bc,d_addr=32'h04000130;
 wire[31:0]i_rdata,d_rdata,b_addr,b_wdata,b_rdata;wire i_ok,d_ok,b_req,b_we,b_n8,b_ldm,b_ack;
 wire[6:0]b_meta;wire[3:0]b_be,b_tmr;logic[11:0]keys=0;
 wire initialized,idle;wire[79:0]pins;integer reads,writes;
 arm9_mem #(.WAYS(4),.BURST(1),.SLOW(1),.EVB(1),.EVBW(1),.IO_REPLAY(1),.READ_ACK_EARLY(1),.OPT(461366243)) u_mem9(
 .clk,.rst,.cpu_solo(1'b1),.cpu_hold(),.i_req,.i_priv(1'b1),.i_addr,.i_rdata,.i_ok,.i_abort(),
 .d_req,.d_block(1'b0),.d_ldm_meta(7'd0),.d_we,.d_priv(1'b1),.d_be(4'hf),.d_addr,.d_wdata(32'd0),.d_kill(1'b0),
 .cp_req(1'b0),.cp_we(1'b0),.cp_op(16'd0),.cp_wdata(32'd0),.d_rdata_f(d_rdata),.d_ok,.d_abort(),
 .io_replay_owned(),.d_wait(),.hivecs(),.b_n8,.b_ldm_meta(b_meta),.b_ldm,.b_wnext(1'b0),.dg_fill(),
 .b_req,.b_we,.b_addr,.b_wdata,.b_be,.b_tmr,.b_ack,.b_rdata);
 logic i7_req=0,d7_req=0;wire i7_ok,d7_ok;
 wire f7_req,f7_we,f7_ack,f7_rvalid,f7_n4;
 wire[3:0]f7_be;wire[31:0]f7_addr,f7_wdata,f7_rdata,i7_data,d7_data;
 nds_arm7_port #(.BOOT_FAB(1),.WRAM_M10K(1),.IL(5),.DL(4),
 .MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.MAIN_IF_REJOIN(1),
 .MAIN_STORE_TURN(1),.VRAM_DATA_ACK_HANDOFF(1)) u_p7(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),
 .i_req(i7_req),.i_addr(32'h000094b4),.i_seq(1'b1),.i_arm(1'b1),.i_redirect(1'b0),.i_consume(1'b0),
 .i_ok(i7_ok),.i_rdata(i7_data),.d_req(d7_req),.d_we(1'b0),.d_be(4'h3),.d_addr(32'h04000130),.d_wdata(32'd0),
 .d_ok(d7_ok),.d_rdata(d7_data),.i_boot_q(32'd0),.d_boot_q(32'd0),
 .w_ok(1'b0),.w_rdata(32'd0),.x_done(1'b0),.x_rdata(32'd0),.inv(1'b0),.inv_addr(16'd0),
 .f_req(f7_req),.f_we(f7_we),.f_n4(f7_n4),.f_be(f7_be),.f_addr(f7_addr),.f_wdata(f7_wdata),
 .f_ack(f7_ack),.f_rvalid(f7_rvalid),.f_rdata(f7_rdata),.wr_mon(1'b0),.wr_addr(32'd0));
 logic bridgeclk=0;
 always #6.734 if(running)bridgeclk=!bridgeclk;
 logic serv_we=0;wire[31:0]bridge_data;
 logic hg_bridge_rd=1,hg_bridge_wr=0;logic[31:0]hg_bridge_current=32'hf8001000;
 nds_mbox mbox(.clk_74a(bridgeclk),.bridge_endian_little(1'b1),
 .bridge_addr(hg_bridge_current),.bridge_rd(hg_bridge_rd),.bridge_wr(hg_bridge_wr),
 .bridge_wr_data(32'h00006b6f),.bridge_rd_data(bridge_data),
 .clk,.s_addr(8'd96),.s_we(serv_we),.s_wdata(32'h6f6b0000),.s_q());
 bit[3:0]hg_bridge_valid=0,hg_bridge_read=0,hg_bridge_write=0;
 logic[31:0]hg_bridge_addr[4];
 always @(posedge bridgeclk)begin
  hg_bridge_valid<={hg_bridge_valid[2:0],1'b1};
  hg_bridge_read<={hg_bridge_read[2:0],hg_bridge_rd};
  hg_bridge_write<={hg_bridge_write[2:0],hg_bridge_wr};
  hg_bridge_addr[0]<=hg_bridge_current;
  for(int i=1;i<4;i++)hg_bridge_addr[i]<=hg_bridge_addr[i-1];
 end
 bit hg_scope_held=0,hg_scope_original_phase=1,hg_scope_content;
 logic[31:0]initial_words[137],live_words[137];
 lane_ownership #(.SERVICE(3)) dut(.clk_sys(clk),.clk_mem(memclk),.clk_cram(cramclk),.rst_sys(rst),.rst_mem(rst),
 .a9_req(b_req),.a9_we(b_we),.a9_n8(b_n8),.a9_ldm(b_ldm),.a9_ldm_meta(b_meta),.a9_addr(b_addr),.a9_wdata(b_wdata),.a9_be(b_be),.a9_ack(b_ack),.a9_rvalid(),.a9_rdata(b_rdata),
 .a7_req(f7_req),.a7_we(f7_we),.a7_n4(f7_n4),.a7_be(f7_be),.a7_addr(f7_addr),.a7_wdata(f7_wdata),.a7_ack(f7_ack),.a7_rvalid(f7_rvalid),.a7_rdata(f7_rdata),
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

`define HG_SCOPE_P7 u_p7
`define HG_SCOPE_MBOX mbox
`include "scoped.svh"
 function automatic logic[8191:0] protected_state();
  return {b_req,b_we,b_addr,b_ack,b_rdata,u_mem9.st,u_mem9.ip_v,u_mem9.ip_a,
   u_mem9.dp_v,u_mem9.dp_a,u_mem9.ibuf_v,u_mem9.ibuf_a,u_mem9.ibuf_d,
   u_mem9.rbuf_v,u_mem9.rbuf_a,u_mem9.rbuf_d,
   hg_read_bad,hg_read_serial,hg_read_accepted_v,hg_read_accepted_id,hg_read_accepted_addr,
   hg_read_accepted_master,hg_read_physical_v,hg_read_physical_owner,hg_read_physical_base,
   hg_read_physical_id,hg_read_physical_words,hg_read_physical_returned,
   dut.u_fab.st,dut.u_fab.mst,dut.u_fab.addr,dut.u_fab.we,dut.u_fab.blk,
   dut.u_arb.own,dut.u_arb.rd,dut.u_arb.beat,dut.u_arb.mr_addr,
   dut.u_phy.busy,dut.u_phy.out_n,dut.u_phy.s_rvalid,dut.u_phy.s_rdata,dut.u_phy.b_word,
   dut.u_phy.req_t,dut.u_phy.req_seen,dut.u_phy.done_t,dut.u_phy.done_seen,
   u_p7.ia_v,u_p7.ia_r,u_p7.ia_ok,u_p7.il_q,u_p7.il_v,u_p7.il_a[0],u_p7.il_a[1],
   u_p7.il_word_v[0],u_p7.il_word_v[1],u_p7.il_flow,u_p7.il_new,
   u_p7.rp_v,u_p7.rp_i,u_p7.rp_a,u_p7.rp_be,u_p7.rp_k,u_p7.rp_il,u_p7.rp_bad,
   u_p7.rp_flow,u_p7.rp_ifgen,u_p7.rp_ifword,u_p7.rp_ifseq,u_p7.rp_stale,
   u_p7.rp_rejoin_window,u_p7.rp_rejoined,u_p7.if_gen,
   u_p7.busy,u_p7.busy_w,u_p7.wb_v,u_p7.wb_a,u_p7.wb_d,u_p7.wb_be,
   u_p7.rb_v,u_p7.rb_a,u_p7.rb_d,u_p7.flow_v,u_p7.flow_a,u_p7.flow_qv,u_p7.flow_q,
   u_p7.flow_pv,u_p7.flow_pa,u_p7.flow_pg,u_p7.fl_v,u_p7.xs_busy,u_p7.sf_n,u_p7.su_v,
   f7_req,f7_we,f7_be,f7_addr,f7_ack,f7_rvalid,f7_rdata,
   mbox.b_addr,mbox.b_we,mbox.b_d,mbox.b_q,mbox.b_qr,mbox.b_q2,bridge_data,
   mbox.wf_a,mbox.wf_d,mbox.wf_n,mbox.f0,mbox.f1,mbox.f2,mbox.fw_v,
   mbox.h_ev,mbox.t_ev,mbox.fw_word,mbox.fw_slot,mbox.fw_data,
   hg_bridge_valid,hg_bridge_read,hg_bridge_write,
   hg_bridge_addr[0],hg_bridge_addr[1],hg_bridge_addr[2],hg_bridge_addr[3]};
 endfunction
 logic[8191:0] before_state;logic[31:0]before_il[8];bit[10:0]original,scoped;
 initial begin
  $readmemh("initial.hex",initial_words);$readmemh("selected.hex",live_words);
  hg_scope_content=hg193_selected_stub::content_match(initial_words,live_words,1,0);
  #1;dut.chips.m0.mem[32'hc246f]=16'he3b0;dut.chips.m1.mem[32'hc246f]=16'he1dd;
  for(int i=0;i<4;i++)begin
   dut.chips.m0.mem[32'hc2470+i]=16'h1010+16'(i);
   dut.chips.m1.mem[32'hc2470+i]=16'he1a0;
  end
  repeat(12)@(negedge clk);rst=0;serv_we=1;
  @(negedge clk);serv_we=0;wait(initialized);repeat(8)@(negedge clk);
  // Populate the boot line through actual P7/fabric/BOOT_SRAM handshakes.
  i7_req=1;wait(i7_ok);@(negedge clk);i7_req=0;
  wait(!u_p7.busy && !u_p7.rp_v && idle);repeat(3)@(negedge clk);
  assert(i7_data==32'h1afffffa)else $fatal(1,"boot payload");
  i_req=1;wait(u_mem9.ibuf_v && u_mem9.ibuf_a==32'h023091bc);@(negedge clk);i_req=0;
  wait(idle);repeat(3)@(negedge clk);
  i_addr=32'h023091c0;i_req=1;
  wait(dut.u_fab.st==dut.u_fab.S_FILL);@(negedge clk);d7_req=1;
  wait(hg_read_physical_returned==3 && dut.u_phy.s_rvalid && !dut.u_phy.busy);
  #0.001;running=0;hg_scope_held=1;i7_req=1;
  #0.001;
  hg193_actual_read_diagnostics();
  $display("SCOPED_POINT p7=%b bridge=%b a9=%b ia_v%b irdata%h rp_v%b busy%b req%b ack%b",hg193_scope_arm7(),hg193_scope_bridge(),hg193_scope_arm9(),u_p7.ia_v,i7_data,u_p7.rp_v,u_p7.busy,f7_req,f7_ack);
  assert(hg193_scope_arm9() && hg193_scope_arm7() && hg193_scope_bridge())else $fatal(1,"scope class not reached");
  before_state=protected_state();for(int i=0;i<8;i++)before_il[i]=u_p7.u_il.mem[i];
  // Composition test only: unaffected families are explicit prerequisites.
  original=11'b01110110000;scoped=11'b10001001111;
  assert(!hg193_scoped_combine(HG193_SCOPED_DEFAULT_ENABLE,original,scoped));
  assert(hg193_scoped_combine(1,original,scoped));
  for(int i=0;i<11;i++)if(original[i])begin
   original[i]=0;assert(!hg193_scoped_combine(1,original,scoped));original[i]=1;
  end
  if($test$plusargs("owner"))force dut.u_fab.mst=2;
  if($test$plusargs("reply"))force mbox.bridge_rd_data=32'h00006b6e;
  if($test$plusargs("credit"))force dut.u_phy.s_rvalid=0;
  if($test$plusargs("il_payload"))u_p7.u_il.mem[0]^=32'h1;
  #0.001;
  assert(hg193_scope_arm9() && hg193_scope_arm7() && hg193_scope_bridge())
   else $fatal(1,"SCOPED_LIVE_OWNER_OR_PAYLOAD_REJECTED");
  assert(protected_state()===before_state)else $fatal(1,"SCOPED_PROTECTED_STATE_CHANGED");
  for(int i=0;i<8;i++)assert(u_p7.u_il.mem[i]===before_il[i])else $fatal(1,"SCOPED_IL_PAYLOAD_CHANGED");
  // No GPU publisher is executed here. Source audit establishes its write-set;
  // a later authorized native run must prove actual publication/readback.
  // Resume ordinary handshakes: the queued KEYINPUT samples after this edge.
  keys=12'h3ff;hg_scope_held=0;running=1;i7_req=0;
  wait(f7_ack);
  assert(hg_read_physical_returned==4 && !hg_read_physical_v &&
   hg_read_i_done_a==32'h023091c0 && hg_read_i_done_d==32'he1a01010)
   else $fatal(1,"fourth word or ARM9 logical completion lost after release");
  assert(f7_rdata==0)else $fatal(1,"queued KEYINPUT used stale sample");
  @(negedge clk);d7_req=0;i_req=0;
  $display("SCOPED_COMPONENT_PASS default0 quad3_plus_fourthvalid queuedKEYINPUT_new0 registered_reply_preserved IL8_preserved");
  $finish;
 end
 initial begin #1000000;$fatal(1,"scoped component timeout");end
endmodule
