#!/usr/bin/env python3
"""One compact strict HG point on L1; no bus/CPU/image/save trace output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'hg193_combined_hook'))
sys.path.insert(0,str(HERE.parent/'hg193_bootstrap_reads'))
import check_observed
from check_capture import check_assertion_bindings
from launch_directory import check as check_directory
from verify_game_launch import validate
from prepare_observer import check_observer_bind

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');os.replace(t,p)
def process():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],NI=os.getpriority(os.PRIO_PROCESS,0))
def gate(p):
 while not p.exists():time.sleep(.1)
def admission():
 load=os.getloadavg();free=shutil.disk_usage(Path.cwd()).free
 rows=subprocess.check_output(['ps','-eo','pid,ni,args'],text=True).splitlines();native=[s for s in rows if re.search(r'\s/\S*/V(?:tb|nds)_\S+',s)]
 assert load[0]<24 and free>8*(1<<30),(load,free)
 assert len(native)<=2,('native capacity before this worker',native)
 return dict(load=load,free_bytes=free,other_native_processes=native,NI=os.getpriority(os.PRIO_PROCESS,0),jobs=1,threads=1)
def main():
 p=argparse.ArgumentParser();p.add_argument('--base',type=Path,required=True);p.add_argument('--child');a=p.parse_args();b=a.base.resolve();os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(b/(a.child+'-child.json'),process());gate(b/(a.child+'.release'))
  if a.child=='compiler':
   plan=json.loads((b/'game-build-plan.json').read_text());os.chdir(plan['cwd']);os.execv(plan['argv'][0],plan['argv'])
  args=json.loads((b/'diagnostic/argv.json').read_text());cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());os.chdir(check_directory(cwd));os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*args])
 assert not(b/'controller.json').exists()
 check_observed.check(b);check_assertion_bindings(b,['full_game','current41']);check_observer_bind((b/'observed-overlay/observer_contract.sv').read_text())
 pending=json.loads((b/'model-pin.pending.json').read_text());assert pending['composition_sha256']==sha(b/'composition.json') and pending['game_build_plan_sha256']==sha(b/'game-build-plan.json')
 plan=json.loads((b/'game-build-plan.json').read_text());assert plan['argv'][plan['argv'].index('-j')+1]==plan['argv'][plan['argv'].index('--threads')+1]=='1'
 initial_admission=admission();controller=process();write(b/'controller.json',dict(controller=controller,source=pending['source'],profile=60,input_sha256=pending['composition_sha256'],launcher_sha256=sha(Path(__file__).resolve()),admission=initial_admission));gate(b/'controller.release')
 for name in ['compiler','native']:
  current=admission();write(b/(name+'-admission.json'),current)
  if name=='native':
   pin=json.loads((b/'model-pin.json').read_text());args=json.loads((b/'diagnostic/argv.json').read_text());write(b/'diagnostic/launch-guard.json',validate(b,pin,args,'hg-title'))
   cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());check_directory(cwd)
   for n,h in cwd['original_input_sha256'].items():assert sha(Path(cwd['parent'])/n)==h,n
   assert not any(x.startswith(('+scene_capture_prefix=','+fst=','+shots=','+savout='))or x=='+root40_ldm_capture'for x in args)
   assert '+frames=85'in args and '+imp_vcount=193'in args
  log=b/('game-build.log'if name=='compiler'else'diagnostic/native.log');started=time.monotonic()
  with log.open('w')as f:
   child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(b),'--child',name],stdout=f,stderr=subprocess.STDOUT)
   while not(b/(name+'-child.json')).exists():assert child.poll()is None;time.sleep(.1)
   identity=json.loads((b/(name+'-child.json')).read_text());assert identity['NI']==10
   write(b/'active.json',dict(stage=name,controller=controller,child=identity,source=pending['source'],profile=60,model_sha256=pin['binary_sha256']if name=='native'else None))
   try:rc=child.wait(timeout=1500)
   except subprocess.TimeoutExpired:child.terminate();child.wait();write(b/'timeout.json',dict(stage=name,identity=identity));raise
  write(b/(name+'-complete.json'),dict(exit=rc,child=identity,reaped=True,wall_seconds=time.monotonic()-started,log_sha256=sha(log)))
  if name=='compiler':
   assert rc==0
   for n,h in json.loads((b/'composition.json').read_text())['copies_sha256'].items():assert sha(b/n)==h,n
   binary=Path(plan['argv'][plan['argv'].index('--Mdir')+1])/'Vtb_ds_pocket';assert binary.read_bytes()[:4]==b'\x7fELF'
   pin=dict(pending,state='ONE_COMPACT_OBSERVER_MODEL_BUILT',build_exit=0,binary_path=str(binary),binary_sha256=sha(binary),build_receipt_sha256=sha(b/'compiler-complete.json'));write(b/'model-pin.json',pin)
  else:
   text=log.read_text();values={};stub={};history={}
   for line in text.splitlines():
    if m:=re.fullmatch(r'HG193_MISSING group=(\w+) name=(\w+) value=(\S+)',line):values.setdefault(m[1],{})[m[2]]=m[3]
    if m:=re.fullmatch(r'HG193_STUB_WORD index=(\d+) actual=(\S+) expected=(\S+)',line):stub[int(m[1])]=dict(actual=m[2],expected=m[3])
    if m:=re.fullmatch(r'HG193_BRIDGE_HISTORY age=(\d+) valid=(\S+) addr=(\S+) rd=(\S+) wr=(\S+)',line):history[int(m[1])]=dict(valid=m[2],address=m[3],read=m[4],write=m[5])
   guards=[s for s in text.splitlines()if s.startswith('HG193_ALL_GUARD')]
   result=dict(source=pin['source'],profile=60,model_sha256=pin['binary_sha256'],native_exit=rc,values=values,stub=stub,bridge_history=history,selected=[s for s in text.splitlines()if s.startswith('HG193_SELECTED_STUB')],guards=guards,false_guards=[s for s in guards if not s.endswith('pass=1')],owners=[s for s in text.splitlines()if s.startswith(('HG193_OWNER','HG193_CALLER'))],proposal_enable=0,history_published=False,raw_dump_enabled=False,process_reaped=True)
   write(b/'diagnostic/observations.json',result)
   assert rc!=0 and sum(map(len,values.values()))==192 and len(stub)==137 and len(history)==4 and len(guards)==456
   assert 'HG193_COMPACT_OBSERVER_BOUND_DEFAULT0_NO_FULL_DUMPS_PASS'in text and 'CAPTURE41_ACCEPTED_SOURCE_FIVE1_METADATA0_PASS'in text
   assert '[129210695000] %Fatal:'in text and 'HG193 combined drain: cpu_arm9_cache'in text
   assert not any(p.suffix in ['.gz','.bin','.ppm','.fst','.vcd']for p in(b/'diagnostic').rglob('*')if p.is_file())
   write(b/'complete.json',dict(state='COMPACT_ORIGINAL_POINT_CAPTURE_COMPLETE_STRICT_REJECTION_RETAINED',model_sha256=pin['binary_sha256'],source=pin['source'],profile=60,signals=192,live_stub_words=137,bridge_histories=4,time_ps=129210695000,guards=456,proposal_enable=0,history_published=False,full_bus_or_CPU_dump=False,compiler_builds=1,native_invocations=1,all_children_reaped=True))
 print((b/'complete.json').read_text())
if __name__=='__main__':main()
