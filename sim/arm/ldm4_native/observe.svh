// Host-only observer. No DUT deposits, force, request or clock changes.
`define L4C dut.ds.u_cpud.g_one.u_cpu.g_a7ds.u_a7
`define L4P dut.ds.u_cpud.g_a7c.u_p7
bit l4_enabled=0,l4_pending=0,l4_list=0,l4_phys=0;
integer l4_words=0,l4_lists=0,l4_admits=0,l4_acks=0,l4_returns=0,l4_held=0,l4_oldhit=0;
integer l4_wfd=0,l4_sfd=0,l4_efd=0;
longint unsigned l4_clock=0;
logic[31:0]l4_addr,l4_pc,l4_ins,l4_start,l4_physaddr;
logic[1:0]l4_beat,l4_next=0;
string l4_prefix;
initial begin
 l4_enabled=$value$plusargs("ldm4_observe=%s",l4_prefix);
 if(l4_enabled)begin
  l4_wfd=$fopen({l4_prefix,".words"},"w");l4_sfd=$fopen({l4_prefix,".state"},"w");l4_efd=$fopen({l4_prefix,".edges"},"w");
  if(!l4_wfd||!l4_sfd||!l4_efd)$fatal(1,"LDM4_OBSERVER_FILES");
 end
 #1;
 if(dut.ds.u_cpud.LDM4_META!=1 || `L4C.LDM4_META!=1 ||
    `L4P.MAIN_LDM4_ACK!=`L4_EXPECT_ACK || dut.A7_DATA_ACK!=0 ||
    dut.CPU_FAST!=0 || dut.A9_SOLO!=5 || dut.ARM7_CACHE!=1 ||
    dut.A7_IF_COMMIT!=1 || dut.A7_IF_PHASE_META!=1 || dut.A7_IF_PHASE_SERVICE!=1)
    $fatal(1,"LDM4_NATIVE_ROUTE");
 $display("LDM4_NATIVE_ROUTE_PASS ACK%0d META1 genericACK0 reference",`L4_EXPECT_ACK);
end
always @(posedge dut.clk_sys)if(l4_enabled)begin
 l4_clock++;
 if(`L4C.rst)begin l4_pending=0;l4_list=0;l4_next=0;end
 else begin
  if(`L4P.d_ldm4_request!==`L4C.ldm4_request || `L4P.d_ldm4_accept!==`L4C.ldm4_accept ||
     `L4P.d_ldm4_cancel!==`L4C.rst)$fatal(1,"LDM4_NATIVE_PUBLIC_PINS");
  if(`L4C.ldm4_request.valid)begin
   if(`L4C.ph || !`L4P.d_req || `L4P.d_we || `L4P.d_be!=15)$fatal(1,"LDM4_NATIVE_OFFER_PHASE");
   if(!l4_pending)begin
    l4_pending=1;l4_addr=`L4P.d_addr;l4_beat=`L4C.ldm4_request.beat;l4_pc=`L4C.pc;l4_ins=`L4C.ins;
    if(l4_beat!=l4_next)$fatal(1,"LDM4_NATIVE_BEAT_ORDER");
    if(l4_beat==0)begin if(l4_list)$fatal(1,"LDM4_NATIVE_DUPLICATE_LIST");l4_list=1;l4_start=l4_addr;end
    if(l4_addr!=l4_start+32'(4*l4_beat))$fatal(1,"LDM4_NATIVE_ADDRESS_ORDER");
   end else if({`L4P.d_addr,`L4C.ldm4_request.beat,`L4C.pc,`L4C.ins}!=={l4_addr,l4_beat,l4_pc,l4_ins})
    $fatal(1,"LDM4_NATIVE_HELD_OFFER_CHANGED");
  end
  if(`L4P.ldm_read_allocate && `L4C.ldm4_request.valid)begin
   if(l4_phys)$fatal(1,"LDM4_NATIVE_DUPLICATE_PHYSICAL_OWNER");
   l4_phys=1;l4_physaddr=`L4P.d_addr;l4_admits++;
  end
  if(l4_phys && `L4P.busy && !`L4P.busy_w && !`L4P.rp_i && `L4P.f_ack)begin
   if(`L4P.rp_a!==l4_physaddr)$fatal(1,"LDM4_NATIVE_PHYSICAL_OWNER_CHANGED");
   l4_phys=0;l4_acks++;
  end
  if(l4_pending)begin
   if(`L4P.ldm_return)l4_returns++;
   if(`L4P.ldm_held)l4_held++;
   if(`L4C.ldm4_request.valid && `L4P.rb_v && `L4P.rb_a[31:2]==`L4P.d_addr[31:2])l4_oldhit++;
   $fdisplay(l4_efd,"%0d,%h,%h,%0d,%b,%b,%b,%b,%b,%b,%b,%b,%h,%b,%b,%b,%b,%b,%b,%b,%b,%h,%h,%0d,%b,%b,%0d,%b,%0d",
    l4_clock,l4_pc,l4_addr,l4_beat,`L4C.ph,`L4C.run,`L4C.if_wait,`L4P.d_req,`L4P.d_ok,`L4C.ldm4_accept,
    `L4P.rp_v,`L4P.rp_i,`L4P.rp_a,`L4P.busy,`L4P.busy_w,`L4P.f_ack,`L4P.ldm_return,`L4P.ldm_held,`L4P.ldm_rp,`L4P.ldm_rb,
    dut.ds.b9_req,dut.ds.b9_addr,dut.ds.u_fab.grant,dut.ds.u_fab.mst,dut.mr_req,dut.mr_ack,dut.ds.u_mrarb.own,dut.psram.m_busy,dut.psram.state);
  end
  if(`L4C.ldm4_accept)begin
   if(!l4_pending || !`L4C.ph || !`L4C.run || `L4C.if_wait || !`L4P.d_ok)$fatal(1,"LDM4_NATIVE_ACCEPT_OWNER_PHASE");
   if(`L4P.d_addr!==l4_addr || `L4P.d_rdata!==ram_word(integer'((l4_addr & 32'h3fffff)>>2)))
    $fatal(1,"LDM4_NATIVE_WRONG_PAYLOAD addr%h got%h backing%h",l4_addr,`L4P.d_rdata,ram_word(integer'((l4_addr & 32'h3fffff)>>2)));
   if(`L4_EXPECT_ACK && !`L4P.ldm_consume)$fatal(1,"LDM4_NATIVE_ACCEPT_WITHOUT_RECEIVER_CONSUME");
   l4_words++;
   $fdisplay(l4_wfd,"%0d,%h,%h,%0d,%h,%h,%h",l4_words,l4_pc,l4_ins,l4_beat,l4_addr,`L4P.d_rdata,`L4C.dbg_cpsr);
   l4_pending=0;l4_next=l4_beat+2'd1;
  end
  if(l4_list && `L4C.pipe_fire && `L4C.e_blk && `L4C.esub==2)begin
   if(l4_pending || l4_next!=0)$fatal(1,"LDM4_NATIVE_LIST_RETIRED_EARLY");
   l4_lists++;$fwrite(l4_sfd,"%0d,%h,%h,%h",l4_lists,l4_pc,l4_ins,`L4C.dbg_cpsr);
   for(integer k=0;k<32;k++)$fwrite(l4_sfd,",%h",`L4C.rf[k]);
   for(integer k=0;k<32;k++)$fwrite(l4_sfd,",%h",`L4C.rfb[k]);
   for(integer k=0;k<5;k++)$fwrite(l4_sfd,",%h",`L4C.spsr[k]);
   $fwrite(l4_sfd,"\n");l4_list=0;
  end
 end
end
final if(l4_enabled)begin
 $display("LDM4_NATIVE_ACTIVITY words%0d lists%0d admissions%0d physicalACKs%0d returns%0d heldedges%0d legacyhitoffers%0d pending%b listlive%b physical%b",l4_words,l4_lists,l4_admits,l4_acks,l4_returns,l4_held,l4_oldhit,l4_pending,l4_list,l4_phys);
 $fclose(l4_wfd);$fclose(l4_sfd);$fclose(l4_efd);
end
`undef L4C
`undef L4P
