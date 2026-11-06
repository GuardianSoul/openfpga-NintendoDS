#!/usr/bin/env python3
"""One gated L1 NI10/j1/t1 build/run; bounded publication, no raw dumps."""
import argparse,hashlib,json,os,re,resource,shutil,subprocess,sys,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'support'))
import check_observed
from launch_directory import check as check_directory
from verify_game_launch import validate

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');os.replace(t,p)
def process():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],nice=os.getpriority(os.PRIO_PROCESS,0))
def gate(b,phase,controller,child=None):
 write(b/'active.json',dict(phase=phase,controller=controller,child=child))
 while not(b/(phase+'.release')).exists():time.sleep(.1)
def admission():
 load=os.getloadavg();free=shutil.disk_usage(Path.cwd()).free
 rows=subprocess.check_output(['ps','-eo','pid,ni,args'],text=True).splitlines()
 native=[s for s in rows if re.search(r'\s/\S*/V(?:tb|nds)_\S+',s)]
 assert load[0]<24 and free>8*(1<<30) and len(native)<=2,(load,free,native)
 return dict(load=load,free_bytes=free,other_native=native,nice=os.getpriority(os.PRIO_PROCESS,0),jobs=1,threads=1)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',required=True,type=Path);p.add_argument('--child');a=p.parse_args();b=a.base.resolve();os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(b/(a.child+'-child.json'),process())
  while not(b/(a.child+'.release')).exists():time.sleep(.1)
  if a.child=='compiler':
   plan=json.loads((b/'game-build-plan.json').read_text());os.chdir(plan['cwd']);os.execv(plan['argv'][0],plan['argv'])
  args=json.loads((b/'diagnostic/argv.json').read_text());cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());os.chdir(check_directory(cwd));os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*args])
 assert not(b/'controller.json').exists()
 check_observed.check(b)
 pending=json.loads((b/'model-pin.pending.json').read_text());assert pending['composition_sha256']==sha(b/'composition.json')and pending['game_build_plan_sha256']==sha(b/'game-build-plan.json')
 plan=json.loads((b/'game-build-plan.json').read_text());assert plan['argv'][plan['argv'].index('-j')+1]==plan['argv'][plan['argv'].index('--threads')+1]=='1'
 controller=process();write(b/'controller.json',dict(controller=controller,launcher_sha256=sha(Path(__file__).resolve()),admission=admission()));gate(b,'controller',controller)
 for phase in ['compiler','native']:
  write(b/(phase+'-admission.json'),admission())
  if phase=='native':
   pin=json.loads((b/'model-pin.json').read_text());args=json.loads((b/'diagnostic/argv.json').read_text());assert args.count('+hg193_scoped_publication')==1
   assert not any(x.startswith(('+scene_capture_prefix=','+fst=','+shots=','+savout='))or x=='+root40_ldm_capture'for x in args)
   write(b/'diagnostic/launch-guard.json',validate(b,pin,args,'hg-title'))
   cwd=json.loads((b/'diagnostic/cwd-binding.json').read_text());check_directory(cwd)
   for n,h in cwd['original_input_sha256'].items():assert sha(Path(cwd['parent'])/n)==h,n
  log=b/('game-build.log'if phase=='compiler'else'diagnostic/native.log')
  with log.open('w')as f:
   child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(b),'--child',phase],stdout=f,stderr=subprocess.STDOUT)
   while not(b/(phase+'-child.json')).exists():assert child.poll()is None;time.sleep(.1)
   identity=json.loads((b/(phase+'-child.json')).read_text());assert identity['nice']==10
   gate(b,phase,controller,identity);started=time.monotonic()
   try:rc=child.wait(timeout=1500)
   except subprocess.TimeoutExpired:
    child.terminate();child.wait();write(b/'timeout.json',dict(phase=phase,child=identity,reaped=True));raise
  write(b/(phase+'-complete.json'),dict(exit=rc,child=identity,reaped=True,post_release_poll_wait_seconds=time.monotonic()-started,log_sha256=sha(log)))
  if phase=='compiler':
   assert rc==0,log.read_text()[-3000:]
   for n,h in json.loads((b/'composition.json').read_text())['copies_sha256'].items():assert sha(b/n)==h,n
   binary=Path(plan['argv'][plan['argv'].index('--Mdir')+1])/'Vtb_ds_pocket'
   pin=dict(pending,state='ONE_SCOPED_PUBLICATION_MODEL_BUILT',build_exit=0,binary_path=str(binary),binary_sha256=sha(binary));write(b/'model-pin.json',pin)
  else:
   text=log.read_text();markers=[s for s in text.splitlines()if s.startswith('HG193_NATIVE_')]
   result=dict(native_exit=rc,model_sha256=pin['binary_sha256'],source=pin['source'],profile=60,markers=markers,compiler_builds=1,native_invocations=1,all_children_reaped=True,raw_dump_enabled=False)
   required=['HG193_NATIVE_EXPLICIT_SCOPE_FLAG_DEFAULT0','HG193_NATIVE_PROTECTED_READBACK_PASS','HG193_NATIVE_PUBLICATION_READBACK_PASS','HG193_NATIVE_FOURTH_ACCEPT','HG193_NATIVE_A9_DONE','HG193_NATIVE_P7_SAMPLE','HG193_NATIVE_P7_DONE','HG193_NATIVE_BOUNDED_PASS']
   result['pass']=rc==0 and all(any(s.startswith(n)for s in markers)for n in required)
   write(b/'complete.json',result);assert result['pass'],text[-4500:]
 write(b/'active.json',dict(phase='complete',controller=controller,child=None,all_children_reaped=True))
 print(json.dumps(result,indent=2))
if __name__=='__main__':main()
