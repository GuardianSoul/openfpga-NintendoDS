// Physical FIFO cells and pointers are required even when logically empty:
// an empty receive returns the stale cell at the current read pointer.
// Define RUNTIME_IPC to actual sys_ipc; caller stops its clock and I/O.
task automatic import_ipc_physical(input logic[31:0] image[0:41]);
 for(int cpu=0;cpu<2;cpu++)begin
  `RUNTIME_IPC.out[cpu]=image[cpu*21][11:8];`RUNTIME_IPC.irqen[cpu]=image[cpu*21][14];
  `RUNTIME_IPC.en[cpu]=image[cpu*21+1][15];`RUNTIME_IPC.err[cpu]=image[cpu*21+1][14];
  `RUNTIME_IPC.rirq[cpu]=image[cpu*21+1][10];`RUNTIME_IPC.sirq[cpu]=image[cpu*21+1][2];
  assert(image[cpu*21+2]<=16&&image[cpu*21+3]<16&&image[cpu*21+4]<16)else $fatal(1,"IPC invalid physical ring");
  `RUNTIME_IPC.n[cpu]=image[cpu*21+2][4:0];`RUNTIME_IPC.rp[cpu]=image[cpu*21+3][3:0];`RUNTIME_IPC.wp[cpu]=image[cpu*21+4][3:0];
  for(int n=0;n<16;n++)`RUNTIME_IPC.u_fifo.mem[cpu*16+n]=image[cpu*21+5+n];
 end
endtask
