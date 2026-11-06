// Simulation-only architectural checkpoint for the separate arm7_ds engine.
// Caller has stopped its clock and drained both ports, including writeback.
// Define RUNTIME_ARM7 to arm7_ds. No memory-system queues are reset here.
task automatic import_arm7_arch(input logic[31:0] regs[0:31],input logic[31:0] psrs[0:7]);
 assert(!`RUNTIME_ARM7.run&&!`RUNTIME_ARM7.d_v&&!`RUNTIME_ARM7.e_v&&
        !`RUNTIME_ARM7.f_rq&&!`RUNTIME_ARM7.dm_rq&&!`RUNTIME_ARM7.rf_we&&!`RUNTIME_ARM7.wq_v&&
        (`RUNTIME_ARM7.st==`RUNTIME_ARM7.S_FETCH||`RUNTIME_ARM7.st==`RUNTIME_ARM7.S_PIPE))
  else $fatal(1,"ARM7 checkpoint not drained");
 for(int p=0;p<31;p++)if(p!=15)begin `RUNTIME_ARM7.rf[p]=regs[p];`RUNTIME_ARM7.rfb[p]=regs[p];end
 `RUNTIME_ARM7.pc=psrs[0];`RUNTIME_ARM7.pc_f=psrs[0];
 `RUNTIME_ARM7.cpsr={psrs[1][31:27],psrs[1][7:0]};`RUNTIME_ARM7.halted=psrs[2][0];
 for(int b=0;b<5;b++)`RUNTIME_ARM7.spsr[b]={psrs[3+b][31:27],psrs[3+b][7:0]};
 `RUNTIME_ARM7.st=`RUNTIME_ARM7.S_PIPE;`RUNTIME_ARM7.ph=0;`RUNTIME_ARM7.esub=0;
endtask
