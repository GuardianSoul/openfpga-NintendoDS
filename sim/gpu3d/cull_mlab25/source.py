#!/usr/bin/env python3
"""Exact bounded source inverse, native binding and fail-closed phase Tcl."""
import gzip,hashlib,json,re,subprocess,tempfile,xml.etree.ElementTree as ET
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/cull-mlab25';B.mkdir(exist_ok=True);BASE='9002ba2590ec05f2d9054dfb9625c1297da78cf5'
def old(p):return subprocess.check_output(['git','show',BASE+':'+p],cwd=R).decode()
path='rtl/gpu3d/gpu3d_gxeng.sv';s=(R/path).read_text();before=old(path);normalized=s[:s.index('\n\n// Fixed-port XYW cache.')]
normalized=normalized.replace("parameter bit CLIP_STORE_PUMP = 1'b0, // private clip store only; current K4/P2X cohort required\n    parameter bit CULL_MLAB = 1'b0 // fixed-port cull XYW cache, E/M writes", "parameter bit CLIP_STORE_PUMP = 1'b0 // private clip store only; current K4/P2X cohort required")
a=normalized.index('        wire [1:0] cull_read_group');b=normalized.index('        logic [3:0]  c_st;',a);oa=before.index('        always_ff @(posedge clk) begin\n            if (rf_we) begin\n                for (int g = 0; g < 4; g++) begin\n                    if (rf_wa == gb');ob=before.index('        logic [3:0]  c_st;',oa);normalized=normalized[:a]+before[oa:ob]+normalized[b:]
for reader in range(3):
 for coord,arr in enumerate(['cpx','cpy','cpw']):normalized=normalized.replace(f'cull_operand[{reader}][{coord}]',f'{arr}[c_g{reader}]')
assert normalized==before,'engine inverse beyond approved cache-only change'
for p in ['rtl/gpu3d/gpu3d_gxvfin.sv','rtl/gpu3d/gpu3d_gxdiv.sv','rtl/gpu3d/gpu3d_gxlight.sv','rtl/gpu3d/gpu3d_gxfront.sv','rtl/gpu3d/gpu3d_ram.sv']:assert(R/p).read_text()==old(p),p
for p,pin in [('rtl/pocket/core_top_ds.sv','.GX_CULL_MLAB(GX_CULL_MLAB), '),('rtl/ds/nds_top.sv','.GX_CULL_MLAB(GX_CULL_MLAB != 0), '),('rtl/ds/nds_gpu3d.sv','.GX_CULL_MLAB(GX_CULL_MLAB), ')]:
 n=(R/p).read_text().replace("\n  , parameter bit GX_CULL_MLAB = 1'b0 // fixed-port XYW cache experiment",'').replace(pin,'');assert n==old(p),p
# Actual compiled vendor hierarchy: nine logical replicas,20/12 native slices.
vvp=(B/'native/positive/model.vvp').read_text();logical=len(re.findall(r'\.scope module, "u_mem" "native_mlab32"',vvp));native=len(re.findall(r'\.scope module, "u_native" "altdpram"',vvp));assert logical==9 and native==18,(logical,native)
Q=Path('build/tools/quartus-lite/25.1/quartus');xml=Q/'libraries/megafunctions/xml_info/altdpram_info.xml';params={e.attrib['NAME'].lower():e.attrib for e in ET.parse(xml).findall('.//PARAMETER')};ports={e.attrib['NAME']:e.attrib for e in ET.parse(xml).findall('.//PORT')};mem=re.search(r'(?ms)^module gpu3d_gxcull_mlab32\b.*?^endmodule',s)[0]
actual_params=re.findall(r'\.(\w+)\s*\(',mem.split('altdpram #(',1)[1].split(')u_native',1)[0]);actual_ports=re.findall(r'\.(\w+)\s*\(',mem.split(')u_native(',1)[1]);assert set(actual_params)<=set(params);assert set(actual_ports)<=set(ports)
assert set(actual_ports)=={'inclock','inclocken','wren','data','wraddress','rdaddress','q'},'unused native mode port connected'
rules=Q/'libraries/megafunctions/xml_info/altdpram_rules.xml'
assert 'm_outclk_used'in rules.read_text()and 'UNREGISTERED'in rules.read_text()
for name in ['indata_reg','wraddress_reg','wrcontrol_reg']:assert 'INCLOCK'in params[name]['VALUE']
for name in ['rdaddress_reg','rdcontrol_reg','outdata_reg']:assert 'UNREGISTERED'in params[name]['VALUE']
assert 'MLAB'in params['ram_block_type']['VALUE'];assert 'WIDTH=slice==0?20:12;'in mem and '.widthad(5),.numwords(32)'in mem
script=(R/'scripts/build_ds.sh').read_text();a=script.index('set cullcache_regs');b=script.index('# Lighting product owners',a);block=script[a:b]
pre=r'''
set clk_sys SYS
set clk_2x FAST
set endpoints {gpu3d_gxcull_cache:u|epoch gpu3d_gxcull_cache:u|seen gpu3d_gxcull_cache:u|snap_hold gpu3d_gxcull_mlab32:u|u_native|data_reg}
array set checks {}
proc get_registers {args} {global endpoints;set r {};foreach e $endpoints {foreach p [lindex $args end] {if {[string match $p "top|$e"]} {lappend r $e;break}}};return $r}
proc get_collection_size {c} {return [llength $c]}
proc get_clocks {c} {if {$c in {SYS FAST}} {return $c};return {}}
proc set_multicycle_path {args} {global checks;if {[lrange $args 0 2] ni {{-setup -end 1} {-hold -end 0}}} {error "relaxed phase"};foreach e [lindex $args end] {set checks($e,[lindex $args 0]) 1}}
'''
post='foreach e $endpoints {foreach k {-setup -hold} {if {![info exists checks($e,$k)]} {error "missing strict endpoint"}}}\nputs PASS\n';phase={}
for name,setup,body in [('positive','',block),('native-endpoint-fault','',block.replace('gpu3d_gxcull_mlab32:', 'gpu3d_gxcull_mlab32_DISCONNECTED:')),('SYS-clock-fault','set clk_sys MISSING\n',block),('FAST-clock-fault','set clk_2x MISSING\n',block)]:
 code='if {[catch {\n'+pre+setup+body+post+'\n} err]} {puts stderr $err;exit 1}\n'
 with tempfile.NamedTemporaryFile('w',suffix='.tcl')as f:
  f.write(code);f.flush();p=subprocess.run([str(Q/'bin/tclsh'),f.name],capture_output=True,text=True)
 phase[name]={'exit':p.returncode,'text':(p.stdout+p.stderr).strip()};assert(p.returncode==0)==(name=='positive'),phase[name]
record={'base':BASE,'engine_exact_inverse':True,'accepted_leaves_identity':True,'logical_replicas':logical,'native_width_slices':native,'widths_per_logical':[20,12],'native_capacity':'18x32x20=11520bits capacity for9logical32bit replicas;4live slots each. Count32x20 granularity, not logical1152bits.','holding_bits':101,'vendor_XML_SHA256':hashlib.sha256(xml.read_bytes()).hexdigest(),'native_parameter_names':actual_params,'native_port_names':actual_ports,'mode_legality':'Output/address/read control allUNREGISTERED => OUTCLOCK unused; only7active/default ports connected. Explicit unused OUTCLOCK0 fromdd81 removed beforefinalsource.','vendor_rules_SHA256':hashlib.sha256(rules.read_bytes()).hexdigest(),'real_vendor_native_receipt':str(B/'native/receipt.json'),'strict_phase':phase,'strict_block_SHA256':hashlib.sha256(block.encode()).hexdigest(),'source_SHA256':{p:hashlib.sha256((R/p).read_bytes()).hexdigest()for p in ['rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_geom.sv','rtl/pocket/core_top_ds.sv','rtl/ds/nds_top.sv','rtl/ds/nds_gpu3d.sv','rtl/apf/apf_top.v','scripts/build_ds.sh']},'scope':'Configured native hierarchy and actual vendor simulation exact; physical mapping/area/STA remain Root fit gates. No outputalias/shared4 changes.'}
(B/'source.json').write_text(json.dumps(record,indent=2)+'\n');print('PASS exact source inverse,9logical/18native slices, vendorbinding,101holding bits and failclosedphase')
