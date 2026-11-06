#!/usr/bin/env python3
"""Render the narrow twelve-word cull import adapter; never changes the schema."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'sim/pocket_ds/runtime_import_cull_cache.svh'


def render():
    s = '''// Simulation-only cull-cache adapter. Schema stays W[4],X[4],Y[4]
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
'''
    for coordinate, base in enumerate([4, 8, 0]):
        for reader in range(3):
            s += f'  for(int g=0;g<4;g++)`RUNTIME_CULL.g_coordinate[{coordinate}].g_reader[{reader}].u_mem.mem[g]=context_data[{base}+g];\n'
    s += '''`endif
  assert(saved===cull_import_metadata() && at_import==$time)
   else $fatal(1,"CULL_IMPORT_METADATA_OR_TIME_CHANGED");
 endtask
 task automatic cull_verify_words(input logic[31:0]context_data[0:11]);
`ifdef ALTERA_RESERVED_QIS
  $fatal(1,"CULL_IMPORT_NATIVE_BACKEND_UNSUPPORTED");
`else
'''
    for coordinate, base in enumerate([4, 8, 0]):
        for reader in range(3):
            s += f'  for(int g=0;g<4;g++)assert(`RUNTIME_CULL.g_coordinate[{coordinate}].g_reader[{reader}].u_mem.mem[g]===context_data[{base}+g])else $fatal(1,"CULL_IMPORT_READBACK coordinate{coordinate} reader{reader} group%0d",g);\n'
    s += '''`endif
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
'''
    for field, base in [('cpw', 0), ('cpx', 4), ('cpy', 8)]:
        for group in range(4):
            s += f'  `RUNTIME_GEOMETRY.u_eng.g_pu.{field}[{group}]=context_data[{base+group}];\n'
    s += ' endtask\n task automatic cull_verify_words(input logic[31:0]context_data[0:11]);\n  assert(!`RUNTIME_GEOMETRY.u_eng.CULL_MLAB)else $fatal(1,"CULL_IMPORT_PROFILE_MISMATCH");\n'
    for field, base in [('cpw', 0), ('cpx', 4), ('cpy', 8)]:
        for group in range(4):
            path = f'u_eng.g_pu.{field}[{group}]'
            s += f'  assert($unsigned(`RUNTIME_GEOMETRY.{path})===context_data[{base+group}])else $fatal(1,"context readback {path}");\n'
    return s + ' endtask\n`endif\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.check:
        assert TARGET.read_text() == render(), 'regenerate runtime_import_cull_cache.svh'
    else:
        TARGET.write_text(render())
