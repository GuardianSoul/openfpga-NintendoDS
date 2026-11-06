#!/usr/bin/env python3
"""One leased serial worker for captured-history before/candidate/mutant."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,resource,subprocess,time
from prepare import restore
R=Path(__file__).resolve().parents[3]
P=argparse.ArgumentParser();P.add_argument('version',choices=['before','after','mutant'])
P.add_argument('--output',type=Path,default=R/'build/fetch-retry-replay')
P.add_argument('--obj-root',type=Path)
P.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
P.add_argument('--status',type=Path,help='Optional coordinator status file')
a=P.parse_args();G=a.output.resolve();restore(G)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
V=a.verilator
D=G/a.version;D.mkdir(exist_ok=False)
RAM=(a.obj_root or G/'objects').resolve();RAM.mkdir(parents=True,exist_ok=True)
(RAM/'tmp').mkdir(exist_ok=True);os.environ['TMPDIR']=str(RAM/'tmp');OBJ=RAM/a.version
receipt=dict(version=a.version,base='c5495cd85fdb8094fbc221562d82773fa9402c80',source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),controller_PID=os.getpid(),stages=[])
if a.version=='before':receipt['source']=receipt['base']
def call(cmd,tag,seconds=180):
 cmd=list(map(str,cmd));start=time.monotonic()
 with (D/(tag+'.log')).open('w')as out:
  p=subprocess.Popen(cmd,cwd=R,stdout=out,stderr=subprocess.STDOUT);s=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),argv=cmd);receipt['stages'].append(s);(D/'worker.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(dict(stage=tag,PID=p.pid)),flush=True)
  if a.status:
   status=a.status;v=json.loads(status.read_text());v['phase']='Focused fetch-retry '+a.version+'/'+tag;v['worker']=dict(host='Desktop',controller=os.getpid(),PID=p.pid,starttime=s['starttime'],jobs=1,threads=1,NI=10);v['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();tmp=status.with_suffix('.tmp.'+str(os.getpid()));tmp.write_text(json.dumps(v,indent=2)+'\n');tmp.replace(status)
  try:s['exit']=p.wait(timeout=seconds)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);s['exit']=p.returncode;s['timeout']=True
 s['reaped']=True;s['wall_seconds']=round(time.monotonic()-start,3);(D/'worker.json').write_text(json.dumps(receipt,indent=2)+'\n');return s['exit']
files=[]
for n in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split():
 b=subprocess.check_output(['git','show','c5495cd8:rtl/arm/'+n+'.sv'],cwd=R)if a.version=='before'else(R/'rtl/arm'/(n+'.sv')).read_bytes()
 if a.version=='mutant'and n=='arm_core':
  old=b'f2_pc <= fetch_pc[0];';assert b.count(old)==1;b=b.replace(old,b"f2_pc <= fetch_pc[0] ^ 32'd4;")
 p=D/(n+'.sv');p.write_bytes(b);files.append(p)
receipt['source_SHA256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in files};(D/'worker.json').write_text(json.dumps(receipt,indent=2)+'\n')
receipt['harness_SHA256']=hashlib.sha256((R/'sim/arm/fetch_retry/tb.sv').read_bytes()).hexdigest()
receipt['input_SHA256']={n:hashlib.sha256((G/n).read_bytes()).hexdigest()for n in ['program.hex','waits.hex','counts.hex']}
cmd=[V,'--binary','--timing','--assert','-O2','-j','1','--threads','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb','--Mdir',OBJ,*files,R/'sim/arm/fetch_retry/tb.sv']
if call(cmd,'build')!=0:
 print((D/'build.log').read_text()[-1800:]);raise SystemExit(1)
receipt['model_SHA256']=hashlib.sha256((OBJ/'Vtb').read_bytes()).hexdigest();receipt['model_path']=str(OBJ/'Vtb');results=[]
for phase in ([0]if a.version=='mutant'else[0,1,2]):
 stem='phase'+str(phase);rc=call([OBJ/'Vtb','+image='+str(G/'program.hex'),'+tape='+str(G/'waits.hex'),'+counts='+str(G/'counts.hex'),'+phase='+str(phase),'+trace='+str(D/(stem+'.trace'))],stem,30)
 text=(D/(stem+'.log')).read_text();result=dict(phase=phase,exit=rc,progress='PROGRESS_PASS'in text,captured_stall='CAPTURED_STALL'in text,tail=text[-500:]);results.append(result);print(json.dumps(result),flush=True)
receipt['results']=results;(D/'worker.json').write_text(json.dumps(receipt,indent=2)+'\n')
if a.version=='before':assert all(r['exit']==0 and r['captured_stall']and not r['progress']for r in results),results
elif a.version=='after':assert all(r['exit']==0 and r['progress']and not r['captured_stall']for r in results),results
else:assert results[0]['exit']!=0 and 'F2_REQUEST_OWNER_MISMATCH'in results[0]['tail'],results
