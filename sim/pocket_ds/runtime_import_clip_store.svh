// Simulation-only ABI v1. Define RUNTIME_CLIP to the exact clip instance.
// Define RUNTIME_CLIP_STORE_ENABLED only for an elaborated PUMP_STORE=1.
// No clocks, reset, phase, pending metadata, queues or services are modified.
function automatic logic [85:0] clip_import_metadata();
`ifdef RUNTIME_CLIP_STORE_ENABLED
 return {`RUNTIME_CLIP.g_store_pump.u_store.epoch,
 `RUNTIME_CLIP.g_store_pump.u_store.seen,
 `RUNTIME_CLIP.g_store_pump.u_store.pending_we,
 `RUNTIME_CLIP.g_store_pump.u_store.pending_addr,
 `RUNTIME_CLIP.g_store_pump.u_store.pending_data,
 `RUNTIME_CLIP.g_store_pump.u_store.inside_addr,
 `RUNTIME_CLIP.g_store_pump.u_store.forward_match,
 `RUNTIME_CLIP.g_store_pump.u_store.forward_word,
 `RUNTIME_CLIP.g_store_pump.u_store.forward_data};
`else
 return 86'd0;
`endif
endfunction

task automatic clip_import_preflight(
 input logic [31:0] words[0:4][0:31], outside_q[0:4], inside_q[0:4],
 input logic [31:0] valid_groups,input logic [4:0] valid_reads,
 input bit held,post_m);
`ifdef ALTERA_RESERVED_QIS
 $fatal(1,"CLIP_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`endif
 assert(held && post_m && `RUNTIME_CLIP.clk===1'b0 && `RUNTIME_CLIP.clk2===1'b0)
  else $fatal(1,"CLIP_IMPORT_PHASE_BARRIER");
 assert(valid_groups===32'hffffffff && valid_reads===5'b11111)
  else $fatal(1,"CLIP_IMPORT_INCOMPLETE_WITNESS");
 assert(`RUNTIME_CLIP.st===`RUNTIME_CLIP.S_IDLE && !`RUNTIME_CLIP.busy &&
  `RUNTIME_CLIP.qe && !`RUNTIME_CLIP.cw && !`RUNTIME_CLIP.run && !`RUNTIME_CLIP.we &&
  !`RUNTIME_CLIP.dgo && !`RUNTIME_CLIP.dwait && `RUNTIME_CLIP.dbusy===9'd0)
  else $fatal(1,"CLIP_IMPORT_ACTIVE_SNAPSHOT");
`ifdef RUNTIME_CLIP_STORE_ENABLED
 assert(`RUNTIME_CLIP.PUMP_STORE)else $fatal(1,"CLIP_IMPORT_PROFILE_MISMATCH");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.epoch===`RUNTIME_CLIP.g_store_pump.u_store.seen)
  else $fatal(1,"CLIP_IMPORT_PHASE_BARRIER");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.pending_we===1'b0)
  else $fatal(1,"CLIP_IMPORT_PENDING_WRITE");
`else
 assert(!`RUNTIME_CLIP.PUMP_STORE)else $fatal(1,"CLIP_IMPORT_PROFILE_MISMATCH");
`endif
 for(int sf=0;sf<5;sf++)begin
  assert(!$isunknown(outside_q[sf]) && !$isunknown(inside_q[sf]))
   else $fatal(1,"CLIP_IMPORT_UNKNOWN_READ");
  for(int g=0;g<32;g++)assert(!$isunknown(words[sf][g]))
   else $fatal(1,"CLIP_IMPORT_UNKNOWN_PAYLOAD");
 end
endtask

// Low-level deposit; callers must preflight and verify in the same stopped
// transaction. The context wrapper below enforces this; the fault bench
// intentionally defers readback so wrong-field data must reach public CWD.
task automatic clip_import_words(input logic [31:0] words[0:4][0:31],
 input logic [31:0] outside_q[0:4],inside_q[0:4]);
`ifdef RUNTIME_CLIP_STORE_ENABLED
`ifdef ALTERA_RESERVED_QIS
 $fatal(1,"CLIP_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`else
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_store_pump.u_store.g_field[0].u_mem.mem[g]=words[0][g];
 `RUNTIME_CLIP.g_store_pump.u_store.outside_word[0]=outside_q[0];
 `RUNTIME_CLIP.g_store_pump.u_store.g_field[0].u_mem.rdata=inside_q[0];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_store_pump.u_store.g_field[1].u_mem.mem[g]=words[1][g];
 `RUNTIME_CLIP.g_store_pump.u_store.outside_word[1]=outside_q[1];
 `RUNTIME_CLIP.g_store_pump.u_store.g_field[1].u_mem.rdata=inside_q[1];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_store_pump.u_store.g_field[2].u_mem.mem[g]=words[2][g];
 `RUNTIME_CLIP.g_store_pump.u_store.outside_word[2]=outside_q[2];
 `RUNTIME_CLIP.g_store_pump.u_store.g_field[2].u_mem.rdata=inside_q[2];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_store_pump.u_store.g_field[3].u_mem.mem[g]=words[3][g];
 `RUNTIME_CLIP.g_store_pump.u_store.outside_word[3]=outside_q[3];
 `RUNTIME_CLIP.g_store_pump.u_store.g_field[3].u_mem.rdata=inside_q[3];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_store_pump.u_store.g_field[4].u_mem.mem[g]=words[4][g];
 `RUNTIME_CLIP.g_store_pump.u_store.outside_word[4]=outside_q[4];
 `RUNTIME_CLIP.g_store_pump.u_store.g_field[4].u_mem.rdata=inside_q[4];
`endif
`else
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[4].u_out.mem[g]=words[0][g];
 `RUNTIME_CLIP.g_word[4].u_out.rdata=outside_q[0];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[4].u_in.mem[g]=words[0][g];
 `RUNTIME_CLIP.g_word[4].u_in.rdata=inside_q[0];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[5].u_out.mem[g]=words[1][g];
 `RUNTIME_CLIP.g_word[5].u_out.rdata=outside_q[1];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[5].u_in.mem[g]=words[1][g];
 `RUNTIME_CLIP.g_word[5].u_in.rdata=inside_q[1];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[6].u_out.mem[g]=words[2][g];
 `RUNTIME_CLIP.g_word[6].u_out.rdata=outside_q[2];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[6].u_in.mem[g]=words[2][g];
 `RUNTIME_CLIP.g_word[6].u_in.rdata=inside_q[2];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[7].u_out.mem[g]=words[3][g];
 `RUNTIME_CLIP.g_word[7].u_out.rdata=outside_q[3];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[7].u_in.mem[g]=words[3][g];
 `RUNTIME_CLIP.g_word[7].u_in.rdata=inside_q[3];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[8].u_out.mem[g]=words[4][g];
 `RUNTIME_CLIP.g_word[8].u_out.rdata=outside_q[4];
 for(int g=0;g<32;g++)`RUNTIME_CLIP.g_word[8].u_in.mem[g]=words[4][g];
 `RUNTIME_CLIP.g_word[8].u_in.rdata=inside_q[4];
`endif
endtask

task automatic clip_verify_words(input logic [31:0] words[0:4][0:31],
 input logic [31:0] outside_q[0:4],inside_q[0:4]);
`ifdef RUNTIME_CLIP_STORE_ENABLED
`ifdef ALTERA_RESERVED_QIS
 $fatal(1,"CLIP_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`else
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_store_pump.u_store.g_field[0].u_mem.mem[g]===words[0][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field0");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.outside_word[0]===outside_q[0] && `RUNTIME_CLIP.g_store_pump.u_store.g_field[0].u_mem.rdata===inside_q[0])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field0");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_store_pump.u_store.g_field[1].u_mem.mem[g]===words[1][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field1");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.outside_word[1]===outside_q[1] && `RUNTIME_CLIP.g_store_pump.u_store.g_field[1].u_mem.rdata===inside_q[1])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field1");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_store_pump.u_store.g_field[2].u_mem.mem[g]===words[2][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field2");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.outside_word[2]===outside_q[2] && `RUNTIME_CLIP.g_store_pump.u_store.g_field[2].u_mem.rdata===inside_q[2])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field2");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_store_pump.u_store.g_field[3].u_mem.mem[g]===words[3][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field3");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.outside_word[3]===outside_q[3] && `RUNTIME_CLIP.g_store_pump.u_store.g_field[3].u_mem.rdata===inside_q[3])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field3");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_store_pump.u_store.g_field[4].u_mem.mem[g]===words[4][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field4");
 assert(`RUNTIME_CLIP.g_store_pump.u_store.outside_word[4]===outside_q[4] && `RUNTIME_CLIP.g_store_pump.u_store.g_field[4].u_mem.rdata===inside_q[4])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field4");
`endif
`else
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[4].u_out.mem[g]===words[0][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field0");
 assert(`RUNTIME_CLIP.g_word[4].u_out.rdata===outside_q[0])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field0");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[4].u_in.mem[g]===words[0][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field0");
 assert(`RUNTIME_CLIP.g_word[4].u_in.rdata===inside_q[0])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field0");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[5].u_out.mem[g]===words[1][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field1");
 assert(`RUNTIME_CLIP.g_word[5].u_out.rdata===outside_q[1])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field1");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[5].u_in.mem[g]===words[1][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field1");
 assert(`RUNTIME_CLIP.g_word[5].u_in.rdata===inside_q[1])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field1");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[6].u_out.mem[g]===words[2][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field2");
 assert(`RUNTIME_CLIP.g_word[6].u_out.rdata===outside_q[2])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field2");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[6].u_in.mem[g]===words[2][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field2");
 assert(`RUNTIME_CLIP.g_word[6].u_in.rdata===inside_q[2])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field2");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[7].u_out.mem[g]===words[3][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field3");
 assert(`RUNTIME_CLIP.g_word[7].u_out.rdata===outside_q[3])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field3");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[7].u_in.mem[g]===words[3][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field3");
 assert(`RUNTIME_CLIP.g_word[7].u_in.rdata===inside_q[3])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field3");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[8].u_out.mem[g]===words[4][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field4");
 assert(`RUNTIME_CLIP.g_word[8].u_out.rdata===outside_q[4])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field4");
 for(int g=0;g<32;g++)assert(`RUNTIME_CLIP.g_word[8].u_in.mem[g]===words[4][g])else $fatal(1,"CLIP_IMPORT_BACKING_READBACK field4");
 assert(`RUNTIME_CLIP.g_word[8].u_in.rdata===inside_q[4])else $fatal(1,"CLIP_IMPORT_HELD_READBACK field4");
`endif
endtask

// Faithful portable sidecar capture from the DEFAULT source only. No writes
// or ticks; enclosing scheduler certifies the last SYS write and phase.
task automatic clip_capture_legacy_witness(
 output logic[31:0]words[0:4][0:31],outside_q[0:4],inside_q[0:4],
 input bit held,post_m,last_sys_write_absent);
 time capture_time;
 capture_time=$time;
 assert(last_sys_write_absent)else $fatal(1,"CLIP_CAPTURE_LAST_WRITE_UNCERTIFIED");
`ifdef RUNTIME_CLIP_STORE_ENABLED
 $fatal(1,"CLIP_CAPTURE_REQUIRES_LEGACY_PROFILE");
`else
 for(int g=0;g<32;g++)begin
  assert(`RUNTIME_CLIP.g_word[4].u_out.mem[g]===`RUNTIME_CLIP.g_word[4].u_in.mem[g])else $fatal(1,"CLIP_CAPTURE_REPLICA_CONFLICT field0");
  words[0][g]=`RUNTIME_CLIP.g_word[4].u_out.mem[g];
 end
 outside_q[0]=`RUNTIME_CLIP.g_word[4].u_out.rdata;
 inside_q[0]=`RUNTIME_CLIP.g_word[4].u_in.rdata;
 for(int g=0;g<32;g++)begin
  assert(`RUNTIME_CLIP.g_word[5].u_out.mem[g]===`RUNTIME_CLIP.g_word[5].u_in.mem[g])else $fatal(1,"CLIP_CAPTURE_REPLICA_CONFLICT field1");
  words[1][g]=`RUNTIME_CLIP.g_word[5].u_out.mem[g];
 end
 outside_q[1]=`RUNTIME_CLIP.g_word[5].u_out.rdata;
 inside_q[1]=`RUNTIME_CLIP.g_word[5].u_in.rdata;
 for(int g=0;g<32;g++)begin
  assert(`RUNTIME_CLIP.g_word[6].u_out.mem[g]===`RUNTIME_CLIP.g_word[6].u_in.mem[g])else $fatal(1,"CLIP_CAPTURE_REPLICA_CONFLICT field2");
  words[2][g]=`RUNTIME_CLIP.g_word[6].u_out.mem[g];
 end
 outside_q[2]=`RUNTIME_CLIP.g_word[6].u_out.rdata;
 inside_q[2]=`RUNTIME_CLIP.g_word[6].u_in.rdata;
 for(int g=0;g<32;g++)begin
  assert(`RUNTIME_CLIP.g_word[7].u_out.mem[g]===`RUNTIME_CLIP.g_word[7].u_in.mem[g])else $fatal(1,"CLIP_CAPTURE_REPLICA_CONFLICT field3");
  words[3][g]=`RUNTIME_CLIP.g_word[7].u_out.mem[g];
 end
 outside_q[3]=`RUNTIME_CLIP.g_word[7].u_out.rdata;
 inside_q[3]=`RUNTIME_CLIP.g_word[7].u_in.rdata;
 for(int g=0;g<32;g++)begin
  assert(`RUNTIME_CLIP.g_word[8].u_out.mem[g]===`RUNTIME_CLIP.g_word[8].u_in.mem[g])else $fatal(1,"CLIP_CAPTURE_REPLICA_CONFLICT field4");
  words[4][g]=`RUNTIME_CLIP.g_word[8].u_out.mem[g];
 end
 outside_q[4]=`RUNTIME_CLIP.g_word[8].u_out.rdata;
 inside_q[4]=`RUNTIME_CLIP.g_word[8].u_in.rdata;
 clip_import_preflight(words,outside_q,inside_q,32'hffffffff,5'b11111,held,post_m);
 assert($time==capture_time)else $fatal(1,"CLIP_CAPTURE_ADVANCED_TIME");
`endif
endtask
