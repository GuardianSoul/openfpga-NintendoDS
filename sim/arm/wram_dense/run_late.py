#!/usr/bin/env python3
"""Reuse one verified native model for the bounded accepted-input case."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,resource,subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--model-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(1024**3,1024**3));resource.setrlimit(resource.RLIMIT_CORE,(0,0))
R=Path(__file__).resolve().parents[3];S=a.model_dir.resolve();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
source=json.loads((S/'receipt.json').read_text())
assert source['status']=='PASS' and not source['behavioral'] and source['mutant']=='none'
assert sha(S/'model.vvp')==source['files']['model.vvp']
for n,f in [('arm7_wram.sv',R/'rtl/arm/arm7_wram.sv'),('tb_wram.sv',R/'sim/arm/wram_dense/tb_wram.sv')]:
    assert (S/n).read_bytes()==f.read_bytes(),n
cmd=['build/tools/oss-cad-suite/bin/vvp',str(S/'model.vvp'),'+late-only']
pf=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def update(child=None):
    s=json.loads(pf.read_text());s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    s['phase']='Final native accepted-input/reset case'if child else'Final native+late+actualfault+CPU gates PASS; D1 RELEASED; area pending'
    s['worker']=dict(host='Desktop',active=child is not None,PID=child.pid if child else None,controller=os.getpid(),NI=10,jobs=1 if child else 0,threads=1 if child else 0)
    if not child:s['lease']='DesktopD1 RELEASED; all own workers reaped; no new lease requested'
    b=(json.dumps(s,indent=2)+'\n').encode();assert len(b)<=2048
    tmp=pf.with_name('CPU.json.CPU.tmp');tmp.write_bytes(b);os.replace(tmp,pf)
with(D/'run.log').open('w')as f:
    child=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);update(child)
    try:rc=child.wait(timeout=30)
    except subprocess.TimeoutExpired:child.terminate();rc=child.wait(timeout=5)
log=(D/'run.log').read_text()
r=dict(status='PASS final native model reused, both accepted read ports late-input/reset'if rc==0 else'FAIL',
    controller=os.getpid(),PID=child.pid,exit=rc,reaped=True,NI=10,jobs=1,threads=1,command=cmd,
    model_SHA256=sha(S/'model.vvp'),model_receipt_SHA256=sha(S/'receipt.json'),log_SHA256=sha(D/'run.log'))
(D/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');update()
assert rc==0 and 'PASS_WRAM_LATE cycles2050 readSamples3072'in log,log
print(log)
