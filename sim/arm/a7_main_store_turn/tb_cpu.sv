// physical_transport is the prior pinned real fabric/arbiter/PSRAM fixture.
// Only this wrapper, WRAM/BIOS helpers and passive observation are new.
`timescale 1ps/1ps
module cpu_lane #(parameter MODE=0)(input logic clk,clk_mem,clk_cram,rst,output logic done=0);
 logic run=0,ir,io,dr,dw,dok,fr,fn,fw,ack,rv,wr,ww,wok=0,wen,ret,irq=0,irq_sent=0;
 logic[31:0]ia,iq,da,dd,dq,fa,fd,fq,wwd,wrd=0,wd,pc,psr;
 logic[3:0]db,fb,wb;logic[17:2]wa_mem;logic[4:0]wa;
 logic iseq,iarm,iredirect,iconsume,fseq,xdone=0,xreq,xwe;
 logic[1:0]fgen,fword;logic[17:2]xa;logic[31:0]xrd=0;
 logic initialized,idle;wire[79:0]pins;integer preads,pwrites;
 logic rq_w=0;logic[31:0]rq_a=0,rq_d=0;logic[3:0]rq_be=0;
 logic[31:0]wram[4096],shadow[32];
 int cycle=0,nret=0,data_count=0,write_count=0,turns=0;
 int endpoint,fail_pc,irq_pc,loops=4,irq_enable=0;
 string image,prefix;integer statefd,datafd,edgefd,memfd;
 arm7_ds #(.MAIN_IF_FLOW(1))cpu(.clk,.rst,.run,.reset_pc(32'h03808000),.hivecs(1'b0),.irq,.fiq(1'b0),.wake(1'b0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .dbg_wen(wen),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halted());
`define PORT_PINS .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0), \
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume), \
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok), \
 .w_req(wr),.w_we(ww),.w_addr(wa_mem),.w_be(wb),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd), \
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0), \
 .x_req(xreq),.x_we(xwe),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xrd),.inv(1'b0),.inv_addr(16'd0), \
 .f_req(fr),.f_n4(fn),.f_ifseq(fseq),.f_ifgen(fgen),.f_ifword(fword),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd), \
 .f_ack(ack),.f_rvalid(rv),.f_rdata(fq),.wr_mon(transport.mon_we),.wr_addr(transport.mon_addr)
 generate if(MODE==0)begin:before_port
 old_nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1))port7(`PORT_PINS);
 end else begin:after_port
 nds_arm7_port #(.MAIN_STORE_TURN(MODE==2),.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1))port7(`PORT_PINS);
 end endgenerate
 physical_transport #(.IF_STREAM(1),.FAB_FLOW(1))transport(.clk_sys(clk),.clk_mem,.clk_cram,.rst_sys(rst),.rst_mem(rst),
 .a9_req(1'b0),.a9_we(1'b0),.a9_n8(1'b0),.a9_ldm(1'b0),.a9_addr(32'd0),.a9_wdata(32'd0),.a9_be(4'hf),.a9_ack(),.a9_rvalid(),.a9_rdata(),
 .a7_req(fr),.a7_we(fw),.a7_n4(fn),.a7_ifseq(fseq),.a7_ifgen(fgen),.a7_ifword(fword),.a7_be(fb),.a7_addr(fa),.a7_wdata(fd),.a7_ack(ack),.a7_rvalid(rv),.a7_rdata(fq),
 .initialized,.idle,.pins,.reads(preads),.writes(pwrites));
 always @(posedge clk)begin
  cycle++;wok<=wr&&!rst;xdone<=xreq&&!rst;
  if(wr)begin
   wrd<=wram[wa_mem[13:2]];
   if(ww)for(int b=0;b<4;b++)if(wb[b])wram[wa_mem[13:2]][b*8+:8]<=wwd[b*8+:8];
  end
  if(xreq)begin
   if(xwe)$fatal(1,"unexpected BIOS write");
   case(xa[13:2])
    12'h006:xrd<=32'he59ff000; // IRQ vector: LDR pc,[pc,#0]
    12'h008:xrd<=32'(irq_pc);
    default:xrd<=32'he1a00000;
   endcase
  end
  // The pipeline's d_we belongs to its request phase. Preserve that actual
  // tuple for the following sample instead of decoding its inactive phase.
  if(!rst&&dr)begin rq_w<=dw;rq_a<=da;rq_d<=dd;rq_be<=db;end
  if(!rst&&dok&&((cpu.st==cpu.S_PIPE&&cpu.ph&&cpu.dm_rq)||(dr&&cpu.st!=cpu.S_PIPE)))begin
   $fdisplay(datafd,"%h,%b,%h,%h",rq_a,rq_w,rq_be,rq_w?rq_d:dq);data_count++;
   if(irq_enable&&!irq_sent&&rq_w&&rq_a==32'h02010200)begin irq<=1;irq_sent<=1;end
  end
  if(irq&&cpu.cpsr[4:0]==5'b10010)irq<=0;
  if(!rst&&fr&&ack&&fw)begin
   $display("WRITE_ACK mode%0d index%0d cycle%0d addr%h be%h data%h",MODE,write_count,cycle,fa,fb,fd);write_count++;
  end
  if(!rst&&run)$fdisplay(edgefd,"%0d,%b,%b,%b,%h,%h,%h,%b,%b,%h,%h,%h,%b,%b,%b,%b",cycle,dr,dw,dok,da,db,dd,fr,fw,fa,fb,fd,ack,io,ir,cpu.ph);
 end
 always @(negedge clk)if(!rst&&!done)begin
  if(wen)shadow[wa]=wd;
  if(ret)begin
   nret++;$fwrite(statefd,"%h,%h",pc,psr);
   for(int j=0;j<32;j++)$fwrite(statefd,",%h",shadow[j]);
   for(int j=0;j<5;j++)$fwrite(statefd,",%h",cpu.spsr[j]);
   $fwrite(statefd,"\n");
   if(pc==32'(fail_pc))$fatal(1,"MAIN program self-check failed mode%0d",MODE);
   if(pc==32'(endpoint))begin run=0;done=1;end
  end
 end
 initial begin
  if(!$value$plusargs("img=%s",image)||!$value$plusargs("out=%s",prefix)||!$value$plusargs("done=%h",endpoint)||!$value$plusargs("fail=%h",fail_pc)||!$value$plusargs("handler=%h",irq_pc))$fatal(1,"missing coupled inputs");
  void'($value$plusargs("loops=%d",loops));void'($value$plusargs("irq=%d",irq_enable));
  statefd=$fopen($sformatf("%s-m%0d.state",prefix,MODE),"w");
  datafd=$fopen($sformatf("%s-m%0d.data",prefix,MODE),"w");
  edgefd=$fopen($sformatf("%s-m%0d.edge",prefix,MODE),"w");
  memfd=$fopen($sformatf("%s-m%0d.mem",prefix,MODE),"w");
  for(int j=0;j<32;j++)shadow[j]=0;
  for(int j=0;j<4096;j++)wram[j]=0;
  $readmemh(image,wram);
  wait(!rst);wait(initialized);repeat(8)@(negedge clk);run=1;
  wait(done);wait(!fr&&idle);repeat(3)@(negedge clk);
  if(shadow[12]!==32'(irq_enable))$fatal(1,"IRQ handler count mode%0d got%0d",MODE,shadow[12]);
  if(write_count!=loops*4+4)$fatal(1,"write cardinality mode%0d got%0d",MODE,write_count);
  for(int j=0;j<64;j++)$fdisplay(memfd,"%h%h",transport.chips.m1.mem[32'h10200/4+j],transport.chips.m0.mem[32'h10200/4+j]);
  for(int j=0;j<4096;j++)$fdisplay(memfd,"%h",wram[j]);
  $fclose(statefd);$fclose(datafd);$fclose(edgefd);$fclose(memfd);
  $display("CPU_STORE_PASS mode%0d cycles%0d states%0d data%0d writes%0d",MODE,cycle,nret,data_count,write_count);
  complete=1;
 end
 logic complete=0;
endmodule
module tb_cpu;
 logic clk=0,clk_mem=0,clk_cram=0,rst=1;wire[2:0]done;
 always #4973 clk_mem=~clk_mem;
 initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
 always @(clk_mem)clk_cram<=#6838 clk_mem;
 generate for(genvar M=0;M<3;M++)begin:g
 cpu_lane #(.MODE(M))lane(.clk,.clk_mem,.clk_cram,.rst,.done(done[M]));
 end endgenerate
 initial begin repeat(8)@(negedge clk);rst=0;wait(g[0].lane.complete&&g[1].lane.complete&&g[2].lane.complete);$display("CPU_STORE_ALL_PASS");$finish;end
 initial begin #2000000000;$fatal(1,"coupled MAIN store timeout");end
endmodule
