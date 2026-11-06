 logic cpu_reset=0,irq=0;wire cpu_rst=rst||cpu_reset;
 int scenario=0,pause_left=0;bit intervention=0;
 logic xr,xwe,xdone=0;logic[17:2]xa;logic[31:0]xq=0;
 logic a9_req=0,a9_ack,a9_rvalid;logic[31:0]a9_addr=32'h02010000,a9_rdata;
 int a9_returns=0,a9_gap=0;
 bit held_packet=0;logic[67:0]packet_descriptor;
 always @(posedge clk)begin
  xdone<=!rst&&xr&&!xdone;
  if(!rst&&xr&&!xdone)begin
   assert(!xwe&&{xa,2'b00}>=18'h18000&&{xa,2'b00}<18'h1c000)else $fatal(1,"unexpected BIOS owner");
   xq<=xa==16'h6006 ? 32'he25ef004 : 32'd0;
  end
  if(rst)held_packet<=0;
  else if(fr&&fn)begin
   if(held_packet)assert({fa,fseq,fgen,fword,fn}==packet_descriptor[37:0])
    else $fatal(1,"old physical descriptor changed before tailACK");
   if(!held_packet)packet_descriptor<={30'd0,fa,fseq,fgen,fword,fn};
   held_packet<=!ack;
  end
  if(scenario==4&&!rst)begin
   if(a9_req&&a9_ack)begin
    assert(a9_rdata==(32'hc9000000|32'(a9_returns%16)))else $fatal(1,"A9 pressure value/order");
    a9_returns++;a9_req<=0;a9_gap<=3;
   end else if(a9_gap>0)a9_gap<=a9_gap-1;
   else if(active&&!a9_req&&a9_returns<32)begin
    a9_req<=1;a9_addr<=32'h02010000+32'((a9_returns%16)*4);
   end
  end
 end
 always @(negedge clk)if(!rst&&!finished)begin
  if(!intervention&&active&&cpu.e_mul)begin
   if((scenario==1||scenario==3)&&cpu.esub==1)begin
    intervention=1;
    if(scenario==1)begin run=0;pause_left=8;end
    else irq=1;
   end else if(scenario==2&&cpu.esub==0&&fr&&fn&&!ack)begin
    intervention=1;cpu_reset=1;run=0;pause_left=8;
    active=0;start_tick=-1;end_tick=-1;mul_steps=0;mul_retired=0;
    i_during_mul=0;consume_during_mul=0;fetches=0;phys_requests=0;
    phase_prepares=0;phase_commits=0;phase_finishes=0;phase_errors=0;
    finish_cycle=-1;prepare_cycle=-1;
    $fdisplay(statefd,"RESET,%0d",cycle);$fdisplay(datafd,"RESET,%0d",cycle);
   end
  end else if(pause_left>0)begin
   pause_left--;if(pause_left==0)begin cpu_reset=0;run=1;end
  end
  if(irq&&cpu.cpsr[4:0]==M_IRQ)irq=0;
 end
