`ifndef ALTERA_RESERVED_QIS
`timescale 1ns/1ps
module tb_clip_import #(parameter int MODE=0);
 import gpu3d_gxu_pkg::*;
 reg clk=0,clk2=0,rst=1,we=0,run=0,can=1,wfree=0;
 reg [10:0]wa=0;reg[31:0]wd=0;
 wire cond0,cond1,cw0,cw1,busy0,busy1,nv0,nv1,side0,side1;
 wire[10:0]cwa0,cwa1;wire[31:0]cwd0,cwd1;wire[3:0]nn0,nn1;
 gpu3d_gxclip #(.A_LA(FU_A_LA),.A_LN(FU_A_LN),.A_CS(FU_A_CS),.A_OCM(PU_A_OCM),.A_CATTR(LU_A_CATTR),.A_POOL(PU_A_POOL),.DIV_P2X(1),.COHORT(1),.STORE_PUMP(0)) a(
 .clk,.clk2,.rst,.we,.run,.can,.wfree,.wa,.wd,.cond(cond0),.cw(cw0),.cwa(cwa0),.cwd(cwd0),.busy(busy0),.nnew_v(nv0),.nnew(nn0),.nside(side0));
 gpu3d_gxclip #(.A_LA(FU_A_LA),.A_LN(FU_A_LN),.A_CS(FU_A_CS),.A_OCM(PU_A_OCM),.A_CATTR(LU_A_CATTR),.A_POOL(PU_A_POOL),.DIV_P2X(1),.COHORT(1),.STORE_PUMP(1)) b(
 .clk,.clk2,.rst,.we,.run,.can,.wfree,.wa,.wd,.cond(cond1),.cw(cw1),.cwa(cwa1),.cwd(cwd1),.busy(busy1),.nnew_v(nv1),.nnew(nn1),.nside(side1));
 `undef RUNTIME_CLIP_STORE_ENABLED
 generate begin:before_bridge
 `define RUNTIME_CLIP a
 `include "runtime_import_clip_store.svh"
 `undef RUNTIME_CLIP
 end endgenerate
 generate begin:enabled_bridge
 `define RUNTIME_CLIP b
 `define RUNTIME_CLIP_STORE_ENABLED
 `include "runtime_import_clip_store.svh"
 `undef RUNTIME_CLIP_STORE_ENABLED
 `undef RUNTIME_CLIP
 end endgenerate
 logic[31:0]words[0:4][0:31],oq[0:4],iq[0:4];
 logic[85:0]metadata_before;
 logic[31:0]captured[0:4][0:31],captured_o[0:4],captured_i[0:4];
 integer n,g,sf,cycles=0,takes=0,consumed=0,results=0,m_events=0,first_late=-1;
 bit checking=0,completed=0;time import_time;
 task automatic compare_public;
  if({cond0,cw0,busy0,nv0}!=={cond1,cw1,busy1,nv1})$fatal(1,"IMPORT_PUBLIC_CONTROL_MISMATCH cycle%0d",cycles);
  if(cw0 && {cwa0,cwd0}!=={cwa1,cwd1})$fatal(1,"IMPORT_PUBLIC_CWD_MISMATCH cycle%0d old%h new%h",cycles,cwd0,cwd1);
  if(nv0 && {nn0,side0}!=={nn1,side1})$fatal(1,"IMPORT_PUBLIC_RESULT_MISMATCH");
  if(MODE==0||MODE==10)begin
   if(a.st!==b.st || a.qw!==b.qw || a.qr!==b.qr || a.pts!==b.pts || a.nk!==b.nk || a.rk!==b.rk)$fatal(1,"IMPORT_STATE_ORDER_MISMATCH");
   for(int i=0;i<9;i++)if(a.vin[i]!==b.vin[i]||a.nv[i]!==b.nv[i])$fatal(1,"IMPORT_CONSUMED_LATCH_MISMATCH field%0d",i);
  end
 endtask
 task automatic tick;
  // E then M. Import occurs only after a completed M while both clocks low.
  #2;clk=1;clk2=1;#1;
  if(checking)compare_public();
  clk=0;clk2=0;#2;clk2=1;#1;clk2=0;#1;
  if(checking)begin compare_public();m_events++;end
  cycles++;
 endtask
 initial begin : test_main
  // Cold initialization BEFORE restore; no reset/tick/settling after deposit.
  repeat(3)tick();rst=0;
  for(sf=0;sf<5;sf++)for(g=0;g<32;g++)words[sf][g]=32'h10000000+32'(sf*32'h00100011+g*32'h00010101);
  for(sf=0;sf<5;sf++)begin oq[sf]=words[sf][0];iq[sf]=words[sf][0];end
  // Existing clean-context shape: four raw vertices, idle/empty clip, no work.
  a.sn_ln=4;b.sn_ln=4;a.sn_cs=0;b.sn_cs=0;a.sn_ocm=63;b.sn_ocm=63;
  a.sn_far=0;b.sn_far=0;a.sn_pool=11'h300;b.sn_pool=11'h300;
  for(g=0;g<10;g++)begin a.sn_la[g]=11'(11'h200+16*g);b.sn_la[g]=a.sn_la[g];end
  a.u=11'h200;b.u=11'h200;
  for(g=0;g<32;g++)a.g_word[0].u_out.mem[g]=(g%4==0?32'hffffe000:g%4==3?32'h00002000:32'd0);
  a.g_word[0].u_out.rdata=a.g_word[0].u_out.mem[0];
  for(g=0;g<32;g++)a.g_word[0].u_in.mem[g]=(g%4==0?32'hffffe000:g%4==3?32'h00002000:32'd0);
  a.g_word[0].u_in.rdata=a.g_word[0].u_in.mem[0];
  for(g=0;g<32;g++)b.g_word[0].u_out.mem[g]=(g%4==0?32'hffffe000:g%4==3?32'h00002000:32'd0);
  b.g_word[0].u_out.rdata=b.g_word[0].u_out.mem[0];
  for(g=0;g<32;g++)b.g_word[0].u_in.mem[g]=(g%4==0?32'hffffe000:g%4==3?32'h00002000:32'd0);
  b.g_word[0].u_in.rdata=b.g_word[0].u_in.mem[0];
  for(g=0;g<32;g++)a.g_word[1].u_out.mem[g]=32'd0;
  a.g_word[1].u_out.rdata=a.g_word[1].u_out.mem[0];
  for(g=0;g<32;g++)a.g_word[1].u_in.mem[g]=32'd0;
  a.g_word[1].u_in.rdata=a.g_word[1].u_in.mem[0];
  for(g=0;g<32;g++)b.g_word[1].u_out.mem[g]=32'd0;
  b.g_word[1].u_out.rdata=b.g_word[1].u_out.mem[0];
  for(g=0;g<32;g++)b.g_word[1].u_in.mem[g]=32'd0;
  b.g_word[1].u_in.rdata=b.g_word[1].u_in.mem[0];
  for(g=0;g<32;g++)a.g_word[2].u_out.mem[g]=32'd0;
  a.g_word[2].u_out.rdata=a.g_word[2].u_out.mem[0];
  for(g=0;g<32;g++)a.g_word[2].u_in.mem[g]=32'd0;
  a.g_word[2].u_in.rdata=a.g_word[2].u_in.mem[0];
  for(g=0;g<32;g++)b.g_word[2].u_out.mem[g]=32'd0;
  b.g_word[2].u_out.rdata=b.g_word[2].u_out.mem[0];
  for(g=0;g<32;g++)b.g_word[2].u_in.mem[g]=32'd0;
  b.g_word[2].u_in.rdata=b.g_word[2].u_in.mem[0];
  for(g=0;g<32;g++)a.g_word[3].u_out.mem[g]=32'd4096;
  a.g_word[3].u_out.rdata=a.g_word[3].u_out.mem[0];
  for(g=0;g<32;g++)a.g_word[3].u_in.mem[g]=32'd4096;
  a.g_word[3].u_in.rdata=a.g_word[3].u_in.mem[0];
  for(g=0;g<32;g++)b.g_word[3].u_out.mem[g]=32'd4096;
  b.g_word[3].u_out.rdata=b.g_word[3].u_out.mem[0];
  for(g=0;g<32;g++)b.g_word[3].u_in.mem[g]=32'd4096;
  b.g_word[3].u_in.rdata=b.g_word[3].u_in.mem[0];
  // Poison dead metadata, keep the strict post-M/empty-pending relation.
  b.g_store_pump.u_store.pending_addr=9'h17a;
  b.g_store_pump.u_store.pending_data=32'h98abcdef;
  b.g_store_pump.u_store.inside_addr=5'd13;
  b.g_store_pump.u_store.forward_match=1;
  b.g_store_pump.u_store.forward_word=4'd4;
  b.g_store_pump.u_store.forward_data=32'h77112233;
  if(MODE==5)b.g_store_pump.u_store.pending_we=1;
  if(MODE==6)b.st=b.S_PLANE;
  before_bridge.clip_import_preflight(words,oq,iq,32'hffffffff,5'b11111,1,1);
  enabled_bridge.clip_import_preflight(words,oq,iq,MODE==4?32'hf:32'hffffffff,MODE==7?5'b01111:5'b11111,1,MODE!=2&&MODE!=3);
  if(MODE==3)$fatal(1,"IMPORT_PHASE_GUARD_MUTANT_ESCAPED_REJECTION");
  metadata_before=enabled_bridge.clip_import_metadata();import_time=$time;
  before_bridge.clip_import_words(words,oq,iq);
  if(MODE==9)a.g_word[4].u_out.mem[0]=~a.g_word[4].u_out.mem[0];
  before_bridge.clip_capture_legacy_witness(captured,captured_o,captured_i,1,1,1);
  for(sf=0;sf<5;sf++)begin
   if(captured_o[sf]!==oq[sf]||captured_i[sf]!==iq[sf])$fatal(1,"CAPTURE_HELD_FIDELITY");
   for(g=0;g<32;g++)if(captured[sf][g]!==words[sf][g])$fatal(1,"CAPTURE_BACKING_FIDELITY");
  end
  enabled_bridge.clip_import_words(captured,captured_o,captured_i);
  if(MODE==0||MODE==10)begin
   before_bridge.clip_verify_words(words,oq,iq);
   enabled_bridge.clip_verify_words(words,oq,iq);
  end
  assert(enabled_bridge.clip_import_metadata()===metadata_before && $time==import_time)
   else $fatal(1,"IMPORT_MUTATED_METADATA_OR_ADVANCED_TIME");
  // Adversarial liveness witness ONLY, never a fabricated canonical image.
  // Leave all backing intact and vary held O/I before first ordinary E.
  if(MODE==10)begin
   b.g_store_pump.u_store.outside_word[0]=~captured_o[0];b.g_store_pump.u_store.g_field[0].u_mem.rdata=~captured_i[0];
   b.g_store_pump.u_store.outside_word[1]=~captured_o[1];b.g_store_pump.u_store.g_field[1].u_mem.rdata=~captured_i[1];
   b.g_store_pump.u_store.outside_word[2]=~captured_o[2];b.g_store_pump.u_store.g_field[2].u_mem.rdata=~captured_i[2];
   b.g_store_pump.u_store.outside_word[3]=~captured_o[3];b.g_store_pump.u_store.g_field[3].u_mem.rdata=~captured_i[3];
   b.g_store_pump.u_store.outside_word[4]=~captured_o[4];b.g_store_pump.u_store.g_field[4].u_mem.rdata=~captured_i[4];
  end
  // First ordinary E starts the real clip. No read refresh/startup clocks.
  checking=1;run=1;
  for(n=0;n<20000&&!completed;n++)begin
   wfree=n>20 && n%3!=0;we=cw0&&wfree;wa=cwa0;wd=cwd0;
   if(we)takes++;
   if(a.st==a.S_NB2)begin
    consumed++;
    if(first_late<0)first_late=cycles;
    if(MODE==10 && m_events==0)$fatal(1,"HELD_LIVENESS_EARLY_CONSUMER");
   end
   if(nv0)results++;
   tick();
   if(n>2 && !cond0 && !busy0)begin
    if(!takes||!consumed)$fatal(1,"IMPORT_FIRST_USE_COVERAGE");
    if(MODE==10)$display("PASS_HELD_LIVENESS firstlate%0d normalM%0d",first_late,m_events);
    $display("PASS_IMPORT_FIRST_USE cycles%0d writes%0d neighbours%0d",cycles,takes,consumed);
    completed=1;
   end
  end
  if(!completed)$fatal(1,"IMPORT_FIRST_USE_TIMEOUT");
  $finish;
 end
endmodule
`endif
