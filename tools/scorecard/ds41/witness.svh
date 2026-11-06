// Passive, simulation-only DS41 witness, included inside tb_ds_pocket.
// No force, deposit, waits, additional guest access, output or core input.
// Default path is the single ARM9 arm_cpu in the production CPU-domain.
`ifndef DS41_SOC
 `define DS41_SOC dut.ds
`endif
`ifndef DS41_CPU
 `define DS41_CPU `DS41_SOC.u_cpud.g_one.u_cpu
`endif
`define DS41_MEM `DS41_CPU.u_mem9
`define DS41_SYS `DS41_SOC.u_sys
`define DS41_FAB `DS41_SOC.u_fab
integer ds41_fd=0,ds41_events=0,ds41_row=0;
reg [63:0] ds41_cc=0,ds41_sc=0;
string ds41_name;
initial if($value$plusargs("ds41_trace=%s",ds41_name))begin
 ds41_fd=$fopen(ds41_name,"w");if(!ds41_fd)$fatal(1,"DS41 witness file open failed");
 $fdisplay(ds41_fd,"{\"event\":\"schema\",\"version\":1,\"sampling\":\"pre-NBA posedge; TIMER_AFTER at following negedge\"}");
end
task automatic ds41_budget;
 ds41_events++;if(ds41_events>50000)$fatal(1,"DS41 passive witness event bound exceeded");
endtask
always @(posedge `DS41_CPU.clk)begin
 ds41_cc<=ds41_cc+1;
 if(ds41_fd)begin
  if(`DS41_MEM.wq_e&&`DS41_MEM.d_ok&&`DS41_MEM.wd_dtcm&&`DS41_MEM.w_we&&`DS41_MEM.w_addr==32'h02ff0040)begin
   ds41_row=`DS41_MEM.w_wdata;
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"MARKER\",\"time_ns\":%.3f,\"cc\":%0d,\"row\":%0d}",$realtime,ds41_cc,ds41_row);
  end
  if(ds41_row!=0)begin
   if(`DS41_CPU.d_req&&!`DS41_CPU.d_tid&&`DS41_CPU.d_addr[31:12]==20'h04000)begin
    ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"CPU_PRESENT\",\"time_ns\":%.3f,\"cc\":%0d,\"row\":%0d,\"pc\":\"%08x\",\"address\":\"%08x\",\"write\":%0d,\"be\":%0d,\"wdata\":\"%08x\",\"core_ce\":%0d}",$realtime,ds41_cc,ds41_row,`DS41_CPU.u_core.e3.pc,`DS41_CPU.d_addr,`DS41_CPU.d_we,`DS41_CPU.d_be,`DS41_CPU.d_wdata,`DS41_CPU.u_core.ce);
   end
   if(`DS41_MEM.wq_e&&!`DS41_MEM.wcp_e&&`DS41_MEM.w_addr[31:12]==20'h04000)begin
    ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"MEM_WB\",\"time_ns\":%.3f,\"cc\":%0d,\"row\":%0d,\"address\":\"%08x\",\"write\":%0d,\"be\":%0d,\"ready\":%0d,\"data\":\"%08x\",\"core_ce\":%0d,\"wb_n\":%0d,\"dp_valid\":%0d,\"dp_address\":\"%08x\",\"state\":%0d}",$realtime,ds41_cc,ds41_row,`DS41_MEM.w_addr,`DS41_MEM.w_we,`DS41_MEM.w_be,`DS41_MEM.d_ok,`DS41_CPU.m_d_rdata,`DS41_CPU.u_core.ce,`DS41_MEM.wb_n,`DS41_MEM.dp_v,`DS41_MEM.dp_a,`DS41_MEM.st);
   end
   if(`DS41_CPU.dbg_retire&&!`DS41_CPU.dbg_tid&&`DS41_CPU.dbg_pc>=32'h01ff8130&&`DS41_CPU.dbg_pc<32'h01ff8150)begin
    ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"RETIRE\",\"time_ns\":%.3f,\"cc\":%0d,\"row\":%0d,\"pc\":\"%08x\",\"write_reg\":%0d,\"reg\":%0d,\"data\":\"%08x\"}",$realtime,ds41_cc,ds41_row,`DS41_CPU.dbg_pc,`DS41_CPU.dbg_wen,`DS41_CPU.dbg_wa,`DS41_CPU.dbg_wd);
   end
  end
 end
end
reg ds41_after=0;
integer ds41_after_row=0;
reg[63:0] ds41_after_edge=0;
always @(posedge `DS41_SOC.clk)begin
 ds41_sc<=ds41_sc+1;ds41_after<=0;
 if(ds41_fd&&ds41_row!=0)begin
  if(`DS41_FAB.st==0&&`DS41_FAB.grant[1]&&`DS41_SOC.b9_addr[31:12]==20'h04000)begin
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"FAB_GRANT\",\"time_ns\":%.3f,\"sc\":%0d,\"row\":%0d,\"owner\":1,\"address\":\"%08x\",\"write\":%0d,\"be\":%0d}",$realtime,ds41_sc,ds41_row,`DS41_SOC.b9_addr,`DS41_SOC.b9_we,`DS41_SOC.b9_be);
  end
  if(`DS41_SOC.b9_req&&`DS41_SOC.b9_ack&&`DS41_SOC.b9_addr[31:12]==20'h04000)begin
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"FAB_ACK\",\"time_ns\":%.3f,\"sc\":%0d,\"row\":%0d,\"address\":\"%08x\",\"write\":%0d,\"be\":%0d,\"data\":\"%08x\"}",$realtime,ds41_sc,ds41_row,`DS41_SOC.b9_addr,`DS41_SOC.b9_we,`DS41_SOC.b9_be,`DS41_SOC.b9_rdata);
  end
  if(`DS41_SOC.io_req)begin
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"IO_ISSUE\",\"time_ns\":%.3f,\"sc\":%0d,\"row\":%0d,\"owner\":%0d,\"grant\":%0d,\"cpu\":%0d,\"address\":\"%08x\",\"write\":%0d,\"be\":%0d,\"data\":\"%08x\",\"tick\":%0d}",$realtime,ds41_sc,ds41_row,`DS41_FAB.mst,`DS41_FAB.grant,`DS41_SOC.io_cpu,{8'h04,`DS41_SOC.io_addr,2'b00},`DS41_SOC.io_we,`DS41_SOC.io_be,`DS41_SOC.io_wdata,`DS41_SOC.tick);
  end
  if(`DS41_SYS.io_req&&!`DS41_SYS.io_cpu&&`DS41_SYS.d_tmr&&!`DS41_SYS.io_we)begin
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"SYS_SAMPLE\",\"time_ns\":%.3f,\"sc\":%0d,\"row\":%0d,\"address\":\"%08x\",\"be\":%0d,\"value\":%0d,\"control\":%0d,\"tick\":%0d}",$realtime,ds41_sc,ds41_row,{11'h020,`DS41_SYS.io_addr,2'b00},`DS41_SYS.io_be,`DS41_SYS.t9_rd[15:0],`DS41_SYS.u_tmr9.cnt[2],`DS41_SYS.tick);
  end
  if(`DS41_SYS.tmr_oh[2])begin
   ds41_after<=1;ds41_after_row<=ds41_row;ds41_after_edge<=ds41_sc;
   ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"SYS_COMMIT\",\"time_ns\":%.3f,\"sc\":%0d,\"row\":%0d,\"be\":%0d,\"wdata\":\"%08x\",\"tick\":%0d,\"counter_before\":%0d,\"control_before\":%0d,\"reload_before\":%0d,\"next_counter\":%0d,\"next_control\":%0d,\"step\":%0d}",$realtime,ds41_sc,ds41_row,`DS41_SYS.io_be,`DS41_SYS.io_wdata,`DS41_SYS.tick,`DS41_SYS.u_tmr9.ctr[2],`DS41_SYS.u_tmr9.cnt[2],`DS41_SYS.u_tmr9.reload[2],`DS41_SYS.u_tmr9.n_ctr[2],`DS41_SYS.u_tmr9.n_cnt[2],`DS41_SYS.u_tmr9.stp[2]);
  end
 end
end
always @(negedge `DS41_SOC.clk)if(ds41_fd&&ds41_after)begin
 ds41_budget();$fdisplay(ds41_fd,"{\"event\":\"TIMER_AFTER\",\"time_ns\":%.3f,\"cause_sc\":%0d,\"row\":%0d,\"counter\":%0d,\"control\":%0d,\"reload\":%0d}",$realtime,ds41_after_edge,ds41_after_row,`DS41_SYS.u_tmr9.ctr[2],`DS41_SYS.u_tmr9.cnt[2],`DS41_SYS.u_tmr9.reload[2]);
end
final if(ds41_fd)begin
 $fdisplay(ds41_fd,"{\"event\":\"final\",\"records\":%0d}",ds41_events);$fclose(ds41_fd);
end
`undef DS41_MEM
`undef DS41_SYS
`undef DS41_FAB
