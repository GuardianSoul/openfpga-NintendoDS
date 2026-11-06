`timescale 1ns/1ps
module lane #(parameter int MODE=0,parameter bit FAST=0)(input logic clk,output bit done=0);
 import arm_pkg::*;
 a7_exec_meta_t meta;
 logic [4095:0] core_state;
 logic [1023:0] rf_state;
 integer metafd;
 logic rst=1,run=0,irq=0,ir,io,dr,dw,dok,wr,ww,wok=0,wen,ret;
 logic[31:0]ia,iq,da,dd,dq,wwd,wrd=0,wd,pc,psr;
 logic[3:0]db,wb;logic[17:2]wa_mem;logic[4:0]wa;
 logic iseq,iarm,iredirect,iconsume,xreq,xwe,xdone=0;
 logic[17:2]xa;logic[31:0]xrd=0;
 logic fr,fw,fn,fack=0,frvalid;logic[31:0]fa,fd,fq=0;logic[3:0]fb;
 logic[4:0]pst;logic[3:0]pk;logic[1:0]pesub;logic pph,pdm;
 logic[31:0]pins,ppc;logic[4:0]pmode;
 logic[31:0]mem[65536],mainmem[256],shadow[32];
 int cycle=0,nret=0,reads=0,writes=0,owned_read=0,data_attempt=0;
 int scenario=0,begin_pc,end_pc,done_pc,handler_pc,body_start=-1,body_end=-1;
 bit irq_sent=0,reset_sent=0;int reset_left=0;
 string image,prefix;integer statefd,datafd,edgefd,memfd,takefd;
`define CPU_PINS .clk,.rst,.run,.reset_pc(32'h03808000),.hivecs(1'b0),.irq,.fiq(1'b0),.wake(1'b0), \
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume), \
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok), \
 .dbg_wen(wen),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halted()
`define PROBE(C) assign pst=C.st;assign pk=C.k;assign pesub=C.esub;assign pph=C.ph;assign pdm=C.dm_rq;assign pins=C.ins;assign ppc=C.pc;assign pmode=C.cpsr[4:0];assign rf_state={C.rf[0],C.rf[1],C.rf[2],C.rf[3],C.rf[4],C.rf[5],C.rf[6],C.rf[7],C.rf[8],C.rf[9],C.rf[10],C.rf[11],C.rf[12],C.rf[13],C.rf[14],C.rf[15],C.rf[16],C.rf[17],C.rf[18],C.rf[19],C.rf[20],C.rf[21],C.rf[22],C.rf[23],C.rf[24],C.rf[25],C.rf[26],C.rf[27],C.rf[28],C.rf[29],C.rf[30],C.rf[31]};assign core_state={C.pc,C.cpsr,C.ins,C.tk,C.tboff,C.tpcal,C.halted,C.opa,C.opb,C.opc,C.opd,C.rdi,C.rv_q,C.r15_q,C.rdst_q,C.r15v_q,C.addr,C.nbase,C.rl,C.first,C.ldw,C.ph,C.mwait,C.wcnt,C.esub,C.dm_rq,C.pc_f,C.f_rq,C.d_v,C.e_v,C.d_pc,C.d_ins,C.d_boff,C.d_tk,C.d_pcal,C.wq_v,C.wq_a,C.wq_d,C.st,C.rdat,C.rdat_b,C.prod_q,C.spsr[0],C.spsr[1],C.spsr[2],C.spsr[3],C.spsr[4]};
 generate if(MODE==0)begin:g_old
 arm7_ds_before #(.WRAM_SWP_PIPE(FAST)) cpu(`CPU_PINS);
 assign meta='0;
 `PROBE(cpu)
 end else begin:g_new
 arm7_ds #(.WRAM_SWP_PIPE(FAST),.EXEC_META(MODE==2))cpu(.exec_meta(meta),`CPU_PINS);
 `PROBE(cpu)
 end endgenerate
 nds_arm7_port #(.WRAM_M10K(1))p7(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .w_req(wr),.w_we(ww),.w_addr(wa_mem),.w_be(wb),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(xreq),.x_we(xwe),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xrd),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(),.f_ifgen(),.f_ifword(),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(fack),.f_rvalid(frvalid),.f_rdata(fq),.wr_mon(1'b0),.wr_addr(32'd0));
 assign frvalid=fack&&!fw;
 a7_exec_data_t held;
 bit was_pending=0;
 always @(posedge clk) begin
  if(rst)begin assert(meta=='0)else $fatal(1,"META reset");was_pending=0;end
  else if(MODE!=2)assert(meta=='0)else $fatal(1,"META default off");
  else begin
   assert(meta.redirect==iredirect)else $fatal(1,"META redirect missing");
   if(meta.shift_step||meta.mul_step||meta.data_valid)
    assert(meta.owner.pc==ppc&&meta.owner.epoch==meta.epoch)else $fatal(1,"META execution identity");
   if(was_pending&&meta.data_pending)assert(meta.data==held)else $fatal(1,"META held descriptor");
   held=meta.data;was_pending=meta.data_pending&&!meta.data_valid;
   if(meta.shift_step||meta.mul_step)begin
    assert(meta.owner.valid&&run&&pph)else $fatal(1,"META internal owner/advance");
    $fdisplay(metafd,"I,%0d,%0d,%0d,%h,%b,%h,%b,%b,%0d,%0d",cycle,meta.owner.epoch,meta.owner.ordinal,meta.owner.pc,meta.owner.thumb,meta.owner.kind,meta.shift_step,meta.mul_step,meta.step,meta.steps);
   end
   if(meta.data_valid)begin
    assert(dok&&meta.owner.valid&&meta.data_pending)else $fatal(1,"META DATA owner/ACK");
    $fdisplay(metafd,"D,%0d,%0d,%0d,%h,%b,%h,%b,%h,%h,%h,%h,%h,%h,%b,%b,%b,%b,%0d,%0d,%0d,%h,%h,%h,%b,%h,%b,%b,%b,%h,%h",cycle,meta.owner.epoch,meta.owner.ordinal,meta.owner.pc,meta.owner.thumb,meta.owner.kind,meta.data.write,meta.data.size,meta.data.address,meta.data.bus_address,meta.data.write_value,meta.read_value,meta.data.be,meta.data.list,meta.data.swp,meta.data.first,meta.data.last,meta.data.beat,meta.data.beats,meta.data.wb_count,meta.data.mask,meta.data.effective_mask,meta.data.form,meta.data.user_bank,meta.data.bank,meta.data.pc_in_list,meta.data.pc_reg,meta.data.writeback,meta.data.writeback_value,meta.data.regnum);
   end
   if(meta.redirect)begin
    assert(iredirect&&meta.next_epoch==meta.epoch+16'd1)else $fatal(1,"META redirect epoch");
    $fdisplay(metafd,"R,%0d,%0d,%0d,%h,%b,%h,%0d",cycle,meta.epoch,meta.next_epoch,meta.frontend_address,meta.owner.valid,meta.owner.pc,meta.owner.ordinal);
   end
  end
 end
 wire reject_data=(scenario==1||scenario==3||scenario==4)&&dr&&da[31:24]==8'h03&&data_attempt%4!=3;
 wire answer=wr&&!rst&&!reject_data;
 wire swp_sample=pk==4'd5&&dok&&((pst==5'd1&&pph&&pdm)||(pst==5'd6)||(pst==5'd16));
 wire write_sample=pst==5'd16||(pst==5'd1&&pesub==2'd2);
 logic rq_w;logic[31:0]rq_a,rq_d;logic[3:0]rq_be;
 bit fpend=0;int fleft=0;logic fw_q;logic[31:0]fa_q,fd_q;logic[3:0]fb_q;
 always @(posedge clk)begin
  cycle++;
  wok<=answer;xdone<=xreq&&!rst;fack<=0;
  if(wr&&!rst)begin
   if(answer)begin
    wrd<=mem[wa_mem];
    if(ww)for(int b=0;b<4;b++)if(wb[b])mem[wa_mem][8*b+:8]<=wwd[8*b+:8];
    if(dr)$fdisplay(takefd,"%b,%h,%h,%h",ww,wa_mem,wb,ww?wwd:mem[wa_mem]);
   end
   if(dr)data_attempt++;
  end
  if(xreq&&!rst)begin
   if(xwe)$fatal(1,"unexpected BIOS write");
   xrd<=mem[xa];
  end
  if(rst)begin fpend=0;fleft=0;wok<=0;xdone<=0;end
  else if(!fpend&&fr&&!fack)begin
   fpend=1;fleft=3;fw_q=fw;fa_q=fa;fd_q=fd;fb_q=fb;
  end else if(fpend)begin
   assert(fr&&{fw,fa,fd,fb}=={fw_q,fa_q,fd_q,fb_q})else $fatal(1,"fabric owner changed");
   if(fleft==1)begin
    fack<=1;fq<=mainmem[fa_q[9:2]];fpend=0;
    if(fw_q)for(int b=0;b<4;b++)if(fb_q[b])mainmem[fa_q[9:2]][8*b+:8]<=fd_q[8*b+:8];
   end else fleft--;
  end
  if(!rst&&dr)begin rq_w<=dw;rq_a<=da;rq_d<=dd;rq_be<=db;end
  if(!rst&&dok&&((pst==5'd1&&pph&&pdm)||pst==5'd6||pst==5'd16||pst==5'd12))begin
   $fdisplay(datafd,"%h,%b,%h,%h",rq_a,rq_w,rq_be,rq_w?rq_d:dq);
  end
  if(!rst&&swp_sample)begin
   if(write_sample)begin
    assert(owned_read==1)else $fatal(1,"SWP_WRITE_WITHOUT_OWNED_READ");
    owned_read=0;writes++;
   end else begin
    assert(owned_read==0)else $fatal(1,"SWP_DUPLICATE_READ");
    owned_read=1;reads++;
    if(scenario==2&&!irq_sent)begin irq<=1;irq_sent=1;end
   end
  end
  if(irq&&pmode==5'b10010)irq<=0;
  if(scenario==5&&cycle==100)run<=0;
  if(scenario==5&&cycle==108)run<=1;
  if(!rst)$fdisplay(edgefd,"%0d,%h,%h,%h,%b,%b,%b,%b,%h,%h,%h,%b,%b,%h,%b,%b,%h,%h,%b,%b,%b,%b,%h,%h,%b",cycle,pst,ppc,pesub,pph,dr,dw,dok,da,db,dd,ir,io,ia,wen,ret,wd,psr,iseq,iarm,iredirect,iconsume,wa,pc,run);
  if(!rst&&!reset_sent&&((scenario==3&&dr&&pk==5&&!dw)||(scenario==4&&swp_sample&&!write_sample)))begin
   rst<=1;run<=0;reset_left=6;reset_sent=1;irq<=0;
   $fdisplay(statefd,"RESET");$fdisplay(datafd,"RESET");$fdisplay(edgefd,"RESET");$fdisplay(takefd,"RESET");
   $fdisplay(metafd,"RESET");
   owned_read=0;reads=0;writes=0;nret=0;body_start=-1;body_end=-1;data_attempt=0;
   for(int k=0;k<32;k++)shadow[k]=0;
  end else if(reset_left>0)begin
   reset_left--;
   if(reset_left==0)begin rst<=0;run<=1;end
  end
 end
 always @(negedge clk)if(!rst&&!done)begin
  if(wen)shadow[wa]=wd;
  if(ret)begin
   nret++;$fwrite(statefd,"%h,%h",pc,psr);
   for(int j=0;j<32;j++)$fwrite(statefd,",%h",shadow[j]);$fwrite(statefd,"\n");
   if(pc==32'(begin_pc)&&body_start<0)body_start=cycle;
   if(pc==32'(end_pc)&&body_end<0)body_end=cycle;
   if(pc==32'(done_pc))begin run=0;done=1;end
  end
 end
 initial begin
  void'($value$plusargs("scenario=%d",scenario));
  if(!$value$plusargs("img=%s",image)||!$value$plusargs("out=%s",prefix)||!$value$plusargs("begin=%h",begin_pc)||!$value$plusargs("end=%h",end_pc)||!$value$plusargs("done=%h",done_pc)||!$value$plusargs("handler=%h",handler_pc))$fatal(1,"missing input");
  statefd=$fopen($sformatf("%s-m%0d.state",prefix,MODE+3*int'(FAST)),"w");datafd=$fopen($sformatf("%s-m%0d.data",prefix,MODE+3*int'(FAST)),"w");edgefd=$fopen($sformatf("%s-m%0d.edge",prefix,MODE+3*int'(FAST)),"w");takefd=$fopen($sformatf("%s-m%0d.take",prefix,MODE+3*int'(FAST)),"w");memfd=$fopen($sformatf("%s-m%0d.mem",prefix,MODE+3*int'(FAST)),"w");
  metafd=$fopen($sformatf("%s-m%0d.meta",prefix,MODE+3*int'(FAST)),"w");
  for(int j=0;j<32;j++)shadow[j]=0;
  for(int j=0;j<65536;j++)mem[j]=0;
  for(int j=0;j<256;j++)mainmem[j]=32'h98765400+32'(j);
  $readmemh(image,mem,32'h8000/4);
  mem[32'h18018/4]=32'he59ff000;mem[32'h18020/4]=32'(handler_pc);
  repeat(8)@(negedge clk);rst=0;run=1;
  wait(done);repeat(4)@(negedge clk);
  assert(owned_read==0&&reads==writes&&reads>0)else $fatal(1,"SWP final cardinality");
  if(scenario==2)assert(irq_sent&&shadow[12]==1)else $fatal(1,"IRQ lost");
  if(scenario==3||scenario==4)assert(reset_sent)else $fatal(1,"reset absent");
  for(int k=0;k<65536;k++)$fdisplay(memfd,"%h",mem[k]);
  for(int k=0;k<256;k++)$fdisplay(memfd,"%h",mainmem[k]);
  $display("META_PASS mode%0d scenario%0d cycles%0d body%0d states%0d reads%0d writes%0d",MODE+3*int'(FAST),scenario,cycle,body_end-body_start,nret,reads,writes);
  $fclose(statefd);$fclose(datafd);$fclose(edgefd);$fclose(takefd);$fclose(memfd);$fclose(metafd);
 end
endmodule
module tb;
 logic clk=0;always #5 clk=~clk;wire[5:0]done;
 genvar m;
 generate for(m=0;m<6;m=m+1)begin:g
 lane #(.MODE(m%3),.FAST(m>=3))u(.clk,.done(done[m]));
 end endgenerate
 always @(posedge clk)if(!g[0].u.rst)begin
  assert(g[0].u.rf_state==g[1].u.rf_state&&g[0].u.rf_state==g[2].u.rf_state)else $fatal(1,"META_BEHAVIOR_RF0");
  assert(g[0].u.core_state==g[1].u.core_state&&g[0].u.core_state==g[2].u.core_state)else $fatal(1,"META_BEHAVIOR_STATE0");
  assert(g[3].u.rf_state==g[4].u.rf_state&&g[3].u.rf_state==g[5].u.rf_state)else $fatal(1,"META_BEHAVIOR_RF1");
  assert(g[3].u.core_state==g[4].u.core_state&&g[3].u.core_state==g[5].u.core_state)else $fatal(1,"META_BEHAVIOR_STATE1");
 end
 initial begin wait(&done);repeat(8)@(negedge clk);$display("META_ALL_PASS");$finish;end
 initial begin #50000000;$fatal(1,"META timeout");end
endmodule
