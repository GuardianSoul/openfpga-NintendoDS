#!/usr/bin/env python3
"""Retire the owned old controller after its before-memory child is reaped."""
from pathlib import Path
import argparse,hashlib,json,os,signal,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);a=p.parse_args();D=a.directory.resolve();os.setpriority(os.PRIO_PROCESS,0,10)
def ident(pid):
 try:return Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
 except FileNotFoundError:return None
start=time.monotonic();initial=json.loads((D/'results.json').read_text());pid=initial['controller'];tick=initial['controller_starttime']
(D/'amendment-watch.json').write_text(json.dumps({'PID':os.getpid(),'starttime':ident(os.getpid()),'target_controller':pid,'target_starttime':tick,'condition':'before-unitmem exit0/reaped; never signal a running before child'},indent=2)+'\n')
print('WATCHING before-unitmem completion; current before child untouched',flush=True)
while time.monotonic()-start<14400:
 r=json.loads((D/'results.json').read_text())
 if r.get('failure'):raise RuntimeError(('old gate failed; no takeover',r['failure']))
 stage=next((s for s in r['stages']if s['tag']=='before-unitmem'and s.get('reaped')),None)
 if not stage:time.sleep(.02);continue
 assert stage['exit']==0 and ident(pid)==tick
 os.kill(pid,signal.SIGSTOP)
 # Parent is frozen, so it cannot launch another child after this inventory.
 children=Path('/proc',str(pid),'task',str(pid),'children').read_text().split();stopped=[]
 for child in children:
  child=int(child);args=Path('/proc',str(child),'cmdline').read_bytes().replace(b'\0',b' ').decode()
  assert str(D/'ACK0')in args and os.getpgid(child)==child,(child,args)
  stopped.append({'PID':child,'starttime':ident(child),'argv':args,'reason':'obsolete duplicateACK0 build; stopped before model completion'})
  os.killpg(child,signal.SIGTERM)
 snapshot=json.loads((D/'results.json').read_text());(D/'results-before-amendment.json').write_text(json.dumps(snapshot,indent=2)+'\n')
 os.kill(pid,signal.SIGTERM);os.kill(pid,signal.SIGCONT)
 for _ in range(200):
  if ident(pid)!=tick or Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[0]=='Z':break
  time.sleep(.02)
 assert ident(pid)!=tick or Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[0]=='Z','owned old controller did not exit'
 (D/'controller-retired.json').write_text(json.dumps({'controller':pid,'starttime':tick,'before_memory_child':stage,'before_run_restarted':False,'obsolete_children_stopped':stopped,'native_before_model_preserved':snapshot['models']['before'],'snapshot_SHA256':hashlib.sha256((D/'results-before-amendment.json').read_bytes()).hexdigest()},indent=2)+'\n')
 print('RETIRED original controller after before child reaped; baseline retained',flush=True);break
else:raise TimeoutError('before controls did not finish within amendment watch bound')
