`timescale 1ns/1ps
module lane #(parameter int MODE=0,parameter bit FAST=0)(input logic clk,output bit done=0);
 import arm_pkg::*;
 logic rst_c=1,rst_p=1,run=0,irq=0,ir,io,dr,dw,dok,wr,ww,wok=0,wen,ret;
 logic[31:0]ia,iq,da,dd,dq,wwd,wrd=0,wd,pc,psr;
 logic[3:0]db,wb;logic[17:2]wa_mem;logic[4:0]wa;
 logic iseq,iarm,iredirect,iconsume,xreq,xwe,xdone=0;
 logic[17:2]xa;logic[31:0]xrd=0;
 logic fr,fw,fn,fack=0,frvalid;logic[31:0]fa,fd,fq=0;logic[3:0]fb;
 logic[4:0]pst;logic[3:0]pk;logic[1:0]pesub;logic pph,pdm,pifwait;
 logic[31:0]pins,ppc;logic[4:0]pmode;
 logic[4095:0]core_state;logic[1023:0]rf_state,rfb_state;
 a7_exec_meta_t observation;
 a7_stm4_meta_t request_meta,answer_owner,posted_owner,accepted_owner,physical_done;
 logic list_accept;
 logic[31:0]mem[65536],mainmem[256],shadow[32],eligible_pc[32];
 int cycle=0,nret=0,scenario=0,done_pc,handler_pc,eligible_n;
 int faults=0,requests=0,accepts=0,admissions=0,drains=0,turns=0,retries=0,scalar_admits=0;
 int pause_drains=0,cpu_reset_drains=0;
 logic rq_w;logic[31:0]rq_a,rq_d;logic[3:0]rq_be;
 int pause_left=0,reset_left=0;bit pause_sent=0,reset_sent=0,irq_sent=0;
 bit cpu_done=0;
 bit fpend=0;int fleft=0;logic fw_q;logic[31:0]fa_q,fd_q;logic[3:0]fb_q;
 int ref_beat=0; a7_stm4_meta_t want,ref_answer='0,ref_post='0;
 string image,eligible_file,prefix;integer statefd,datafd,edgefd,memfd,takefd,metafd;
`define PINS .clk,.rst(rst_c),.run({run,1'b0}),.reset_pc0(32'd0),.reset_pc1(32'h03808000),.hivecs7(1'b0),.irq({irq,1'b0}),.fiq(2'd0),.wake7(1'b0), \
 .b9_ack(1'b0),.b9_rdata(32'd0),.b9_wnext(1'b0), \
 .a7_i_req(ir),.a7_i_addr(ia),.a7_i_rdata(iq),.a7_i_ok(io),.a7_i_seq(iseq),.a7_i_arm(iarm),.a7_i_redirect(iredirect),.a7_i_consume(iconsume), \
 .a7_d_req(dr),.a7_d_we(dw),.a7_d_be(db),.a7_d_addr(da),.a7_d_wdata(dd),.a7_d_rdata(dq),.a7_d_ok(dok), \
 .a7_exec_meta(observation),.dbg_wen(wen),.dbg_wa(wrapper_wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr)
 wire[5:0]wrapper_wa;assign wa=wrapper_wa[4:0];
`include "probe.svh"
`include "instances.svh"
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_STORE_TURN(1),.MAIN_IF_FLOW(1),.MAIN_IF_QUAD(1),.MAIN_IF_EARLY(1))p7(
 .clk,.rst(rst_p),.wramcnt(2'd3),.biosprot(16'd0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .w_req(wr),.w_we(ww),.w_addr(wa_mem),.w_be(wb),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(xreq),.x_we(xwe),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xrd),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(),.f_ifgen(),.f_ifword(),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),
 .f_ack(fack),.f_rvalid(frvalid),.f_rdata(fq),.wr_mon(1'b0),.wr_addr(32'd0));
 assign frvalid=fack&&!fw&&fn;
 wire admit=!rst_p&&dr&&dw&&!p7.dw&&p7.dreg==0&&(!p7.wb_v||p7.main_store_turn);
 wire physical_ack=!rst_p&&p7.busy&&p7.busy_w&&fack;
 generate if(MODE==1)begin:g_owner_default
 arm7_stm4_owner owner(.clk,.rst_cpu(rst_c),.rst_port(rst_p),.request_meta,.write_admit(admit),.cpu_accept(list_accept),.physical_ack,
 .answer_owner,.posted_owner,.accepted_owner,.physical_done);
 end else begin:g_owner_explicit
 arm7_stm4_owner #(.ENABLE(MODE==3))owner(.clk,.rst_cpu(rst_c),.rst_port(rst_p),.request_meta,
 .write_admit(admit),.cpu_accept(list_accept),.physical_ack,.answer_owner,.posted_owner,.accepted_owner,.physical_done);
 end endgenerate
 function automatic bit positive(input logic[31:0]a);
  for(int i=0;i<32;i++)if(i<eligible_n&&eligible_pc[i]==a)return 1;
  return 0;
 endfunction
 wire actual_accept=!rst_c&&dok&&((pst==1&&pph&&run&&!pifwait&&pdm&&pesub==1&&pk==9)||pst==12);
 wire expected_accept=actual_accept&&positive(ppc);
 always_comb begin
  want='0;
  if(!rst_c&&dr&&dw&&positive(ppc))begin want.valid=1;want.beat=2'(ref_beat);end
 end
 task automatic fault(input string why);
  faults++;if(faults<=4)$display("STM_METADATA_FAULT mode%0d c%0d %s",MODE+4*int'(FAST),cycle,why);
 endtask
 always @(posedge clk)if(!done)begin
  cycle++;
  assert(observation=='0)else $fatal(1,"FULL402_OBSERVATION_ACTIVATED");
  if(MODE!=3)begin
   if({request_meta,list_accept,answer_owner,posted_owner,accepted_owner,physical_done}!='0)fault("default/off nonzero");
  end else begin
   if(request_meta!==want)fault("request beat/eligibility");
   if(list_accept!==expected_accept)fault("qualified CPU accept");
   if(!rst_c&&!rst_p&&answer_owner!==ref_answer)fault("answer owner");
   if(!rst_p&&posted_owner!==ref_post)fault("posted owner");
   if(accepted_owner!==((!rst_c&&!rst_p&&expected_accept)?ref_answer:a7_stm4_meta_t'('0)))fault("accepted old owner");
   if(physical_done!==((!rst_p&&physical_ack)?ref_post:a7_stm4_meta_t'('0)))fault("physical old owner");
  end
  if(!rst_c&&dr)begin
   if(want.valid)requests++;
   if(want.valid&&!admit)retries++;
  end
  if(expected_accept)begin accepts++;ref_beat=(ref_beat+1)%4;end
  if(rst_c)ref_beat=0;
  if(physical_ack)begin
   if(ref_post.valid)drains++;
   if(ref_post.valid&&!run)pause_drains++;
   if(ref_post.valid&&rst_c)cpu_reset_drains++;
   $fdisplay(metafd,"ACK,%0d,%h,%h,%h,%h",cycle,fa,fd,ref_post,physical_done);
  end
  if(admit)begin
   admissions++;if(!want.valid)scalar_admits++;
   if(p7.main_store_turn)turns++;
   $fdisplay(metafd,"ADMIT,%0d,%h,%h,%h,%h",cycle,da,dd,want,request_meta);
  end
  if(rst_c||rst_p)ref_answer='0;
  else begin if(expected_accept)ref_answer='0;if(admit)ref_answer=want;end
  if(rst_p)ref_post='0;
  else begin if(physical_ack)ref_post='0;if(admit)ref_post=want;end
  wok<=wr&&!rst_p;xdone<=xreq&&!rst_p;fack<=0;
  if(wr&&!rst_p)begin
   wrd<=mem[wa_mem];
   if(ww)for(int b=0;b<4;b++)if(wb[b])mem[wa_mem][8*b+:8]<=wwd[8*b+:8];
   if(dr)$fdisplay(takefd,"%b,%h,%h,%h",ww,wa_mem,wb,ww?wwd:mem[wa_mem]);
  end
  if(xreq&&!rst_p)begin if(xwe)$fatal(1,"BIOS write");xrd<=mem[xa];end
  if(rst_p)begin fpend=0;fleft=0;wok<=0;xdone<=0;end
  else if(!fpend&&fr&&!fack)begin
   assert(!fn)else $fatal(1,"fixture has no MAIN instruction code");
   fpend=1;fleft=4+(scenario==1?8:0);fw_q=fw;fa_q=fa;fd_q=fd;fb_q=fb;
  end
  else if(fpend)begin
   assert(fr&&{fw,fa,fd,fb}=={fw_q,fa_q,fd_q,fb_q})else $fatal(1,"physical packet changed");
   if(fleft==1)begin fack<=1;fq<=mainmem[fa_q[9:2]];fpend=0;
    if(fw_q)for(int b=0;b<4;b++)if(fb_q[b])mainmem[fa_q[9:2]][8*b+:8]<=fd_q[8*b+:8];
   end else fleft--;
  end
  if(!rst_c&&dr)begin rq_w<=dw;rq_a<=da;rq_d<=dd;rq_be<=db;end
  if(!rst_c&&actual_accept)$fdisplay(datafd,"%h,%h,%h,%b,%h,%h",ppc,pins,rq_a,rq_w,rq_d,dq);
  if(!rst_c)$fdisplay(edgefd,"%0d,%h,%h,%h,%b,%b,%b,%b,%h,%h,%h,%b,%b,%h,%b,%b,%h,%h,%b,%b,%b,%b,%h,%h,%b,%b,%h,%h,%h,%b",
    cycle,pst,ppc,pesub,pph,dr,dw,dok,da,db,dd,ir,io,ia,wen,ret,wd,psr,iseq,iarm,iredirect,iconsume,wa,pc,run,fr,fa,fd,fb,fack);
  if(!rst_c&&scenario==2&&!irq_sent&&expected_accept&&ref_beat==1)begin irq<=1;irq_sent=1;end
  if(irq&&pmode==5'h12)begin assert(ref_beat==0)else $fatal(1,"IRQ entered inside STM list");irq<=0;end
  if(!rst_c&&scenario==3&&!pause_sent&&admit&&want.valid)begin run<=0;pause_left=12;pause_sent=1;end
  if(pause_left>0)begin pause_left--;if(pause_left==0)run<=1;end
  if(!rst_c&&!reset_sent&&((scenario==4&&admit&&want.valid)||
      (scenario==5&&physical_ack&&ref_post.valid)))begin
   rst_c<=1;if(scenario==4)rst_p<=1;run<=0;reset_left=8;reset_sent=1;irq<=0;
   $fdisplay(statefd,"RESET");$fdisplay(datafd,"RESET");$fdisplay(edgefd,"RESET");$fdisplay(takefd,"RESET");
   for(int i=0;i<32;i++)shadow[i]=0;
  end else if(reset_left>0)begin reset_left--;if(reset_left==0)begin rst_c<=0;rst_p<=0;run<=1;end end
 end
 always @(negedge clk)if(!rst_c&&!cpu_done)begin
  if(wen)shadow[wa]=wd;
  if(ret)begin
   nret++;$fwrite(statefd,"%h,%h",pc,psr);
   for(int j=0;j<32;j++)$fwrite(statefd,",%h",shadow[j]);$fwrite(statefd,"\n");
   if(pc==32'(done_pc))begin run=0;cpu_done=1;end
  end
 end
 initial begin
  void'($value$plusargs("scenario=%d",scenario));
  if(!$value$plusargs("img=%s",image)||!$value$plusargs("eligible=%s",eligible_file)||
     !$value$plusargs("eligible_n=%d",eligible_n)||!$value$plusargs("out=%s",prefix)||
     !$value$plusargs("done=%h",done_pc)||!$value$plusargs("handler=%h",handler_pc))$fatal(1,"missing input");
  statefd=$fopen($sformatf("%s-m%0d.state",prefix,MODE+4*int'(FAST)),"w");
  datafd=$fopen($sformatf("%s-m%0d.data",prefix,MODE+4*int'(FAST)),"w");
  edgefd=$fopen($sformatf("%s-m%0d.edge",prefix,MODE+4*int'(FAST)),"w");
  takefd=$fopen($sformatf("%s-m%0d.take",prefix,MODE+4*int'(FAST)),"w");
  memfd=$fopen($sformatf("%s-m%0d.mem",prefix,MODE+4*int'(FAST)),"w");
  metafd=$fopen($sformatf("%s-m%0d.meta",prefix,MODE+4*int'(FAST)),"w");
  for(int j=0;j<32;j++)begin shadow[j]=0;eligible_pc[j]='1;end
  for(int j=0;j<65536;j++)mem[j]=0;
  for(int j=0;j<256;j++)mainmem[j]=32'h98765400+32'(j);
  $readmemh(image,mem,32'h8000/4);$readmemh(eligible_file,eligible_pc);
  mem[32'h18018/4]=32'he59ff000;mem[32'h18020/4]=32'(handler_pc);
  repeat(8)@(negedge clk);rst_c=0;rst_p=0;run=1;
  wait(cpu_done);repeat(20)@(negedge clk);
  assert(accepts>0&&turns>0&&scalar_admits>0)else $fatal(1,"required path absent");
  if(scenario==2)assert(irq_sent&&shadow[11]==1)else $fatal(1,"IRQ absent/lost");
  if(scenario==3)assert(pause_sent&&pause_drains>0)else $fatal(1,"pause/posted drain absent");
  if(scenario==4||scenario==5)assert(reset_sent)else $fatal(1,"reset absent");
  if(scenario==5)assert(cpu_reset_drains>0)else $fatal(1,"CPU reset lost physical owner");
  for(int k=0;k<65536;k++)$fdisplay(memfd,"%h",mem[k]);
  for(int k=0;k<256;k++)$fdisplay(memfd,"%h",mainmem[k]);
  $display("STM_LANE_PASS mode%0d scenario%0d cycles%0d states%0d accepts%0d requests%0d admits%0d drains%0d turns%0d retries%0d faults%0d",
    MODE+4*int'(FAST),scenario,cycle,nret,accepts,requests,admissions,drains,turns,retries,faults);
  $fclose(statefd);$fclose(datafd);$fclose(edgefd);$fclose(takefd);$fclose(memfd);$fclose(metafd);
  done=1;
 end
endmodule
module tb;
 logic clk=0;always #5 clk=~clk;wire[7:0]done;
 generate for(genvar m=0;m<8;m++)begin:g
 lane #(.MODE(m%4),.FAST(m>=4))u(.clk,.done(done[m]));
 end endgenerate
 always @(posedge clk)if(!g[0].u.rst_c)begin
  assert(g[0].u.core_state==g[1].u.core_state&&g[0].u.core_state==g[2].u.core_state&&g[0].u.core_state==g[3].u.core_state)else $fatal(1,"STM_BEHAVIOR_STATE0");
  assert(g[0].u.rf_state==g[1].u.rf_state&&g[0].u.rf_state==g[2].u.rf_state&&g[0].u.rf_state==g[3].u.rf_state)else $fatal(1,"STM_BEHAVIOR_RF0");
  assert(g[0].u.rfb_state==g[1].u.rfb_state&&g[0].u.rfb_state==g[2].u.rfb_state&&g[0].u.rfb_state==g[3].u.rfb_state)else $fatal(1,"STM_BEHAVIOR_RFB0");
  assert(g[4].u.core_state==g[5].u.core_state&&g[4].u.core_state==g[6].u.core_state&&g[4].u.core_state==g[7].u.core_state)else $fatal(1,"STM_BEHAVIOR_STATE1");
  assert(g[4].u.rf_state==g[5].u.rf_state&&g[4].u.rf_state==g[6].u.rf_state&&g[4].u.rf_state==g[7].u.rf_state)else $fatal(1,"STM_BEHAVIOR_RF1");
  assert(g[4].u.rfb_state==g[5].u.rfb_state&&g[4].u.rfb_state==g[6].u.rfb_state&&g[4].u.rfb_state==g[7].u.rfb_state)else $fatal(1,"STM_BEHAVIOR_RFB1");
 end
 initial begin
  wait(&done);repeat(8)@(negedge clk);
  $display("STM_BEHAVIOR_ALL_PASS");
  if(g[3].u.faults+g[7].u.faults>0)$fatal(1,"STM_METADATA_MUTATION_CAUGHT after complete behavior proof");
  $display("STM_METADATA_ALL_PASS");$finish;
 end
 initial begin #50000000;$fatal(1,"STM timeout");end
endmodule
