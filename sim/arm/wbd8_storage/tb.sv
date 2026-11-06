`timescale 1ns/1ps
module tb #(parameter bit MEM1=1, parameter bit NB=1);
 localparam int OPT=MEM1 ? 461366243 : 0;
 logic clk=0,rst=1,solo=1,kill=0;
 always #5 clk=~clk;
 logic iq=0,dq=0,dwe=0,cq=0,cwe=0;
 logic[31:0]ia=32'h02000000,da=0,dd=0,cd=0;
 logic[3:0]be=15;
 logic[15:0]cop=0;
 wire[1:0]hold_cpu,iok,iabort,dok,dabort,dwait,owned,hivecs,breq,bwe,bn8,bldm;
 wire[31:0]idata[2],ddata[2],baddr[2],bwdata[2];
 wire[3:0]bbe[2],btmr[2];wire[6:0]bmeta[2];wire[1:0]fill[2];
 logic ack=0,hold_bus=1;
 logic[31:0]rdata;
 integer edge_no=0,delay_left=0,serial=0,stage=0;
 integer pushes=0,pops=0,simul=0,full_refusals=0,held=0,reset_nonempty=0,reads=0,ifetches=0;
 integer occupancy[9];integer simultaneous_at[9];integer full_pop_refusal=0;integer wrap_cycles=0;integer nb_held=0,orphaned=0;
 logic[31:0]rng=32'h394ed135;
 logic[71:0] gold[$];logic[71:0] old_word,new_word;
 logic[63:0] signature=64'h4851525545554538;
 arm9_mem_before #(.WAYS(4),.SLOW(1),.OPT(OPT),.EVB(1),.IO_REPLAY(1),.READ_ACK_EARLY(1),.NCNB_WAIT(NB),.EARLYD(1),.RESET_CTRL(0)) refmem(
 .clk,.rst,.cpu_solo(solo),.cpu_hold(hold_cpu[0]),.i_req(iq),.i_priv(1'b1),.i_addr(ia),.i_rdata(idata[0]),.i_ok(iok[0]),.i_abort(iabort[0]),
 .d_req(dq),.d_block(1'b0),.d_ldm_meta(7'd0),.d_we(dwe),.d_priv(1'b1),.d_be(be),.d_addr(da),.d_wdata(dd),.d_kill(kill),.cp_req(cq),.cp_we(cwe),.cp_op(cop),.cp_wdata(cd),
 .d_rdata_f(ddata[0]),.d_ok(dok[0]),.d_abort(dabort[0]),.io_replay_owned(owned[0]),.d_wait(dwait[0]),.hivecs(hivecs[0]),
 .b_n8(bn8[0]),.b_ldm_meta(bmeta[0]),.b_ldm(bldm[0]),.b_wnext(1'b0),.dg_fill(fill[0]),.b_req(breq[0]),.b_we(bwe[0]),.b_addr(baddr[0]),.b_wdata(bwdata[0]),.b_be(bbe[0]),.b_tmr(btmr[0]),.b_ack(ack),.b_rdata(rdata));
 arm9_mem #(.WAYS(4),.SLOW(1),.OPT(OPT),.EVB(1),.IO_REPLAY(1),.READ_ACK_EARLY(1),.NCNB_WAIT(NB),.EARLYD(1),.RESET_CTRL(0)) dut(
 .clk,.rst,.cpu_solo(solo),.cpu_hold(hold_cpu[1]),.i_req(iq),.i_priv(1'b1),.i_addr(ia),.i_rdata(idata[1]),.i_ok(iok[1]),.i_abort(iabort[1]),
 .d_req(dq),.d_block(1'b0),.d_ldm_meta(7'd0),.d_we(dwe),.d_priv(1'b1),.d_be(be),.d_addr(da),.d_wdata(dd),.d_kill(kill),.cp_req(cq),.cp_we(cwe),.cp_op(cop),.cp_wdata(cd),
 .d_rdata_f(ddata[1]),.d_ok(dok[1]),.d_abort(dabort[1]),.io_replay_owned(owned[1]),.d_wait(dwait[1]),.hivecs(hivecs[1]),
 .b_n8(bn8[1]),.b_ldm_meta(bmeta[1]),.b_ldm(bldm[1]),.b_wnext(1'b0),.dg_fill(fill[1]),.b_req(breq[1]),.b_we(bwe[1]),.b_addr(baddr[1]),.b_wdata(bwdata[1]),.b_be(bbe[1]),.b_tmr(btmr[1]),.b_ack(ack),.b_rdata(rdata));
 always_comb begin
  ack=!rst&&!hold_bus&&breq[0]&&delay_left==0;
  rdata=baddr[0]^32'hbd3927a1^32'(serial);
 end
 always @(posedge clk)begin
  edge_no=edge_no+1;
  if(rst)begin
   if(refmem.wb_n!=0)reset_nonempty++;
   gold.delete();delay_left=0;
  end else begin
   assert(hold_cpu[0]===hold_cpu[1]&&iok[0]===iok[1]&&iabort[0]===iabort[1]&&dok[0]===dok[1]&&dabort[0]===dabort[1]&&dwait[0]===dwait[1]&&owned[0]===owned[1]&&hivecs[0]===hivecs[1])else $fatal(1,"answer/control mismatch edge%0d stage%0d",edge_no,stage);
   assert(refmem.wb_n===dut.wb_n&&refmem.wd_push===dut.wd_push&&refmem.st===dut.st&&refmem.nb_owned===dut.nb_owned&&refmem.nb_ack===dut.nb_ack&&refmem.dp_v===dut.dp_v&&refmem.ip_v===dut.ip_v&&refmem.ev_v===dut.ev_v)else $fatal(1,"state/ownership mismatch edge%0d",edge_no);
   assert(breq[0]===breq[1])else $fatal(1,"request cycle mismatch");
   if(breq[0])assert({bwe[0],baddr[0],bbe[0],btmr[0],bn8[0],bldm[0],bmeta[0]}==={bwe[1],baddr[1],bbe[1],btmr[1],bn8[1],bldm[1],bmeta[1]})else $fatal(1,"physical packet mismatch edge%0d",edge_no);
   if(breq[0]&&bwe[0])assert(bwdata[0]===bwdata[1])else $fatal(1,"write payload mismatch");
   if(refmem.wq_e&&!refmem.w_we&&dok[0])assert(ddata[0]===ddata[1])else $fatal(1,"data return mismatch");
   if(refmem.f_req&&iok[0])assert(idata[0]===idata[1])else $fatal(1,"fetch return mismatch");
   assert(refmem.wb_n==gold.size())else $fatal(1,"independent count mismatch");
   occupancy[refmem.wb_n]++;
   if(refmem.wbuf_v)begin
    assert({refmem.wbuf_a,refmem.wbuf_d,refmem.wbuf_be,refmem.wbuf_tmr}===gold[0])else $fatal(1,"reference descriptor mismatch");
    assert({dut.wbuf_a,dut.wbuf_d,dut.wbuf_be,dut.wbuf_tmr}===gold[0])else $fatal(1,"queue head mismatch edge%0d n%0d",edge_no,dut.wb_n);
   end
   if(refmem.st==refmem.S_WDRAIN&&ack)begin
    assert(gold.size()!=0)else $fatal(1,"unowned drain");old_word=gold.pop_front();pops++;
    signature={signature[56:0],signature[63:57]}^{baddr[0],bwdata[0]}^{56'd0,bbe[0],btmr[0]};
   end
   if(refmem.wd_push)begin
    new_word={refmem.w_addr,refmem.w_wdata,refmem.w_be,(refmem.w_addr[31:12]==20'h04000&&refmem.w_addr[11:4]==8'h10 ? (4'd1<<refmem.w_addr[3:2]):4'd0)};
    gold.push_back(new_word);pushes++;
    if(refmem.st==refmem.S_WDRAIN&&ack)begin simul++;simultaneous_at[refmem.wb_n]++;end
   end
   if(refmem.wb_full&&refmem.wq_e&&refmem.w_we&&!dok[0])begin full_refusals++;if(refmem.st==refmem.S_WDRAIN&&ack)full_pop_refusal++;end
   if(hold_cpu[0])held++;
   if(refmem.nb_slot&&!refmem.nb_ack)nb_held++;
   if(kill&&refmem.nb_owned)orphaned++;
   if(ack)begin serial++;delay_left=(serial*7+3)%19;if(!bwe[0])reads++;end
   else if(!hold_bus&&delay_left>0)delay_left--;
   if(iq)ifetches++;
   if(edge_no>160000)$fatal(1,"bounded leaf timeout");
  end
 end
 task automatic tickn(input integer n);repeat(n)@(negedge clk);endtask
 task automatic idle;
  dq=0;cq=0;iq=0;kill=0;
 endtask
 task automatic cp(input integer crn,input integer crm,input integer opc,input logic[31:0]v);
  while(hold_cpu[0])tickn(1);
  idle();cwe=1;cq=1;cop=16'((crn<<7)|(crm<<3)|opc);cd=v;tickn(1);cq=0;tickn(3);
 endtask
 task automatic setup;
  cp(6,0,0,32'h3f);cp(5,0,2,32'h3);cp(5,0,3,32'h3);cp(3,0,0,32'h1);cp(1,0,0,32'h1);
 endtask
 task automatic burst(input integer n,input integer salt);
  repeat(n)begin
   if(!hold_cpu[0])begin
    dq=!(salt==23 && refmem.wb_n>=6);dwe=1;be=4'((salt+edge_no)%15+1);
    da=(edge_no%4==0) ? 32'h04000100+32'((edge_no%16)&12):32'h02001000+32'((edge_no*13)%256);
    dd=32'h6ab135e7^32'(edge_no*197+salt);
   end
   tickn(1);
  end
 endtask
 task automatic drain;
  idle();hold_bus=0;
  while(refmem.wb_n!=0||refmem.st!=refmem.S_IDLE||refmem.dp_v||refmem.ip_v||refmem.ev_v)tickn(1);
  tickn(3);
 endtask
 generate if(MEM1)begin : tail_mapping
  always @(posedge clk)if(!rst)begin
   assert(3'(dut.g_wb_tail.wp-dut.g_wb_tail.rp)==3'(dut.wb_n==0?0:dut.wb_n-1))else $fatal(1,"tail pointer/count mapping");
   for(integer i=1;i<dut.wb_n;i++)assert(dut.g_wb_tail.tail[(integer'(dut.g_wb_tail.rp)+i-1)&7]==={refmem.wb_a[i],refmem.wb_d[i],refmem.wb_be[i],refmem.wb_tmr[i]})else $fatal(1,"valid tail descriptor mismatch");
  end
 end endgenerate
 initial begin
  for(integer i=0;i<9;i++)begin occupancy[i]=0;simultaneous_at[i]=0;end
  tickn(4);rst=0;tickn(4);setup();
  stage=1;hold_bus=1;burst(96,1);idle();tickn(8);assert(refmem.wb_n==(MEM1?8:1))else $fatal(1,"queue did not fill");
  stage=2;hold_bus=0;burst(2400,3);drain();burst(2400,23);drain();
  if(MEM1)for(integer level=1;level<=8;level++)begin
   hold_bus=1;burst(level,level+51);idle();tickn(3);
   assert(refmem.wb_n==level)else $fatal(1,"directed occupancy preparation");
   dq=1;dwe=1;da=32'h04000104+32'(level&3);dd=32'h81452f9a^32'(level);be=4'(level+1);tickn(1);
   dq=0;delay_left=0;hold_bus=0;tickn(1);drain();
  end
  stage=3;
  // Older buffered words drain while the following effective C0B0 word owns WB.
  hold_bus=1;burst(6,4);idle();cp(3,0,0,0);dq=1;dwe=1;da=32'h0400010a;dd=32'h00800080;be=12;tickn(1);hold_bus=0;
  tickn(60);idle();drain();
  // Cancel retirement ownership only; captured physical data still drains.
  stage=4;hold_bus=1;dq=1;dwe=1;da=32'h04000102;dd=32'h00000000;be=12;tickn(1);
  if(MEM1&&NB)while(!refmem.nb_owned)tickn(1);
  else tickn(2);
  kill=1;tickn(3);idle();hold_bus=0;drain();
  stage=5;cp(3,0,0,1);hold_bus=1;burst(5,9);idle();tickn(2);rst=1;tickn(3);rst=0;hold_bus=0;tickn(4);setup();burst(1800,11);drain();
  stage=6;
  // Actual uncached reads/fetches contend behind buffered writes.
  for(integer k=0;k<4000;k++)begin
   if(!hold_cpu[0])begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    dq=rng[3:0]<11;dwe=rng[6:4]<5;da=(rng[8]?32'h04000004:32'h02002000)+(rng[9]?32'd4:32'd0);dd=rng;be=4'((rng[13:10]%15)+1);iq=rng[15];ia=32'h02008000+{22'd0,rng[7:2],2'b00};kill=0;
   end
   tickn(1);
  end
  drain();
  $display("COVERAGE edges%0d push%0d pop%0d simultaneous%0d full%0d held%0d reset%0d read%0d ifetch%0d nbhold%0d orphan%0d",edge_no,pushes,pops,simul,full_refusals,held,reset_nonempty,reads,ifetches,nb_held,orphaned);
  assert(pushes>250&&pops>200&&full_refusals>30&&reset_nonempty>0&&reads>10&&ifetches>10)else $fatal(1,"inactive coverage");
  if(MEM1&&NB)assert(nb_held>0&&orphaned>0)else $fatal(1,"NCNB hold not covered");
  if(MEM1)begin
   for(integer i=0;i<9;i++)assert(occupancy[i]>0)else $fatal(1,"missing occupancy%0d",i);
   for(integer i=1;i<8;i++)assert(simultaneous_at[i]>0)else $fatal(1,"missing simultaneous occupancy%0d",i);
   assert(full_pop_refusal>0&&simultaneous_at[8]==0)else $fatal(1,"full admission/ACK boundary coverage");
  end else assert(simul==0)else $fatal(1,"legacy full pop incorrectly admitted push");
  $display("WBD_EQ_PASS MEM1%0d NB%0d edges%0d push%0d pop%0d simultaneous%0d full%0d hold%0d nbhold%0d orphan%0d resets%0d reads%0d ifetch%0d signature%h",MEM1,NB,edge_no,pushes,pops,simul,full_refusals,held,nb_held,orphaned,reset_nonempty,reads,ifetches,signature);
  for(integer i=0;i<9;i++)$display("OCCUPANCY %0d %0d SIMULTANEOUS %0d",i,occupancy[i],simultaneous_at[i]);
  $display("FULL_POP_REFUSAL %0d",full_pop_refusal);
  $finish;
 end
endmodule
