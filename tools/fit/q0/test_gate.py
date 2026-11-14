#!/usr/bin/env python3
"""Offline collector/gate qualification only. Never invokes Quartus or qualifies STA."""
from pathlib import Path
import argparse,ctypes,json,os,re,shutil,subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import gate
R=Path(__file__).resolve().parents[3];B=R/'build/q0-clock-gate';B.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10)
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--reports',type=Path,default=Path('/home/user/Git/NDS_Pocket/build/coordinator'));args=ap.parse_args()
lib=ctypes.CDLL('build/tools/oss-cad-suite/lib/libtcl8.6.so');lib.Tcl_CreateInterp.restype=ctypes.c_void_p;lib.Tcl_Eval.argtypes=[ctypes.c_void_p,ctypes.c_char_p];lib.Tcl_Eval.restype=ctypes.c_int;lib.Tcl_GetStringResult.argtypes=[ctypes.c_void_p];lib.Tcl_GetStringResult.restype=ctypes.c_char_p;lib.Tcl_DeleteInterp.argtypes=[ctypes.c_void_p]
SYS='ic|core_pll|pll|general[5].gpll~PLL_OUTPUT_COUNTER|divclk';FAST=SYS.replace('[5]','[7]');PREFIX='core_top:ic|nds_top:ds|nds_gpu3d:g_3d.u_gpu3d|gpu3d_raster:u_raster|gpu3d_factor_pump:g_xpump.u_factor|'
regs=[(PREFIX+f'q0_fast_{stem}[{i}][0]',FAST)for stem in ['rem','den','q']for i in range(4)]+[(PREFIX+f'q0_fast_{stem}',FAST)for stem in ['seen','phase','run']]+[(PREFIX+'q0_sys_toggle',SYS)]+[(PREFIX+f'q0_sys_q[{i}][0]',SYS)for i in range(4)]+[('top|source',SYS),('top|cacheTC|phase',FAST),('top|cachePC|phase',FAST)]
setup='''
set ::Q0_COLLECTOR_LIBRARY 1
set ::case normal
set ::cs [dict create]
set ::regnames [dict create]
set ::names {}
'''
for i,(n,c)in enumerate(regs):setup+=f'dict set ::cs r{i} {{{c}}}\ndict set ::regnames r{i} {{{n}}}\nlappend ::names r{i}\n'
setup+='dict set ::cs r100 UNCLOCKED\ndict set ::regnames r100 {vendor|PLL_RECONFIGFMAX_CAP_FF}\nlappend ::names r100\n'
setup+='''
proc foreach_in_collection {v col body} {if {[lindex $col 0] eq "COL"} {set col [lrange $col 1 end]};uplevel 1 [list foreach $v $col $body]}
proc all_clocks {} {return [list {SYS} {FAST} MASTER]}
proc get_clock_info {option c} {
 switch -- $option {
  -name {return $c}
  -period {if {[string first {general[5]} $c]>=0} {return 14.917};return 7.458}
  -targets {if {$c eq "MASTER"} {return [list COL tBASE]};if {[string first {general[5]} $c]>=0} {return [list COL tSYS]};if {$::case eq "multiple_targets"} {return {COL tFAST tFAST2}};return [list COL tFAST]}
  -child_clocks {if {$c eq "MASTER"} {return [list {SYS} {FAST}]};return {}}
 };error BAD_CLOCK_API
}
proc all_registers {} {return $::names}
proc get_register_info {option r} {
 if {$option eq "-clock_edges"} {if {$r eq "r100"||($::case eq "unclocked_Q0"&&$r eq "r0")} {return {}};return edge_active}
 if {$option ne "-name"} {error BAD_REGISTER_API};dict get $::regnames $r
}
proc get_node_info {option r} {if {$option eq "-type"} {if {$r eq "tBASE"} {return port};return pin};if {[string index $r 0] eq "t"} {return "physical_target/$r"};get_register_info $option $r}
proc get_clocks {args} {
 if {[llength $args]!=2||[lindex $args 0] ne "-nowarn"} {error BAD_CLOCK_QUERY}
 foreach c [all_clocks] {if {$c eq [lindex $args 1]} {if {$::case eq "wrong_clock_alias"} {return [list COL BAD_CLOCK_ALIAS]};return [list COL $c]}};return {}
}
proc get_fanins {args} {
 set opt [lindex $args 0];set collection [lindex $args end]
 if {[lindex $collection 0] ne "COL"||[llength $collection]!=2} {error ATOMIC_REGISTER_ID_IS_NOT_A_FILTER}
 set dest [lindex $collection 1]
 if {$opt eq "-clock"} {
  if {$dest eq "r100"||($::case eq "unclocked_Q0"&&$dest eq "r0")} {return {}}
  if {[llength $args]==2} {if {$::case eq "unknown_clock"&&$dest eq "r0"} {return {}};return tBASE}
  if {[lindex $args 1] ne "-through"||[llength $args]!=4} {error BAD_STANDARD_CLOCK_FANIN_API}
  set targetcol [lindex $args 2]
  if {[lindex $targetcol 0] ne "COL"} {error ATOMIC_TARGET_ID_IS_NOT_A_FILTER}
  set target [lindex $targetcol 1]
  if {$::case eq "unknown_clock"&&$dest eq "r0"} {return {}}
  if {$target eq "tBASE"} {return clockport}
  if {$::case eq "multiple_clock"&&$dest eq "r0"} {return clockport}
  set c [dict get $::cs $dest]
  if {($target eq "tSYS"&&$c eq {SYS})||($target in {tFAST tFAST2}&&$c eq {FAST})} {return clockport};return {}
 }
 if {$opt ne "-synch"||[llength $args]!=2} {error BAD_FANIN_API}
 set n [dict get $::regnames $dest]
 if {[string first q0_sys_q $n]>=0&&[string first {[0]} $n]>=0} {return r11}
 if {[string first q0_sys_ $n]>=0} {return r20}
 if {[string first q0_fast_ $n]>=0} {return [list r20 r0]}
 return r20
}
proc get_collection_size {col} {if {[lindex $col 0] eq "COL"} {return [expr {[llength $col]-1}]};llength $col}
proc get_registers {args} {
 if {[lindex $args 0] eq "-no_duplicates"} {set args [lrange $args 1 end]}
 if {[llength $args]!=2||[lindex $args 0] ne "-nowarn"} {error BAD_REGISTER_QUERY}
 foreach r $::names {if {[dict get $::regnames $r] eq [lindex $args 1]} {if {$::case eq "wrong_register_alias"&&$r eq "r0"} {return [list COL r1]};return [list COL $r]}};return {}
}
proc add_to_collection {a b} {
 if {[lindex $b 0] ne "COL"} {error ATOMIC_ADD_OBJECT_ID_IS_NOT_A_FILTER}
 if {$a eq {}} {set a COL};concat $a [lrange $b 1 end]
}
proc get_available_operating_conditions {} {return {Slow_85C Slow_0C Fast_0C}}
proc set_operating_conditions {corner} {set ::corner $corner}
proc update_timing_netlist {} {}
proc get_timing_paths {args} {
 foreach bad {-to_clock -startpoints_only} {if {[lsearch $args $bad]>=0} {error BAD_PATH_API}}
 if {[lsearch $args -false_path]>=0} {if {$::case eq "falsepath"} {return cut};return {}}
 set src [lindex $args [expr {[lsearch $args -from]+1}]];set dst [lindex $args [expr {[lsearch $args -to]+1}]]
 if {[lindex $src 0] ne "COL"||[lindex $dst 0] ne "COL"} {error ATOMIC_PATH_ENDPOINT_ID_IS_NOT_A_FILTER}
 set src [lindex $src 1];set dst [lindex $dst 1]
 set type [string range [lindex $args 0] 1 end]
 return [list [list $src $dst $type]]
}
proc get_path_info {key path} {
 lassign $path src dst type
 set legacy [expr {[string first cache [dict get $::regnames $dst]]>=0}]
 set wrong [expr {($legacy&&$::case ne "legacy_mcp_lost")||$::case eq "global_mcp"}]
 switch -- $key {
  -from {return $src} -to {return $dst} -from_clock {return [dict get $::cs $src]} -to_clock {return [dict get $::cs $dst]}
  -type {return $type}
  -slack {if {$::case eq "negative_hold"&&$type eq "hold"} {return -0.001};return 0.011}
  -clock_relationship {if {$type eq "hold"} {return 0};if {$wrong} {return 14.916};if {[dict get $::cs $src] eq {SYS}&&[dict get $::cs $dst] eq {SYS}} {return 14.917};return 7.458}
  -setup_start_multicycle - -hold_start_multicycle {return 0}
  -setup_end_multicycle {return [expr {$wrong?2:1}]}
  -hold_end_multicycle {return [expr {$wrong?1:0}]}
 };error UNKNOWN_PATH_PROPERTY
}
proc report_exceptions {args} {
 if {[lsearch $args -valid]>=0} {error UNSUPPORTED_REPORT_EXCEPTIONS_VALID}
 set fn [lindex $args [expr {[lsearch $args -file]+1}]];set f [open $fn w]
 if {[string first legacy [file tail $fn]]>=0} {puts $f {set_multicycle_path setup2 hold1 Complete}} else {puts $f {No exceptions were found}}
 close $f
}
proc report_sdc {args} {set f [open [lindex $args end] w];puts $f {SDC diagnostic mock only};close $f}
proc report_timing {args} {set f [open [lindex $args end] w];puts $f {Timing diagnostic mock only};close $f}
'''.replace('{SYS}','{'+SYS+'}').replace('{FAST}','{'+FAST+'}')
tcl=(Path(__file__).with_name('collect.tcl')).read_text();(B/'standard_clock.tcl').write_bytes(Path(__file__).with_name('standard_clock.tcl').read_bytes());result={'scope':'OFFLINE_COLLECTOR_TESTS_ONLY_NO_NEW_STA','tests':{}}
# Pin literal filter escaping independently of the API mocks.
interp=lib.Tcl_CreateInterp()
code='source {'+str(Path(__file__).with_name('standard_clock.tcl'))+'}\n'+r'foreach n {{top|q[0]} {top|a*?\x} {clk|general[7].gpll}} {if {![string match [q0_filter $n] $n]} {error BAD_LITERAL_FILTER}}'
rc=lib.Tcl_Eval(interp,code.encode());msg=lib.Tcl_GetStringResult(interp).decode();assert rc==0,msg
rc=lib.Tcl_Eval(interp,b'proc q0_filter {n} {return $n};set n {top|q[0]};if {![string match [q0_filter $n] $n]} {error BAD_LITERAL_FILTER}')
assert rc!=0 and b'BAD_LITERAL_FILTER'in lib.Tcl_GetStringResult(interp);lib.Tcl_DeleteInterp(interp)
result['tests']['literal_name_filter_and_actual_escape_mutant']='literal array/glob names preserved; unescaped-filter source fault caught'
# Existing real failed fit must never qualify, even with apparently populated resources.
fitpath=args.reports/'fit2159/apf_top.fit.rpt';mappath=fitpath.with_name('apf_top.map.rpt')
try:gate.mapping(fitpath.read_text(errors='replace'),mappath.read_text(errors='replace'));raise AssertionError('accepted failed fit')
except gate.GateError as e:assert 'fitter not successful'in str(e);result['tests']['real2159_failed_fit']=str(e)
# Existing RC7 samples: exactly the relationship the new gate must reject.
sample=args.reports/'rc053-clock-audit/sampled-sys-fast-paths.json';real=json.loads(sample.read_text());assert len(real)==4 and all(x['relationship_ns']==14.916 for x in real)
primary=args.reports/'rc053-clock-audit/timing_endpoints.log'
headers=None;parsed=[]
for line in primary.read_text().splitlines():
 if not line.startswith(';'):continue
 cells=[x.strip()for x in line.split(';')[1:-1]]
 if cells and cells[0]=='Slack':headers=cells;continue
 if headers and len(cells)==len(headers):
  record=dict(zip(headers,cells))
  if 'general[5]'in record.get('Launch Clock','')and 'general[7]'in record.get('Latch Clock',''):
   parsed.append(record)
assert len(parsed)==4 and all(float(x['Relationship'])==14.916 for x in parsed)
result['tests']['real2129_primary_legacy_rows']={'count':len(parsed),'relationship_ns':14.916,'STA_scope':'existing RC7 samples only, NOT Q0 endpoints'}
result['existing_report_bindings']={str(p):gate.H(p.read_bytes())for p in [fitpath,mappath,sample,primary]}
# Build a physical-report FORMAT fixture from real report tables, explicitly mock.
fit=fitpath.read_text(errors='replace');fit=re.sub(r'(^;\s*Fitter Status\s*;)\s*Failed[^;]*',r'\1 Successful (MOCK) ',fit,flags=re.M)
start=fit.index('; Fitter Resource Utilization by Entity ');end=fit.index('; Fitter RAM Summary ',start)
entity=fit[start:end];lines=entity.splitlines();header=next(l for l in lines if l.startswith('; Compilation Hierarchy Node'));cols=[x.strip()for x in header.split(';')[1:-1]]
vals={c:'0'for c in cols};vals.update({'Compilation Hierarchy Node':'Q0 mock factor','Full Hierarchy Name':'|apf_top|'+PREFIX.rstrip('|'),'DSP Blocks':'0','Block Memory Bits':'0'})
row='; '+' ; '.join(vals[c]for c in cols)+' ;\n';insert=entity.index('\n',entity.index(header))+1
# Insert after the separator so resources.table retains the real table framing.
insert=entity.index('\n',insert)+1
fit=fit[:start]+entity[:insert]+row+entity[insert:]+fit[end:]
# The old reciprocal row is removed only in the mock candidate mapping.
fit='\n'.join(l for l in fit.splitlines()if not('u_raster'in l and'u_frecip'in l))+'\n'
for label in ['normal','global_mcp','legacy_mcp_lost','falsepath','negative_hold','selector_fault','unknown_clock','multiple_clock','multiple_targets','atomic_register_query','atomic_path_query','atomic_add_query','wrong_register_alias','wrong_clock_alias','unclocked_Q0']:
 out=B/label
 if out.exists():shutil.rmtree(out)
 private=tcl
 if label=='selector_fault':private=private.replace('expr {[string match {*gpu3d_factor_pump:*} $name] || [string match {*q0_fast_*} $name] || [string match {*q0_sys_*} $name]}','expr {0}')
 if label=='atomic_register_query':private=private.replace('[get_fanins -synch [q0_regset $dest]]','[get_fanins -synch $dest]')
 if label=='atomic_add_query':private=private.replace('add_to_collection $nc [q0_regset $r]','add_to_collection $nc $r')
 if label=='atomic_path_query':private=private.replace('-from [q0_regset $source] -to [q0_regset $dest]','-from $source -to $dest')
 private_path=B/('collector-'+label+'.tcl');private_path.write_text(private)
 code=setup+f'\nset ::case {label}\nsource {{{private_path}}}\nq0_collect {{{out}}}'
 interp=lib.Tcl_CreateInterp();rc=lib.Tcl_Eval(interp,code.encode());msg=lib.Tcl_GetStringResult(interp).decode();lib.Tcl_DeleteInterp(interp)
 (B/(label+'.tcl')).write_text(code)
 if label=='unclocked_Q0':
  assert rc!=0 and 'Q0 clock missing/ambiguous'in msg,(label,msg)
  result['tests'][label]=msg;continue
 if label in ['wrong_register_alias','wrong_clock_alias']:
  assert rc!=0 and ('not one named register'in msg or'not one named clock'in msg),(label,msg)
  result['tests'][label]=msg;continue
 if label in ['atomic_register_query','atomic_path_query','atomic_add_query']:
  assert rc!=0 and 'IS_NOT_A_FILTER'in msg,(label,msg)
  result['tests'][label]=msg;continue
 if label in ['selector_fault','unknown_clock','multiple_clock','multiple_targets']:
  assert rc!=0 and any(x in msg for x in ['empty Q0','unknown/multiple clock','multiple defining clock']),msg
  result['tests'][label]=msg;continue
 assert rc==0,(label,msg)
 (out/'fit.rpt').write_text(fit);(out/'map.rpt').write_bytes(mappath.read_bytes());gate.seal(out,'mock','3c1db8f0d4c6381cf8f03fc6bdb71bf3ce46616a',0,{'rtl/gpu3d/gpu3d_factor_pump.sv':'mock-format-only'})
 try:
  v=gate.evaluate(out,allow_mock=True);assert label=='normal',label;assert v['status']=='MOCK_GATE_PASS_NOT_STA';result['tests'][label]=v
 except gate.GateError as e:assert label!='normal',(label,str(e));result['tests'][label]=str(e)
# Verifier faults must also be caught, including complete endpoint/legacy coverage.
for label,filename,edit in [
 ('missing_endpoint','inventory.tsv',lambda s:'\n'.join(l for l in s.splitlines()if'q0_fast_rem[0]'not in l)+'\n'),
 ('missing_legacy_pair','arcs.tsv',lambda s:'\n'.join(l for l in s.splitlines()if'cachePC'not in l)+'\n'),
 ('missing_hold','paths.tsv',lambda s:'\n'.join(l for l in s.splitlines()if not l.startswith('path\tFast_0C\t1\thold\t'))+'\n'),
 ('unknown_exception_format','exceptions-setup-to.rpt',lambda s:'report incomplete\n'),
 ('applied_false_exception','exceptions-hold-from.rpt',lambda s:'set_false_path Complete\n'),
 ('old_rom','fit.rpt',lambda s:s.replace('core_top:ic|core_bridge_cmd_lean:commands|mf_datatable:idt','core_top:ic|gpu3d_raster:u_raster|gpu3d_frecip:g_drec.u_frecip')),
 ('factor_DSP','fit.rpt',lambda s:s.replace(row,'; '+' ; '.join('1'if c=='DSP Blocks'else vals[c]for c in cols)+' ;\n')),
 ('real_old_relationship','paths.tsv',lambda s:s.replace('\t7.458\t','\t14.916\t'))]:
 out=B/label
 if out.exists():shutil.rmtree(out)
 shutil.copytree(B/'normal',out);p=out/filename;p.write_text(edit(p.read_text()));gate.seal(out,'mock','3c1db8f0d4c6381cf8f03fc6bdb71bf3ce46616a',0,{'Q0':'mock'})
 try:gate.evaluate(out,allow_mock=True);raise AssertionError('uncaught '+label)
 except gate.GateError as e:result['tests'][label]=str(e)
# Public production mode refuses an otherwise passing mock; an absent bundle fails too.
for label,out in [('mock_not_STA',B/'normal'),('missing_bundle',B/'absent')]:
 q=subprocess.run([sys.executable,str(Path(gate.__file__)),'check',str(out)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 assert q.returncode!=0 and b'FAIL_CLOSED'in q.stdout;result['tests'][label]=q.stdout.decode();(B/(label+'.log')).write_bytes(q.stdout)
result['status']='PASS_OFFLINE_COLLECTOR_GATE_AND_FAULTS_NOT_STA';(B/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(result['status'],len(result['tests']),'cases')
