#!/usr/bin/env python3
"""Scoped actual lighting source pairs with same-edge event/state checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='9f88b3a9');p.add_argument('--mutant',action='store_true');p.add_argument('--cancel-only',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
start=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
def phase(value,active=1):
 d=json.loads(status.read_text());d.update(phase=value,worker={'host':'Desktop','controller_pid':os.getpid(),'starttime':start,'active':active,'nice':10,'jobs':1,'threads':1},updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()));s=json.dumps(d,indent=2)+'\n';assert len(s.encode())<=2048;t=status.with_suffix('.tmp');t.write_text(s);os.replace(t,status)
phase('newlighting typed relation starting; mutant='+str(a.mutant));print(f'controller_pid={os.getpid()} starttime={start} NI10/j1/t1 out={out}',flush=True)
fn='rtl/gpu3d/gpu3d_gxlight.sv';old=subprocess.check_output(['git','show',a.before+':'+fn],cwd=ROOT).decode();new=(ROOT/fn).read_text()
if a.mutant:
 needle='spc[i][color] <= product[i][19:0];';assert new.count(needle)==1;new=new.replace(needle,"spc[i][color] <= product[i][19:0] ^ 20'h40000; // actual product-bit fault")
def unit(src,name):return src[src.index('module gpu3d_gxlightp #('):].split('endmodule',1)[0].replace('module gpu3d_gxlightp #(','module '+name+' #(',1)+'endmodule\n'
helper=new[new.index('module gpu3d_gxlight_products ('):].split('endmodule',1)[0]+'endmodule\n'
(out/'before.sv').write_text(''.join(unit(old,'light_before'+str(i))for i in range(4)))
(out/'after.sv').write_text(''.join(unit(new,'light_after'+str(i))for i in range(4))+helper)
top=['''module tb_light_products(
input logic clk,clk2,rst,we,start,fast,hold,cancel,material_valid,input logic[3:0]start_mask,input logic[10:0]wa,
input logic[31:0]wd,material_word,input logic[1:0]material_kind,input logic[29:0]nrm,
output logic[3:0]busy,cw,cv,output logic[14:0]cvd[4],output logic[31:0]cwd[4],
output logic[10:0]cwa[4],output logic[29:0]nr[4],output logic[1:0]state[4],
output logic[2:0]count[4],wn[4],output logic[3:0]lm[4]);
''']
outs={'busy':1,'cw':1,'cv':1,'cvd':15,'cwd':32,'cwa':11,'nr':30}
ins='clk rst we start fast hold abort material_valid wa wd material_word material_kind nrm'.split()
for i in range(4):
 for side in ['a','b']:
  for n,w in outs.items():top.append(f'wire[{w-1}:0]{n}_{i}{side};')
  cons=[f'.{n}({"start&&start_mask["+str(i)+"]"if n=="start"else"cancel"if n=="abort"else n})'for n in ins]+[f'.{n}({n}_{i}{side})'for n in outs]
  if side=='b':cons.insert(1,'.clk2(clk2)')
  top.append(f'light_{"before"if side=="a"else"after"}{i} #(.MAT_PAR({i//2}),.NOWR({i%2})) {side}{i}('+','.join(cons)+');')
 for n in outs:top.append(f'assign {n}[{i}]={n}_{i}b;')
 for n,k in [('state','st'),('count','cnt'),('wn','wn'),('lm','lm')]:top.append(f'assign {n}[{i}]=b{i}.{k};')
 top.append(f'''always @(negedge clk)begin
 if({{busy_{i}a,cw_{i}a,cv_{i}a,nr_{i}a,a{i}.st,a{i}.cnt,a{i}.wn,a{i}.lm}}!=={{busy_{i}b,cw_{i}b,cv_{i}b,nr_{i}b,b{i}.st,b{i}.cnt,b{i}.wn,b{i}.lm}})$fatal(1,"light{i} control/event/state mismatch");
 if(!rst&&!cancel)begin
  if(cv_{i}a&&cvd_{i}a!==cvd_{i}b)$fatal(1,"light{i} visible color mismatch old=%04x new=%04x",cvd_{i}a,cvd_{i}b);
  if(cw_{i}a&&{{cwa_{i}a,cwd_{i}a}}!=={{cwa_{i}b,cwd_{i}b}})$fatal(1,"light{i} visible RFwrite mismatch");
  for(int c=0;c<3;c++)begin
   if(a{i}.ntv[c]!==b{i}.ntv[c]||a{i}.memi[c]!==b{i}.memi[c])$fatal(1,"light{i} normal/emission state mismatch");
   if(a{i}.mdif_cache[c]!==b{i}.mdif_cache[c]||a{i}.mamb_cache[c]!==b{i}.mamb_cache[c]||a{i}.mspe_cache[c]!==b{i}.mspe_cache[c])$fatal(1,"light{i} material state mismatch");
  end
  for(int k=0;k<16;k++)if(a{i}.vec[k]!==b{i}.vec[k])$fatal(1,"light{i} vector state mismatch");
  for(int l=0;l<4;l++)begin
   if(a{i}.dot[l]!==b{i}.dot[l]||a{i}.pos[l]!==b{i}.pos[l])$fatal(1,"light{i} retained dot/pos mismatch");
   for(int k=0;k<16;k++)if(a{i}.lt[l][k]!==b{i}.lt[l][k])$fatal(1,"light{i} light state mismatch");
   if(a{i}.sqv[l]!==b{i}.sqv[l])$fatal(1,"light{i} qualified square mismatch");
   if(b{i}.st==b{i}.S_RUN&&b{i}.cnt>=4||b{i}.st==b{i}.S_FIN)begin
    if(a{i}.shine0[l]!==b{i}.shine0[l]||a{i}.srd[l]!==b{i}.srd[l])$fatal(1,"light{i} shine/table edge mismatch");
    for(int c=0;c<3;c++)if(a{i}.dif[l][c]!==b{i}.dif[l][c])$fatal(1,"light{i} qualified diffuse mismatch");
   end
   if(b{i}.st==b{i}.S_FIN)for(int c=0;c<3;c++)if(a{i}.spc[l][c]!==b{i}.spc[l][c]||a{i}.vb[c]!==b{i}.vb[c])$fatal(1,"light{i} qualified spec/VB mismatch");
  end
 end
end
''')
top.append('endmodule\n');(out/'wrapper.sv').write_text('\n'.join(top));(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/light_products/main.cpp').read_bytes())
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_light_products','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1',str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]
def capacity():
 rows=[s.split(None,3)for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]];parent={int(p):int(pp)for p,pp,_,_ in rows}
 def ancestors(pid):
  seen=set()
  while pid in parent and pid not in seen:seen.add(pid);pid=parent[pid]
  return seen
 heavy={int(p)for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census'))or c in('cc1plus','cc1','lto1')};leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other}for other in heavy)};foreign=[pid for pid in leaves if os.getpid()not in ancestors(pid)]
 with(out/'capacity.jsonl').open('a')as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'max_foreign':2})+'\n')
 return len(foreign)<=2
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
with(out/'build.log').open('w')as f:rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
if rc:raise SystemExit('build failed '+str(rc))
print('BUILD_PASS',flush=True);phase('lighting typed BUILD_PASS/running; mutant='+str(a.mutant))
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
run=[str(out/'obj/Vtb_light_products')]+(['--cancel-only']if a.cancel_only else [])
with(out/'run.log').open('w')as f:rc=subprocess.run(run,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
r={'before':a.before,'before_sha256':hashlib.sha256(old.encode()).hexdigest(),'candidate_sha256':hashlib.sha256(new.encode()).hexdigest(),'command':cmd,'run_command':run,'mutant':a.mutant,'cancel_only':a.cancel_only,'exit':rc,'controller':os.getpid(),'starttime':start,'nice':10,'jobs':1,'threads':1,'configs':['MAT0/NOWR0','MAT0/NOWR1','MAT1/NOWR0','MAT1/NOWR1'],'scope':'newlighting privateproducts under actualheld-input contract, event/state/output relation and independentcolor model; no native/baseline repeat'};(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');log=(out/'run.log').read_text();print(log,flush=True)
if(rc==0)==a.mutant:raise SystemExit('unexpected verdict')
if a.mutant and not any(x in log for x in ['visible color mismatch','visible RFwrite mismatch']):raise SystemExit('fault not caught at visible consumer')
phase('lighting typed component terminal; mutant='+str(a.mutant),0)
