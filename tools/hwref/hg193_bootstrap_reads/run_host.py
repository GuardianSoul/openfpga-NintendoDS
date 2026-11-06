#!/usr/bin/env python3
"""One source-bound strict HG diagnostic on L1, explicit external PID gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'hg193_combined_hook'))
from launch_directory import check as check_directory
import check_observed
from check_capture import check_assertion_bindings
from verify_game_launch import validate

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');os.replace(t,p)
def process():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],nice=os.getpriority(os.PRIO_PROCESS,0))
def gate(p):
 while not p.exists():time.sleep(.1)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',type=Path,required=True);p.add_argument('--child');a=p.parse_args();b=a.base.resolve()
 os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(b/(a.child+'-child.json'),process());gate(b/(a.child+'.release'))
  if a.child=='compiler':
   plan=json.loads((b/'game-build-plan.json').read_text());os.chdir(plan['cwd']);os.execv(plan['argv'][0],plan['argv'])
  argv=json.loads((b/'diagnostic/argv.json').read_text());cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());os.chdir(check_directory(cwd));os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*argv])
 assert not (b/'controller.json').exists()
 comp=json.loads((b/'component-complete.json').read_text());assert comp['actual_transport_positive'] and comp['actual_live_fabric_master_fault_caught']
 for n in ['predicate.svh','caller.svh']:
  contract=json.loads((b/'component-source-binding.json').read_text());assert sha(b/'include'/n)==contract['inputs']['source/'+n]
 check_observed.check(b);check_assertion_bindings(b,['full_game','current41'])
 pending=json.loads((b/'model-pin.pending.json').read_text());assert pending['composition_sha256']==sha(b/'composition.json') and pending['game_build_plan_sha256']==sha(b/'game-build-plan.json')
 assert len(os.sched_getaffinity(0))>=1 and os.getloadavg()[0]<24
 controller=process();write(b/'controller.json',dict(controller=controller,source=pending['source'],profile=60,input_sha256=sha(b/'composition.json'),component_qualification_sha256=sha(b/'component-complete.json'),launcher_sha256=sha(Path(__file__).resolve()),jobs=1,threads=1,state='WAITING_RECORDED_CONTROLLER_GATE'))
 gate(b/'controller.release')
 for name in ['compiler','native']:
  assert os.getloadavg()[0]<24
  if name=='native':
   pin=json.loads((b/'model-pin.json').read_text());args=json.loads((b/'diagnostic/argv.json').read_text());guard=validate(b,pin,args,'hg-title');write(b/'diagnostic/launch-guard.json',guard)
   cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());check_directory(cwd)
   values={x[1:].split('=',1)[0]:x.split('=',1)[1]for x in args if x.startswith('+')and '='in x}
   assert values['frames']=='85' and values['scene_capture_frames']=='106' and values['scene_save_words']=='131072'
   assert int(values['scene_save_words'])*4==int(values['savsize']) and values['imp_vcount']=='193'
  log=b/('game-build.log'if name=='compiler'else 'diagnostic/native.log')
  started=time.monotonic()
  with log.open('w') as f:
   child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(b),'--child',name],stdout=f,stderr=subprocess.STDOUT)
   while not (b/(name+'-child.json')).exists():assert child.poll()is None;time.sleep(.1)
   identity=json.loads((b/(name+'-child.json')).read_text());assert identity['nice']==10
   write(b/'active.json',dict(stage=name,controller=controller,child=identity,source=pending['source'],profile=60,model_sha256=pin['binary_sha256']if name=='native'else None))
   try:rc=child.wait(timeout=1500)
   except subprocess.TimeoutExpired:
    child.terminate();rc=child.wait();write(b/'timeout.json',dict(stage=name,child=identity));raise
  write(b/(name+'-complete.json'),dict(exit=rc,child=identity,reaped=True,wall_seconds=time.monotonic()-started,log_sha256=sha(log)))
  if name=='compiler':
   assert rc==0
   binding=json.loads((b/'composition.json').read_text())
   for n,h in binding['copies_sha256'].items():assert sha(b/n)==h,n
   plan=json.loads((b/'game-build-plan.json').read_text());binary=Path(plan['argv'][plan['argv'].index('--Mdir')+1])/'Vtb_ds_pocket'
   pin=dict(pending,state='ACTUAL_STRICT_HG_DIAGNOSTIC_BUILD_COMPLETE',build_exit=0,binary_path=str(binary),binary_sha256=sha(binary),build_receipt_sha256=sha(b/'compiler-complete.json'))
   write(b/'model-pin.json',pin)
  else:
   text=log.read_text();assert rc!=0 and 'HG193_ALL_GUARD'in text and 'HG193_OWNER_RAW'in text and 'HG193_CALLER'in text
   assert 'CAPTURE41_ACCEPTED_SOURCE_FIVE1_METADATA0_PASS'in text and 'STRICT_HG_BOUND_LAUNCH_CONTRACT_PASS'in text
   rows=[x for x in text.splitlines()if x.startswith('HG193_ALL_GUARD')];assert len(rows)==456
   assert 'HG193 combined drain: cpu_arm9_cache'in text
   write(b/'diagnostic/result.json',dict(state='STRICT_DIAGNOSTIC_CAPTURED_ORIGINAL_FAILURE',source=pin['source'],model_sha256=pin['binary_sha256'],profile=60,all_guard_clauses=len(rows),false_clauses=[x for x in rows if not x.endswith('pass=1')],owners=[x for x in text.splitlines()if x.startswith(('HG193_OWNER','HG193_CALLER'))],history_published=False,proposal_enabled=False,scene_accepted=False,process_reaped=True))
 print(json.dumps(json.loads((b/'diagnostic/result.json').read_text())),flush=True)
if __name__=='__main__':main()
