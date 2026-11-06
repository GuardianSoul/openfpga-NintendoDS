#!/usr/bin/env python3
"""All seven real ROM images at original output edges, with actual RTL faults."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--mutant',choices=['none','index','word'],default='none');p.add_argument('--before',default='a9465f58a8a6a633655434b5285b60fb1fbf7095');a=p.parse_args()
os.nice(10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print('ROM_UNIT_PID',os.getpid(),'NI10/j1/t1',a.mutant,flush=True)
names=['gpu3d_gxrom']+['gpu3d_gxrom_u'+s for s in 'slvwfx']
files=[];old_hashes={}
for name in names:
    path='rtl/gpu3d/'+name+'.sv';old=subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT)
    old_hashes[path]=hashlib.sha256(old).hexdigest();f=out/(name+'_before.sv');f.write_bytes(old.replace(('module '+name+' #').encode(),('module '+name+'_before #').encode(),1));files.append(f)
helper=(ROOT/'rtl/gpu3d/gpu3d_gxrom_adict.sv').read_text()
if a.mutant=='index':
    old='index_q <= index_mem[addr];';assert helper.count(old)==1;helper=helper.replace(old,"index_q <= index_mem[addr] ^ 10'd1;")
if a.mutant=='word':
    old='word_q <= word_mem[index_q];';assert helper.count(old)==1;helper=helper.replace(old,"word_q <= word_mem[index_q] ^ 70'd1;")
h=out/'helper.sv';h.write_text(helper)
top=['module tb_rom_dict(input logic clk,clk2,rst,input logic [10:0] addr);',"wire [10:0] ra=rst?11'd40:addr;",'logic valid=0; always @(posedge clk) valid<=1;']
for i,name in enumerate(names):
    for tag,module,extra in [('a',name+'_before',''),('b',name,',.A_DICT(1)')]:
        top.append(f'wire [69:0] a{i}{tag}; wire [34:0] b{i}{tag},p{i}{tag}; wire [31:0] t{i}{tag};')
        ports=f'.clk,.a_addr(ra),.a_q(a{i}{tag}),.b_addr(addr),.b_q(b{i}{tag}),.b_p(p{i}{tag}),.t_idx(addr[6:0]),.t_imm(t{i}{tag})'
        if tag=='b':ports+=',.clk2,.rst'
        top.append(f'{module} #(.B2(1){extra}) r{i}{tag}({ports});')
    top.append(f'''always @(negedge clk2) if(valid) begin
if(a{i}a!==a{i}b) $fatal(1,"ROMDICT A mismatch image{i} addr%0d rst%0d ref%h got%h",addr,rst,a{i}a,a{i}b);
if(b{i}a!==b{i}b||p{i}a!==p{i}b||t{i}a!==t{i}b) $fatal(1,"ROMDICT B/immediate mismatch image{i}"); end''')
top.append('endmodule');w=out/'wrapper.sv';w.write_text('\n'.join(top)+'\n')
files += [h]+[ROOT/'rtl/gpu3d'/(n+'.sv')for n in names]+[w,ROOT/'sim/gpu3d/rom_dictionary/unit.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_rom_dict','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1']+list(map(str,files))
with(out/'build.log').open('w')as log:subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
print('ROM_UNIT_BUILD_PASS',a.mutant,flush=True)
with(out/'run.log').open('w')as log:r=subprocess.run([str(out/'obj/Vtb_rom_dict')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();caught=r.returncode!=0 and 'ROMDICT A mismatch' in log
assert (r.returncode==0 if a.mutant=='none' else caught),log
rec=dict(before=a.before,mutant=a.mutant,exit=r.returncode,actual_RTL_fault_caught=caught,command=cmd,old_hashes=old_hashes,helper_sha256=hashlib.sha256(helper.encode()).hexdigest(),output=log)
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n');print(log,flush=True)
