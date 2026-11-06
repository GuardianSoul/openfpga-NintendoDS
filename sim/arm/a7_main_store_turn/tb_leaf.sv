`timescale 1ns/1ps
// Independent request/sample driver and physical ACK owner. No DS prices.
module tb_leaf;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic req=0,we=0,ok,fr,fw,ack=0,rv=0,fn,ir=0,io;
 logic[31:0]addr=0,wd=0,rd,fa,fd,fq=0,ia=0,iq;
 logic[3:0]be=15,fb;
 logic[31:0]ea[256],ed[256],memory[1024];logic[3:0]eb[256];
 int expected=0,committed=0,cycle=0,cases=0,accepted_cycle[256],commit_cycle[256];
 bit locked=0;logic[68:0]owner;
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_QUAD(1),.MAIN_IF_EARLY(1)
`ifndef BEFORE
 ,.MAIN_STORE_TURN(`TURN)
`endif
 )dut(.clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),
 .i_req(ir),.i_addr(ia),.i_seq(1'b0),.i_arm(1'b1),.i_redirect(1'b0),.i_consume(1'b0),.i_ok(io),.i_rdata(iq),
 .d_req(req),.d_we(we),.d_be(be),.d_addr(addr),.d_wdata(wd),.d_ok(ok),.d_rdata(rd),
 .w_req(),.w_we(),.w_addr(),.w_be(),.w_wdata(),.w_ok(1'b0),.w_rdata(32'd0),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1'b0),.x_rdata(32'd0),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(),.f_ifgen(),.f_ifword(),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(ack),.f_rvalid(rv),.f_rdata(fq),.wr_mon(1'b0),.wr_addr(32'd0));
 always @(posedge clk)begin
  cycle++;
  if(rst)locked=0;
  else begin
   if(locked&&(!fr||{fw,fa,fb,fw?fd:32'd0}!==owner))$fatal(1,"physical descriptor changed before ACK");
   if(fr&&!locked)begin owner={fw,fa,fb,fw?fd:32'd0};locked=1;end
   if(fr&&ack)begin
    locked=0;
    if(fw)begin
     if(committed>=expected||fa!==ea[committed]||fb!==eb[committed]||fd!==ed[committed])
      $fatal(1,"ordered physical write mismatch index%0d got%h/%h/%h",committed,fa,fb,fd);
     for(int b=0;b<4;b++)if(fb[b])memory[fa[11:2]][b*8+:8]=fd[b*8+:8];
     commit_cycle[committed]=cycle;committed++;
    end
   end
   $display("EDGE %0d D%b/%b/%b %h/%h/%h F%b/%b/%b %h/%h/%h",cycle,req,we,ok,addr,be,wd,fr,fw,ack,fa,fb,fd);
  end
 end
 task automatic tick(input int n=1);repeat(n)@(negedge clk);endtask
 task automatic physical(input bit writing);
  int n=0;while(!fr)begin tick();if(n++>40)$fatal(1,"physical owner missing");end
  if(fw!==writing)$fatal(1,"wrong physical owner type");
 endtask
 task automatic reset_port;
  req=0;ir=0;ack=0;rv=0;rst=1;tick(3);rst=0;tick(2);
 endtask
 task automatic post(input logic[31:0]a,v,input logic[3:0]mask,input bit finish_old=0);
  int n=0,index;bit accepted=0;
  index=expected;ea[index]=a;ed[index]=v;eb[index]=mask;expected++;
  addr=a;wd=v;be=mask;we=1;
  while(!accepted)begin
   req=1;ack=finish_old&&n==0;tick();accepted=ok;ack=0;
   if(accepted)accepted_cycle[index]=cycle;
   req=0;tick();n++;if(n>30)$fatal(1,"posted write refused after completion");
  end
 endtask
 task automatic finish_write;
  physical(1);tick(2);ack=1;tick();ack=0;tick();
 endtask
 task automatic read_word(input logic[31:0]a);
  int n=0;bit answered=0,returned=0;logic[31:0]want;
  want=memory[a[11:2]];addr=a;be=15;we=0;
  while(!answered)begin
   req=1;tick();answered=ok;if(answered&&rd!==want)$fatal(1,"MAIN readback mismatch");req=0;
   if(fr&&!returned)begin
    if(fw||fa!==a)$fatal(1,"read passed older write or wrong address");
    fq=memory[fa[11:2]];ack=1;returned=1;
   end
   tick();ack=0;n++;if(n>30)$fatal(1,"MAIN readback timeout");
  end
  tick();cases++;
 endtask
 task automatic fetch_word(input logic[31:0]a);
  int n=0;bit answered=0;logic[31:0]want;
  want=memory[a[11:2]];ia=a;
  while(!answered)begin
   ir=1;tick();answered=io;if(answered&&iq!==want)$fatal(1,"stale fetched code after accepted turnover");ir=0;
   if(fr)begin
    if(fw||!fn||fa[31:4]!==a[31:4])$fatal(1,"wrong fetch owner");
    for(int k=0;k<4;k++)begin fq=memory[{a[11:4],2'b0}+k];rv=1;ack=k==3;tick();end
    ack=0;rv=0;
   end
   tick();if(n++>30)$fatal(1,"fetch timeout");
  end
  tick();cases++;
 endtask
 initial begin
  for(int j=0;j<1024;j++)memory[j]=32'h11720000^32'(j);
  reset_port();
  // Consecutive real words, including a 16-byte boundary, on the old ACK.
  post(32'h02000200,32'h89ab0000,15);
  for(int j=1;j<8;j++)begin physical(1);tick(j%3);post(32'h02000200+32'(4*j),32'h89ab0000+32'(j),15,1);end
  finish_write();cases++;
  for(int j=0;j<8;j++)$display("WRITE_TIME %0d %0d %0d",j,accepted_cycle[j],commit_cycle[j]);
  // A live adjacent demand under backpressure must not replace its owner.
  post(32'h02000300,32'h12345678,15);physical(1);
  addr=32'h02000304;wd=32'h76543210;be=15;we=1;
  repeat(3)begin req=1;tick();if(ok)$fatal(1,"premature store turnover without ACK");req=0;tick();end
  post(addr,wd,15,1);finish_write();cases++;
  // A held retry of the already accepted store is not a distinct next word.
  post(32'h02000320,32'h55112233,15);physical(1);
  req=1;ack=1;tick();if(ok)$fatal(1,"duplicate held store accepted on ACK");req=0;ack=0;tick(3);
  if(fr)$fatal(1,"duplicate physical write after held store");cases++;
  // Byte/halfword, repeated and nonadjacent words retain their posted order.
  post(32'h02000400,32'haaaaaaaa,15);
  physical(1);post(32'h02000401,32'hbbbbbbbb,2,1);
  physical(1);post(32'h02000402,32'hcccccccc,12,1);
  physical(1);post(32'h02000400,32'h12340000,15,1);
  physical(1);post(32'h02000420,32'h43210000,15,1);
  finish_write();read_word(32'h02000400);read_word(32'h02000420);cases++;
  // The new slot must apply the same own-store instruction invalidation.
  fetch_word(32'h02001000);
  post(32'h02000ffc,32'hdead1234,15);physical(1);
  post(32'h02001000,32'he3a00017,15,1);finish_write();fetch_word(32'h02001000);cases++;
  // A non-MAIN instruction fill can retain tail words while stores drain.
  // Turning its intervening MAIN write must leave that pending read next.
  ia=32'h08000800;ir=1;tick();ir=0;physical(0);
  post(32'h02000700,32'h71112233,15);
  fq=32'he1a00000;ack=1;tick();ack=0;physical(1);
  post(32'h02000704,32'h74445566,15,1);physical(0);
  if(fa!==32'h08000804)$fatal(1,"turnover store passed the pending read");
  ack=1;tick();ack=0;finish_write();
  for(int j=2;j<4;j++)begin
   physical(0);if(fa!==32'h08000800+32'(j*4))$fatal(1,"pending read tail reordered");
   ack=1;tick();ack=0;
  end
  tick(2);cases++;
  // Reset an uncompleted posted owner, including a simultaneous old ACK.
  for(int phase=0;phase<2;phase++)begin
   post(32'h02000600+32'(phase*4),32'hface0000+32'(phase),15);physical(1);
   expected--;req=0;rst=1;ack=phase!=0;tick();ack=0;tick(2);rst=0;tick(2);
   if(fr||ok)$fatal(1,"reset retained uncompleted store");cases++;
  end
  if(expected!=committed)$fatal(1,"physical write count %0d/%0d",committed,expected);
  $display("STORE_LEAF_PASS cases%0d writes%0d cycles%0d",cases,committed,cycle);$finish;
 end
 initial begin #200000;$fatal(1,"leaf fixture timeout");end
endmodule
