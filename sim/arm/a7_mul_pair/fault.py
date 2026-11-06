#!/usr/bin/env python3
"""Catch the actual native ARM7 partial-product fault at CPU observations."""
from pathlib import Path
import subprocess,os,json,resource,hashlib
R=Path(__file__).resolve().parents[3];os.chdir(R);D=R/'build/cpu-a7-mul-pair';M=D/'mutant';M.mkdir(exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
r=json.loads((D/'result.json').read_text());assert r.get('state','').startswith('PASS')
P=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
s=(D/'native/arm_mul.sv').read_text();assert s.count('.by(b1)')==1;(M/'arm_mul.sv').write_text(s.replace('.by(b1)','.by(a1)'))
stages=[]
def call(cmd,tag):
 with(M/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),stdout=f,stderr=subprocess.STDOUT)
  row={'tag':tag,'PID':p.pid,'command':list(map(str,cmd))};stages.append(row)
  d=json.loads(P.read_text());d.update(phase='A7MUL_'+tag,worker={'active':True,'host':'DesktopD1','PID':p.pid,'controller':os.getpid(),'NI':10,'jobs':1,'threads':1});q=P.with_suffix('.json.tmp-cpu-compression');q.write_text(json.dumps(d,separators=(',',':'))+'\n');os.replace(q,P)
  try:rc=p.wait(timeout=240)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);raise
  row.update(exit=rc,reaped=True)
 return rc,(M/(tag+'.log')).read_text()
files=sorted((D/'native').glob('*.sv'));files.remove(D/'native/arm_pkg.sv');files.insert(0,D/'native/arm_pkg.sv');files[files.index(D/'native/arm_mul.sv')]=M/'arm_mul.sv';files.append(R/'sim/arm/mul_pair/contract.sv')
v='build/tools/oss-cad-suite/bin/verilator'
rc,log=call([v,'--binary','--timing','--assert','--threads','1','-j','1','-O2','--x-assign','fast','--x-initial','fast','-Wno-fatal','--top-module','tb_arm',*r['options'],'--Mdir',M/'obj',*files,D/'tb_arm.sv'],'build');assert rc==0,log[-3000:]
rc,log=call([M/'obj/Vtb_arm',f'+img1={D}/directed.hex','+pc1=02000000','+run=2','+maxcycles=3000000','+dbg=1',f'+trace1={M}/actual.csv',f'+ref1={D}/before-mul-directed.1.csv'],'directed')
assert 'TEST FAILED'in log and 'timeout'not in log.lower() and 'LOCKSTEP MISMATCH'in log,log[-3000:]
r={'state':'CAUGHT actual native BY partial-product fault in dedicated ARM7 public state','mutant_SHA256':hashlib.sha256((M/'arm_mul.sv').read_bytes()).hexdigest(),'model_SHA256':hashlib.sha256((M/'obj/Vtb_arm').read_bytes()).hexdigest(),'messages':[x for x in log.splitlines()if 'MISMATCH'in x or 'FAIL result'in x or 'TEST FAILED'in x],'timeout':False,'stages':stages}
(M/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(r['state'],flush=True)
