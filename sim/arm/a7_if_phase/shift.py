#!/usr/bin/env python3
"""New component-only register-shift coverage; no DS/native/baseline run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--pair',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
p.add_argument('--scenarios',type=int,nargs='+',default=[0,1,5])
a=p.parse_args();old=a.pair.resolve();D=a.out.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10)
shutil.copytree(old/'source',D/'source');shutil.copytree(old/'inputs',D/'inputs')
S=D/'source';tb=(S/'tb.sv').read_text()
old_count='if(active&&in_body(cpu.pc)&&(cpu.esub==0||cpu.esub==1))mul_steps++;'
assert tb.count(old_count)==1
tb=tb.replace(old_count,'if(active&&in_body(cpu.pc)&&cpu.esub==0)mul_steps++;')
tb=tb.replace('if(!cpu_rst&&cpu.pipe_fire&&cpu.e_mul)begin','if(!cpu_rst&&cpu.pipe_fire&&cpu.e_sr)begin')
old_assert='assert(cpu.opa==3&&cpu.opb==32\'((cpu.ins[11:8]==6)?rs6:rs))'
assert tb.count(old_assert)==1
tb=tb.replace(old_assert,"assert(cpu.opa==3&&cpu.opb==3&&(cpu.ins==32'he1813231||cpu.ins==32'he1813631))")
tb=tb.replace('cpu.e_mul','(cpu.e_mul||cpu.e_sr)')
pause='if((scenario==1||scenario==3)&&cpu.esub==1)begin'
assert tb.count(pause)==1
tb=tb.replace(pause,'if((scenario==1||scenario==3)&&cpu.esub==2&&cpu.phase_prepared)begin')
needle='$readmemh(kernel_image,words);'
assert tb.count(needle)==1
hook='''
  assert(kind==1&&rs==1&&rs6==1)else $fatal(1,"RSHIFT_FIXTURE_ARGUMENTS");
  for(int k=1;k<=64;k++)begin
   assert(words[k]==((k%2)?32'he0030291:32'he0030691))else $fatal(1,"RSHIFT_ORIGINAL_IMAGE");
   words[k]=(k%2)?32'he1813231:32'he1813631;
  end
'''
tb=tb.replace(needle,needle+hook)
tb=tb.replace('  $fclose(phase_obs_fd);','  assert(phase_obs_starts==320&&phase_obs_advances==320&&phase_obs_accepts==320&&!phase_obs_cancels)else $fatal(1,"RSHIFT_CHANNEL_COUNTS");\n  $display("RSHIFT_META_PASS oneactualIperoperation");\n  $fclose(phase_obs_fd);')
(S/'tb.sv').write_text(tb)
base=json.loads((old/'run-inputs.json').read_text())
result=dict(scope='Component-only ORR register shift, Rs2=Rs6=1. No DS timing/cross-opcode delay claim.',stages=[],cases={})
statusfile=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def call(cmd,tag):
    start=time.monotonic()
    with (D/(tag+'.log')).open('w') as f:
        c=subprocess.Popen(list(map(str,cmd)),stdout=f,stderr=subprocess.STDOUT,cwd=D)
        row=dict(tag=tag,argv=list(map(str,cmd)),PID=c.pid,NI=os.getpriority(os.PRIO_PROCESS,c.pid));result['stages'].append(row);save()
        d=json.loads(statusfile.read_text());d['worker']=dict(host='Desktop',active=True,controller=os.getpid(),PID=c.pid,NI=10,jobs=1,threads=1);d['phase']='CPU I-phase RSHIFT '+tag
        tmp=statusfile.with_suffix('.json.tmp');tmp.write_text(json.dumps(d,separators=(',',':'))+'\n');tmp.replace(statusfile)
        print(tag,c.pid,flush=True);row['exit']=c.wait(timeout=180)
    row.update(reaped=True,elapsed=time.monotonic()-start);save();assert row['exit']==0,(D/(tag+'.log')).read_text()[-3500:]
    return (D/(tag+'.log')).read_text()
sources=sorted(S.glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv')
call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','-GCOMMIT=1','-GPHASE_META=1','--Mdir',D/'obj',*sources],'build')
for scenario in a.scenarios:
    key='s'+str(scenario)
    args={v.split('=',1)[0]:v.split('=',1)[1] for v in base['template'][1:]}
    args.update({'+out':str(D/key),'+phase_out':str(D/(key+'.csv')),'+case':'0','+scenario':str(scenario),'+policy':'1','+loops':'4','+rs':'1','+rs6':'1','+kind':'1','+detail':'1'})
    for n in ['kernel','wrapper','boot']:args['+'+n]=str(D/'inputs'/Path(args['+'+n]).name)
    text=call([D/'obj/Vtb',*[k+'='+v for k,v in args.items()]],key)
    for marker in ['PHASE_FUNCTION_PASS','PAIRED_SLOT_PASS','ADVERSE_PASS','RSHIFT_META_PASS']:assert marker in text
    result['cases'][key]=dict(phase_csv=hashlib.sha256((D/(key+'.csv')).read_bytes()).hexdigest(),status='PASS');save()
result['status']='PASS one-I register shift scenarios'+str(a.scenarios)+'; unchanged physicalservice'
result['model_sha256']=hashlib.sha256((D/'obj/Vtb').read_bytes()).hexdigest()
result['source_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
save()
d=json.loads(statusfile.read_text());d['worker']=dict(host='Desktop',active=False,PID=None);d['phase']=result['status'];tmp=statusfile.with_suffix('.json.tmp');tmp.write_text(json.dumps(d,separators=(',',':'))+'\n');tmp.replace(statusfile)
print(result['status'])
