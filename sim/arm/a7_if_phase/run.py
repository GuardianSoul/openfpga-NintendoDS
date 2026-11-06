#!/usr/bin/env python3
"""Allocated changed-leaf checks; reuse previous captures, never rerun baseline."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();D=a.out.resolve();S=D/'source';I=D/'inputs'
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(300,300))
resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3))
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for n,h in json.loads((D/'inputs.json').read_text())['source'].items():assert sha(D/n)==h,n
result=dict(controller=os.getpid(),NI=10,jobs=1,threads=1,models={},stages=[],cases={})
statusfile=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def status(phase,child=None):
    d=json.loads(statusfile.read_text());d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();d['phase']=phase
    d['worker']=dict(host='Desktop',active=child is not None,controller=os.getpid(),PID=child.pid if child else None,NI=10,jobs=1,threads=1)
    b=(json.dumps(d,separators=(',',':'))+'\n').encode();assert len(b)<=2048
    tmp=statusfile.with_suffix('.json.tmp');tmp.write_bytes(b);tmp.replace(statusfile)
def call(cmd,tag,fault=False):
    log=D/(tag+'.log');log.parent.mkdir(parents=True,exist_ok=True);start=time.monotonic()
    with log.open('w') as f:
        child=subprocess.Popen(list(map(str,cmd)),cwd=D,stdout=f,stderr=subprocess.STDOUT)
        row=dict(tag=tag,argv=list(map(str,cmd)),PID=child.pid,NI=os.getpriority(os.PRIO_PROCESS,child.pid))
        result['stages'].append(row);save();status('CPU I-phase '+tag,child)
        print(tag,child.pid,flush=True)
        try:row['exit']=child.wait(timeout=180)
        except subprocess.TimeoutExpired:
            child.terminate();row['exit']=child.wait(timeout=10);row['timeout']=True
    row.update(reaped=True,elapsed=time.monotonic()-start);save();status('CPU I-phase '+tag+' terminal')
    text=log.read_text()
    if fault:
        assert row['exit']!=0 and 'PHASE_META_WRONG_OWNER_ADDRESS' in text and not row.get('timeout'),text[-2500:]
    else:
        assert row['exit']==0,(tag,text[-3500:])
    return text
base=json.loads((D/'run-inputs.json').read_text())
roles=[('on',1,[(1,s,1) for s in range(6)]+[(0,0,1),(2,0,1)]),
       ('meta-off',0,[(2,0,1)]),('wrong-owner',1,[(2,0,1)])]
for role,meta,cases in roles:
    q=D/role;q.mkdir()
    sources=sorted(S.glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv')
    if role=='wrong-owner':sources[sources.index(S/'cpu.sv')]=D/'cpu-wrong-owner.sv'
    call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert',
          '--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','-GCOMMIT=1','-GPHASE_META='+str(meta),
          '--Mdir',q/'obj',*sources],role+'/build')
    model=q/'obj/Vtb';result['models'][role]=dict(SHA256=sha(model),sources={str(f.relative_to(D)):sha(f) for f in sources});save()
    for case,scenario,policy in cases:
        key=f'c{case}-s{scenario}-p{policy}';tag=role+'/'+key
        args={v.split('=',1)[0]:v.split('=',1)[1] for v in base['template'][1:]}
        rs,rs6=[(127,127),(2147483647,2147483647),(127,2147483647)][case]
        args.update({'+out':str(D/tag),'+phase_out':str(D/(tag+'.csv')),'+case':str(case),'+scenario':str(scenario),
                     '+policy':str(policy),'+loops':'4','+rs':format(rs,'x'),'+rs6':format(rs6,'x'),'+detail':'1'})
        for n in ['kernel','wrapper','boot']:args['+'+n]=str(I/Path(args['+'+n]).name)
        if scenario==3:
            args['+boot']=str(I/'irq-boot.hex')
            for n,sym in [('call','timed_call'),('done','timed_done'),('sym_rs','rs_literal'),('sym_rs6','rs6_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:args['+'+n]=format(base['IRQ_symbols'][sym],'x')
        text=call([model,*[k+'='+v for k,v in args.items()]],tag,role=='wrong-owner')
        if role=='wrong-owner':result['actual_fault']=dict(tag=tag,caught='PHASE_META_WRONG_OWNER_ADDRESS');save();continue
        for marker in ['PAIRED_SLOT_PASS','PHASE_FUNCTION_PASS','ADVERSE_PASS','IF_PHASE_META_PASS']:assert marker in text
        captures={}
        for ext in ['state','data','edge','full','pins','slot']:
            got=D/(tag+'.'+ext);previous=D/'reference'/key/ext
            assert got.read_bytes()==previous.read_bytes(),('changed leaf changed prior qualified behavior',tag,ext)
            captures[ext]=sha(got)
        result['cases'][tag]=dict(captures=captures,previous_literal=True,phase_csv=sha(D/(tag+'.csv')));save()
    for f in (q/'obj').iterdir():
        if f.is_file() and f.name not in ('Vtb','Vtb__verFiles.dat'):f.unlink()
result['status']='PASS8producerON+1metadataOFF literal previous state/data/SYS/ports/MEMpins; actual wrong-owner export fault caught'
save();status(result['status']);print(result['status'],flush=True)
