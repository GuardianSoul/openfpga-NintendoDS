#!/usr/bin/env python3
"""Serial RF before-state/read/CE/ABI qualification with actual RTL mutants."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,resource,subprocess,time

R=Path(__file__).resolve().parents[3]
P=argparse.ArgumentParser(description=__doc__)
P.add_argument('--output',type=Path,default=R/'build/rf-mlab/unit')
P.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
P.add_argument('--status',type=Path)
a=P.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
(D/'tmp').mkdir();os.environ['TMPDIR']=str(D/'tmp')
sha=lambda b:hashlib.sha256(b).hexdigest()
result=dict(base='6c5752c437befe7cea6892357f980618a4a20015',controller=os.getpid(),stages=[],results={})
def save():
 (D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def status(phase,p=None):
 if not a.status:return
 s=json.loads(a.status.read_text());s['phase']=phase
 s['worker']=dict(host='Desktop',controller=os.getpid()if p else None,PID=p.pid if p else None,jobs=1 if p else 0,threads=1 if p else 0,NI=10)
 s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 temp=a.status.with_suffix('.tmp.'+str(os.getpid()));temp.write_text(json.dumps(s,indent=2)+'\n');temp.replace(a.status)
def call(cmd,log,tag,seconds=180):
 cmd=list(map(str,cmd));start=time.monotonic()
 with log.open('w')as f:
  p=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
  s=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd)
  result['stages'].append(s);save();status(tag,p);print(json.dumps(dict(tag=tag,PID=p.pid)),flush=True)
  try:s['exit']=p.wait(timeout=seconds)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);s['exit']=p.returncode;s['timeout']=True
 s['reaped']=True;s['wall_seconds']=round(time.monotonic()-start,3);save();status(tag+' terminal');return s['exit']
old=subprocess.check_output(['git','show',result['base']+':rtl/arm/arm_regfile.sv'],cwd=R).replace(b'module arm_regfile #(',b'module arm_regfile_before #(')
candidate=(R/'rtl/arm/arm_regfile.sv').read_bytes();tb=(R/'sim/arm/rf_mlab/tb.sv').read_bytes()
priority=b"      if (we2) owner[wa2] <= 1'b1;\n      if (we) owner[wa] <= 1'b0;"
assert candidate.count(priority)==1
variants={'candidate':candidate,
 'priority-mutant':candidate.replace(priority,b"      if (we) owner[wa] <= 1'b0;\n      if (we2) owner[wa2] <= 1'b1;"),
 'owner-mutant':candidate.replace(b's0 <= owner[ra0];',b's0 <= ~owner[ra0];')}
assert variants['owner-mutant']!=candidate
for name,source in variants.items():
 out=D/name;out.mkdir();(out/'prior.sv').write_bytes(old);(out/'candidate.sv').write_bytes(source);(out/'tb.sv').write_bytes(tb)
 result['results'][name]=dict(source_SHA256=sha(source),prior_SHA256=sha(old),TB_SHA256=sha(tb));save()
 cmd=[a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',out/'obj',out/'prior.sv',out/'candidate.sv',out/'tb.sv']
 rc=call(cmd,out/'build.log',name+'/build');assert rc==0,(name,(out/'build.log').read_text()[-1500:])
 model=out/'obj/Vtb';result['results'][name]['model_SHA256']=sha(model.read_bytes());save()
 rc=call([model,'+trace='+str(out/'trace.csv')],out/'run.log',name+'/run',30)
 log=(out/'run.log').read_text();result['results'][name].update(exit=rc,tail=log[-1200:]);save()
 if name=='candidate':assert rc==0 and 'RF_EQUIVALENCE_PASS'in log,log[-1200:]
 else:assert rc!=0 and any(x in log for x in ['RF_LOGICAL_OWNER_OR_PRIORITY','RF_READ_OR_OLD_DATA']),log
status('RF unit: exact reads/state/CE/import and two actual RTL mutants PASS')
print('PASS candidate RF equivalence and actual owner/priority mutations',flush=True)
