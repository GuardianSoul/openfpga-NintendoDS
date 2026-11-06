#!/usr/bin/env python3
"""One gated NI10/j1/t1 real-transport component; no game/native execution."""
import argparse, hashlib, json, os, resource, subprocess, sys, time
from pathlib import Path

def write(p,v):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(v,indent=2)+'\n');os.replace(t,p)
def identity():
 return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],nice=os.getpriority(os.PRIO_PROCESS,0))
def gate(out,phase,controller,child=None):
 write(out/'active.json',dict(phase=phase,controller=controller,child=child))
 while not(out/(phase+'.release')).exists():time.sleep(.1)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--child');a=p.parse_args();out=a.out.resolve()
 os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(out/(a.child+'.child.json'),identity())
  while not(out/(a.child+'.release')).exists():time.sleep(.1)
  os.execvpe(json.loads((out/'plan.json').read_text())[a.child][0],json.loads((out/'plan.json').read_text())[a.child],os.environ)
 controller=identity();gate(out,'controller',controller)
 results={}
 for name in json.loads((out/'plan.json').read_text()):
  with(out/(name+'.log')).open('w')as log:
   child=subprocess.Popen([sys.executable,__file__,'--out',str(out),'--child',name],cwd=out,stdout=log,stderr=subprocess.STDOUT)
   while not(out/(name+'.child.json')).exists():
    assert child.poll()is None;time.sleep(.1)
   info=json.loads((out/(name+'.child.json')).read_text());gate(out,name,controller,info)
   started=time.monotonic();rc=child.wait();elapsed=time.monotonic()-started
  results[name]=dict(exit=rc,child=info,reaped=True,seconds=elapsed);write(out/'results.json',results)
  text=(out/(name+'.log')).read_text()
  expected={'owner':'SCOPED_LIVE_OWNER_OR_PAYLOAD_REJECTED','reply':'SCOPED_LIVE_OWNER_OR_PAYLOAD_REJECTED','credit':'SCOPED_LIVE_OWNER_OR_PAYLOAD_REJECTED','il_payload':'SCOPED_IL_PAYLOAD_CHANGED'}
  if name in expected:assert rc!=0 and expected[name]in text and 'timeout'not in text.lower(),(name,text[-2500:])
  else:assert rc==0,(name,text[-3500:])
  if name=='positive':assert 'SCOPED_COMPONENT_PASS'in text
  if name=='compile':
   model=out/'obj/Vtb_scoped';write(out/'model.json',dict(sha256=hashlib.sha256(model.read_bytes()).hexdigest()))
 write(out/'complete.json',dict(results=results,default_enable=0,actual_publisher_executions=0,game_models=0))
 write(out/'active.json',dict(phase='complete',controller=controller,child=None,all_owned_children_reaped=True))
 print('SCOPED_COMPONENT_QUALIFICATION_PASS',flush=True)
if __name__=='__main__':main()
