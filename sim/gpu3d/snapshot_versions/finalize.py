#!/usr/bin/env python3
"""Versioned snapshots: complete finalize data, service and retained state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='1effca28')
p.add_argument('--mutant', action='store_true')
p.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
print(f'worker_pid={os.getpid()} nice=10 jobs=1 threads=1', flush=True)
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
path = 'rtl/gpu3d/gpu3d_gxvfin.sv'
old = subprocess.check_output(['git', 'show', a.before+':'+path], cwd=ROOT).decode()
new = (ROOT/path).read_text()
primitive=(ROOT/'rtl/gpu3d/gpu3d_gxdiv.sv').read_text()
(out/'primitive.sv').write_text(primitive)
if a.mutant:
    needle='wire slot_write_version = live_write_version ^ slot_fork;'
    assert new.count(needle)==1
    new=new.replace(needle,'wire slot_write_version = live_write_version; // actual missing fork fault')
def unit(src, name):
    src = src[src.index('module gpu3d_gxfin\n'):]
    return src.split('endmodule', 1)[0].replace('module gpu3d_gxfin\n', f'module {name}\n', 1)+'endmodule\n'
(out/'before.sv').write_text(unit(old, 'fin_before'))
(out/'after.sv').write_text(unit(new, 'fin_after'))
pkg = (ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
constants = {n:int(v,16) for n,v in re.findall(r'localparam logic \[10:0\] (\w+) = 11\'h([0-9A-Fa-f]+)',pkg)}
(out/'addresses.h').write_text('\n'.join(f'constexpr unsigned {n}=0x{v:x};' for n,v in constants.items())+'\n')
params = ','.join(f'.{n}({v})' for n,v in {'A_LA':'FU_A_LA','A_LN':'FU_A_LN','A_CS':'FU_A_CS','A_TEXPAL':'FU_A_TEXPAL','A_FACING':'FU_A_FACING','A_FATTR':'FU_A_FATTR','A_TRT':'FU_A_TRT','A_TRA':'FU_A_TRA','A_VP':'FU_A_VP','A_CATTR':'LU_A_CATTR','A_TEXP':'FU_A_TEXP','G_FZ':'FU_G_FZ'}.items())
outputs = {'cond':1,'pidx':11,'rd':1,'sop':1,'sm':3,'sr':32,'cw':1,'cwa':11,'cwd':32,'pv':1,'ptype':1,'pd':128,'key':32,'busy':1,'ready':1}
inputs = 'clk,clk2,rst,we,wa,wd,run,xarg,np,sct,wfree,ofree,hgo,h_la,h_ln,h_cs,h_face,h_wb'.split(',')
top = ['''module tb_finalize_mlab(
input logic clk,clk2,rst,we,run,wfree,ofree,hgo,h_face,h_wb,
input logic [10:0] wa,h_la[4], input logic [31:0] wd,sct,
input logic [2:0] xarg, input logic [11:0] np,
input logic [3:0] h_ln, input logic [1:0] h_cs,
output wire cond,ready,busy,cw,pv,ptype,output wire [10:0] cwa,
output wire [31:0] cwd, output wire q_active,
output logic [31:0] cw_takes,headers,vertices,overlap_starts,publish_pending,
output logic [31:0] triple,reuse_writes,new_writes,z_skips,hold_cw,hold_pv,
output logic [31:0] forks,sameedge,live_rewrites,protected_writes,output logic [15:0] fork_words);
import gpu3d_gxu_pkg::*;
''']
for suffix, module in [('a','fin_before'),('b','fin_after')]:
    for n,w in outputs.items(): top.append(f'wire [{w-1}:0] {n}_{suffix};')
    con = [f'.{n}({n})' for n in inputs]+[f'.{n}({n}_{suffix})' for n in outputs]
    top.append(f'{module} #({params}'+",.DIV_P2X(1'b1)"+f') {suffix}('+','.join(con)+');')
for n in ['cond','ready','busy','cw','pv','ptype','cwa','cwd']: top.append(f'assign {n}={n}_a;')
top.append('assign q_active=a.q_on;')
top.append('always @(negedge clk) if(!rst) begin')
for n in outputs:
    gate = '1'
    if n in ['cwa','cwd']: gate='cw_a'
    if n in ['ptype','pd','pidx']: gate='pv_a'
    if n in ['key','sm','sr']: gate='sop_a'
    top.append(f'if({gate} && {n}_a !== {n}_b) $fatal(1,"finalize {n} mismatch");')
for n in ['pst','fin','a_on','a_rdy','b_on','b_dv','dstart','so_on','q_on','q_auto','thdr','ti','sk','ai','ak','bi','pln','pcs','auto','wb','fst','kt','kb','wo_r','deg','pnp','q_kt','q_kb','q_wo','q_deg','q_wbuf','q_texpal','q_facing','q_trtra','q_cattr','q_texp','q_ln','q_pnp']:
    top.append(f'if(a.{n} !== b.{n}) $fatal(1,"finalize state {n} mismatch");')
top.append('for(int i=0;i<10;i++) if(a.wpend[i] !== b.wpend[i] || a.rg[i] !== b.rg[i]) $fatal(1,"finalize entry state mismatch"); end')
top.append('''logic was_q;
always @(posedge clk) if(rst) begin
cw_takes<=0; headers<=0; vertices<=0; overlap_starts<=0; publish_pending<=0;
triple<=0;reuse_writes<=0;new_writes<=0;z_skips<=0;hold_cw<=0;hold_pv<=0;was_q<=0;
forks<=0;sameedge<=0;live_rewrites<=0;protected_writes<=0;fork_words<=0;
end else begin
was_q<=a.q_on;
forks<=forks+32'(b.slot_we&&b.slot_fork);
sameedge<=sameedge+32'(b.slot_we&&hgo);
live_rewrites<=live_rewrites+32'(b.slot_we&&b.snapshot_active&&!b.slot_fork);
protected_writes<=protected_writes+32'(b.slot_we&&b.snapshot_active);
if(b.slot_we&&b.slot_fork) fork_words<=fork_words|(16'd1<<wa[3:0]);
cw_takes<=cw_takes+32'(cw_a&&wfree);
headers<=headers+32'(pv_a&&ofree&&!ptype_a);
vertices<=vertices+32'(pv_a&&ofree&&ptype_a);
overlap_starts<=overlap_starts+32'(a.q_on && (hgo || a.go && (xarg==0 || xarg==3)));
publish_pending<=publish_pending+32'(!was_q && a.q_on && a.wany);
triple<=triple+32'(cw_a && pv_a && ptype_a && (b.p_we || b.z_we || b.c_we));
reuse_writes<=reuse_writes+32'(b.reuse_p||b.reuse_c);
new_writes<=new_writes+32'(b.b_fin);
z_skips<=z_skips+32'(b.b_fin && !b.z_we);
hold_cw<=hold_cw+32'(cw_a&&!wfree);
hold_pv<=hold_pv+32'(pv_a&&!ofree);
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top))
(out/'driver.cpp').write_bytes((ROOT/'sim/gpu3d/snapshot_versions/finalize.cpp').read_bytes())
cmd = [a.verilator,'--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_finalize_mlab','--Mdir',str(out/'obj'),'-CFLAGS',f'-std=c++20 -O1 -I{out}',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'primitive.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'driver.cpp')]
with (out/'build.log').open('w') as log: subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
print('BUILD_PASS',flush=True)
with (out/'run.log').open('w') as log: run=subprocess.run([str(out/'obj/Vtb_finalize_mlab')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
receipt = dict(driver_sha256=hashlib.sha256((out/'driver.cpp').read_bytes()).hexdigest(), before=a.before, before_sha256=hashlib.sha256(old.encode()).hexdigest(), candidate_sha256=hashlib.sha256(new.encode()).hexdigest(),command=cmd,mutant=a.mutant,exit=run.returncode,pid=os.getpid(),nice=os.getpriority(os.PRIO_PROCESS,0),jobs=1,threads=1)
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print((out/'run.log').read_text())
if (run.returncode==0)==a.mutant: raise SystemExit('unexpected result')
if a.mutant and 'gpu3d_gxfin snapshot:' not in (out/'run.log').read_text(): raise SystemExit('version fork fault was not caught')
