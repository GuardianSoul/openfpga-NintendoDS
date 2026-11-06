#!/usr/bin/env python3
"""One leased serial chain of fresh guest inputs using the qualified models."""
from pathlib import Path
import argparse,json,os,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];os.chdir(R)
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--models',type=Path,required=True);p.add_argument('--allocated',action='store_true',required=True);p.add_argument('--await-release',action='store_true');a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.dont_write_bytecode=True;sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
save=lambda p,x:p.write_text(json.dumps(x,indent=2)+'\n')
save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while a.await_release and not(G/'release').exists():time.sleep(.2)
cases=[('repeat4',['--pilot','--loops','4','--program','sim/ds/a7_vram_return/program_repeat.S']),('repeat16',['--pilot','--loops','16','--program','sim/ds/a7_vram_return/program_repeat.S']),('fetch',['--pilot','--program','sim/ds/a7_vram_return/program_fetch.s']),('late',['--only-vram-conflict'])]
for name,opts in cases:
 guard();cmd=[sys.executable,str(R/'sim/ds/a7_vram_return/run.py'),'--allocated','--out',str(G/name),'--reuse-models',str(a.models.resolve()),'--no-faults']+opts
 with(G/(name+'.log')).open('w')as f:
  child=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);row=dict(pid=child.pid,starttime=Path('/proc',str(child.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,child.pid),cmd=cmd,log=str(G/(name+'.log')))
  with(G/'processes.jsonl').open('a')as pf:pf.write(json.dumps(row)+'\n')
  print('INPUT',name,'PID',child.pid,flush=True);rc=wait_owned(child)
 row.update(exit=rc,reaped=True);save(G/(name+'.process.json'),row);assert rc==0,(name,(G/(name+'.log')).read_text()[-2200:])
print('VRAM_RETURN_INPUTS_COMPLETE',flush=True)
