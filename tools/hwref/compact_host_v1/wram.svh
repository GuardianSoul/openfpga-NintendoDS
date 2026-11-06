// Host ABI1. Included only by the opt-in adapter, deposits only under IMPORT.
`ifdef IMPORT
bit compact_wram_applied=0;
task automatic compact_restore_wram;
 assert(!compact_wram_applied && !imp_stub_pend && dut.A7_WRAM==1 &&
  dut.CPU_FAST==0 && dut.ARM7_CACHE==1)
  else $fatal(1,"COMPACT_WRAM_BOOTSTRAP_BOUNDARY");
 for(int w=0;w<16384;w++)begin
  dut.ds.u_wram.u_private.mem[w]=imp_sram[w];
 end
 for(int w=0;w<8192;w++)dut.ds.u_wram.u_shared.mem[w]=imp_sram[16384+w];
 for(int w=0;w<16384;w++)assert(dut.ds.u_wram.u_private.mem[w]===imp_sram[w])
  else $fatal(1,"COMPACT_WRAM_PRIVATE_READBACK word%0d",w);
 for(int w=0;w<8192;w++)assert(dut.ds.u_wram.u_shared.mem[w]===imp_sram[16384+w])
  else $fatal(1,"COMPACT_WRAM_SHARED_READBACK word%0d",w);
 compact_wram_applied=1;
 $display("COMPACT_WRAM_IMPORT_READBACK_PASS private16384 shared8192 total24576");
endtask
`endif
