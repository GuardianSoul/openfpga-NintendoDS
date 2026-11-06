`timescale 1ps/1ps
module tb_main #(parameter HIT=0);
 logic clk=0,clk_mem=0,clk_cram=0,rst=1;
 always #4973 clk_mem=~clk_mem;
 initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
 always @(clk_mem)clk_cram<=#6838 clk_mem;
 logic run=0,ir,io,iseq,iarm,iredirect,iconsume,dr,dw,dok,wen,ret;
 logic[31:0]ia,iq,da,dd,dq,pc,psr,wd;logic[3:0]db;logic[4:0]wa;
 logic fr,fn,fw,fseq,fack,frvalid;logic[1:0]fgen,fword;logic[31:0]fa,fd,fq;logic[3:0]fb;
 logic wr,ww,wok=0;logic[17:2]waddr;logic[3:0]wbe;logic[31:0]wwd,wrd=0;
 logic xr,xw,xdone=0;logic[17:2]xa;logic[31:0]xrd=0;
 logic a9_req=0,a9_we=0,a9_n8=0,a9_ack,a9_rvalid;logic[31:0]a9_addr=0,a9_wdata=0,a9_rdata;
 wire initialized,idle;wire[79:0]pins;integer preads,pwrites;
 int cycle=0,nret=0,begin_pc,end_pc,done_pc,fail_pc,start_pc,body_start=-1,body_end=-1,pressure=0,phase=0;
 int hit_go=0,miss_go=0,blocked=0,physical_words=0,data_count=0,commits=0,early=0,resetmode=0;
 bit host_done=0,finished=0;logic[31:0]wram[4096],shadow[32];
 integer sf,df,ef,of,pf;string image,out;
 arm7_ds #(.MAIN_IF_FLOW(1))cpu(.clk,.rst,.run,.reset_pc(32'(start_pc)),.hivecs(1'b0),.irq(1'b0),.fiq(1'b0),.wake(1'b0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .dbg_wen(wen),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halted());
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.MAIN_STORE_TURN(1),.MAIN_IF_REJOIN(1),.DATA_ACK_HANDOFF(0))p7(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),.i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .w_req(wr),.w_we(ww),.w_addr(waddr),.w_be(wbe),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(xr),.x_we(xw),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xrd),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(fseq),.f_ifgen(fgen),.f_ifword(fword),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(fack),.f_rvalid(frvalid),.f_rdata(fq),.wr_mon(bus.mon_we),.wr_addr(bus.mon_addr));
 main_transport #(.HIT(HIT))bus(.clk_sys(clk),.clk_mem,.clk_cram,.rst_sys(rst),.rst_mem(rst),
 .a9_req,.a9_we,.a9_n8,.a9_ldm(1'b0),.a9_addr,.a9_wdata,.a9_be(4'hf),.a9_ack,.a9_rvalid,.a9_rdata,
 .a7_req(fr),.a7_we(fw),.a7_n4(fn),.a7_ifseq(fseq),.a7_ifgen(fgen),.a7_ifword(fword),.a7_be(fb),.a7_addr(fa),.a7_wdata(fd),.a7_ack(fack),.a7_rvalid(frvalid),.a7_rdata(fq),
 .initialized,.idle,.pins,.reads(preads),.writes(pwrites));
 function automatic logic[31:0]physword(input logic[31:0]a);
 return {bus.chips.m1.mem[a[21:2]],bus.chips.m0.mem[a[21:2]]};endfunction
 logic rq_w;logic[31:0]rq_a,rq_d;logic[3:0]rq_be;
 bit f_owned=0;logic[68:0]f_tuple;
 always @(posedge clk)begin
  cycle++;wok<=wr&&!rst;xdone<=xr&&!rst;
  if(wr)begin wrd<=wram[waddr[13:2]];if(ww)for(int b=0;b<4;b++)if(wbe[b])wram[waddr[13:2]][8*b+:8]<=wwd[8*b+:8];end
  if(xr)begin if(xw)$fatal(1,"unexpected BIOS write");xrd<=32'he1a00000;end
  if(rst)f_owned=0;
  else begin
   if(dr)begin rq_w<=dw;rq_a<=da;rq_d<=dd;rq_be<=db;end
   if(dok&&((cpu.st==cpu.S_PIPE&&cpu.ph&&cpu.dm_rq)||(dr&&cpu.st!=cpu.S_PIPE)))begin
    if(!rq_w&&rq_a[31:24]==8'h02&&dq!==physword(rq_a))$fatal(1,"actual CPU MAIN payload addr%h got%h expected%h",rq_a,dq,physword(rq_a));
    $fdisplay(df,"%h,%b,%h,%h",rq_a,rq_w,rq_be,rq_w?rq_d:dq);data_count++;
    $fdisplay(of,"DACK %0d %h %b %h %h list%h first%b",cycle,rq_a,rq_w,rq_be,rq_w?rq_d:dq,cpu.rl,cpu.first);
   end
   if(fr&&!f_owned)begin f_owned=1;f_tuple={fw,fa,fb,fd};$fdisplay(of,"FSTART %0d %h %b %h %b %b %h %h",cycle,fa,fw,fb,fn,fseq,fgen,fword);end
   if(f_owned&&!fr)$fatal(1,"fabric descriptor disappeared before ACK");
   if(f_owned&&{fw,fa,fb,fd}!==f_tuple)$fatal(1,"fabric held tuple changed before ACK");
   if(fack)begin if(!f_owned||!fr)$fatal(1,"orphan ARM7 ACK");$fdisplay(of,"FACK %0d %h %h",cycle,fa,fq);f_owned=0;end
   if(fr&&!fack&&!(bus.u_fab.st==bus.u_fab.S_GO&&bus.u_fab.mst==2))blocked++;
   if(bus.u_fab.st==bus.u_fab.S_IDLE&&bus.u_fab.grant[2])$fdisplay(of,"GRANT %0d %h %b %h %b",cycle,fa,fw,fb,fn);
   if(bus.u_fab.st==bus.u_fab.S_GO&&bus.u_fab.mst==2&&bus.u_fab.tgt==bus.u_fab.T_MAIN&&!bus.u_fab.we&&!bus.u_fab.q7)begin
    if(bus.u_fab.lb_hit_raw)hit_go++;else miss_go++;
    $fdisplay(of,"SERVICE %0d %h hit%b q%h",cycle,bus.u_fab.addr,bus.u_fab.lb_hit_raw,bus.u_fab.lb_q);
   end
   if(bus.mr_req&&bus.mr_ack)$fdisplay(pf,"%0d %b %h %h %h %b %b %b",bus.u_fab.mst,bus.mr_we,bus.mr_addr,bus.mr_be,bus.mr_wdata,bus.mr_n8,bus.mr_if4,bus.mr_ld4);
   if(bus.mr_rvalid)physical_words++;
   if(bus.mon_we)begin commits++;$fdisplay(of,"COMMIT %0d %h %h %h",cycle,bus.mon_addr,bus.mon_be,bus.mon_wdata);end
`ifdef NEW_HIT
   if(bus.u_fab.a7_hit_done)begin
    early++;
    if(!fr||fw||fn||fb!=15||fa!=bus.u_fab.addr||!bus.u_fab.lb_hit_raw)$fatal(1,"early ACK without coherent held hit");
    $fdisplay(of,"EARLY %0d %h",cycle,fa);
   end
`endif
   $fdisplay(ef,"%0d %b%b%b %h %h %h %b%b%b %h %h %b%b%b %h %b %h %h %h %h %h",cycle,dr,dw,dok,da,db,dd,fr,fw,fack,fa,fb,fn,fseq,frvalid,fq,cpu.ph,cpu.st,cpu.esub,cpu.rl,p7.rp_v,p7.rb_v);
  end
 end
 always @(negedge clk)if(!rst&&run)begin
  if(wen)shadow[wa]=wd;
  if(ret)begin
   nret++;$fwrite(sf,"%h,%h",pc,psr);for(int j=0;j<32;j++)$fwrite(sf,",%h",shadow[j]);for(int j=0;j<5;j++)$fwrite(sf,",%h",cpu.spsr[j]);$fwrite(sf,"\n");
   if(pc==32'(begin_pc)&&body_start<0)body_start=cycle;
   if(pc==32'(end_pc)&&body_end<0)body_end=cycle;
   if(pc==32'(fail_pc))$fatal(1,"ARM7 self-check failed");
   if(pc==32'(done_pc))begin finished=1;run=0;end
  end
 end
 initial begin
  wait(body_start>=0);
  if(pressure)for(int k=0;k<4;k++)begin
   repeat(phase+k%2)@(negedge clk);a9_req=1;a9_n8=1;a9_addr=32'h02020000+32'(k*32);
   begin int n;n=0;do begin @(posedge clk);if(a9_rvalid)begin if(a9_rdata!==physword(a9_addr+32'(n*4)))$fatal(1,"ARM9 owner/data");n++;end end while(!a9_ack);if(n!=8)$fatal(1,"ARM9 physical block word count");end
   @(negedge clk);a9_req=0;a9_n8=0;
  end
  host_done=1;
 end
 initial begin
  void'($value$plusargs("pressure=%d",pressure));void'($value$plusargs("phase=%d",phase));void'($value$plusargs("resetmode=%d",resetmode));
  if(!$value$plusargs("img=%s",image)||!$value$plusargs("out=%s",out)||!$value$plusargs("start=%h",start_pc)||!$value$plusargs("begin=%h",begin_pc)||!$value$plusargs("end=%h",end_pc)||!$value$plusargs("done=%h",done_pc)||!$value$plusargs("fail=%h",fail_pc))$fatal(1,"missing inputs");
  sf=$fopen({out,".state"},"w");df=$fopen({out,".data"},"w");ef=$fopen({out,".edge"},"w");of=$fopen({out,".owner"},"w");pf=$fopen({out,".physical"},"w");
  for(int k=0;k<4096;k++)wram[k]=0;for(int k=0;k<32;k++)shadow[k]=0;$readmemh(image,wram);
  for(int k=0;k<256;k++)begin bus.chips.m0.mem[32'h10000/4+k]=16'hc000+16'(k);bus.chips.m1.mem[32'h10000/4+k]=16'h89ab;bus.chips.m0.mem[32'h20000/4+k]=16'h5000+16'(k);bus.chips.m1.mem[32'h20000/4+k]=16'hf00d;end
  for(int k=0;k<4096;k++)begin bus.chips.m0.mem[32'h80000/4+k]=wram[k][15:0];bus.chips.m1.mem[32'h80000/4+k]=wram[k][31:16];end
  repeat(8)@(negedge clk);rst=0;wait(initialized);repeat(8)@(negedge clk);run=1;
  wait(finished&&host_done);wait(idle&&!fr);repeat(4)@(negedge clk);
  if(commits!=1||pwrites!=1||f_owned)$fatal(1,"write/owner cardinality");
  $display("MAIN_HIT_PASS cycles%0d body%0d states%0d data%0d hit%0d miss%0d blocked%0d reads%0d words%0d writes%0d early%0d",cycle,body_end-body_start,nret,data_count,hit_go,miss_go,blocked,preads,physical_words,pwrites,early);$finish;
 end
 initial begin
  wait(run);
  if(resetmode!=0)begin
   if(resetmode==1)begin
    do @(negedge clk);while(!(bus.u_fab.st==bus.u_fab.S_GO&&bus.u_fab.mst==2&&bus.u_fab.lb_hit_raw&&!bus.u_fab.we));
   end else begin
    do @(posedge clk);while(!(bus.mr_req&&bus.mr_ack&&!bus.mr_we&&bus.u_fab.mst==2));
    @(negedge clk);
   end
   run=0;rst=1;a9_req=0;repeat(8)@(negedge clk);rst=0;
   wait(initialized);repeat(20)@(negedge clk);
   if(fr||fack||frvalid||p7.busy||p7.rp_v||p7.rb_v||f_owned||!idle||commits||pwrites)$fatal(1,"reset kept/published owner or unexpectedwrite");
   $display("MAIN_RESET_PASS mode%0d ownercleared1 commits0 writes0",resetmode);$finish;
  end
 end
 initial begin #300000000;$fatal(1,"MAIN hit timeout");end
endmodule
