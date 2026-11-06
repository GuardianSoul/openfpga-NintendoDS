// Opt-in observation only. No DUT assignments, waits, ACKs or clock changes.
bit hg193_proposal_enable=0,hg193_native_published=0;
bit hg_scope_held=0,hg_scope_original_phase=0,hg_scope_content=0;
bit[3:0]hg_bridge_valid=0,hg_bridge_read=0,hg_bridge_write=0;
logic[31:0]hg_bridge_addr[4],hg_bridge_current;
bit hg_bridge_rd,hg_bridge_wr;
logic[63:0]hg_native_id;
logic[31:0]hg_native_p7_sample=0,hg_native_fourth=0;
bit hg_native_fourth_seen=0,hg_native_a9_done=0,hg_native_p7_sampled=0,hg_native_p7_done=0;
int hg_native_post_edges=0;
realtime hg_native_publication_time;
time hg_native_publication_ticks;
`define HG_READ_MEM dut.ds.u_cpud.g_one.u_cpu.u_mem9
`define HG_READ_FAB dut.ds.u_fab
`define HG_READ_PHY dut.psram
`define HG_SCOPE_P7 dut.ds.u_cpud.g_a7c.u_p7
`define HG_SCOPE_MBOX dut.g_mbox.commands
`include "scoped.svh"
`include "generated_native_scoped_drain.svh"
`include "protected-state.svh"
task automatic hg193_native_refresh;
 hg_scope_held=hg193_combined_held;
 hg_scope_original_phase=imp_vc==193 && dut.line_start && dut.vcount==193 &&
  !dut.clk_sys && !dut.clk_2x && !imp_stub_pend;
 hg_scope_content=hg193_selected_stub_actual_match();
 hg_bridge_valid=hg_bridge_history_valid;
 hg_bridge_read=hg_bridge_rd_history;hg_bridge_write=hg_bridge_wr_history;
 for(int i=0;i<4;i++)hg_bridge_addr[i]=hg_bridge_address_history[i];
 hg_bridge_rd=bridge_rd;hg_bridge_wr=bridge_wr;hg_bridge_current=bridge_addr;
endtask
function automatic bit hg193_native_ready();
 return hg193_proposal_enable ? hg193_scoped_transport_ready() : hg193_combined_transport_drained();
endfunction
task automatic hg193_native_assert_ready;
 hg193_native_refresh();
 if(!hg193_proposal_enable)assert_hg193_combined_drained();
 else begin
  assert(hg193_combined_held && HG193_SCOPED_DEFAULT_ENABLE==0)
   else $fatal(1,"HG193_NATIVE_SCOPE_MUST_BE_EXPLICIT_DEFAULT0");
  assert(hg193_scope_arm9() && hg193_scope_arm7() && hg193_scope_bridge())
   else $fatal(1,"HG193_NATIVE_OWNER_SCOPE_REJECTED a9=%b p7=%b bridge=%b",hg193_scope_arm9(),hg193_scope_arm7(),hg193_scope_bridge());
  assert(hg193_scoped_transport_ready())else $fatal(1,"HG193_NATIVE_RESIDUAL_FAMILY_REJECTED");
 end
endtask
task automatic hg193_native_before;
 hg193_native_refresh();
 // Console $time rounds in this module's ns units. The separate package
 // reads integer simulator ticks in1ps units, without scaling or epsilon.
 $display("HG193_NATIVE_ENTRY console_ps=%0t ticks_ps=%0d expected_ps=%0d strict=%b published=%b",$time,hg193_native_time::now_ps(),hg193_native_time::ORIGINAL_TICKS_PS,hg193_combined_transport_drained(),hg193_native_published);
 assert(!hg193_native_published && hg193_native_time::exact(hg193_native_time::now_ps()) && !hg193_combined_transport_drained())
  else $fatal(1,"HG193_NATIVE_ORIGINAL_POINT_CHANGED_OR_STRICT_CONTROL_NOT_REJECTED");
 hg_native_publication_time=$realtime;hg_native_publication_ticks=hg193_native_time::now_ps();hg_native_id=hg_read_physical_id;
 hg193_protected_capture();
 $display("HG193_NATIVE_BEFORE time_ps=%0t ticks_ps=%0d id=%0d returned=%0d fourthvalid=%b pending_a7_ack=%b key=%h bridge=%h",$time,hg193_native_time::now_ps(),hg_native_id,hg_read_physical_returned,dut.psram.s_rvalid,dut.ds.u_fab.a7_ack,dut.keys,bridge_rd_data);
endtask
task automatic hg193_native_after;
 hg193_protected_verify();
 assert($realtime==hg_native_publication_time && hg193_native_time::now_ps()==hg_native_publication_ticks && hg_read_physical_id==hg_native_id &&
  hg_read_physical_returned==3 && dut.psram.s_rvalid && !dut.ds.u_fab.a7_ack &&
  hg193_applied && hg193_native_ready())else $fatal(1,"HG193_NATIVE_PUBLICATION_ALTERED_TIME_OR_CREDIT");
 hg193_native_published=1;
 $display("HG193_NATIVE_PUBLICATION_READBACK_PASS time_ps=%0t ticks_ps=%0d default0=%b optin=%b",$time,hg193_native_time::now_ps(),HG193_SCOPED_DEFAULT_ENABLE,hg193_proposal_enable);
endtask
initial begin
 hg193_proposal_enable=$test$plusargs("hg193_scoped_publication");
 assert(HG193_SCOPED_DEFAULT_ENABLE==0 && hg193_bootstrap_reads::PROPOSAL_DEFAULT_ENABLE==0)
  else $fatal(1,"HG193_NATIVE_DEFAULT_CHANGED");
 if(hg193_proposal_enable)begin
  assert(hg193_native_time::exact(64'd129210695256) &&
   !hg193_native_time::exact(64'd129210695255) &&
   !hg193_native_time::exact(64'd129210695257))
   else $fatal(1,"HG193_NATIVE_EXACT_TIME_CONTROLS_FAILED");
  $display("HG193_NATIVE_TIME_CONTROLS_PASS exact_ps=129210695256 minus1ps=0 plus1ps=0");
  assert(!$test$plusargs("scene_capture_prefix=") && !$test$plusargs("fst=") &&
   !$test$plusargs("shots=") && !$test$plusargs("savout=") && !$test$plusargs("root40_ldm_capture"))
   else $fatal(1,"HG193_NATIVE_FORBIDS_RAW_OUTPUT");
  $display("HG193_NATIVE_EXPLICIT_SCOPE_FLAG_DEFAULT0");
 end
end
// Separate observations of the physical tail, ARM9 logical completion and
// ARM7's ordinary IO acceptance/completion. Never turns a queued read into ACK.
always @(posedge dut.clk_sys)if(hg193_proposal_enable && hg193_native_published)begin
 hg_native_post_edges++;
 if(dut.psram.s_rvalid && hg_read_physical_v && hg_read_physical_id==hg_native_id)begin
  assert(hg_read_physical_returned==3 && !hg_native_fourth_seen)
   else $fatal(1,"HG193_NATIVE_FOURTH_CREDIT_DUPLICATED_OR_RELABELED");
  hg_native_fourth_seen=1;hg_native_fourth=dut.psram.s_rdata;
  $display("HG193_NATIVE_FOURTH_ACCEPT time_ps=%0t ticks_ps=%0d id=%0d data=%h",$time,hg193_native_time::now_ps(),hg_native_id,hg_native_fourth);
 end
 if(dut.ds.u_cpud.g_one.u_cpu.u_mem9.b_req && dut.ds.u_cpud.g_one.u_cpu.u_mem9.b_ack &&
  hg_read_accepted_id==hg_native_id)begin
  assert(hg_native_fourth_seen && !dut.ds.u_cpud.g_one.u_cpu.u_mem9.b_we &&
   dut.ds.u_cpud.g_one.u_cpu.u_mem9.b_addr==32'h023091c0)
   else $fatal(1,"HG193_NATIVE_A9_LOGICAL_OWNER_CHANGED");
  hg_native_a9_done=1;
  $display("HG193_NATIVE_A9_DONE time_ps=%0t ticks_ps=%0d id=%0d data=%h",$time,hg193_native_time::now_ps(),hg_native_id,dut.ds.u_cpud.g_one.u_cpu.u_mem9.b_rdata);
 end
 if(dut.ds.u_fab.mst==2 && dut.ds.u_fab.addr==32'h04000130 &&
  !dut.ds.u_fab.we && dut.ds.u_fab.io_ack &&
  ((dut.ds.u_fab.st==dut.ds.u_fab.S_GO && dut.ds.u_fab.io_sent) ||
   (dut.ds.u_fab.st==dut.ds.u_fab.S_WAIT && dut.ds.u_fab.tgt_q==dut.ds.u_fab.T_IO)))begin
  assert(!hg_native_p7_sampled && dut.ds.u_fab.be==3)
   else $fatal(1,"HG193_NATIVE_P7_SAMPLE_OWNER_CHANGED");
  hg_native_p7_sampled=1;hg_native_p7_sample=dut.ds.u_fab.io_rdata;
  $display("HG193_NATIVE_P7_SAMPLE time_ps=%0t ticks_ps=%0d key=%h data=%h",$time,hg193_native_time::now_ps(),dut.keys,hg_native_p7_sample);
 end
 if(dut.ds.u_cpud.g_a7c.u_p7.f_req && dut.ds.u_cpud.g_a7c.u_p7.f_ack &&
  dut.ds.u_cpud.g_a7c.u_p7.f_addr==32'h04000130 && !dut.ds.u_cpud.g_a7c.u_p7.f_we)begin
  assert(hg_native_p7_sampled && dut.ds.u_cpud.g_a7c.u_p7.f_rdata===hg_native_p7_sample)
   else $fatal(1,"HG193_NATIVE_P7_COMPLETION_PAYLOAD_CHANGED");
  hg_native_p7_done=1;
  $display("HG193_NATIVE_P7_DONE time_ps=%0t ticks_ps=%0d data=%h",$time,hg193_native_time::now_ps(),hg_native_p7_sample);
 end
 assert(hg_native_post_edges<128)else $fatal(1,"HG193_NATIVE_PENDING_COMPLETION_TIMEOUT");
end
// Observe registered ownership/response state after the ordinary positive edge.
// This adds no wait or clock step to the import/release task.
always @(negedge dut.clk_sys)if(hg193_proposal_enable && hg193_native_published &&
 hg_native_fourth_seen && hg_native_a9_done && hg_native_p7_done)begin
 assert(!hg_read_physical_v && hg_read_physical_returned==4 &&
  dut.ds.u_cpud.g_a7c.u_p7.rb_v &&
  dut.ds.u_cpud.g_a7c.u_p7.rb_a==32'h04000130 &&
  dut.ds.u_cpud.g_a7c.u_p7.rb_d===hg_native_p7_sample)
  else $fatal(1,"HG193_NATIVE_REGISTERED_COMPLETION_READBACK_FAILED");
 $display("HG193_NATIVE_BOUNDED_PASS time_ps=%0t ticks_ps=%0d edges=%0d fourth=%h p7=%h",$time,hg193_native_time::now_ps(),hg_native_post_edges,hg_native_fourth,hg_native_p7_sample);
 $finish;
end
`undef HG_READ_MEM
`undef HG_READ_FAB
`undef HG_READ_PHY
`undef HG_SCOPE_P7
`undef HG_SCOPE_MBOX
