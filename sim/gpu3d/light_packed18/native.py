#!/usr/bin/env python3
"""Source-bind native pairs to local vendor ports and a transparent arithmetic contract.

This checks the actual QIS branch against an explicit dual-independent-mode
contract, not the encrypted vendor simulator. Hardware packing/STA remain fit gates.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--prepare-only', action='store_true')
p.add_argument('--prepared', action='store_true')
p.add_argument('--mutant', action='store_true')
a = p.parse_args()
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
H = lambda b: hashlib.sha256(b).hexdigest()
source = (ROOT/'rtl/gpu3d/gpu3d_gxlight.sv').read_text()
pair = source[source.index('module gpu3d_gxlight_pair18 ('):].split('endmodule', 1)[0]+'endmodule\n'
before = subprocess.check_output(['git','show','3e34e6e8:rtl/gpu3d/gpu3d_gxlight.sv'], cwd=ROOT).decode()
old_drivers = '''    (* multstyle = "dsp" *) wire signed [35:0] product [8];
    genvar lane;
    generate for(lane=0;lane<8;lane++) begin : g_lane
        assign product[lane]=a[lane]*b[lane];
    end endgenerate'''
new_drivers = '''    wire signed [35:0] product [8];
    genvar pair;
    generate for(pair=0;pair<4;pair++) begin : g_pair
        gpu3d_gxlight_pair18 u_pair (
            .a0(a[2*pair]), .b0(b[2*pair]), .a1(a[2*pair+1]), .b1(b[2*pair+1]),
            .p0(product[2*pair]), .p1(product[2*pair+1]));
    end endgenerate'''
assert source.replace(pair+'\n', '', 1).replace(new_drivers, old_drivers) == before
for path in ['rtl/gpu3d/gpu3d_gxeng.sv']:
    assert (ROOT/path).read_bytes() == subprocess.check_output(['git','show','3e34e6e8:'+path],cwd=ROOT)
script=(ROOT/'scripts/build_ds.sh').read_bytes()
old_script=subprocess.check_output(['git','show','3e34e6e8:scripts/build_ds.sh'],cwd=ROOT)
# Approved45b05bf2 reporting-only companion changes the failure message,
# outside the generated QSF/SDC. Require its exact isolated delta.
report_old=b'  echo "RESULT ds s$seed$qmode: quartus failed (rc $rc)" | tee result.txt\n'
report_new=b'''  resources=$(python3 "$root/tools/fit/resources.py" "output_files/$top.fit.rpt" "output_files/$top.map.rpt") || resources="needed ALMs unavailable, M10K demand unavailable, synthesis DSP unavailable, LABs unavailable"
  sta_status="STA not reached"; [ ! -f sta.log ] || sta_status="STA failed"
  echo "RESULT ds s$seed$qmode: $resources; timing FAIL ($sta_status); quartus failed (rc $rc)" | tee result.txt
'''
assert script==old_script or script.replace(report_new,report_old)==old_script
if not a.prepared:
    vendor = Path('build/tools/quartus-lite/25.1/quartus')
    xml = vendor/'libraries/megafunctions/xml_info/cyclonev_mac_info.xml'
    atoms = vendor/'eda/sim_lib/cyclonev_atoms.v'
    params = {e.attrib['NAME'].lower(): e.attrib for e in ET.parse(xml).findall('.//PARAMETER')}
    ports = {e.attrib['NAME']: e.attrib for e in ET.parse(xml).findall('.//PORT')}
    assert 'm18x18_full' in params['operation_mode']['VALUE'].split('|')
    for name in ['signed_max','signed_may','signed_mbx','signed_mby']:
        assert 'true' in params[name]['VALUE'].split('|')
    for name in ['ax_clock','ay_scan_in_clock','bx_clock','by_clock','output_clock']:
        assert 'none' in params[name]['VALUE'].split('|')
    for name,width in [('ax','ax_width'),('ay','ay_scan_in_width'),('bx','bx_width'),('by','by_width'),('resulta','result_a_width'),('resultb','result_b_width')]:
        assert ports[name]['WIDTH'] == width
    module = atoms.read_text().split('module cyclonev_mac (',1)[1].split('endmodule',1)[0]
    actual_params = re.findall(r'\.(\w+)\s*\(', pair.split('cyclonev_mac #(',1)[1].split(') u_native',1)[0])
    actual_ports = re.findall(r'\.(\w+)\s*\(', pair.split(') u_native (',1)[1])
    profile={'operation_mode':'"m18x18_full"',
             **{k:'18'for k in ['ax_width','ay_scan_in_width','bx_width','by_width']},
             **{k:'36'for k in ['result_a_width','result_b_width']},
             **{k:'"true"'for k in ['signed_max','signed_may','signed_mbx','signed_mby']},
             **{k:'"none"'for k in ['ax_clock','ay_scan_in_clock','bx_clock','by_clock','output_clock']}}
    configured={k:v.strip()for k,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',pair.split('cyclonev_mac #(',1)[1].split(') u_native',1)[0])}
    assert configured==profile, 'static legal-port profile requires this exact native configuration'
    for name in actual_params:
        assert name in params and re.search(r'\bparameter\s+'+name+r'\b',module),name
    active_ports={'ax','ay','bx','by','resulta','resultb'}
    def legal_profile(text):
        named=re.findall(r'\.(\w+)\s*\(',text.split(') u_native (',1)[1])
        return len(named)==6 and set(named)==active_ports
    assert legal_profile(pair), 'm18x18_full unregistered input/input profile has exactly six active ports'
    assert set(actual_ports).issubset(ports)
    illegal_pair=pair.replace('.resulta(p0)',".az(1'b0), .resulta(p0)")
    assert illegal_pair!=pair and not legal_profile(illegal_pair), 'connected unused AZ mutant escaped legality check'
    (out/'port-legality.json').write_text(json.dumps(dict(configuration=profile,active_ports=sorted(active_ports),actual_connections=dict(re.findall(r'\.(\w+)\s*\(([^()]*)\)',pair.split(') u_native (',1)[1])),illegal_connection_mutant=dict(port='az',connection="1'b0",accepted=False,caught=True),prior_actual_errors=['1171/38629905:15649 AZ connectionwidth1/max0','1171/38629905:21186 COEFSELA unused']),indent=2)+'\n')
    for name,value in [('operand_source_max','input'),('operand_source_may','input'),('operand_source_mbx','input'),('operand_source_mby','input'),('ay_use_scan_in','false'),('by_use_scan_in','false'),('use_chainadder','false'),('enable_double_accum','false'),('preadder_subtract_a','false'),('preadder_subtract_b','false'),('negate_clock','none'),('accumulate_clock','none'),('load_const_clock','none'),('sub_clock','none')]:
        item=params[name];assert item['VALUE'].split('|')[int(item['DEFAULT_VALUE_INDEX'])]==value
        assert re.search(r'\bparameter\s+'+name+r'\s*=\s*"'+value+r'"',module),name
    binding = dict(pair_sha256=H(pair.encode()), vendor_xml=str(xml), vendor_xml_sha256=H(xml.read_bytes()),
                   vendor_atoms=str(atoms), vendor_atoms_sha256=H(atoms.read_bytes()),
                   composition='Only the eight inferred product drivers become four literal paired drivers. All operands/consumers/schedule/FF/reset/import paths and gxeng byte-exact; build script exact or only approved45b05bf2 failure-report delta, QSF/SDC unchanged.',
                   contract='Native m18x18_full with ax/ay and bx/by, signed flags true, unregistered inputs/output, no preadder/accum/chain; resulta=ax*ay and resultb=bx*by, each full36. Vendor CycloneV independent mode handbook and shipped25.1 port/schema are trusted premises.',
                   active_port_profile=dict(mode='m18x18_full',ports=sorted(active_ports),omitted=sorted(set(ports)-active_ports),unused_AZ_connection_mutant_caught=True,prior_failure='Actual1171/38629905 errors15649 AZ connected1/configuredmax0 and21186 COEFSELA unused; generic schema declares ports for all modes and is not a mode-specific legal connection list.'),
                   limitation='Transparent contract model is not the encrypted vendor model or post-map simulation. Actual fit must establish four physical blocks, no configuration error and ordinary half-cycle timing.')
    (out/'binding.json').write_text(json.dumps(binding,indent=2)+'\n')
else:
    binding=json.loads((out/'binding.json').read_text())
    assert binding['pair_sha256']==H(pair.encode()), 'prepared actual source changed'
if a.prepare_only:
    print('NATIVE_BINDING_PREPARED actual pairs/source inverse and vendor25.1 schema')
    raise SystemExit(0)
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
print('NATIVE_PAIR_PID',os.getpid(),'NI10/j1/t1',flush=True)
if a.mutant:
    assert pair.count('.by(b1)')==1
    pair=pair.replace('.by(b1)', '.by(b0)')
native='`define ALTERA_RESERVED_QIS\n'+pair.replace('module gpu3d_gxlight_pair18 (','module native_pair (',1)+'`undef ALTERA_RESERVED_QIS\n'
fallback=pair.replace('module gpu3d_gxlight_pair18 (','module behavioral_pair (',1)
(out/'actual-pair.sv').write_text(native+fallback)
model='''// Transparent independent-mode contract; not the encrypted vendor model.
module cyclonev_mac #(
parameter operation_mode="",parameter ax_width=18,ay_scan_in_width=18,bx_width=18,by_width=18,
parameter result_a_width=36,result_b_width=36,
parameter signed_max="",signed_may="",signed_mbx="",signed_mby="",
parameter ax_clock="",ay_scan_in_clock="",bx_clock="",by_clock="",output_clock=""
)(input logic[ax_width-1:0]ax,input logic[ay_scan_in_width-1:0]ay,
input logic[bx_width-1:0]bx,input logic[by_width-1:0]by,
output wire[result_a_width-1:0]resulta,output wire[result_b_width-1:0]resultb);
initial begin
assert(operation_mode=="m18x18_full"&&signed_max=="true"&&signed_may=="true"&&signed_mbx=="true"&&signed_mby=="true");
assert(ax_width==18&&ay_scan_in_width==18&&bx_width==18&&by_width==18&&result_a_width==36&&result_b_width==36);
assert(ax_clock=="none"&&ay_scan_in_clock=="none"&&bx_clock=="none"&&by_clock=="none"&&output_clock=="none");
end
assign resulta=$signed(ax)*$signed(ay);assign resultb=$signed(bx)*$signed(by);
endmodule
module tb_native_pair(input logic[17:0]a0,b0,a1,b1,output wire[35:0]n0,n1,f0,f1);
native_pair n(.a0,.b0,.a1,.b1,.p0(n0),.p1(n1));
behavioral_pair f(.a0,.b0,.a1,.b1,.p0(f0),.p1(f1));
endmodule
'''
(out/'contract.sv').write_text(model)
(out/'main.cpp').write_text('''#include "Vtb_native_pair.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
int main(int argc,char**argv){VerilatedContext c;c.threads(1);c.commandArgs(argc,argv);Vtb_native_pair d{&c};
uint32_t seed=0xa4d19731;auto rand=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed&0x3ffffU;};
auto sx=[](uint32_t v){return int64_t(int32_t(v^0x20000U)-int32_t(0x20000U));};
const uint64_t mask=(1ULL<<36)-1;uint32_t edges[]={0,1,2,0x1ffff,0x20000,0x20001,0x3fffe,0x3ffff};
for(unsigned i=0;i<2004096;++i){unsigned k=i;d.a0=i<4096?edges[(k>>0)&7]:rand();d.b0=i<4096?edges[(k>>3)&7]:rand();d.a1=i<4096?edges[(k>>6)&7]:rand();d.b1=i<4096?edges[(k>>9)&7]:rand();d.eval();
uint64_t e0=uint64_t(sx(d.a0)*sx(d.b0))&mask,e1=uint64_t(sx(d.a1)*sx(d.b1))&mask;
if(d.n0!=e0||d.n1!=e1||d.f0!=e0||d.f1!=e1){std::printf("ACTUAL_NATIVE_PORT_CONSUMER_MISMATCH case=%u p0=%llx/%llx p1=%llx/%llx\\n",i,(unsigned long long)d.n0,(unsigned long long)e0,(unsigned long long)d.n1,(unsigned long long)e1);return 1;}}
std::puts("PASS native actual QIS branch and fallback 2004096 fullsigned18x18 pairs; 4096 boundary tuples, 2000000 random, threads1; transparent vendorcontract, not encrypted model");}
''')
files=[out/'actual-pair.sv',out/'contract.sv',out/'main.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_native_pair','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1']+list(map(str,files))
with(out/'build.log').open('w')as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'native pair contract build failed'
with(out/'run.log').open('w')as f:r=subprocess.run([str(out/'obj/Vtb_native_pair')],stdout=f,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
(out/'receipt.json').write_text(json.dumps(dict(binding=binding,mutant=a.mutant,exit=r.returncode,PID=os.getpid(),command=cmd,files_sha256={str(f):H(f.read_bytes())for f in files},output=log),indent=2)+'\n')
assert r.returncode!=0 and 'ACTUAL_NATIVE_PORT_CONSUMER_MISMATCH' in log if a.mutant else r.returncode==0
