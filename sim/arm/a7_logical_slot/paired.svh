 // A test-only blocked logical-consume link. This exercises real receiver
 // slot backpressure; it is not a regional service price or a DS model.
 wire cv,ca; wire[31:0]cvaddr;
 logic bridge_active=0;integer bridge_left=0;logic[31:0]bridge_owner;
 wire bridge_start=scenario==5&&policy!=0&&active&&!intervention&&cpu.phase_next_commit;
 wire bridge_release=bridge_active&&bridge_left==0;
 wire p7_consume=(bridge_start||bridge_active)?bridge_release:iconsume;
 wire[31:0]p7_address=bridge_active?bridge_owner:ia;
 wire p7_request=(bridge_start||bridge_active)?1'b0:ir;
 integer slotfd=0,pinfd=0,fullfd=0;
 integer slot_offers=0,slot_accepts=0,slot_waits=0,slot_turns=0;
 always @(posedge clk)begin
  if(cpu_rst)begin
   bridge_active<=0;bridge_left<=0;
   slot_offers=0;slot_accepts=0;slot_waits=0;slot_turns=0;
  end else begin
   if(bridge_start)begin
    bridge_active<=1;bridge_owner<=ia;bridge_left<=8;intervention<=1;
   end else if(bridge_active)begin
    if(bridge_left>0)bridge_left<=bridge_left-1;
    else begin
     assert(ca)else $fatal(1,"paired blocked slot did not accept held offer");
     bridge_active<=0;
    end
   end
   if(active)begin
    if(cpu.phase_next_commit)slot_offers++;
    if(cv&&!ca)slot_waits++;
    if(ca)begin slot_accepts++;if(p7_consume&&p7.flow_v)slot_turns++;end
   end
  end
  if(slotfd)$fdisplay(slotfd,"%0d,%b,%h,%b,%b,%b,%h,%b,%h,%0d,%b,%b,%0d",
   cycle,cv,cvaddr,ca,iconsume,p7_consume,p7_address,p7.flow_v,{p7.flow_a,2'b0},p7.flow_left,
   bridge_start,bridge_active,bridge_left);
  if(fullfd)$fdisplay(fullfd,"%0d %0d %0d %0d %0d %h %h %h %b %b %h %b %b %h %h %b %b %b %b %h %h %b %b %b %b %h %0d",
   cycle,cpu.st,cpu.ph,cpu.esub,cpu.wcnt,cpu.pc,cpu.ins,ia,ir,io,iq,dr,dw,da,dd,dok,iconsume,
   iredirect,fr,fa,fq,rv,ack,fn,p7.flow_v,{p7.flow_a,2'b0},p7.flow_left);
 end
 always @(posedge clk_mem)if(pinfd)$fdisplay(pinfd,"%0t %h",$time,pins);
