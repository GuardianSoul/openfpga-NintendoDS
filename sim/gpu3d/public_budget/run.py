#!/usr/bin/env python3
"""One explicitly allocated DesktopD1 worker; reference observer only."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-public-witness18'
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
V='build/tools/oss-cad-suite/bin/verilator'
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def phase(name,pid=None,active=True):
 d=json.loads(S.read_text());d['phase']=name;d['worker']={'active':active,'host':'Desktop','lease':'D1 explicit Root allocation','PID':os.getpid(),'child_PID':pid,'nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();s=json.dumps(d,separators=(',',':'))+'\n';assert len(s)<2048;t=S.with_suffix('.Geometry18.tmp');t.write_text(s);t.replace(S)
def run(cmd,log,stage):
 with log.open('w')as f:
  child=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);phase(stage,child.pid);rc=child.wait()
 phase(stage+' reaped',child.pid,False);return rc,child.pid
prep=json.loads((B/'prepare.json').read_text())
files=[B/x for x in prep['files']]+[B/'observer.sv',R/'sim/gpu3d/public_budget/caller.cpp']
cmd=[V,'--cc','--exe','--build','--build-jobs','1','-j','1','--threads','1','--assert','-Wno-fatal','-MAKEFLAGS','VM_PARALLEL_BUILDS=0','--Mdir',str(B/'obj'),'--top-module','tb_public_budget','-CFLAGS','-std=c++20 -O1']+list(map(str,files))
(B/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
print('PUBLIC_OBSERVER_D1_PID',os.getpid(),flush=True)
rc,pid=run(cmd,B/'build.log','D1 pinned passive observer build');assert rc==0,(B/'build.log').read_text()[-4000:]
records=[]
for mode in ['positive','disconnect']:
 c=[str(B/'obj/Vtb_public_budget')]+(['disconnect']if mode=='disconnect'else[])
 rc,pid=run(c,B/f'{mode}.log',f'D1 passive observer {mode}');assert rc==0,(B/f'{mode}.log').read_text()[-3000:]
 records.append({'mode':mode,'child_PID':pid,'exit':rc,'log_sha256':hashlib.sha256((B/f'{mode}.log').read_bytes()).hexdigest()})
(B/'execution.json').write_text(json.dumps({'reference':prep['reference'],'controller_PID':os.getpid(),'runs':records,'production_edits':False},indent=2)+'\n')
phase('D1 passive captures complete; executable schedule/join analysis next',pid,False)
print('PASS passive runtime; semantic joins still require analyze.py',flush=True)
