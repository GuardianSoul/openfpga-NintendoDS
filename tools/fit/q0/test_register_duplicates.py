#!/usr/bin/env python3
"""Offline Standard query semantics regression; never qualifies physical STA."""
from pathlib import Path
import ctypes,json,os
os.setpriority(os.PRIO_PROCESS,0,10)
D=Path(__file__).resolve().parent;B=D.parents[2]/'build/q0-register-duplicates';B.mkdir(parents=True,exist_ok=True)
lib=ctypes.CDLL('build/tools/oss-cad-suite/lib/libtcl8.6.so')
lib.Tcl_CreateInterp.restype=ctypes.c_void_p;lib.Tcl_Eval.argtypes=[ctypes.c_void_p,ctypes.c_char_p];lib.Tcl_Eval.restype=ctypes.c_int;lib.Tcl_GetStringResult.argtypes=[ctypes.c_void_p];lib.Tcl_GetStringResult.restype=ctypes.c_char_p;lib.Tcl_DeleteInterp.argtypes=[ctypes.c_void_p]
# The documented default query expands a source to its physical duplicate.
# Exact queries must still visit that duplicate itself and reject wrong aliases.
setup='''
proc get_register_info {option id} {
 if {$option ne "-name"} {error BAD_INFO_OPTION}
 return [dict get [dict create r0 {top|state.SETTLE} r1 {top|state.SETTLE~duplicate}] $id]
}
proc get_collection_size {col} {return [expr {[llength $col]-1}]}
proc foreach_in_collection {var col body} {uplevel 1 [list foreach $var [lrange $col 1 end] $body]}
proc get_registers {args} {
 set exact [expr {[lindex $args 0] eq "-no_duplicates"}]
 if {$exact} {set args [lrange $args 1 end]}
 if {[llength $args]!=2 || [lindex $args 0] ne "-nowarn"} {error BAD_QUERY}
 set name [lindex $args 1]
 if {$name eq {top|state.SETTLE}} {
  if {$::wrong_alias} {return {COL r1}}
  if {$exact} {return {COL r0}}
  return {COL r0 r1}
 }
 if {$name eq {top|state.SETTLE~duplicate}} {return {COL r1}}
 return COL
}
'''
body='''
if {[q0_regset r0] ne {COL r0}} {error ORIGINAL_IDENTITY_LOST}
if {[q0_regset r1] ne {COL r1}} {error DUPLICATE_NOT_VISITED}
set ::wrong_alias 1
if {![catch {q0_regset r0}]} {error WRONG_ALIAS_ACCEPTED}
set ::wrong_alias 0
set result PASS_BOTH_PHYSICAL_IDENTITIES_AND_ALIAS_REJECTION
'''
s=(D/'standard_clock.tcl').read_text();out={}
for label,source in [('positive',s),('actual_query_mutant',s.replace('get_registers -no_duplicates -nowarn','get_registers -nowarn',1))]:
 i=lib.Tcl_CreateInterp();code='set ::wrong_alias 0\n'+setup+'\n'+source+'\n'+body+'\nset result'
 rc=lib.Tcl_Eval(i,code.encode());msg=lib.Tcl_GetStringResult(i).decode();lib.Tcl_DeleteInterp(i);out[label]={'returncode':rc,'message':msg}
assert out['positive']['returncode']==0,out
assert out['actual_query_mutant']['returncode']!=0 and 'not one named register' in out['actual_query_mutant']['message'],out
(B/'result.json').write_text(json.dumps(out,indent=2)+'\n');print('PASS duplicate expansion reproduced; both physical identities visited; wrong alias rejected; actual query mutant caught; offline only')
