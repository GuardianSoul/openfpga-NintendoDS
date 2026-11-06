// Simulation-only architectural checkpoint for current solo ARM9 dual-write RF.
// Caller has stopped clocks and drained all accepted memory/CP15 traffic.
// Define RUNTIME_CORE to arm_core. Does not restore caches/TCMs or drain buses.
task automatic import_cpu9_dual(input logic[31:0] regs[0:31],input logic[31:0] psrs[0:7]);
 assert(!`RUNTIME_CORE.ce && `RUNTIME_CORE.SOLO_ONLY && `RUNTIME_CORE.BLK1 &&
        !`RUNTIME_CORE.f2_v&&!`RUNTIME_CORE.p_v&&!`RUNTIME_CORE.e1.valid&&
        !`RUNTIME_CORE.e2.valid&&!`RUNTIME_CORE.e3.valid&&!`RUNTIME_CORE.w_valid&&
        !`RUNTIME_CORE.x_valid&&!`RUNTIME_CORE.wbq_en&&!`RUNTIME_CORE.se_v&&!`RUNTIME_CORE.sa_v)
  else $fatal(1,"ARM9 checkpoint not drained/current dual-write profile");
 // RF logical ABI: the observer's g_dual.regs is read-only. Populate every
 // physical replica and its last-writer owner through the import task.
 for(int p=0;p<31;p++)if(p!=15)`RUNTIME_CORE.u_rf.g_dual.import_phys(6'(p),regs[p]);
 for(int lane=0;lane<2;lane++)begin
  `RUNTIME_CORE.fetch_pc[lane]=psrs[0];`RUNTIME_CORE.fetch_thumb[lane]=psrs[1][5];
  `RUNTIME_CORE.cpsr_s[lane]=`RUNTIME_CORE.psr13(psrs[1]);`RUNTIME_CORE.halted[lane]=psrs[2][0];
  `RUNTIME_CORE.ib_v[lane]=0;`RUNTIME_CORE.ib1_v[lane]=0;`RUNTIME_CORE.ustep[lane]=0;
  `RUNTIME_CORE.rh[lane]=0;`RUNTIME_CORE.dwait_r[lane]=0;`RUNTIME_CORE.ll_v[lane]=0;`RUNTIME_CORE.bl_v[lane]=0;
  `RUNTIME_CORE.irq_r[lane]=0;`RUNTIME_CORE.fiq_r[lane]=0;
 end
 `RUNTIME_CORE.ib4_n=0;`RUNTIME_CORE.ib4_h=0;`RUNTIME_CORE.tid=0;
 for(int b=0;b<5;b++)begin
  `RUNTIME_CORE.spf_e[b]=psrs[3+b][31:27];`RUNTIME_CORE.spf_x[b]=psrs[3+b][31:27];
  `RUNTIME_CORE.spc_e[b]=psrs[3+b][7:0];`RUNTIME_CORE.spc_x[b]=psrs[3+b][7:0];
  `RUNTIME_CORE.sp_vld[b]=1;
 end
endtask
