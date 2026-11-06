#!/usr/bin/env python3
"""Run four pinned native60 guests on the one completed changed executable."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import resource
import subprocess
import sys
import time

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--prepared',type=Path,required=True)
p.add_argument('--allocated',action='store_true',required=True)
p.add_argument('--await-release',action='store_true')
a=p.parse_args();G=a.prepared.resolve()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(name):return json.loads((G/name).read_text())
def save(name,value):
 path=G/name;path.parent.mkdir(parents=True,exist_ok=True);temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(json.dumps(value,indent=2)+'\n');temp.replace(path)
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
assert not(G/'runtime-controller.json').exists()
save('runtime-controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10))
print('GATED',read('runtime-controller.json'),flush=True)
while a.await_release and not(G/'runtime-release.json').exists():time.sleep(.2)
model=read('model.json');source=read('source-manifest.json');profile=read('profile.json');commands=read('run-commands.json')
assert model['source']==source['source']=='aeaa0cb386d2fbd6f8d2505f8033015956da54b5'
assert model['profile']==profile and len(profile)==60
assert sha(G/'model/Vtb_ds_pocket')==model['sha256']
assert set(commands)=={'ds30','unita7','unitmem','ldm53-live'}
release=read('runtime-release.json')
assert release['model_sha256']==model['sha256'] and release['commands_sha256']==sha(G/'run-commands.json')
for name,h in release['checker_sha256'].items():assert sha(G/name)==h,name
for name,h in source['files'].items():assert sha(G/'source'/name)==h,name
for name,h in model['host_sha256'].items():assert sha(G/name)==h,name
os.environ['TMPDIR']=str(G/'tmp')

def call(argv,tag,cwd):
 guard();argv=list(map(str,argv));start=time.monotonic();path=G/(tag+'.log');path.parent.mkdir(parents=True,exist_ok=True)
 with path.open('w')as output:
  child=subprocess.Popen(argv,cwd=cwd,stdout=output,stderr=subprocess.STDOUT)
  row=dict(pid=child.pid,starttime=Path('/proc',str(child.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,child.pid),argv=argv,cwd=str(cwd))
  save(tag+'.active.json',row)
  with(G/'runtime-processes.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
  print('STAGE',tag,child.pid,row['starttime'],flush=True);rc=wait_owned(child)
 row.update(exit=rc,reaped=True,wall_seconds=time.monotonic()-start);save(tag+'.process.json',row)
 assert rc==0,(tag,rc,path.read_text()[-3500:])
 return row

def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

native_guard=load('native60_guard',G/'native_guard.py')
results={}
for name in ['ds30','unita7','unitmem','ldm53-live']:
 run=commands[name];D=G/'runs'/name
 for filename,h in run['expanded_sha256'].items():assert sha(D/'run'/filename)==h,(name,filename)
 manifest=dict(source=source['source'],model_sha256=model['sha256'],ROM_sha256=run['ROM_sha256'],profile=profile,
               argv=run['argv'],cwd=run['cwd'],expanded_sha256=run['expanded_sha256'],host_sha256=model['host_sha256'],controller=read('runtime-controller.json'))
 save('runs/'+name+'/manifest.json',manifest)
 process=call(run['argv'],'runs/'+name+'/run',D/'run')
 text=(D/'run.log').read_text()
 for marker in ['NATIVE58_ENABLED_OWNED_ROUTES_PASS','VRAM_IO59_PUBLIC_ROUTE_PASS','NATIVE60_WRITE_TURN_ROUTE_PASS']:
  assert text.count(marker)==1,(name,marker)
 active=name=='ldm53-live'
 assert text.count('NATIVE60_LDM53_ACTIVE_PASS')==int(active)
 assert text.count('NATIVE60_LDM53_INACTIVE_PASS')==int(not active)
 manifest.update(process=process,log_sha256=sha(D/'run.log'));save('runs/'+name+'/manifest.json',manifest)
 if name=='ds30':
  call([sys.executable,G/'ds30/check_observer.py','--prepared',G/'ds30','--prefix',D/'ds30-capture',
        '--run-manifest',D/'manifest.json','--log',D/'run.log'],'runs/ds30/check',G/'source')
  results[name]=read('runs/ds30/check.log')
 else:
  checks={'unita7':22,'unitmem':32,'ldm53-live':3}[name]
  checked=native_guard.validate(text,checks,name)
  assert checked['accepted'],(name,checked)
  results[name]=dict(guards=checked)
  if active:
   observer=G/'host-observer/tools/scorecard/ldm53_observer.py'
   plan=read('host-inputs/ldm53_observer_plan.json')
   binding=dict(source=source['source'],model_sha256=model['sha256'],rom_sha256=run['ROM_sha256'],
      observer_sha256=sha(G/'host-observer/sim/pocket_ds/ldm53_observer.sv'),
      compiled_observer_sha256=model['host_sha256']['host-observer/sim/pocket_ds/ldm53_observer.sv'],
      roi_sha256=sha(G/'host-inputs/ldm53_roi_first_timed.hex'),profile=plan['profile'],
      top_profile=profile,source_check=read('host-inputs/source-check.json'),
      ownership='No dynamic instruction/uop ownership claimed; native stage-PC only; other ownerPC0')
   save('runs/ldm53-live/binding.json',binding)
   call([sys.executable,observer,'verify','--trace',D/'ldm53.csv','--binding',D/'binding.json',
         '--roi',G/'host-inputs/ldm53_roi_first_timed.hex','--out',D/'raw-checked.json'],
        'runs/ldm53-live/raw-check',G/'source')
   call([sys.executable,G/'host-tools/check_ldm53.py','--prepared',G/'ldm53-control',
         '--main',D/'main.bin','--out',D/'functional-checked.json'],
        'runs/ldm53-live/functional-check',G/'source')
   results[name].update(raw=read('runs/ldm53-live/raw-checked.json'),functional=read('runs/ldm53-live/functional-checked.json'))
 save('runs/'+name+'/result.json',results[name]);save('runtime-results.json',results)
for name,h in source['files'].items():assert sha(G/'source'/name)==h,name
save('native-complete.json',dict(source=source['source'],model_sha256=model['sha256'],profile=profile,
    status='Four changed-source guests and actual CPU53 raw/body/result/ROI contracts PASS; DS timing separate',runs=list(results)))
print('NATIVE60_COMPLETE',flush=True)
