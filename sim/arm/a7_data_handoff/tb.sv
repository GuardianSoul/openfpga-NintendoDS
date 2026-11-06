`timescale 1ns/1ps
// CPU request/sample phases and physical ownership are driven independently.
// No synthetic DS wait-price or peripheral-completion rule is asserted.
module tb_data;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic req=0,we=0,ok,fr,fw,ack=0;logic[31:0]addr=0,wd=0,rd,fa,fd,fq=0;
 logic[3:0]be=15,fb;int cases=0,answers=0,fast=0,held=0,cycle=0;
 logic[31:0]wanted=0;bit watching=0,writing=0;int last_answer=-1;
 nds_arm7_port #(.DATA_ACK_HANDOFF(1),.WRAM_M10K(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1))dut(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),.i_req(1'b0),.i_addr(32'd0),.i_seq(1'b0),.i_arm(1'b1),.i_redirect(1'b0),.i_consume(1'b0),.i_ok(),.i_rdata(),
 .d_req(req),.d_we(we),.d_be(be),.d_addr(addr),.d_wdata(wd),.d_ok(ok),.d_rdata(rd),
 .w_req(),.w_we(),.w_addr(),.w_be(),.w_wdata(),.w_ok(1'b0),.w_rdata(32'd0),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1'b0),.x_rdata(32'd0),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(),.f_ifseq(),.f_ifgen(),.f_ifword(),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(ack),.f_rvalid(1'b0),.f_rdata(fq),.wr_mon(1'b0),.wr_addr(32'd0));
 always @(posedge clk)begin
  cycle++;
  if(!rst)begin
   if(dut.data_return)begin
    fast++;
    if(!ack || !fr || fw || !dut.rp_v || dut.rp_i)$fatal(1,"premature/unowned data completion");
   end
   if(dut.data_held)held++;
   if(watching&&ok)begin
    if(!writing && rd!==wanted)$fatal(1,"owned data payload got%h want%h",rd,wanted);
    answers++;last_answer=cycle;
   end
   $display("OWNER c%0d d%0d/%0d w%0d a%h be%h wb%0d busy%0d/%0d rp%0d/%0d a%h rb%0d owned%0d f%0d/%0d ack%0d return%0d held%0d",cycle,req,ok,we,addr,be,dut.wb_v,dut.busy,dut.busy_w,dut.rp_v,dut.rp_i,dut.rp_a,dut.rb_v,dut.da_owned,fr,fw,ack,dut.data_return,dut.data_held);
  end
 end
 task automatic tick(input int n=1);repeat(n)@(negedge clk);endtask
 task automatic clear_case;
  rst=1;req=0;ack=0;watching=0;we=0;be=15;tick(4);rst=0;tick(2);
 endtask
 task automatic pulse;
  req=1;tick();req=0;tick();
 endtask
 task automatic physical(input logic[31:0]a,input bit w,input logic[3:0]b);
  int n=0;while(!fr)begin tick();if(n++>30)$fatal(1,"physical request missing");end
  if(fa!==a||fw!==w||fb!==b)$fatal(1,"physical owner descriptor");
 endtask
 task automatic read_case(input logic[31:0]a,input logic[3:0]mask,input int phase);
  int before_n,ret_cycle;bit sent;
  clear_case();addr=a;be=mask;wanted=32'h61ab80f3^a;fq=wanted;before_n=answers;watching=1;
  pulse();physical(a,0,mask);
  // Own the descriptor through delayed, alternating replays. Then return
  // on either CPU phase, including the phase with no registered lookup.
  for(int n=0;n<8+phase;n++)begin
   req=(n%2)==0;
   if(n==6+phase)ack=1;
   tick();ack=0;if(answers>before_n)begin req=0;break;end
  end
  req=0;tick(3);
  if(answers!=before_n+1)$fatal(1,"read completion count %0d",answers-before_n);
  if(fr||dut.rb_v)$fatal(1,"consumed response replayed");
  watching=0;cases++;
 endtask
 task automatic orphan_case(input int variant);
  int before_n;
  clear_case();addr=32'h04000100;be=3;wanted=32'h12345678;fq=wanted;before_n=answers;
  pulse();physical(addr,0,be);
  // No matching sample phase: the real reply must remain buffered.
  addr=variant==0?32'h04000104:32'h04000100;be=variant==1?12:3;
  if(variant==2)req=0;else req=1;
  tick();req=0;ack=1;#1;
  if(dut.data_return)$fatal(1,"mismatched/orphaned lookup consumed owner");
  tick();ack=0;
  if(!dut.rb_v)$fatal(1,"orphan response lost");
  addr=32'h04000100;be=3;watching=1;pulse();tick(2);watching=0;
  if(answers!=before_n+1||fr)$fatal(1,"orphan replay count");cases++;
 endtask
 task automatic posted_case;
  int before_n;
  clear_case();addr=32'h04000408;wd=32'h89abcdef;we=1;watching=1;writing=1;before_n=answers;
  pulse();watching=0;writing=0;
  if(answers!=before_n+1)$fatal(1,"posted store waited for own ACK");
  physical(addr,1,15);tick(3);
  if(!dut.wb_v||!fr||fd!==wd)$fatal(1,"posted write owner changed");
  addr=32'h04000104;be=3;we=0;req=1;tick();req=0;tick();
  if(!fw||dut.data_return||dut.data_held)$fatal(1,"read passed pending write");
  ack=1;tick();ack=0;
  wanted=32'h84726135;fq=wanted;watching=1;
  for(int n=0;n<12;n++)begin
   req=(n%2)==0;
   if(n==6)begin physical(addr,0,3);ack=1;end
   tick();ack=0;if(answers==before_n+2)begin req=0;break;end
  end
  req=0;tick(2);watching=0;
  if(answers!=before_n+2)$fatal(1,"write/read replay completion");cases++;
 endtask
 task automatic reset_case(input int phase);
  clear_case();addr=32'h04000100;be=3;pulse();physical(addr,0,be);
  req=1;tick();req=0;if(phase)tick();rst=1;ack=1;#1;
  if(ok||dut.data_return||dut.data_held)$fatal(1,"reset published response");
  tick();ack=0;tick(2);rst=0;tick(2);
  if(dut.rb_v||dut.da_owned||fr)$fatal(1,"reset kept data owner");cases++;
 endtask
 initial begin
  for(int phase=0;phase<2;phase++)begin
   read_case(32'h04000100,3,phase);
   read_case(32'h04000105,2,phase);
   read_case(32'h02090000,15,phase);
  end
  for(int k=0;k<3;k++)orphan_case(k);
  posted_case();for(int k=0;k<2;k++)reset_case(k);
  if(cases!=12||!fast||!held)$fatal(1,"data owner coverage");
  $display("DATA_OWNER_PASS cases%0d actualACK%0d held%0d",cases,fast,held);$finish;
 end
 initial begin #200000;$fatal(1,"data owner timeout");end
endmodule
