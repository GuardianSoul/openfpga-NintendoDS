// All-scene state-import input contract. Independent of HG history enable.
`ifdef COMBINED_STATE_IMPORT
`include "hg193_shared_model_binding.svh"
bit combined_wram_present=0,combined_wram_applied=0;
string combined_wram_expected_path,combined_wram_fault="none";
logic[31:0]combined_wram_expected[0:24575];
initial begin
 combined_wram_present=$test$plusargs("combined_wram_restore");
 if(combined_wram_present)begin
  assert_hg193_shared_model_binding();
  assert($value$plusargs("combined_wram_expected=%s",combined_wram_expected_path))
   else $fatal(1,"COMBINED_WRAM_EXPECTED_INPUT_REQUIRED");
  $readmemh(combined_wram_expected_path,combined_wram_expected);
  if($value$plusargs("combined_wram_fault=%s",combined_wram_fault))begin
`ifndef COMBINED_WRAM_FAULTS
   $fatal(1,"COMBINED_WRAM_FAULT_BUILD_REQUIRED");
`endif
  end
 end
end
task automatic combined_restore_wram;
 assert_hg193_shared_model_binding();
 assert(combined_wram_present && !combined_wram_applied && !imp_stub_pend &&
        dut.A7_WRAM==1 && dut.CPU_FAST==0 && dut.ARM7_CACHE==1)
 else $fatal(1,"COMBINED_WRAM_BOOTSTRAP_BOUNDARY_OR_LAYOUT");
 assert(combined_wram_fault=="none" || combined_wram_fault=="missing-private" ||
        combined_wram_fault=="missing-shared" || combined_wram_fault=="wrong-private" ||
        combined_wram_fault=="wrong-shared")else $fatal(1,"COMBINED_WRAM_UNKNOWN_FAULT");
 for(int w=0;w<24576;w++)assert(imp_sram[w]===combined_wram_expected[w])
  else $fatal(1,"COMBINED_WRAM_EXISTING_INPUT_DIFFERS word%0d",w);
 // A missing-deposit control must not pass accidentally on initially equal
 // zero storage: poison one fixture word, then deliberately omit that bank.
`ifdef COMBINED_WRAM_FAULTS
 if(combined_wram_fault=="missing-private")dut.ds.u_wram.u_private.mem[0]=combined_wram_expected[0]^32'd1;
 if(combined_wram_fault=="missing-shared")dut.ds.u_wram.u_shared.mem[0]=combined_wram_expected[16384]^32'd1;
`endif
 if(combined_wram_fault!="missing-private")
  for(int w=0;w<16384;w++)dut.ds.u_wram.u_private.mem[w]=imp_sram[w];
 if(combined_wram_fault!="missing-shared")
  for(int w=0;w<8192;w++)dut.ds.u_wram.u_shared.mem[w]=imp_sram[16384+w];
`ifdef COMBINED_WRAM_FAULTS
 if(combined_wram_fault=="wrong-private")dut.ds.u_wram.u_private.mem[0]^=32'd1;
 if(combined_wram_fault=="wrong-shared")dut.ds.u_wram.u_shared.mem[0]^=32'd1;
`endif
 for(int w=0;w<16384;w++)assert(dut.ds.u_wram.u_private.mem[w]===combined_wram_expected[w])
  else $fatal(1,"COMBINED_WRAM_PRIVATE_READBACK_MISMATCH word%0d",w);
 for(int w=0;w<8192;w++)assert(dut.ds.u_wram.u_shared.mem[w]===combined_wram_expected[16384+w])
  else $fatal(1,"COMBINED_WRAM_SHARED_READBACK_MISMATCH word%0d",w);
 combined_wram_applied=1;
 $display("COMBINED_WRAM_IMPORT_READBACK_PASS private16384 shared8192 total24576");
endtask
`endif
