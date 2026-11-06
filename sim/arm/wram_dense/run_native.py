#!/usr/bin/env python3
"""Single NI10/j1/t1 vendor-RAM experiment with reaped child receipts."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,resource,shutil,subprocess

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--tb',type=Path,default=R/'sim/arm/wram_dense/tb_rden.sv')
p.add_argument('--top',default='tb_rden')
p.add_argument('--source',type=Path,action='append',default=[])
p.add_argument('--mutant',choices=['none','hold','merge'],default='none')
p.add_argument('--behavioral',action='store_true',help='Verilator architectural/import model, not native packing')
p.add_argument('--plusarg',action='append',default=[])
a=p.parse_args();os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(120,120));resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_CORE,(0,0))
D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
oss=Path('build/tools/oss-cad-suite/bin')
vendor=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
shutil.copyfile(vendor,D/'altera_mf.v');shutil.copyfile(a.tb,D/a.tb.name)
sources=[]
for f in a.source:
    content=f.read_text()
    if a.mutant=='hold' and 'module arm7_wram_dense' in content:
        needle='.rden_a(!mid)';assert needle in content;content=content.replace(needle,'.rden_a(1\'b1)',1)
    if a.mutant=='merge' and 'module arm7_wram_dense' in content:
        needle='a_write_mask | b_write_mask';assert needle in content;content=content.replace(needle,'b_write_mask',1)
    target=D/f.name;target.write_text(content);sources.append(target)
r=dict(controller=os.getpid(),NI=10,jobs=1,threads=1,mutant=a.mutant,behavioral=a.behavioral,stages=[])
status=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def update(phase,pid=None):
    s=json.loads(status.read_text());s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();s['phase']=phase
    s['worker']=dict(host='Desktop',active=pid is not None,PID=pid,controller=os.getpid(),NI=10,jobs=1,threads=1)
    b=(json.dumps(s,indent=2)+'\n').encode();assert len(b)<=2048
    temp=status.with_name('CPU.json.CPU.tmp');temp.write_bytes(b);os.replace(temp,status)
def save():(D/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
build=[oss/'iverilog','-g2012','-D','ALTERA_RESERVED_QIS','-s',a.top,'-o',D/'model.vvp',D/'altera_mf.v',*sources,D/a.tb.name]
run=[oss/'vvp',D/'model.vvp']
if a.behavioral:
    build=[oss/'verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module',a.top,'--Mdir',D/'obj',*sources,D/a.tb.name]
    run=[D/('obj/V'+a.top)]
run+=['+'+x for x in a.plusarg]
for tag,cmd in [('build',build),('run',run)]:
    cmd=list(map(str,cmd))
    with(D/(tag+'.log')).open('w')as f:
        child=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT)
        update('Vendor WRAM '+tag+' ('+a.mutant+')',child.pid)
        row=dict(tag=tag,PID=child.pid,command=cmd);r['stages'].append(row);save()
        try:row['exit']=child.wait(timeout=55)
        except subprocess.TimeoutExpired:child.terminate();row['exit']=child.wait(timeout=5);row['timeout']=True
        row['reaped']=True;save()
    if tag=='build' or a.mutant=='none':assert row['exit']==0,(tag,(D/(tag+'.log')).read_text()[-3500:])
log=(D/'run.log').read_text()
if a.mutant=='none':assert 'PASS_' in log
else:assert r['stages'][-1]['exit']!=0 and ('mismatch' in log or 'hold' in log),log
r['status']='PASS'if a.mutant=='none'else'CAUGHT_ACTUAL_'+a.mutant.upper()+'_FAULT'
r['files']={f.name:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()for f in D.iterdir()if f.is_file()and f.name!='receipt.json'}
save();update('Vendor WRAM '+r['status']+'; both children reaped')
print(log);print([(x['tag'],x['PID'],x['exit'])for x in r['stages']])
