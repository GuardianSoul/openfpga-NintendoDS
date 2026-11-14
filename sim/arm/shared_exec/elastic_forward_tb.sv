// Full engine, fast fetch plus long native data response: deliberately holds
// a distance2 consumer while the other context overwrites the shared wbq.
module elastic_forward_tb #(parameter bit FAULT_FORWARD=0);
 logic clk=0,rst=1; always #5 clk=~clk;
 logic i_req,i_tid,i_priv,d_req,d_tid,d_priv,d_we,d_ok,d_abort,d_kill,cp_req,cp_we;
 logic[31:0] i_addr,i_data,d_addr,d_data,d_rdata,cp_data;
 logic[1:0] d_size;logic[3:0] d_be;logic[15:0] cp_op;
 logic ia,da;logic[1:0] cancel;
 logic dw,ret,tid;logic[5:0] wa;logic[31:0] wd,pc,psr;logic[1:0] halted;
 logic[31:0] image0[0:1023],image1[0:1023];
 logic[1:0] pending=0,done=0;
 integer delay_count[0:1],cycles=0,stalls=0,older=0,overwrites=0;
 logic prev_paused=0;logic[31:0] prev_wbq=0;
 arm_shared_elastic #(.FAULT_FORWARD(FAULT_FORWARD),.V5(2'b01),.RF_STYLE("MLAB"),.A9_SOLO(0),.SOLO_ONLY(0),.A9_OPT(1711268835),.SLOW(0)) dut(
 .clk,.rst,.run(2'b11),.reset_pc0(32'h02000000),.reset_pc1(32'h02000000),
 .hivecs(2'b00),.irq(2'b00),.fiq(2'b00),.halt_req(2'b00),.wake(2'b00),.fetch_hold(2'b00),
 .i_req,.i_tid,.i_priv,.i_addr,.i_rdata(i_data),.i_ok(1'b1),.i_abort(1'b0),.i_accept(ia),.d_accept(da),.i_cancel(cancel),
 .d_req,.d_tid,.d_priv,.d_we,.d_size,.d_be,.d_addr,.d_wdata(d_data),.d_rdata,.d_ok,.d_abort,.d_wait(2'b00),.d_kill,
 .cp_req,.cp_we,.cp_op,.cp_wdata(cp_data),.dbg_wen(dw),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_tid(tid),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halt(halted));
 assign d_ok=pending[~i_tid] && delay_count[~i_tid]==0;
 assign d_abort=0;
 assign d_rdata=(~i_tid & 1)?32'h22:32'h11;
 always @(posedge clk) begin
  if(i_req) i_data<=i_tid ? image1[i_addr[11:2]] : image0[i_addr[11:2]];
  if(!rst) begin
   cycles=cycles+1;
   for(integer c=0;c<2;c++)if(pending[c]&&delay_count[c]>0)delay_count[c]<=delay_count[c]-1;
   if(dut.wait_w)stalls=stalls+1;
   if(dut.wait_w && (dut.e2_sa[0]||dut.e2_sb[0]||dut.e2_sc[0] ||
      dut.e2_va==32'h55 || dut.e2_vb==32'h55 || dut.e2_vc==32'h55 ||
      dut.e2_va==32'h66 || dut.e2_vb==32'h66 || dut.e2_vc==32'h66))older=older+1;
   if(prev_paused && prev_wbq!==dut.wbq_d)overwrites=overwrites+1;
   prev_paused=(dut.paused!=0);prev_wbq=dut.wbq_d;
   if(d_req)begin
    if(pending[d_tid])$fatal(1,"forward: duplicate data launch");
    pending[d_tid]<=1;delay_count[d_tid]<=18;
    if(d_we && d_addr==32'h0f000000)begin
     if(d_data!=0)$fatal(1,"FORWARD_PROGRAM_FAIL ctx%0d value%h",d_tid,d_data);
     if(done[d_tid])$fatal(1,"forward: duplicate final store");
     done[d_tid]=1;
    end
   end
   if(da)pending[~i_tid]<=0;
   if(done==3)begin
    if(stalls==0 || older==0 || overwrites==0)$fatal(1,"forward: missing real hold/overwrite coverage");
    $display("ELASTIC_FORWARD_PASS cycles=%0d held=%0d operands=%0d overwritten=%0d",cycles,stalls,older,overwrites);$finish;
   end
   if(cycles>3000)$fatal(1,"forward: deadline");
  end
 end
 string f0,f1;
 initial begin
  for(integer c=0;c<2;c++)delay_count[c]=0;
  for(integer j=0;j<1024;j++)begin image0[j]=32'heafffffe;image1[j]=32'heafffffe;end
  if(!$value$plusargs("img0=%s",f0)||!$value$plusargs("img1=%s",f1))$fatal(1,"forward: need images");
  $readmemh(f0,image0);$readmemh(f1,image1);
  repeat(4)@(negedge clk);rst=0;
 end
endmodule
