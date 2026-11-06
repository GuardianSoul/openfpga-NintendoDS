#!/usr/bin/env python3
"""Build/run the actual stopped/drained ARM9 checkpoint helper on the new RF."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,resource,subprocess

R=Path(__file__).resolve().parents[3]
P=argparse.ArgumentParser(description=__doc__)
P.add_argument('--output',type=Path,default=R/'build/rf-mlab/import-replay')
P.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
P.add_argument('--status',type=Path)
a=P.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
(D/'tmp').mkdir();os.environ['TMPDIR']=str(D/'tmp');os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
files=[R/'rtl/arm'/(n+'.sv')for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core']]+[R/'sim/arm/rf_mlab/import_tb.sv']
q=dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),stages=[],source_SHA256={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files+[R/'sim/pocket_ds/runtime_import_cpu9_dual.svh']})
for tag,cmd in [('build',[a.verilator,'--binary','--timing','--assert','-j','1','--threads','1','-O2','-Wno-fatal','-I'+str(R),'--top-module','import_tb','--Mdir',D/'obj',*files]),('run',[D/'obj/Vimport_tb'])]:
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT)
  s=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=list(map(str,cmd)))
  q['stages'].append(s);(D/'receipt.json').write_text(json.dumps(q,indent=2)+'\n');print(tag,p.pid,flush=True)
  if a.status:
   v=json.loads(a.status.read_text());v['phase']='RF helper ABI '+tag;v['worker']=dict(host='Desktop',controller=os.getpid(),PID=p.pid,jobs=1,threads=1,NI=10);v['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=a.status.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(v,indent=2)+'\n');t.replace(a.status)
  try:s['exit']=p.wait(timeout=180)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);s['exit']=p.returncode;s['timeout']=True
  s['reaped']=True;(D/'receipt.json').write_text(json.dumps(q,indent=2)+'\n')
  if a.status:
   v['worker']=dict(host='Desktop',controller=None,PID=None,jobs=0,threads=0);v['phase']='RF helper ABI '+tag+' terminal';v['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=a.status.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(v,indent=2)+'\n');t.replace(a.status)
  assert s['exit']==0,(D/(tag+'.log')).read_text()[-2200:]
q['model_SHA256']=hashlib.sha256((D/'obj/Vimport_tb').read_bytes()).hexdigest()
q['PASS']='RF_HELPER_IMPORT_PASS'in(D/'run.log').read_text();assert q['PASS']
(D/'receipt.json').write_text(json.dumps(q,indent=2)+'\n');print((D/'run.log').read_text())
