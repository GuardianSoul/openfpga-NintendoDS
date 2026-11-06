`timescale 1ns/1ps
// The driver is independent of P7's valid/tag state. Physical owners stay
// fixed through ACK; only actual input beats supply instruction payload.
module tb_rejoin;
 logic clk=0,rst=1;always #5 clk=~clk;
 logic ir=0,iseq=0,redirect=0,consume=0,iarm=1,io,fr,fn,fw,ack=0,rv=0,fseq;
 logic[31:0]ia=0,iq,fa,fq=0,fd,da=0,dd=0,monaddr=0;
 logic[1:0]fgen,fword;logic[3:0]fb;logic dr=0,dwe=0,dok,mon=0;
 int cycle=0,cases=0,adoptions=0,redirects=0,target_packets=0,logical_start=0;
 bit locked=0,permit=0,forbid_live=0,fresh=0;
 logic[36:0]held;logic[31:0]base=32'h02001000,target;
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.MAIN_IF_REJOIN(`REJOIN),.MAIN_STORE_TURN(1))dut(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),.i_req(ir),.i_addr(ia),.i_seq(iseq),.i_arm(iarm),.i_redirect(redirect),.i_consume(consume),.i_ok(io),.i_rdata(iq),
 .d_req(dr),.d_we(dwe),.d_be(4'hf),.d_addr(da),.d_wdata(dd),.d_ok(dok),.d_rdata(),
 .w_req(),.w_we(),.w_addr(),.w_be(),.w_wdata(),.w_ok(1'b0),.w_rdata(32'd0),.ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1'b0),.x_rdata(32'd0),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(fseq),.f_ifgen(fgen),.f_ifword(fword),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(ack),.f_rvalid(rv),.f_rdata(fq),.wr_mon(mon),.wr_addr(monaddr));
 function automatic logic[31:0]word_value(input logic[31:0]line,input int k,input bit changed=0);
  return 32'h93ab7011 ^ (line&32'h003ffff0) ^ (32'(k)*32'h10203041) ^ (changed?32'h00300100:32'd0);
 endfunction
 always @(posedge clk)begin
  cycle++;
  if(rst)begin locked=0;redirects=0;end
  else begin
   if(locked&&(!fr||{fa,fseq,fgen,fword}!==held))$fatal(1,"old physical owner changed before tail ACK");
   if(fr&&!locked)begin
    held={fa,fseq,fgen,fword};locked=1;redirects=0;
    if(fn&&fa[31:4]==target[31:4])target_packets++;
   end
   if(redirect&&fr)redirects++;
   if(fr&&ack)locked=0;
   if(dut.rejoin_now)begin
    if(redirects!=1)$fatal(1,"stale generation adopted after repeated redirect");
    if(!permit)$fatal(1,"unfresh or wrong-target owner adopted");
    if(fa[31:4]!=ia[31:4])$fatal(1,"wrong target quad adopted");
    adoptions++;
   end
   if(forbid_live&&dut.rejoin_live)$fatal(1,"write visibility did not cancel adoption");
  end
 end
 task automatic tick(input int n=1);repeat(n)@(negedge clk);endtask
 task automatic reset_case;
  rst=1;ir=0;redirect=0;consume=0;ack=0;rv=0;dr=0;dwe=0;mon=0;iarm=1;permit=0;forbid_live=0;fresh=0;target=base+8;target_packets=0;
  tick(3);rst=0;tick(2);
 endtask
 task automatic physical;
  int n=0;while(!fr)begin tick();if(n++>40)$fatal(1,"physical quad missing");end
  if(!fn||fw)$fatal(1,"unexpected physical descriptor");
 endtask
 task automatic beat(input int k,input logic[31:0]line,input bit changed=0);
  physical();if(dut.rp_k!=2'(k))$fatal(1,"physical word index changed");
  fq=word_value(line,k,changed);rv=1;ack=k==3;tick();rv=0;ack=0;
 endtask
 task automatic begin_old(input int prefix);
  reset_case();ia=base;ir=1;iseq=0;tick();ir=0;physical();
  for(int k=0;k<prefix;k++)beat(k,base);
 endtask
 task automatic redirects_n(input int n);
  repeat(n)begin redirect=1;tick();redirect=0;tick();end
 endtask
 task automatic answer;
  int n=0;bit got=0;
  while(!got)begin
   ia=target;ir=1;iseq=0;tick();
   if(io)begin
    if(iq!==word_value(target&32'hfffffff0,int'(target[3:2]),fresh))$fatal(1,"adopted target payload mismatch");
    if(cycle-logical_start<16)$fatal(1,"new N price bypassed");got=1;
   end
   ir=0;
   if(!got&&fr&&fn&&fa[31:4]==target[31:4])begin
    // A rejected adoption must fetch actual fresh data; no payload is
    // supplied to an unrelated speculative next quad.
    for(int k=0;k<4;k++)beat(k,target&32'hfffffff0,fresh);
   end
   tick();if(n++>45)$fatal(1,"target answer timeout");
  end
 endtask
 task automatic run_case(input int prefix,nredirect,input logic[31:0]destination,input int visibility=0,input bit on_last=0);
  int before_n;bit allowed;
  begin_old(prefix);target=destination;redirects_n(nredirect);
  if(visibility==1)begin mon=1;monaddr=base^32'h00400000;tick();mon=0;fresh=1;end
  if(visibility==2)begin mon=1;monaddr=base^32'h00400000;fresh=1;end
  allowed=nredirect==1&&destination[31:4]==base[31:4]&&(visibility==0||visibility==3);
  permit=allowed;before_n=adoptions;ia=target;ir=1;iseq=0;logical_start=cycle;
  // Admission can coincide with any actual beat, including final ACK.
  if(on_last)begin fq=word_value(base,3);rv=1;ack=1;end
  tick();ir=0;rv=0;ack=0;mon=0;
  if(adoptions-before_n!=int'(allowed&&`REJOIN))$fatal(1,"actual new-N adoption cardinality");
  if(visibility==3)begin
   // Invalidation after admission while the old packet is still pending.
   forbid_live=1;mon=1;monaddr=base^32'h00400000;fresh=1;tick();mon=0;
  end
  if(!on_last)for(int k=prefix;k<4;k++)beat(k,base);
  if(allowed&&`REJOIN&&visibility!=3)begin
   answer();if(target_packets!=1)$fatal(1,"adopted target was physically refetched");
  end else answer();
  cases++;$display("REJOIN_CASE %0d prefix%0d redirects%0d target%h visibility%0d",cases,prefix,nredirect,target,visibility);
 endtask
 initial begin
  run_case(2,1,base+8);
  run_case(0,1,base+8); // adoption before any actual word has returned
  run_case(3,1,base+12,0,1); // new N on physical final ACK
  run_case(2,1,base+4); // previously returned prefix
  run_case(2,1,base+24); // different target quad must not adopt
  run_case(2,2,base+8);
  run_case(2,5,base+8); // generation wraps, first-redirect window stays shut
  run_case(2,1,base+8,1);
  run_case(2,1,base+8,2);
  run_case(2,1,base+8,3);
  // An accepted own store invalidates the pending line before any bus ACK.
  begin_old(2);redirects_n(1);da=base;dd=32'h12345678;dwe=1;dr=1;tick();dr=0;dwe=0;
  target=base+8;ia=target;ir=1;permit=0;tick();ir=0;
  if(dut.rejoin_now||dut.rp_rejoined)$fatal(1,"own posted write allowed adoption");cases++;
  // Reset while the new N and old tail coincide cannot retain an owner.
  begin_old(2);redirects_n(1);ia=base+8;ir=1;rst=1;rv=1;fq=word_value(base,2);tick();ir=0;rv=0;tick();rst=0;tick();
  if(fr||io||dut.rp_rejoined||dut.rp_rejoin_window)$fatal(1,"reset retained adoption");cases++;
  $display("REJOIN_OWNER_PASS cases%0d adoptions%0d",cases,adoptions);$finish;
 end
 initial begin #200000;$fatal(1,"owner fixture timeout");end
endmodule
