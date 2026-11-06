// Simulation-only cull-cache adapter. Schema stays W[4],X[4],Y[4]
// at context words2500..2511. Define RUNTIME_CULL_MLAB_ENABLED only
// for CULL_MLAB=1. Preflight checks the elaborated parameter, fail closed.
// Does not write clocks, reset, epoch/seen, pending metadata, or unused slots.
`ifdef RUNTIME_CULL_MLAB_ENABLED
`define RUNTIME_CULL `RUNTIME_GEOMETRY.u_eng.g_pu.g_cull_mlab.u_cache
 function automatic logic[100:0] cull_import_metadata();
  return {`RUNTIME_CULL.epoch,`RUNTIME_CULL.seen,`RUNTIME_CULL.snap_hold,
   `RUNTIME_CULL.group_hold,`RUNTIME_CULL.data_hold[0],
   `RUNTIME_CULL.data_hold[1],`RUNTIME_CULL.data_hold[2]};
 endfunction
 task automatic cull_import_preflight(input logic[31:0]context_data[0:11],input bit held);
`ifdef ALTERA_RESERVED_QIS
  $fatal(1,"CULL_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`endif
  assert(`RUNTIME_GEOMETRY.u_eng.CULL_MLAB)else $fatal(1,"CULL_IMPORT_PROFILE_MISMATCH");
  assert(held && `RUNTIME_CULL.clk===1'b0 && `RUNTIME_CULL.clk2===1'b0 &&
   !$isunknown({`RUNTIME_CULL.epoch,`RUNTIME_CULL.seen,`RUNTIME_CULL.snap_hold}))
   else $fatal(1,"CULL_IMPORT_PHASE_BARRIER");
  for(int i=0;i<12;i++)assert(!$isunknown(context_data[i]))
   else $fatal(1,"CULL_IMPORT_UNKNOWN_WORD");
  // The old FF image is logical post-SYS state. A not-yet-committed M
  // write may replay only the same captured value; otherwise reject before
  // any context write. A post-M stale snap_hold is already consumed.
  if(`RUNTIME_CULL.epoch!=`RUNTIME_CULL.seen && `RUNTIME_CULL.snap_hold)begin
   assert(!$isunknown(`RUNTIME_CULL.group_hold) &&
    `RUNTIME_CULL.data_hold[0]===context_data[4+int'(`RUNTIME_CULL.group_hold)] &&
    `RUNTIME_CULL.data_hold[1]===context_data[8+int'(`RUNTIME_CULL.group_hold)] &&
    `RUNTIME_CULL.data_hold[2]===context_data[0+int'(`RUNTIME_CULL.group_hold)])
    else $fatal(1,"CULL_IMPORT_PENDING_CONFLICT");
  end
 endtask
 // Enclosing full-context import preflights before any field is deposited.
 // This task also guards direct narrow uses in a stopped transaction.
 task automatic cull_import_words(input logic[31:0]context_data[0:11],input bit held);
  logic[100:0]saved;time at_import;
  cull_import_preflight(context_data,held);saved=cull_import_metadata();at_import=$time;
`ifndef ALTERA_RESERVED_QIS
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[0].g_reader[0].u_mem.mem[g]=context_data[4+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[0].g_reader[1].u_mem.mem[g]=context_data[4+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[0].g_reader[2].u_mem.mem[g]=context_data[4+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[1].g_reader[0].u_mem.mem[g]=context_data[8+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[1].g_reader[1].u_mem.mem[g]=context_data[8+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[1].g_reader[2].u_mem.mem[g]=context_data[8+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[2].g_reader[0].u_mem.mem[g]=context_data[0+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[2].g_reader[1].u_mem.mem[g]=context_data[0+g];
  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[2].g_reader[2].u_mem.mem[g]=context_data[0+g];
`endif
  assert(saved===cull_import_metadata() && at_import==$time)
   else $fatal(1,"CULL_IMPORT_METADATA_OR_TIME_CHANGED");
 endtask
 task automatic cull_verify_words(input logic[31:0]context_data[0:11]);
`ifdef ALTERA_RESERVED_QIS
  $fatal(1,"CULL_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`else
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[0].g_reader[0].u_mem.mem[g]===context_data[4+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate0 reader0 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[0].g_reader[1].u_mem.mem[g]===context_data[4+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate0 reader1 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[0].g_reader[2].u_mem.mem[g]===context_data[4+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate0 reader2 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[1].g_reader[0].u_mem.mem[g]===context_data[8+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate1 reader0 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[1].g_reader[1].u_mem.mem[g]===context_data[8+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate1 reader1 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[1].g_reader[2].u_mem.mem[g]===context_data[8+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate1 reader2 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[2].g_reader[0].u_mem.mem[g]===context_data[0+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate2 reader0 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[2].g_reader[1].u_mem.mem[g]===context_data[0+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate2 reader1 group%0d",g);
  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[2].g_reader[2].u_mem.mem[g]===context_data[0+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate2 reader2 group%0d",g);
`endif
 endtask
`undef RUNTIME_CULL
`else
 function automatic logic[100:0] cull_import_metadata();
  return 101'd0;
 endfunction
 task automatic cull_import_preflight(input logic[31:0]context_data[0:11],input bit held);
  assert(!`RUNTIME_GEOMETRY.u_eng.CULL_MLAB)else $fatal(1,"CULL_IMPORT_PROFILE_MISMATCH");
  // Existing default-off contract remains the enclosing import's authority.
 endtask
 task automatic cull_import_words(input logic[31:0]context_data[0:11],input bit held);
  cull_import_preflight(context_data,held);
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpw[0]=context_data[0];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpw[1]=context_data[1];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpw[2]=context_data[2];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpw[3]=context_data[3];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpx[0]=context_data[4];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpx[1]=context_data[5];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpx[2]=context_data[6];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpx[3]=context_data[7];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpy[0]=context_data[8];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpy[1]=context_data[9];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpy[2]=context_data[10];
  `RUNTIME_GEOMETRY.u_eng.g_pu.cpy[3]=context_data[11];
 endtask
 task automatic cull_verify_words(input logic[31:0]context_data[0:11]);
  assert(!`RUNTIME_GEOMETRY.u_eng.CULL_MLAB)else $fatal(1,"CULL_IMPORT_PROFILE_MISMATCH");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpw[0])===context_data[0])else $fatal(1,"context readback u_eng.g_pu.cpw[0]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpw[1])===context_data[1])else $fatal(1,"context readback u_eng.g_pu.cpw[1]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpw[2])===context_data[2])else $fatal(1,"context readback u_eng.g_pu.cpw[2]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpw[3])===context_data[3])else $fatal(1,"context readback u_eng.g_pu.cpw[3]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpx[0])===context_data[4])else $fatal(1,"context readback u_eng.g_pu.cpx[0]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpx[1])===context_data[5])else $fatal(1,"context readback u_eng.g_pu.cpx[1]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpx[2])===context_data[6])else $fatal(1,"context readback u_eng.g_pu.cpx[2]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpx[3])===context_data[7])else $fatal(1,"context readback u_eng.g_pu.cpx[3]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpy[0])===context_data[8])else $fatal(1,"context readback u_eng.g_pu.cpy[0]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpy[1])===context_data[9])else $fatal(1,"context readback u_eng.g_pu.cpy[1]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpy[2])===context_data[10])else $fatal(1,"context readback u_eng.g_pu.cpy[2]");
  assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpy[3])===context_data[11])else $fatal(1,"context readback u_eng.g_pu.cpy[3]");
 endtask
`endif
