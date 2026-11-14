module tb #(parameter bit FAULT_OWNER=0);
 logic clk2=1,clk_sys=0,rst=1;
 always #5 clk2=~clk2;
 always #10 clk_sys=~clk_sys;
 logic[1:0] ni_req,ni_priv,ni_ok,ni_abort=0;
 logic[31:0] ni_addr[0:1],ni_data[0:1];
 logic[1:0] nd_req,nd_we,nd_priv,nc_req,nc_we,nd_ok,nd_abort=0;
 logic[1:0] nd_size[0:1];logic[3:0] nd_be[0:1];
 logic[31:0] nd_addr[0:1],nd_data[0:1],nd_rdata[0:1];logic[15:0]nc_op[0:1];
 logic dbg_wen,dbg_retire,dbg_tid;logic[5:0]dbg_wa;
 logic[31:0]dbg_wd,dbg_pc,dbg_cpsr;logic[1:0]dbg_halt;
 logic[31:0] mem[0:1][0:4095];
 logic[1:0]done=0;integer cycles=0,reads=0,writes=0,concurrent=0,retired[0:1];
 logic[1:0] old_ireq=0,old_dreq=0;
 logic[31:0] old_ia[0:1],old_da[0:1],old_dd[0:1];
 logic[3:0]old_be[0:1];logic[1:0]old_we;
 integer waitmode=1;integer slots[0:1],prevslots[0:1];
 arm_dual_shared #(.FAULT_OWNER(FAULT_OWNER)) dut(.clk2,.clk_sys,.rst,.run(2'b11),.hivecs(2'b00),.irq(2'b00),.fiq(2'b00),.halt_req(2'b00),.wake(2'b00),.native_wait(2'b00),
 .reset_pc0(32'h02000000),.reset_pc1(32'h02000000),
 .ni_req,.ni_priv,.ni_addr,.ni_data,.ni_ok,.ni_abort,.nd_req,.nd_we,.nd_priv,.nc_req,.nc_we,.nd_size,.nd_be,.nd_addr,.nd_data,.nc_op,.nd_rdata,.nd_ok,.nd_abort,
 .dbg_wen,.dbg_retire,.dbg_tid,.dbg_wa,.dbg_wd,.dbg_pc,.dbg_cpsr,.dbg_halt);
 always_comb begin
  for(int c=0;c<2;c=c+1)begin
   ni_data[c]=mem[c][ni_addr[c][13:2]];
   nd_rdata[c]=mem[c][nd_addr[c][13:2]];
   ni_ok[c]=ni_req[c]&&(waitmode==0||(waitmode==1?cycles%5!=c:cycles%17>=12));
   nd_ok[c]=(nd_req[c]||nc_req[c])&&(waitmode==0||(waitmode==1?cycles%7!=c:cycles%17>=12));
  end
 end
 always @(posedge clk_sys)if(!rst)begin
  cycles=cycles+1;
  if(cycles>1&&(slots[0]-prevslots[0]!=1||slots[1]-prevslots[1]!=1))$fatal(1,"fixed-slot capacity violation");
  prevslots[0]=slots[0];prevslots[1]=slots[1];
  if((ni_req[0]||nd_req[0])&&(ni_req[1]||nd_req[1]))concurrent=concurrent+1;
  for(int c=0;c<2;c=c+1)begin
   if(old_ireq[c]&&ni_addr[c]!==old_ia[c])$fatal(1,"native I packet not held");
   if(old_dreq[c]&&{nd_addr[c],nd_data[c],nd_we[c],nd_be[c]}!=={old_da[c],old_dd[c],old_we[c],old_be[c]})$fatal(1,"native D packet not held");
   old_ireq[c]=ni_req[c]&&!ni_ok[c];old_ia[c]=ni_addr[c];
   old_dreq[c]=nd_req[c]&&!nd_ok[c];old_da[c]=nd_addr[c];old_dd[c]=nd_data[c];old_we[c]=nd_we[c];old_be[c]=nd_be[c];
   if(nd_req[c]&&nd_ok[c])begin
    if(nd_we[c])begin
     writes=writes+1;
     if($test$plusargs("debug"))$display("NATIVE_STORE SYS%0d c%0d a%h d%h",cycles,c,nd_addr[c],nd_data[c]);
     for(int b=0;b<4;b=b+1)if(nd_be[c][b])mem[c][nd_addr[c][13:2]][b*8+:8]<=nd_data[c][b*8+:8];
     if(nd_addr[c]==32'h0f000000)begin
      if(nd_data[c]!=0)$fatal(1,"SELF_CHECK_FAIL context%0d result%h",c,nd_data[c]);
      done[c]=1;
     end
    end else reads=reads+1;
   end
  end
  if(&done)begin
   if(writes!=4)$fatal(1,"duplicate/lost native store writes=%0d",writes);
   if(concurrent==0||retired[0]==0||retired[1]==0)$fatal(1,"missing dual progress");
   $display("SHARED_EXEC_PASS SYS=%0d reads=%0d writes=%0d concurrent=%0d retire0=%0d retire1=%0d slots0=%0d slots1=%0d",cycles,reads,writes,concurrent,retired[0],retired[1],slots[0],slots[1]);$finish;
  end
  if(cycles==10000)begin
   $display("STATE Ireq%b Ibusy%b consumed%b lastv%b Dbusy%b consumed%b lastv%b corefetch%h/%h qI%h/%h lastI%h/%h rh%b%b ib%b%b ib1%b%b",ni_req,dut.ibusy,dut.idone,dut.last_iv,dut.dbusy,dut.ddone,dut.last_dv,dut.engine.fetch_pc[0],dut.engine.fetch_pc[1],dut.iq[0],dut.iq[1],dut.last_i[0],dut.last_i[1],dut.engine.rh[0],dut.engine.rh[1],dut.engine.ib_v[0],dut.engine.ib_v[1],dut.engine.ib1_v[0],dut.engine.ib1_v[1]);
   $fatal(1,"shared engine timeout pc%h ctx%0d done%h",dbg_pc,dbg_tid,done);end;
 end
 always @(negedge clk2)if(!rst)begin
  slots[dut.engine.c0]=slots[dut.engine.c0]+1;
  if(dbg_retire)begin
   retired[dbg_tid]=retired[dbg_tid]+1;
   if($test$plusargs("debug")&&cycles<300)$display("RET SYS%0d c%0d pc%h cpsr%h",cycles,dbg_tid,dbg_pc,dbg_cpsr);
  end
  if($test$plusargs("debug")&&cycles<300&&(dut.cd_req||dut.cc_req))$display("CORE_D SYS%0d c%0d a%h d%h we%0d busy%0d consumed%0d",cycles,dut.cd_tid,dut.cd_addr,dut.cd_wdata,dut.cd_we,dut.dbusy[dut.cd_tid],dut.ddone[dut.cd_tid]);
 end
 initial begin
  string p0,p1;
  retired[0]=0;retired[1]=0;slots[0]=0;slots[1]=0;prevslots[0]=0;prevslots[1]=0;
  if($value$plusargs("waitmode=%d",waitmode))begin end
  for(int c=0;c<2;c=c+1)for(int a=0;a<4096;a=a+1)mem[c][a]=0;
  if(!$value$plusargs("img0=%s",p0)||!$value$plusargs("img1=%s",p1))$fatal(1,"missing images");
  $readmemh(p0,mem[0]);$readmemh(p1,mem[1]);
  repeat(4)@(posedge clk_sys);#1;rst=0;
 end
endmodule
