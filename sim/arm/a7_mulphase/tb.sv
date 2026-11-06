`timescale 1ps/1ps
`default_nettype none
module tb;
 import arm_pkg::*;
 logic clk=0,clk_mem=0,clk_cram=0,rst=1,run=0;
 always #4973 clk_mem=~clk_mem;
 initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
 always @(clk_mem)clk_cram<=#6838 clk_mem;
 logic initialized,idle;wire[79:0]pins;integer preads,pwrites;
 logic ir,io,dr,dw,dok,fr,fn,fw,ack,rv,wr,ww,wok=0,wen,ret;
 logic[31:0]ia,iq,da,dd,dq,fa,fd,fq,wwd,wrd=0,wd,pc,psr;
 logic[3:0]db,fb,wb;logic[17:2]wa_mem;logic[4:0]wa;
 logic iseq,iarm,iredirect,iconsume,fseq;logic[1:0]fgen,fword;
 logic[31:0]ram[0:16383],words[0:1023],wrapper[0:23],shadow[0:31];
 int loops,rs,m_ref,region,entry,caseid,wrong_operand=0,detail=0;
 int cycle=0,start_tick=-1,end_tick=-1,mul_steps=0,mul_retired=0,fetches=0;
 int i_during_mul=0,consume_during_mul=0,phys_requests=0;
 int sym_call,sym_done,sym_rs,sym_loops,sym_entry;
 bit active=0,finished=0;string kernel_image,wrapper_image,boot_image,out;
 integer edgefd=0,statefd=0,datafd=0;
 arm7_ds #(.MAIN_IF_FLOW(1),.WRAM_SWP_PIPE(1))cpu(
 .clk,.rst,.run,.reset_pc(32'h03808000),.hivecs(1'b0),.irq(1'b0),.fiq(1'b0),.wake(1'b0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),.exec_meta(),.stm4_request(),.stm4_accept(),
 .dbg_wen(wen),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halted());
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.MAIN_IF_REJOIN(1),.MAIN_STORE_TURN(1))p7(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),.i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),.f_ifseq(fseq),.f_ifgen(fgen),.f_ifword(fword),
 .w_req(wr),.w_we(ww),.w_addr(wa_mem),.w_be(wb),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1'b0),.x_rdata(32'd0),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(ack),.f_rvalid(rv),.f_rdata(fq),.wr_mon(1'b0),.wr_addr(32'd0));
 physical_before #(.IF_STREAM(1),.FAB_FLOW(1))transport(.clk_sys(clk),.clk_mem,.clk_cram,.rst_sys(rst),.rst_mem(rst),
 .a9_req(1'b0),.a9_we(1'b0),.a9_n8(1'b0),.a9_ldm(1'b0),.a9_addr(32'd0),.a9_wdata(32'd0),.a9_be(4'hF),.a9_ack(),.a9_rvalid(),.a9_rdata(),
 .a7_req(fr),.a7_we(fw),.a7_n4(fn),.a7_ifseq(fseq),.a7_ifgen(fgen),.a7_ifword(fword),.a7_addr(fa),.a7_wdata(fd),.a7_ack(ack),.a7_rvalid(rv),.a7_rdata(fq),
 .initialized,.idle,.pins,.reads(preads),.writes(pwrites));
 function automatic bit in_body(input logic[31:0]a);
  return a>=32'(entry+4)&&a<32'(entry+260);
 endfunction
 function automatic logic[31:0]memory(input logic[31:0]a);
  if(a[31:24]==8'h03)return ram[a[15:2]];
  if(a>=32'h02fcd000&&a<32'h02fce000)return words[(a-32'h02fcd000)>>2];
  return 0;
 endfunction
 always @(posedge clk)begin
  cycle<=cycle+1;wok<=wr&&!rst;
  if(wr&&!rst)begin
   wrd<=ram[wa_mem[15:2]];
   if(ww)for(int b=0;b<4;b++)if(wb[b])ram[wa_mem[15:2]][8*b+:8]<=wwd[8*b+:8];
  end
  if(!rst&&iconsume)begin
   assert(iq==memory(ia))else $fatal(1,"MUL_FETCH_WORD %h got%h want%h",ia,iq,memory(ia));
   if(active)fetches++;
  end
  if(!rst&&cpu.pipe_fire&&cpu.e_mul)begin
   assert(cpu.opa==3&&cpu.opb==32'(rs)&&cpu.mterm==3'(m_ref))else $fatal(1,"MUL_INPUT_MAPPING Rm%h Rs%h m%0d",cpu.opa,cpu.opb,cpu.mterm);
   if(active&&in_body(cpu.pc)&&(cpu.esub==0||cpu.esub==1))mul_steps++;
  end
  if(active&&ir&&cpu.e_mul&&cpu.e_busy)i_during_mul++;
  if(active&&iconsume&&cpu.e_mul&&cpu.e_busy)consume_during_mul++;
  if(active&&fr&&ack)phys_requests++;
  if(active&&cpu.dm_rq&&dok)$fdisplay(datafd,"%0d,%h,%h,%b,%h,%h",cycle,cpu.pc,da,dw,dd,dq);
  if(detail&&active&&(cpu.e_mul||in_body(ia)||in_body(cpu.pc)))
   $fdisplay(edgefd,"%0d,%h,%h,%h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%h,%h",
    cycle,cpu.pc,cpu.ins,ia,iq,cpu.st,cpu.ph,cpu.esub,cpu.wcnt,cpu.e_mul,cpu.e_busy,cpu.pipe_fire,cpu.if_wait,
    ir,io,iseq,iconsume,cpu.mterm,iredirect,p7.flow_left,p7.flow_a,p7.flow_sc,p7.flow_v,fa,fr,ack,rv,fq,fn,fw,cpu.opa,cpu.opb);
 end
 always @(negedge clk)if(!rst)begin
  if(wen)shadow[wa]=wd;
  if(ret&&!finished)begin
   if(pc==32'(sym_call))begin active=1;start_tick=cycle;end
   if(active)begin
    $fwrite(statefd,"%0d,%h,%h",cycle,pc,psr);for(int r=0;r<32;r++)$fwrite(statefd,",%h",shadow[r]);$fwrite(statefd,"\n");
    if(in_body(pc))mul_retired++;
   end
   if(pc==32'(sym_done))begin end_tick=cycle;active=0;finished=1;run=0;end
  end
 end
 task automatic invocation(input int address,input int n);
  int b;b=(address&65535)/4;
  assert(ram[b]==32'(n)&&ram[b+1]==3&&ram[b+2]==32'(rs))else $fatal(1,"MUL_SNAPSHOT_INPUT");
  assert(ram[b+16]==0&&ram[b+17]==3&&ram[b+18]==32'(rs)&&ram[b+19]==32'(3*rs))else $fatal(1,"MUL_SNAPSHOT_OUTPUT");
  for(int i=4;i<15;i++)assert(ram[b+i]==ram[b+16+i])else $fatal(1,"MUL_PRESERVED_REGISTER %0d",i);
  assert(ram[b+4]==32'(entry)&&ram[b+14]==32'h03800788)else $fatal(1,"MUL_CALL_OWNER");
  assert((ram[b+31]&32'hf0000000)==32'h60000000&&(ram[b+31]&32'h0fffffff)==(ram[b+15]&32'h0fffffff))else $fatal(1,"MUL_FINAL_FLAGS");
 endtask
 initial begin
  if(!$value$plusargs("kernel=%s",kernel_image)||!$value$plusargs("wrapper=%s",wrapper_image)||!$value$plusargs("boot=%s",boot_image)||
     !$value$plusargs("out=%s",out)||!$value$plusargs("loops=%d",loops)||!$value$plusargs("rs=%h",rs)||
     !$value$plusargs("case=%d",caseid)||!$value$plusargs("region=%d",region)||!$value$plusargs("call=%h",sym_call)||
     !$value$plusargs("done=%h",sym_done)||!$value$plusargs("sym_rs=%h",sym_rs)||!$value$plusargs("sym_loops=%h",sym_loops)||!$value$plusargs("sym_entry=%h",sym_entry))$fatal(1,"missing fixture input");
  void'($value$plusargs("detail=%d",detail));void'($value$plusargs("wrong_operand=%d",wrong_operand));
  m_ref=caseid+1;entry=region?32'h02fcd000:32'h03800640;
  for(int i=0;i<16384;i++)ram[i]=0;for(int i=0;i<1024;i++)words[i]=0;for(int i=0;i<32;i++)shadow[i]=0;
  $readmemh(kernel_image,words);$readmemh(wrapper_image,wrapper);$readmemh(boot_image,ram,32'h8000/4);
  for(int i=0;i<68;i++)ram[32'h640/4+i]=words[i];for(int i=0;i<24;i++)ram[32'h750/4+i]=wrapper[i];
  ram[(sym_rs&65535)/4]=wrong_operand?32'h7f:32'(rs);ram[(sym_loops&65535)/4]=32'(loops);ram[(sym_entry&65535)/4]=32'(entry);
  for(int j=0;j<1024;j++)begin transport.chips.m0.mem[(32'h003cd000)/4+j]=words[j][15:0];transport.chips.m1.mem[(32'h003cd000)/4+j]=words[j][31:16];end
  statefd=$fopen({out,".state"},"w");datafd=$fopen({out,".data"},"w");edgefd=$fopen({out,".edge"},"w");
  if(detail)$fdisplay(edgefd,"cycle,pc,ins,ia,iq,st,ph,esub,wcnt,e_mul,e_busy,pipe_fire,if_wait,ir,io,iseq,consume,mterm,redirect,flow_left,flow_a,flow_sc,flow_v,fa,fr,ack,rv,fq,fn,fw,opa,opb");
  repeat(8)@(negedge clk);rst=0;wait(initialized);repeat(8)@(negedge clk);run=1;
  wait(finished);wait(!fr&&idle);repeat(3)@(negedge clk);
  invocation(32'h03802000,1);invocation(32'h03802080,loops);
  assert(mul_steps==m_ref*loops*64&&mul_retired==loops*64&&consume_during_mul==0)else $fatal(1,"MUL_ADVANCE_COUNT steps%0d expected%0d retires%0d",mul_steps,m_ref*loops*64,mul_retired);
  assert(start_tick>0&&end_tick>start_tick&&shadow[0]==32'(3*rs))else $fatal(1,"MUL_RETURN_INTERVAL");
  for(int i=0;i<68;i++)assert(ram[32'h640/4+i]==words[i])else $fatal(1,"MUL_CODE_CHANGED");
  assert(pwrites==0)else $fatal(1,"MUL_MAIN_WRITE");
  $display("MUL_PHASE_PASS case%0d region%0d loops%0d elapsed%0d mul_steps%0d retires%0d i_internal%0d fetches%0d logical_packets%0d physical%0d",
   caseid,region,loops,end_tick-start_tick,mul_steps,mul_retired,i_during_mul,fetches,phys_requests,preads);
  $fclose(statefd);$fclose(datafd);$fclose(edgefd);$finish;
 end
 initial begin #20000000000;$fatal(1,"bounded MUL fixture timeout");end
endmodule
