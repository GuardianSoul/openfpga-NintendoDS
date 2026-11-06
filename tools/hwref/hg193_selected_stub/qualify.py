#!/usr/bin/env python3
"""One tiny selected-content matcher component. No production/game model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

OWNER=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/hwref.json')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');os.replace(t,p)
def proc():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],NI=os.getpriority(os.PRIO_PROCESS,0))
def gate(p):
 while not p.exists():time.sleep(.1)
def status(phase,controller,child=None):
 d=json.loads(OWNER.read_text());d.update(phase=phase,worker=dict(host='DesktopD2',controller=controller,child=child,jobs=1,threads=1),lease='D2tiny selectedstub matcher only; L1free; no game native/probe',next_action='Qualify exact selectedtramp/136immutable comparison; stage missingARM7/bridge/live137word diagnostics; guards/default0 preserved.');write(OWNER,d)
def main():
 p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True);p.add_argument('--child');a=p.parse_args();b=a.base.resolve();os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  plan=json.loads((b/'plan.json').read_text());write(b/(a.child+'-child.json'),proc());gate(b/(a.child+'.release'));os.execv(plan[a.child][0],plan[a.child])
 assert not(b/'controller.json').exists()
 binding=json.loads((b/'source-binding.json').read_text())
 for n,h in binding.items():assert sha(b/n)==h,n
 v='build/tools/oss-cad-suite/bin/verilator';model=b/'obj/Vtb_matcher'
 plan=dict(compile=[v,'--binary','--assert','--timing','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_matcher','--Mdir',str(model.parent),'-I'+str(b),str(b/'tb_matcher.sv')],run=[str(model),'+initial='+str(b/'initial.hex'),'+replayed='+str(b/'replayed.hex')]);write(b/'plan.json',plan)
 controller=proc();write(b/'controller.json',dict(controller=controller,source_binding_sha256=sha(b/'source-binding.json'),qualifier_sha256=sha(Path(__file__).resolve())));status('Selectedstub component controller gated',controller);gate(b/'release')
 results={}
 for name in ['compile','run']:
  with(b/(name+'.log')).open('w')as f:
   child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(b),'--child',name],stdout=f,stderr=subprocess.STDOUT)
   while not(b/(name+'-child.json')).exists():assert child.poll()is None;time.sleep(.1)
   identity=json.loads((b/(name+'-child.json')).read_text());assert identity['NI']==10
   write(b/'active.json',dict(controller=controller,child=identity,phase=name));status('Selectedstub component '+name,controller,identity)
   (b/(name+'.release')).touch();rc=child.wait()
  results[name]=dict(exit=rc,child=identity,reaped=True,log_sha256=sha(b/(name+'.log')));write(b/'results.json',results);assert rc==0,(name,(b/(name+'.log')).read_text()[-1500:])
  if name=='compile':write(b/'model.json',dict(sha256=sha(model),path=str(model)))
 assert 'SELECTED_STUB_MATCHER_PASS checks4389 payload_mutants4384'in(b/'run.log').read_text()
 write(b/'complete.json',dict(component='PASS',checks=4389,actual_derived_payload_bit_mutations=4384,selected_tail='023091b0',scope='Reconstruction fixture from pinned original bytes +existing actual write extraction; no new live137word view/physical completion proof.',proposal_enable=0,production_model_runs=0,raw_scans=0,results=results))
 d=json.loads(OWNER.read_text());d.update(phase='Selectedstub4389/4384componentPASS; source discriminator work; D2released',worker=dict(host=None,active_workers=0,controller=None,child=None,all_owned_children_reaped=True),lease='D2free/L1free; no pending model/native/probe');write(OWNER,d)
 print((b/'complete.json').read_text())
if __name__=='__main__':main()
