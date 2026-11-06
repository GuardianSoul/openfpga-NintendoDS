`timescale 1ns/1ps
// Focused c549 import copy-loop contract. Natural software setup, no deposits.
// Bus prices replay actual captured owner-start to ACK delays; this is a
// regression driver, not a replacement DS timing model.
module tb;
 logic clk=0,rst=1;
 always begin #7.460;clk=1;#7.459;clk=0;end
 logic [31:0] ram[0:(1<<20)-1];
 logic [31:0] waits[0:2559],counts[0:9];
 integer seen[0:9];
 logic req,we,ack,ldm,n8,rv,wn;
 logic [31:0] addr,wd,data;
 logic [3:0] be,tmr;
 logic ret,tid,wen;logic[5:0]wa;logic[31:0]rwd,pc,cpsr;
 arm_cpu #(.A9_ONLY(1),.A9_SOLO(1),.A9_OPT(461366243),.SLOW(1),
  .ARM9_LDM_BASE_FORWARD(1),.ARM9_WAYS(4),.ARM9_EVB(1),.ARM9_EARLYD(1),
  .ARM9_READ_ACK_EARLY(1),.ARM9_NCNB_WAIT(1),.ARM9_BURST(1)) dut(
  .clk,.rst,.run(2'b01),.reset_pc0(32'h02000000),.reset_pc1(32'd0),
  .hivecs7(1'b0),.irq(2'b0),.fiq(2'b0),.wake7(1'b0),
  .b9_req(req),.b9_we(we),.b9_addr(addr),.b9_wdata(wd),.b9_be(be),.b9_tmr(tmr),
  .b9_ldm(ldm),.b9_n8(n8),.b9_wnext(wn),.b9_ack(ack),.b9_rdata(data),
  .a7_i_rdata(32'd0),.a7_i_ok(1'b0),.a7_d_rdata(32'd0),.a7_d_ok(1'b0),
  .dbg_retire(ret),.dbg_tid(tid),.dbg_wen(wen),.dbg_wa(wa),.dbg_wd(rwd),.dbg_pc(pc),.dbg_cpsr(cpsr));
 integer cycle=0,phase=0,tape_i=0,admit_after=-1,due=0;
 integer fd=0,stores=0,trigger_at=-1,requests68=0,ack6c=0,ack70=0,valid68=0,retired=0;
 logic busy=0,ack_q=0;
 logic[31:0]held_addr=0,held_data=0;
 logic[31:0]shadow[0:63];
 string image,tape,trace,countfile;
 function automatic logic[31:0]rd(input logic[31:0]a);return ram[a[21:2]];endfunction
 function automatic logic[31:0]itcm(input integer a);
  return {dut.u_mem9.u_itcm.lane[3].mem[a],dut.u_mem9.u_itcm.lane[2].mem[a],
          dut.u_mem9.u_itcm.lane[1].mem[a],dut.u_mem9.u_itcm.lane[0].mem[a]};
 endfunction
 // Target I/D return waits come from the captured port history. The natural
 // software-setup prefix is zero-wait. This is an ownership regression,
 // not a replacement physical timing model or a DS wait-state rule.
 function automatic integer slot_of(input logic[31:0]a);
  if(a>=32'h021aa064&&a<=32'h021aa074)return (a-32'h021aa064)>>2;
  case(a)
   32'h021b8034:return 5;32'h021b8038:return 6;32'h021b803c:return 7;
   32'h021ab000:return 8;32'h021ab004:return 9;
   default:return -1;
  endcase
 endfunction
 wire code_price=slot_of(addr)>=0;
 wire setup_ready=req&&!code_price&&!busy;
 assign ack=setup_ready||ack_q;
 assign data=(busy||ack_q)?held_data:rd(addr);
 assign rv=ack;
 initial begin
  for(int i=0;i<(1<<20);i++)ram[i]=0;
  for(int i=0;i<2560;i++)waits[i]=0;
  for(int i=0;i<10;i++)begin counts[i]=0;seen[i]=0;end
  assert($value$plusargs("image=%s",image));assert($value$plusargs("tape=%s",tape));
  void'($value$plusargs("phase=%d",phase));assert($value$plusargs("counts=%s",countfile));
  if($value$plusargs("trace=%s",trace))fd=$fopen(trace,"w");
  $readmemh(image,ram);$readmemh(tape,waits);$readmemh(countfile,counts);
  repeat(8)@(negedge clk);rst=0;
 end
 // Every admitted owner keeps its real price and captured payload through
 // ACK. CPU retry/backpressure cannot cancel it or synthesize a response.
 always @(negedge clk)if(!rst)begin
  ack_q=0;
  if(admit_after<0&&req&&code_price)admit_after=cycle;
  if(!busy&&req&&code_price&&cycle>=admit_after)begin
   integer price,slot,k,n;
   slot=slot_of(addr);n=counts[slot];k=seen[slot];
   assert(n>0)else $fatal(1,"missing captured instruction price");
   if(k>=n)k=n<4?n-1:n-4+(k-n)%4;
   price=waits[slot*256+k];seen[slot]++;
   // Phase0 is the captured return wait;1/2 add only external wait to this
   // already admitted speculative068 owner, exercising the retry phases.
   if(addr==32'h021aa068&&seen[slot]==2)price+=phase;
   assert(price>=1&&price<=100)else $fatal(1,"illegal recorded price");
   held_addr=addr;held_data=rd(addr);due=cycle+price;busy=1;
   $display("ADMIT c%0d a%08x price%0d i%0d",cycle,addr,price,tape_i);tape_i++;
  end
  if(busy&&cycle+1>=due)begin ack_q=1;end
 end
 always @(posedge clk)if(!rst)begin
  cycle++;
  // A live F2 request and memory's registered owner must name the same
  // instruction word, including while the reply is still waiting.
  if(dut.u_core.f2_v&&dut.u_mem9.f_req)
   assert(dut.u_core.f2_pc[31:2]==dut.u_mem9.f_addr[31:2])
    else $fatal(1,"F2_REQUEST_OWNER_MISMATCH");
  if(busy)assert(req&&addr==held_addr&&!we)else $fatal(1,"admitted owner changed before ACK");
  if(ack_q)begin
   $display("ACK c%0d a%08x d%08x",cycle,held_addr,held_data);busy=0;
   if(trigger_at>=0&&held_addr==32'h021aa06c)ack6c++;
   if(trigger_at>=0&&held_addr==32'h021aa070)ack70++;
  end
  if(dut.u_core.rf_we2)shadow[dut.u_core.rf_wa2]=dut.u_core.rf_wd2;
  if(wen)shadow[wa]=rwd;
  if(ret&&!tid)begin
   // The first architectural instruction must belong to the reset PC.
   // This independently catches a deliberately corrupted F2 owner tag.
   if(retired==0)assert(pc==32'h02000000)else $fatal(1,"RESET_INSTRUCTION_OWNER_MISMATCH");
   retired++;
   if(fd)$fwrite(fd,"%0d %08x %08x %08x %08x %08x %08x %08x\n",cycle,pc,cpsr,shadow[3],shadow[4],shadow[5],shadow[6],shadow[7]);
   if(pc==32'h021aa06c)stores++;
   if(pc==32'h021aa064&&shadow[3]==4&&shadow[6]==32'h7ff8)begin
    trigger_at=cycle;$display("TRIGGER c%0d R3%08x R5%08x R6%08x",cycle,shadow[3],shadow[5],shadow[6]);
   end
  end
  if(trigger_at>=0)begin
   if(dut.u_core.i_req&&dut.u_core.i_addr==32'h021aa068)requests68++;
   if(dut.u_core.p_v&&dut.u_core.p_pc==32'h021aa068&&!dut.u_core.p_ok)valid68++;
  end
  if(cycle>16000)begin
   if(trigger_at>=0&&requests68>100&&valid68>100&&ack6c>10&&ack70>10&&stores==1)
    $display("CAPTURED_STALL requests68%0d valid68%0d ACK6c%0d ACK70%0d",requests68,valid68,ack6c,ack70);
   else $display("UNRELATED_TIMEOUT pc%08x stores%0d trigger%0d requests68%0d valid68%0d ACK6c%0d ACK70%0d",pc,stores,trigger_at,requests68,valid68,ack6c,ack70);
   $finish;
  end
 end
 always @(negedge clk)if(!rst&&stores==2)begin
  assert(shadow[3]==8&&shadow[4]==32'h021b8040&&shadow[5]==32'h021ab008&&shadow[6]==32'h7ff8&&shadow[7]==32'he3a0c301)
   else $fatal(1,"architectural copy-loop state mismatch");
  assert(itcm(0)==32'he92d4000&&itcm(1)==32'he3a0c301)else $fatal(1,"ITCM copy payload mismatch");
  $display("PROGRESS_PASS c%0d price_owners%0d",cycle,tape_i);$finish;
 end
endmodule
