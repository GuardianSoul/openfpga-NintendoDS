#!/usr/bin/env python3
"""Five69 actual source pair: public events/order/cycles, no old phase identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='362fea1dc1fcaee361977f06fd12826d45d03699')
p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
def phase(s,active=1):
    r=json.loads(status.read_text());r.update(phase=s,worker=dict(host='Desktop',active=active,controller_pid=os.getpid(),nice=10,jobs=1,threads=1),updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    b=json.dumps(r,indent=2)+'\n';assert len(b.encode())<=2048;t=status.with_suffix('.json.tmp');t.write_text(b);os.replace(t,status)
phase('Five69 source-pair build; mutant='+str(a.mutant))
print('FIVE69_PID',os.getpid(),'NI10/j1/t1',flush=True)
H=lambda b:hashlib.sha256(b).hexdigest()
fn='rtl/gpu3d/gpu3d_gxlight.sv';old=subprocess.check_output(['git','show',a.before+':'+fn],cwd=ROOT).decode();new=(ROOT/fn).read_text()
if a.mutant:
    needle='dif[2][1]<=product[3][19:0];';assert new.count(needle)==1
    new=new.replace(needle,'dif[2][1]<=product[4][19:0]; // actual wrong-lane ownership fault')
def unit(s,n):
    return s[s.index('module gpu3d_gxlightp #('):].split('endmodule',1)[0].replace('module gpu3d_gxlightp #(','module '+n+' #(',1)+'endmodule\n'
(out/'before.sv').write_text(''.join(unit(old,'light_before'+str(i))for i in range(4)))
(out/'after.sv').write_text(''.join(unit(new,'light_after'+str(i))for i in range(4))+new[new.index('module gpu3d_gxlight_products ('):])
top=['''module tb_light_products(
input logic clk,clk2,rst,we,start,fast,hold,cancel,material_valid,input logic[3:0]start_mask,input logic[10:0]wa,
input logic[31:0]wd,material_word,input logic[1:0]material_kind,input logic[29:0]nrm,
output logic[3:0]busy,cw,cv,output logic[14:0]cvd[4],output logic[31:0]cwd[4],
output logic[10:0]cwa[4],output logic[29:0]nr[4],output logic[1:0]state[4],
output logic[2:0]count[4],wn[4],output logic[3:0]lm[4]);''']
outs=dict(busy=1,cw=1,cv=1,cvd=15,cwd=32,cwa=11,nr=30)
ins='clk clk2 rst we start fast hold abort material_valid wa wd material_word material_kind nrm'.split()
for i in range(4):
    for side in ['a','b']:
        for n,w in outs.items():top.append(f'wire[{w-1}:0]{n}_{i}{side};')
        con=[f'.{n}('+('start&&start_mask['+str(i)+']'if n=='start'else'cancel'if n=='abort'else n)+')'for n in ins]
        con += [f'.{n}({n}_{i}{side})'for n in outs]
        extra=",.SHARED5(1'b1)"if side=='b'else''
        top.append(f'light_{"before"if side=="a"else"after"}{i} #(.MAT_PAR({i//2}),.NOWR({i%2}){extra}) {side}{i}('+','.join(con)+');')
    for n in outs:top.append(f'assign {n}[{i}]={n}_{i}b;')
    for n,k in [('state','st'),('count','cnt'),('wn','wn'),('lm','lm')]:top.append(f'assign {n}[{i}]=b{i}.{k};')
    top.append(f'''always @(negedge clk2)begin
if({{busy_{i}a,cw_{i}a,cv_{i}a,nr_{i}a,a{i}.st,a{i}.cnt,a{i}.wn,a{i}.lm}}!=={{busy_{i}b,cw_{i}b,cv_{i}b,nr_{i}b,b{i}.st,b{i}.cnt,b{i}.wn,b{i}.lm}})$fatal(1,"five{i} control/event mismatch");
if(!rst&&!cancel)begin
if(cv_{i}a&&cvd_{i}a!==cvd_{i}b)$fatal(1,"five{i} visible color mismatch old=%04x new=%04x",cvd_{i}a,cvd_{i}b);
if(cw_{i}a&&{{cwa_{i}a,cwd_{i}a}}!=={{cwa_{i}b,cwd_{i}b}})$fatal(1,"five{i} visible RFwrite mismatch");
for(int c=0;c<3;c++)begin
if(a{i}.memi[c]!==b{i}.memi[c]||a{i}.mdif_cache[c]!==b{i}.mdif_cache[c]||a{i}.mamb_cache[c]!==b{i}.mamb_cache[c]||a{i}.mspe_cache[c]!==b{i}.mspe_cache[c])$fatal(1,"five{i} architectural material mismatch");
end
for(int k=0;k<16;k++)if(a{i}.vec[k]!==b{i}.vec[k])$fatal(1,"five{i} vector state mismatch");
for(int l=0;l<4;l++)begin
for(int k=0;k<16;k++)if(a{i}.lt[l][k]!==b{i}.lt[l][k])$fatal(1,"five{i} light state mismatch");
end
end
end''')
top.append('endmodule\n');(out/'wrapper.sv').write_text('\n'.join(top))
(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/light_five/main.cpp').read_bytes())
files=[ROOT/'rtl/gpu3d/gpu3d_ram.sv',out/'before.sv',out/'after.sv',out/'wrapper.sv',out/'main.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_light_products','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1']+list(map(str,files))
(out/'load.txt').write_text(subprocess.check_output(['uptime'],text=True))
with(out/'build.log').open('w')as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'build failed'
print('FIVE69_BUILD_PASS',flush=True);phase('Five69 public source-pair running; mutant='+str(a.mutant))
exe=out/'obj/Vtb_light_products'
with(out/'run.log').open('w')as f:r=subprocess.run([str(exe)],stdout=f,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text()
rec=dict(before=a.before,mutant=a.mutant,PID=os.getpid(),command=cmd,exit=r.returncode,
         before_sha256=H(old.encode()),candidate_sha256=H(new.encode()),binary_sha256=H(exe.read_bytes()),
         files_sha256={str(f):H(f.read_bytes())for f in files},output=log,
         scope='All4 MAT_PAR/NOWR configurations, public event/order/cycle edge equivalence and independent exact color/RF model under component legal-input protocol. Actual caller sampling proof remains separate. No old internal NT/DOT phase identity.')
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n');print(log,flush=True)
phase('Five69 source-pair terminal rc='+str(r.returncode)+' mutant='+str(a.mutant),0)
if a.mutant:assert r.returncode!=0 and any(t in log for t in ['visible color mismatch','visible RFwrite mismatch'])
else:assert r.returncode==0
