#!/usr/bin/env python3
"""One allocated worker, sequential builds/runs of only affected behavior."""
import json,os,resource,subprocess,sys,time
from pathlib import Path
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[3]
print(f'suite_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
stages=[('primitive','primitive.py',[]),('step-mutant','primitive.py',['--mutant']),('clip-red1','clip.py',['--red','1']),('clip-red0','clip.py',['--red','0']),('finalize','finalize.py',[])]
for name,script,args in stages:
 print(f'CHECK {name}',flush=True)
 (out/'phase.json').write_text(json.dumps({'stage':name,'controller':os.getpid(),'time':time.time()})+'\n')
 subprocess.run([sys.executable,str(Path(__file__).with_name(script)),'--out',str(out/name),*args],cwd=root,check=True)
print('SUITE_PASS',flush=True)
