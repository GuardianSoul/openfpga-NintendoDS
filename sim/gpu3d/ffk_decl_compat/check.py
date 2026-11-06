#!/usr/bin/env python3
"""Exhaustive four-state relation of literal old/new decoder declarations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='8134da6d');p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);out=a.out.resolve();out.mkdir(exist_ok=True,parents=True)
start=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json');d=json.loads(status.read_text());d.update(phase='4stateexactffk declaration relation starting; mutant='+str(a.mutant),worker={'host':'Desktop','controller_pid':os.getpid(),'starttime':start,'active':1,'nice':10,'jobs':1,'threads':1});tmp=status.with_suffix('.tmp');tmp.write_text(json.dumps(d,indent=2)+'\n');os.replace(tmp,status)
print(f'controller_pid={os.getpid()} starttime={start} NI10/j1/t1',flush=True)
fn='rtl/gpu3d/gpu3d_gxeng.sv';old=subprocess.check_output(['git','show',a.before+':'+fn],cwd=ROOT).decode();new=(ROOT/fn).read_text()
if a.mutant:
 needle="e_hidx == FF_HV16 ? 3'd2";assert new.count(needle)==1;new=new.replace(needle,"e_hidx == FF_HV16 ? 3'd3")
pkg=(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text();defs='\n'.join(l for l in pkg.splitlines()if re.search(r'localparam.*\bFF_HV(?:16|10|XY|XZ|YZ|DF)\b',l))
def literal(src):
 begin=re.search(r'        wire\s+\[2:0\]\s+ffk_n\b',src).start();end=src.index('        assign fft_m',begin);return src[begin:end]
oldlit,newlit=literal(old),literal(new)
def module(name,code):return f'''module {name}(input ff_col,ff_tex,input[5:0]e_hidx,output[2:0]q);
{defs}
generate if(1)begin:g_ff
{code}
assign q=ffk_n;
end endgenerate
endmodule
'''
tb='''module tb;
reg ff_col,ff_tex;reg[5:0]e_hidx;wire[2:0]a,b;integer n,k,known,unknown;
before_decoder u0(ff_col,ff_tex,e_hidx,a);after_decoder u1(ff_col,ff_tex,e_hidx,b);
function automatic four(input integer v);begin case(v)0:four=0;1:four=1;2:four=1'bx;default:four=1'bz;endcase end endfunction
initial begin known=0;unknown=0;
 for(n=0;n<65536;n=n+1)begin
  ff_col=four(n&3);ff_tex=four((n>>2)&3);
  for(k=0;k<6;k=k+1)e_hidx[k]=four((n>>(4+2*k))&3);
  #1;
  if(a!==b)$fatal(1,"actual ffk handler mismatch n=%0d col=%b tex=%b h=%b old=%b new=%b",n,ff_col,ff_tex,e_hidx,a,b);
  if((^a)===1'bx)unknown=unknown+1;else known=known+1;
 end
 $display("PASS 4state_cases=65536 known=%0d unknown=%0d",known,unknown);$finish;
end
endmodule
'''
(out/'decoder.sv').write_text(module('before_decoder',oldlit)+module('after_decoder',newlit)+tb)
oss=Path('build/tools/oss-cad-suite/bin')
cmd=[str(oss/'iverilog'),'-g2012','-s','tb','-o',str(out/'test.vvp'),str(out/'decoder.sv')]
with(out/'build.log').open('w')as f:subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,check=True)
with(out/'run.log').open('w')as f:
 child=subprocess.Popen([str(oss/'vvp'),str(out/'test.vvp')],stdout=f,stderr=subprocess.STDOUT)
 tasks=0
 try:tasks=len(list(Path('/proc/'+str(child.pid)+'/task').iterdir()))
 except FileNotFoundError:pass
 rc=child.wait()
assert tasks<=1
log=(out/'run.log').read_text();print(log,flush=True)
r={'before':a.before,'before_sha256':hashlib.sha256(old.encode()).hexdigest(),'candidate_sha256':hashlib.sha256(new.encode()).hexdigest(),'old_literal':oldlit,'new_literal':newlit,'command':cmd,'run_command':[str(oss/'vvp'),str(out/'test.vvp')],'mutant':a.mutant,'exit':rc,'controller':os.getpid(),'starttime':start,'child':child.pid,'observed_tasks':tasks,'nice':10,'jobs':1,'threads':1,'scope':'one changed decoder declaration/assignment; actualliteralbranchfault; no geometry/native baseline rerun'};(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
assert (rc!=0)==a.mutant
if a.mutant:assert 'actual ffk handler mismatch'in log
else:assert '4state_cases=65536'in log
