module native_tb #(parameter bit FAULT_OWNER=0,parameter bit FAULT_LAUNCH=0);
 logic clk2=1,clk_sys=0,rst=1;
 always #5 clk2=~clk2;
 always #10 clk_sys=~clk_sys;
 logic[1:0]irq=0,dbg_halt,dg_fill;
 logic wake7;
 logic b9_n8,b9_req,b9_we,b9_ack;
 logic[31:0]b9_addr,b9_wdata,b9_rdata;
 logic[3:0]b9_be,b9_tmr;
 logic a7_i_req,a7_i_ok,a7_d_req,a7_d_we,a7_d_ok;
 logic[31:0]a7_i_addr,a7_i_rdata,a7_d_addr,a7_d_wdata,a7_d_rdata;
 logic[3:0]a7_d_be;
 logic dbg_wen,dbg_retire,dbg_tid;logic[5:0]dbg_wa;
 logic[31:0]dbg_wd,dbg_pc,dbg_cpsr;
 logic[31:0]mem0[0:4095],mem1[0:4095];
 integer cycles=0,waitmode=1,halt_cycle=0,halt_events=0,irq_events=0,postwake=0,cpwrites=0,cpreads=0,a9stores=0,a7stores=0,buswrites=0,overlap=0,waitcycles=0,other_progress_wait=0,native_cp_commits=0;
 integer slots[0:1],prevslots[0:1],retired[0:1];
 logic[1:0]done=0;
 bit irq_mode_seen=0,halt_seen=0,reset_pending=0,reset_performed=0,reset_had_pending=0;
 logic old_breq=0,old_i7=0,old_d7=0;
 logic[31:0]old_ba,old_bd,old_i7a,old_d7a,old_d7d;
 logic[3:0]old_bbe,old_d7be;logic old_bw,old_d7w;
 arm_cpu_shared #(.FAULT_OWNER(FAULT_OWNER),.FAULT_LAUNCH(FAULT_LAUNCH)) dut(
 .clk_sys,.clk2,.rst,.run(2'b11),.irq,.fiq(2'b00),.reset_pc0(32'h02000000),.reset_pc1(32'h02000000),.hivecs7(1'b0),.wake7,
 .b9_n8,.b9_req,.b9_we,.b9_addr,.b9_wdata,.b9_be,.b9_tmr,.b9_wnext(1'b0),.b9_ack,.b9_rdata,
 .a7_i_req,.a7_i_addr,.a7_i_rdata,.a7_i_ok,.a7_d_req,.a7_d_we,.a7_d_addr,.a7_d_wdata,.a7_d_be,.a7_d_rdata,.a7_d_ok,
 .dbg_wen,.dbg_retire,.dbg_tid,.dbg_wa,.dbg_wd,.dbg_pc,.dbg_cpsr,.dbg_halt,.dg_fill);
 wire ready_i=waitmode==0||(waitmode==1?cycles%5!=1:cycles%17>=12);
 wire ready_d=waitmode==0||(waitmode==1?cycles%7!=1:cycles%17>=12);
 wire ready_b=waitmode==0||(waitmode==1?cycles%7!=3:cycles%17>=12);
 assign a7_i_ok=a7_i_req&&ready_i&&!rst;
 assign a7_d_ok=a7_d_req&&ready_d&&!rst;
 assign b9_ack=b9_req&&ready_b&&!rst;
 assign b9_rdata=mem0[b9_addr[13:2]];
 assign a7_i_rdata=mem1[a7_i_addr[13:2]];
 assign a7_d_rdata=mem1[a7_d_addr[13:2]];
 assign wake7=halt_seen&&cycles>=halt_cycle+20;
 task bus_store(input integer c,input logic[31:0]a,d,input logic[3:0]be);
  begin
   if(a[27:24]!=4'hf&&a[27:24]!=4'h4)for(integer b=0;b<4;b=b+1)if(be[b])begin if(c==0)mem0[a[13:2]][b*8+:8]<=d[b*8+:8];else mem1[a[13:2]][b*8+:8]<=d[b*8+:8];end
   if(a==32'h0f000000)begin
    if(d!=0)$fatal(1,"SELF_CHECK_FAIL context%0d result%h",c,d);
    if(done[c])$fatal(1,"duplicate exit store");
    done[c]=1;
   end
   if(c==0&&a==32'h0f000004)begin irq[0]=1;irq_events=irq_events+1;end
   if(c==1&&a==32'h0f000008)begin if(!wake7)$fatal(1,"ARM7 progressed before wake");postwake=postwake+1;end
   if(c==1&&a[31:2]==30'h010000c0&&be[1]&&d[15:8]==8'h80)begin halt_events=halt_events+1;halt_seen=1;halt_cycle=cycles;end
  end
 endtask
 always @(posedge clk_sys)begin
  if(rst)begin
   cycles=0;done=0;irq=0;irq_mode_seen=0;halt_seen=0;halt_events=0;irq_events=0;postwake=0;cpwrites=0;cpreads=0;a9stores=0;a7stores=0;buswrites=0;overlap=0;waitcycles=0;other_progress_wait=0;native_cp_commits=0;
   old_breq=0;old_i7=0;old_d7=0;prevslots[0]=0;prevslots[1]=0;
  end else begin
   cycles=cycles+1;
   if(cycles>1&&(slots[0]-prevslots[0]!=1||slots[1]-prevslots[1]!=1))$fatal(1,"slot capacity changed");
   prevslots[0]=slots[0];prevslots[1]=slots[1];
   if(irq_mode_seen)irq[0]=0;
   if((dut.ni_req[0]||dut.nd_req[0]||dut.nc_req[0]||b9_req)&&(a7_i_req||a7_d_req))overlap=overlap+1;
   if(old_breq&&({b9_addr,b9_be,b9_we}!=={old_ba,old_bbe,old_bw}||(old_bw&&b9_wdata!==old_bd)))$fatal(1,"ARM9 bus packet changed before ACK");
   if(old_i7&&a7_i_addr!==old_i7a)$fatal(1,"ARM7 I packet changed before ACK");
   if(old_d7&&{a7_d_addr,a7_d_wdata,a7_d_be,a7_d_we}!=={old_d7a,old_d7d,old_d7be,old_d7w})$fatal(1,"ARM7 D packet changed before ACK");
   old_breq=b9_req&&!b9_ack;old_ba=b9_addr;old_bd=b9_wdata;old_bbe=b9_be;old_bw=b9_we;
   old_i7=a7_i_req&&!a7_i_ok;old_i7a=a7_i_addr;
   old_d7=a7_d_req&&!a7_d_ok;old_d7a=a7_d_addr;old_d7d=a7_d_wdata;old_d7be=a7_d_be;old_d7w=a7_d_we;
   if(dut.m_d_wait)waitcycles=waitcycles+1;
   if(dut.u_mem9.cp_write)native_cp_commits=native_cp_commits+1;
   if(dut.nd_ok[0]&&dut.nc_req[0])begin
    if(!dut.u_mem9.w_cp||dut.u_mem9.w_cpop!==dut.nc_op[0]||dut.u_mem9.w_cpwe!==dut.nc_we[0]||(dut.nc_we[0]&&dut.u_mem9.w_wdata!==dut.nd_data[0]))$fatal(1,"NATIVE_CP_OWNER_FAIL");
   end
   if(dut.nd_ok[0]&&dut.nd_req[0])begin
    if(!dut.u_mem9.w_req||dut.u_mem9.w_addr!==dut.nd_addr[0]||dut.u_mem9.w_we!==dut.nd_we[0]||dut.u_mem9.w_be!==dut.nd_be[0]||(dut.nd_we[0]&&dut.u_mem9.w_wdata!==dut.nd_data[0]))$fatal(1,"NATIVE_DATA_OWNER_FAIL");
   end
   if(dut.nd_ok[0])begin
    if(dut.nc_req[0])begin if(dut.nc_we[0])cpwrites=cpwrites+1;else cpreads=cpreads+1;end
    if(dut.nd_req[0]&&dut.nd_we[0])a9stores=a9stores+1;
   end
   if(b9_req&&b9_ack&&b9_we)begin buswrites=buswrites+1;bus_store(0,b9_addr,b9_wdata,b9_be);end
   if(a7_d_req&&a7_d_ok&&a7_d_we)begin a7stores=a7stores+1;bus_store(1,a7_d_addr,a7_d_wdata,a7_d_be);end
   if(halt_seen&&cycles==halt_cycle+10&&!dbg_halt[1])$fatal(1,"ARM7 HALTCNT did not halt");
   if(&done)begin
    if(cpwrites!=18||cpreads!=1||halt_events!=1||postwake!=1||irq_events!=1||!irq_mode_seen||overlap==0)$fatal(1,"native feature/duplicate gate cp%0d/%0d halt%0d wake%0d irq%0d mode%0d overlap%0d",cpwrites,cpreads,halt_events,postwake,irq_events,irq_mode_seen,overlap);
    if(waitcycles==0||other_progress_wait==0||native_cp_commits!=16)$fatal(1,"real wait/ordinaryCPwrite gate %0d/%0d/%0d",waitcycles,other_progress_wait,native_cp_commits);
    if(a9stores!=6||a7stores!=4)$fatal(1,"native CPU store count %0d/%0d",a9stores,a7stores);
    if(reset_pending&&!reset_had_pending)$fatal(1,"reset did not cover pending work");
    $display("NATIVE_SHARED_PASS SYS=%0d CPwrite=%0d CPread=%0d stores9=%0d stores7=%0d buswrites=%0d overlap=%0d IRQ=%0d HALT=%0d postwake=%0d slots0=%0d slots1=%0d retired0=%0d retired1=%0d reset_pending=%0d waitcycles=%0d other_wait_progress=%0d ordinaryCP=%0d",cycles,cpwrites,cpreads,a9stores,a7stores,buswrites,overlap,irq_events,halt_events,postwake,slots[0],slots[1],retired[0],retired[1],reset_had_pending,waitcycles,other_progress_wait,native_cp_commits);$finish;
   end
   if(cycles==30000)begin
    $display("NATIVE_STATE done%b cp%0d/%0d irq%b mode%0d halted%b Iq%b Dq%b pc%h ctx%0d",done,cpwrites,cpreads,irq,irq_mode_seen,dbg_halt,dut.shared.ibusy,dut.shared.dbusy,dbg_pc,dbg_tid);
    $fatal(1,"native shared timeout");
   end
  end
 end
 always @(negedge clk2)begin
  if(rst)begin slots[0]=0;slots[1]=0;retired[0]=0;retired[1]=0;end
  else begin
   slots[dut.shared.engine.c0]=slots[dut.shared.engine.c0]+1;
   if(dbg_retire)begin retired[dbg_tid]=retired[dbg_tid]+1;if(dbg_tid&&dut.m_d_wait)other_progress_wait=other_progress_wait+1;end
   if(dut.shared.engine.c0==0&&dut.shared.engine.cpsr[0][4:0]==5'h12)irq_mode_seen=1;
   if($test$plusargs("debug")&&dbg_retire&&cycles<1600)$display("NRET SYS%0d c%0d pc%h cpsr%h",cycles,dbg_tid,dbg_pc,dbg_cpsr);
  end
 end
 initial begin
  string p0,p1;integer z;
  slots[0]=0;slots[1]=0;retired[0]=0;retired[1]=0;
  if($value$plusargs("waitmode=%d",waitmode))begin end
  if($value$plusargs("reset_pending=%d",z))reset_pending=(z!=0);
  for(integer a=0;a<4096;a=a+1)begin mem0[a]=0;mem1[a]=0;end
  if(!$value$plusargs("img0=%s",p0)||!$value$plusargs("img1=%s",p1))$fatal(1,"missing images");
  $readmemh(p0,mem0);$readmemh(p1,mem1);
  repeat(4)@(posedge clk_sys);#1;rst=0;
  if(reset_pending)begin
   repeat(50)@(negedge clk_sys);#1;
   reset_had_pending=(dut.ni_req!=0||dut.nd_req!=0||dut.nc_req!=0||b9_req);
   rst=1;repeat(3)@(posedge clk_sys);#1;rst=0;reset_performed=1;
  end
 end
endmodule
