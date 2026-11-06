// Passive joined52 observer: input ports and private host-file state only.
// Runtime activation: +iocause=/absolute/fresh/prefix. No timing target.
`timescale 1ns/1ps
module memory_io_cause_observer (
 input wire cpu_clk,sys_clk,rst,ce,
 input wire er,et,ew,input wire[3:0] eb,input wire[31:0] ea,ed,ep,
 input wire wq,wcp,ww,ok,abort_w,input wire[3:0] wb,
 input wire[31:0] wa,wd,wp,rd,input wire[4:0] state,
 input wire dpv,dpl,dpldm,input wire[31:0] dpa,
 input wire nbs,nbo,nba,push,hold_cpu,dwait,ret,read_ack,rb,
 input wire owned,retry,kill,have,hazard,sbub,fetch_en,f2v,pv,
 input wire[2:0] ibn,input wire[31:0] fp,up,e1p,e2p,
 input wire e1v,e2v,e3v,
 input wire br,bw,ba,input wire[31:0] baddr,bwd,brd,input wire[3:0] bbe,
 input wire[3:0] grant,input wire[3:0] fst,input wire[1:0] mst,
 input wire igrant,isent,ir,ic,iw,input wire[3:0] ibe,
 input wire[31:0] ia,iwd,ird,input wire sysreq,dispreq,tick,
 input wire timer_commit,input wire[15:0] timer_count,timer_control
);
 function automatic bit target(input logic[31:0] a);
  return a[31:2]==30'h01000001 || a[31:2]==30'h01000004 || a[31:2]==30'h01000042;
 endfunction
 integer cf=0,bf=0,prior=0;
 longint unsigned cc=0,sc=0,cn=0,bn=0,cdrop=0,bdrop=0;
 string prefix;
 initial if($value$plusargs("iocause=%s",prefix))begin
  cf=$fopen({prefix,".cpu.csv"},"r");
  if(cf)begin $fclose(cf);$fatal(1,"IOCAUSE preserve CPU trace");end
  bf=$fopen({prefix,".bus.csv"},"r");
  if(bf)begin $fclose(bf);$fatal(1,"IOCAUSE preserve bus trace");end
  cf=$fopen({prefix,".cpu.csv"},"w");bf=$fopen({prefix,".bus.csv"},"w");
  if(!cf||!bf)$fatal(1,"IOCAUSE open trace");
  $fdisplay(cf,"#IOCAUSE1 CPU preposedge; hex fields prefixed0x; time_ps is unshifted realtime; window16 after last target; cap250000");
  $fdisplay(cf,"event,edge,time_ps,rst,ce,E3_req,E3_tid,E3_we,E3_be,E3_addr,E3_data,E3_pc,W_req,W_cp,W_we,W_be,W_addr,W_data,W_pc,W_ready,W_abort,W_rdata,mem_state,dp_v,dp_addr,dp_block,dp_ldm,nb_slot,nb_owned,nb_ack,wd_push,cpu_hold,d_wait,read_return,read_ack,rbuf_v,io_owned,io_retry,kill,have,hazard,sbub,fetch_en,f2_v,p_v,ib4_n,F_pc,D_pc,E1_pc,E2_pc,E1_v,E2_v,E3_v");
  $fdisplay(bf,"#IOCAUSE1 BUS preposedge; physical67MHz not DS SYS ticks; owner is grant on igrant otherwise mst; cap150000");
  $fdisplay(bf,"event,edge,time_ps,rst,tick,b9_req,b9_we,b9_ack,b9_addr,b9_be,b9_wdata,b9_rdata,fab_state,grant,mst,io_grant,io_sent,io_req,io_cpu,io_we,io_addr,io_be,io_wdata,io_rdata,sys_req,disp_req,tm2_commit,tm2_count,tm2_control");
 end
 always @(posedge cpu_clk)begin
  if(cf)begin
   if((er&&!et&&target(ea))||(wq&&target(wa))||(dpv&&target(dpa)))prior=16;
   else if(prior!=0)prior=prior-1;
   if(prior!=0 || rst)begin
    if(cn<250000)begin
     $fdisplay(cf,"CPU,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,0x%08x,0x%08x,0x%08x,%0d,%0d,%0d,%0d,0x%08x,0x%08x,0x%08x,%0d,%0d,0x%08x,%0d,%0d,0x%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,0x%08x,0x%08x,0x%08x,0x%08x,%0d,%0d,%0d",cc,64'($realtime/1ps),rst,ce,er,et,ew,eb,ea,ed,ep,wq,wcp,ww,wb,wa,wd,wp,ok,abort_w,rd,state,dpv,dpa,dpl,dpldm,nbs,nbo,nba,push,hold_cpu,dwait,ret,read_ack,rb,owned,retry,kill,have,hazard,sbub,fetch_en,f2v,pv,ibn,fp,up,e1p,e2p,e1v,e2v,e3v);cn=cn+1;
    end else cdrop=cdrop+1;
   end
  end
  cc=cc+1;
 end
 always @(posedge sys_clk)begin
  if(bf&&((br&&target(baddr))||(ir&&target(ia))||rst))begin
   if(bn<150000)begin
    $fdisplay(bf,"BUS,%0d,%0d,%0d,%0d,%0d,%0d,%0d,0x%08x,%0d,0x%08x,0x%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,0x%08x,%0d,0x%08x,0x%08x,%0d,%0d,%0d,%0d,%0d",sc,64'($realtime/1ps),rst,tick,br,bw,ba,baddr,bbe,bwd,brd,fst,grant,mst,igrant,isent,ir,ic,iw,ia,ibe,iwd,ird,sysreq,dispreq,timer_commit,timer_count,timer_control);bn=bn+1;
   end else bdrop=bdrop+1;
  end
  sc=sc+1;
 end
 final begin
  if(cf)begin $fdisplay(cf,"END,%0d,%0d",cn,cdrop);$fclose(cf);end
  if(bf)begin $fdisplay(bf,"END,%0d,%0d",bn,bdrop);$fclose(bf);end
 end
endmodule
`define IOC_CPU u_cpud.g_one.u_cpu
`define IOC_CORE `IOC_CPU.u_core
`define IOC_MEM `IOC_CPU.u_mem9
bind nds_top memory_io_cause_observer memory_iocause52 (
 .cpu_clk(`IOC_CPU.clk),.sys_clk(clk),.rst(rst),.ce(`IOC_CORE.ce),
 .er(`IOC_CPU.d_req),.et(`IOC_CPU.d_tid),.ew(`IOC_CPU.d_we),.eb(`IOC_CPU.d_be),
 .ea(`IOC_CPU.d_addr),.ed(`IOC_CPU.d_wdata),.ep(`IOC_CORE.e3.pc),
 .wq(`IOC_MEM.wq_e),.wcp(`IOC_MEM.wcp_e),.ww(`IOC_MEM.w_we),.ok(`IOC_MEM.d_ok),.abort_w(`IOC_MEM.d_abort),
 .wb(`IOC_MEM.w_be),.wa(`IOC_MEM.w_addr),.wd(`IOC_MEM.w_wdata),.wp(`IOC_CORE.w_pc),.rd(`IOC_CPU.m_d_rdata),.state(5'(`IOC_MEM.st)),
 .dpv(`IOC_MEM.dp_v),.dpa(`IOC_MEM.dp_a),.dpl(`IOC_MEM.dp_block),.dpldm(`IOC_MEM.dp_ldm),
 .nbs(`IOC_MEM.nb_slot),.nbo(`IOC_MEM.nb_owned),.nba(`IOC_MEM.nb_ack),.push(`IOC_MEM.wd_push),.hold_cpu(`IOC_MEM.cpu_hold),
 .dwait(`IOC_MEM.d_wait),.ret(`IOC_MEM.read_return),.read_ack(`IOC_MEM.read_ack),.rb(`IOC_MEM.rbuf_v),
 .owned(`IOC_MEM.io_replay_owned),.retry(`IOC_CORE.io_retry_go),.kill(`IOC_CORE.kill_e),.have(`IOC_CORE.have),.hazard(`IOC_CORE.hazard),.sbub(`IOC_CORE.sbub),
 .fetch_en(`IOC_CORE.fetch_en),.f2v(`IOC_CORE.f2_v),.pv(`IOC_CORE.p_v),.ibn(`IOC_CORE.ib4_n),.fp(`IOC_CORE.fetch_pc[0]),.up(`IOC_CORE.u.pc),
 .e1p(`IOC_CORE.e1.pc),.e2p(`IOC_CORE.e2.pc),.e1v(`IOC_CORE.e1.valid),.e2v(`IOC_CORE.e2.valid),.e3v(`IOC_CORE.e3.valid),
 .br(b9_req),.bw(b9_we),.ba(b9_ack),.baddr(b9_addr),.bwd(b9_wdata),.brd(b9_rdata),.bbe(b9_be),
 .grant(u_fab.grant),.fst(4'(u_fab.st)),.mst(u_fab.mst),.igrant(u_fab.io_grant),.isent(u_fab.io_sent),
 .ir(io_req),.ic(io_cpu),.iw(io_we),.ibe(io_be),.ia({8'h04,io_addr,2'b00}),.iwd(io_wdata),.ird(io_rdata),
 .sysreq(sys_req),.dispreq(disp_req),.tick(tick),.timer_commit(u_sys.tmr_oh[2]),.timer_count(u_sys.t9_rd[15:0]),.timer_control(u_sys.u_tmr9.cnt[2])
);
`undef IOC_CPU
`undef IOC_CORE
`undef IOC_MEM
