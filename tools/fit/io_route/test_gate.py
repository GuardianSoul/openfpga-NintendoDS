#!/usr/bin/env python3
"""Offline execution of production SDC/collector, plus caught gate faults.
Never runs Quartus. PASS is explicitly MOCK, never STA.
"""
import ctypes,hashlib,importlib.util,json,os,pathlib,shutil,sys
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[2];OUT=ROOT/'build/rc16/gate-fixtures';OUT.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('ior_gate',HERE/'gate.py');gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
os.nice(10)
SYS='ic|core_pll|pll|general[5].gpll~PLL_OUTPUT_COUNTER|divclk';FAST=SYS.replace('[5]','[7]')
PREFIX='top|nds_io:u_io|nds_io_route:g_route.u_route|'
regs=[PREFIX+f'route_lane[{i}]'for i in range(2)]+[PREFIX+f'route_envelope[{i}]'for i in range(3)]+[PREFIX+'ram_reply_mirror',PREFIX+'nds_io_route_ram:u_lookup|altsyncram:u_ram|ram_block1a0','top|nds_io:u_io|nds_io_route:g_route.u_route|keycnt9[0]','top|nds_fabric:u_fab|addr[0]']
setup=r'''
set ::IO_ROUTE_COLLECTOR_LIBRARY 1
set ::names {};set ::regnames [dict create];set ::domains [dict create];set ::mcp [dict create]
proc foreach_in_collection {v col body} {if {[lindex $col 0] eq "COL"} {set col [lrange $col 1 end]};uplevel 1 [list foreach $v $col $body]}
proc all_registers {} {return $::names}
proc all_clocks {} {return {SYS FAST MASTER}}
proc get_clock_info {key c} {
 switch -- $key {
  -name {if {$c eq "SYS"} {return $::SYS};if {$c eq "FAST"} {return $::FAST};return MASTER}
  -targets {return [list COL t$c]}
  -child_clocks {if {$c eq "MASTER"} {return [list $::SYS $::FAST]};return {}}
  -period {if {$c eq "SYS"} {return 14.917};return 7.458}
 };error BAD_CLOCK_INFO
}
proc get_clocks {args} {set c [lindex $args end];foreach id {SYS FAST MASTER} {if {$c eq [get_clock_info -name $id]} {return [list COL $id]}};error BAD_CLOCK_QUERY}
proc get_register_info {key r} {if {$key eq "-clock_edges"} {return rising};if {$key ne "-name"} {error BAD_REGISTER_API};dict get $::regnames $r}
proc get_node_info {key n} {if {$key eq "-type"} {if {$n eq "tMASTER"} {return port};return pin};if {[string index $n 0] eq "r"} {return [get_register_info -name $n]};return physical/$n}
proc get_collection_size {col} {if {[lindex $col 0] ne "COL"} {error UNTYPED_COLLECTION};expr {[llength $col]-1}}
proc get_registers {args} {
 if {[llength $args]!=2 || [lindex $args 0] ne "-nowarn"} {error BAD_REGISTER_QUERY}
 set patterns [lindex $args 1];set out COL
 foreach r $::names {
  set n [dict get $::regnames $r]
  if {$n eq $patterns} {if {$::case eq "wrong_alias"&&$r eq "r0"} {return {COL r1}};return [list COL $r]}
  foreach p $patterns {set literal [string map [list {[} {\[} {]} {\]}] $p];if {[string match $p $n]||[string match $literal $n]} {lappend out $r;break}}
 };if {$::case eq "wrong_alias"&&"r0"in[lrange $out 1 end]} {return {COL r1}};return $out
}
proc add_to_collection {a b} {get_collection_size $a;get_collection_size $b;return [concat $a [lrange $b 1 end]]}
proc remove_from_collection {a b} {get_collection_size $a;get_collection_size $b;set out COL;foreach r [lrange $a 1 end] {if {$r ni[lrange $b 1 end]} {lappend out $r}};return $out}
proc get_fanins {args} {
 set col [lindex $args end];get_collection_size $col;if {[llength $col]!=2} {error NOT_ONE_REGISTER};set r [lindex $col 1]
 if {[lindex $args 0] eq "-synch"} {return {COL r8}}
 if {[lindex $args 0] ne "-clock"} {error BAD_FANIN_API}
 if {[llength $args]==2} {return {COL tMASTER}}
 set t [lindex $args 2];get_collection_size $t
 if {$::case eq "unknown_clock"&&$r eq "r0"} {return COL}
 if {[lindex $t 1] eq "t[dict get $::domains $r]"} {return {COL clockpin}};return COL
}
proc set_multicycle_path {args} {
 set to [lindex $args [expr {[lsearch $args -to]+1}]];get_collection_size $to
 set fr [lindex $args [expr {[lsearch $args -from]+1}]];get_collection_size $fr
 if {[lindex $args 0] eq "-setup"} {foreach r [lrange $to 1 end] {dict set ::mcp $r [lindex $args 1]}}
}
proc post_message {args} {}
proc get_available_operating_conditions {} {return {Slow_85C Slow_0C Fast_0C}}
proc set_operating_conditions {corner} {set ::corner $corner}
proc update_timing_netlist {} {}
proc get_timing_paths {args} {
 set t [string range [lindex $args 0] 1 end]
 if {[lsearch $args -false_path]>=0} {if {$::case eq "falsepath"} {return {COL cut}};return COL}
 if {$::case eq "missing_path"} {return COL}
 set src [lindex $args [expr {[lsearch $args -from]+1}]];set dst [lindex $args [expr {[lsearch $args -to]+1}]]
 get_collection_size $src;get_collection_size $dst
 return [list COL [list [lindex $src 1] [lindex $dst 1] $t]]
}
proc get_path_info {key path} {
 lassign $path src dst t
 set bad [expr {[dict exists $::mcp $dst]||$::case eq "global_mcp"}]
 switch -- $key {
  -from {return $src} -to {return $dst}
  -from_clock {return [dict get $::domains $src]} -to_clock {return [dict get $::domains $dst]}
  -type {return $t}
  -slack {if {$::case eq "negative_hold"&&$t eq "hold"} {return -0.001};return 0.011}
  -clock_relationship {if {$t eq "hold"} {return 0};return 14.917}
  -setup_start_multicycle - -hold_start_multicycle {return 0}
  -setup_end_multicycle {return [expr {$bad?2:1}]}
  -hold_end_multicycle {return [expr {$bad?1:0}]}
 };error UNKNOWN_PATH_PROPERTY
}
proc report_exceptions {args} {
 set filename [lindex $args [expr {[lsearch $args -file]+1}]];set f [open $filename w]
 puts $f {No exceptions were found};close $f
}
proc report_sdc {args} {set f [open [lindex $args end] w];puts $f {Applied SDC fixture; no Quartus run};close $f}
'''
setup+=f'set ::SYS {{{SYS}}}\nset ::FAST {{{FAST}}}\nset clk_sys {{{SYS}}}\n'
for i,n in enumerate(regs):setup+=f'lappend ::names r{i}\ndict set ::regnames r{i} {{{n}}}\ndict set ::domains r{i} SYS\n'
lib=ctypes.CDLL('build/tools/oss-cad-suite/lib/libtcl8.6.so');lib.Tcl_CreateInterp.restype=ctypes.c_void_p
lib.Tcl_Eval.argtypes=[ctypes.c_void_p,ctypes.c_char_p];lib.Tcl_Eval.restype=ctypes.c_int;lib.Tcl_GetStringResult.argtypes=[ctypes.c_void_p];lib.Tcl_GetStringResult.restype=ctypes.c_char_p;lib.Tcl_DeleteInterp.argtypes=[ctypes.c_void_p]
script=(ROOT/'scripts/build_ds.sh').read_text();broad=script[script.index('set fab "*|nds_fabric:u_fab|"'):script.index('\n\nSDC',script.index('set fab "*|nds_fabric:u_fab|"'))]
strict=(HERE/'strict.tcl').read_text();collector=(HERE/'collect.tcl').read_text()
native2172=json.loads((HERE/'fixtures/2172-metadata-map.json').read_text())
cases=['normal','ram_MCP_omission','metadata_MCP_omission','wrong_FAST','unknown_clock','wrong_alias','global_mcp','negative_hold','falsepath','missing_path','collector_RAM_pair_omitted','collector_corner_omitted','native_RDW_wrong','unplaced_RAM','failed_fit','legacy_fallback_no_required_route']
cases += ['native2172_FSM_omission','native2172_alias_omission','native2172_combined_omission','native2172_lowered_count_omits_paths']
expected_message={'ram_MCP_omission':'new lookup received multicycle','metadata_MCP_omission':'new lookup received multicycle','wrong_FAST':'IO_ROUTE non-SYS endpoint','unknown_clock':'IO_ROUTE non-SYS endpoint','wrong_alias':'not one named register','global_mcp':'new lookup received multicycle','negative_hold':'negative hold slack','falsepath':'missing/false-pathed pair','missing_path':'missing/false-pathed pair','collector_RAM_pair_omitted':'missing endpoint fanin inventory','collector_corner_omitted':'incomplete operating corners','native_RDW_wrong':'lookup RDW is not OLD_DATA','unplaced_RAM':'lookup RAM is unplaced','failed_fit':'fitter not successful','legacy_fallback_no_required_route':'IO_ROUTE no physical endpoints'}
expected_message.update(native2172_FSM_omission='IO_ROUTE missing metadata/RAM endpoints: 3/1',native2172_alias_omission='IO_ROUTE missing metadata/RAM endpoints: 5/1',native2172_combined_omission='IO_ROUTE missing metadata/RAM endpoints: 2/1',native2172_lowered_count_omits_paths='missing six metadata FFs/RAM endpoints')
results=[]
for case in cases:
    out=OUT/case
    if out.exists():shutil.rmtree(out)
    out.mkdir();sd=strict;ct=collector
    if case in ('ram_MCP_omission','metadata_MCP_omission'):
        r='r6'if case.startswith('ram')else'r0'
        sd=sd.replace('set fab_tr [remove_from_collection $fab_tr $ior_strict]',f'set ior_strict [remove_from_collection $ior_strict [q0_regset {r}]]\n    set fab_tr [remove_from_collection $fab_tr $ior_strict]')
    if case=='collector_RAM_pair_omitted':ct=ct.replace('foreach n $strict {','foreach n [lrange $strict 0 5] {')
    if case=='collector_corner_omitted':ct=ct.replace('foreach corner $corners {','foreach corner [lrange $corners 0 1] {')
    if case=='native2172_lowered_count_omits_paths':sd=sd.replace('$ior_metadata!=6','$ior_metadata!=2')
    (out/'io_route_strict.tcl').write_text(sd);shutil.copyfile(HERE/'names.tcl',out/'io_route_names.tcl')
    # Collect uses absolute source directives; execute its actual procedure body.
    prefix=setup+f'set ::case {case}\nsource {{{HERE.parent/"q0/standard_clock.tcl"}}}\nset q0_index [q0_clock_index]\n'
    if case=='wrong_FAST':prefix+='dict set ::domains r0 FAST\n'
    if case in ('native2172_FSM_omission','native2172_combined_omission','native2172_lowered_count_omits_paths'):
        for i,n in zip((2,3,4,9),native2172['envelope_retained_nodes']):
            prefix+=f'dict set ::regnames r{i} {{{n}}}\ndict set ::domains r{i} SYS\n'
        prefix+='lappend ::names r9\n'
    if case in ('native2172_alias_omission','native2172_combined_omission','native2172_lowered_count_omits_paths'):
        prefix+=f'dict set ::regnames r0 {{{native2172["lane_merged_target"]}}}\n'
    if case=='legacy_fallback_no_required_route':
        for i in range(8):prefix+=f'dict set ::regnames r{i} {{top|nds_io:u_io|nds_io_legacy:g_legacy.u_legacy|legacy{i}}}\n'
    source=broad.replace('source [file join [file dirname [info script]] io_route_strict.tcl]',f'source {{{out/"io_route_strict.tcl"}}}')
    private_tools=out/'tools/io_route';private_tools.mkdir(parents=True)
    (private_tools/'collect.tcl').write_text(ct);shutil.copyfile(HERE/'names.tcl',private_tools/'names.tcl')
    (out/'tools/q0').mkdir();shutil.copyfile(HERE.parent/'q0/standard_clock.tcl',out/'tools/q0/standard_clock.tcl')
    program=prefix+source+f'\nsource {{{private_tools/"collect.tcl"}}}\nior_collect {{{out/"collected"}}}\n'
    interp=lib.Tcl_CreateInterp();rc=lib.Tcl_Eval(interp,program.encode());message=lib.Tcl_GetStringResult(interp).decode()
    if rc:
        lib.Tcl_Eval(interp,b'set ::errorInfo');message=lib.Tcl_GetStringResult(interp).decode()
    lib.Tcl_DeleteInterp(interp)
    verdict=None
    if rc==0:
        collected=out/'collected'
        headers=['Name','Mode','Clock Mode','Port A Width','Port B Width','Port A Depth','Port B Depth','M10K blocks','MLABs','Mixed Width RDW Mode','Location']
        vals=[regs[6],'Simple Dual Port','Single Clock','40','40','256','256','1','0','Old Data','M10K_X1_Y1']
        if case=='native_RDW_wrong':vals[-2]='Don\'t care'
        if case=='unplaced_RAM':vals[-1]='Unassigned'
        fit='; Fitter Status ; Successful ;\n; Fitter RAM Summary ;\n; '+' ; '.join(headers)+' ;\n; '+' ; '.join(vals)+' ;\n'
        if case=='failed_fit':fit=fit.replace('Fitter Status ; Successful','Fitter Status ; Failed')
        (collected/'fit.rpt').write_text(fit);gate.seal(collected,'mock','a'*40,0,{'fixture':'b'*64})
        try:verdict=gate.evaluate(collected,allow_mock=True);passed=case=='normal'
        except (gate.GateError,OSError,ValueError,KeyError,IndexError)as e:message=str(e);passed=case!='normal'
    else:passed=case!='normal'
    if case!='normal':assert expected_message[case]in message,(case,message)
    row={'case':case,'PASS':passed,'tcl_exit':rc,'message':message,'verdict':verdict};results.append(row);print(json.dumps(row),flush=True)
    assert passed,row
try:gate.evaluate(OUT/'normal/collected')
except gate.GateError as e:assert 'not live Quartus evidence'in str(e)
else:raise AssertionError('mock evidence accepted by live gate')
(ROOT/'build/rc16/gate-tests.json').write_text(json.dumps({'status':'PASS_OFFLINE_PRODUCTION_GATE_FIXTURES_NOT_STA','cases':results,'actual_production_SDC_block_sha256':hashlib.sha256(broad.encode()).hexdigest(),'resolver_sha256':hashlib.sha256((HERE.parent/'q0/standard_clock.tcl').read_bytes()).hexdigest()},indent=2)+'\n')
