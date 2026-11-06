#!/usr/bin/env python3
"""One serial allocated production transplant gate; previous models not rerun."""
from pathlib import Path
import argparse, hashlib, json, os, resource, subprocess, time

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();D=a.output.resolve();S=D/'source';I=D/'inputs'
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
resource.setrlimit(resource.RLIMIT_CPU,(300,300));resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
start=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
for n,h in json.loads((D/'inputs.json').read_text())['source_sha256'].items():assert sha(D/n)==h,n
result=dict(controller=os.getpid(),starttime=start(os.getpid()),host=os.uname().nodename,NI=10,jobs=1,threads=1,stages=[],cases={},models={})
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def call(cmd,tag,fault=False):
    cmd=list(map(str,cmd));log=D/(tag+'.log');log.parent.mkdir(parents=True,exist_ok=True);begin=time.monotonic()
    with log.open('w') as out:
        child=subprocess.Popen(cmd,cwd=D,stdout=out,stderr=subprocess.STDOUT)
        row=dict(tag=tag,PID=child.pid,starttime=start(child.pid),command=cmd);result['stages'].append(row);save()
        print(tag,child.pid,flush=True)
        try:row['exit']=child.wait(timeout=180)
        except subprocess.TimeoutExpired:
            child.terminate();row['exit']=child.wait(timeout=10);row['timeout']=True
    row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save();text=log.read_text()
    if fault:
        markers=['CPU_SLOT_UNACCEPTED_OFFER_CHANGED','P7_SLOT_PRODUCER_CHANGED_UNACCEPTED_OWNER']
        assert row['exit']!=0 and any(m in text for m in markers) and 'timeout' not in text.lower(),text[-2500:]
        return dict(caught=next(m for m in markers if m in text))
    assert row['exit']==0,(tag,text[-2500:]);return text

base=json.loads((D/'run-inputs.json').read_text())
controls=[(1,s,0) for s in range(5)]+[(c,0,0) for c in [0,2]]
enabled=[(1,s,1) for s in range(6)]+[(c,0,1) for c in [0,2]]
for role,commit,cases in [('off',0,controls),('on',1,enabled),('cpu-drop',1,[(1,5,1)])]:
    Q=D/role;Q.mkdir();inputs=sorted(S.glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv')
    if role=='cpu-drop':inputs[inputs.index(S/'cpu.sv')]=D/'cpu-drop.sv'
    call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','-GCOMMIT='+str(commit),'--Mdir',Q/'obj',*inputs],role+'/build')
    model=Q/'obj/Vtb';result['models'][role]=dict(SHA256=sha(model),inputs={str(f.relative_to(D)):sha(f) for f in inputs});save()
    for case,scenario,policy in cases:
        key=f'c{case}-s{scenario}-p{policy}';tag=role+'/'+key
        args={v.split('=',1)[0]:v.split('=',1)[1] for v in base['template'][1:]}
        rs,rs6=[(127,127),(2147483647,2147483647),(127,2147483647)][case]
        args.update({'+out':str(D/tag),'+case':str(case),'+scenario':str(scenario),'+policy':str(policy),'+loops':'4','+rs':format(rs,'x'),'+rs6':format(rs6,'x'),'+detail':'1'})
        for name in ['kernel','wrapper','boot']:args['+'+name]=str(I/Path(args['+'+name]).name)
        if scenario==3:
            args['+boot']=str(I/'irq-boot.hex')
            for n,sym in [('call','timed_call'),('done','timed_done'),('sym_rs','rs_literal'),('sym_rs6','rs6_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:args['+'+n]=format(base['IRQ_symbols'][sym],'x')
        text=call([model,*[k+'='+v for k,v in args.items()]],tag,role=='cpu-drop')
        if role=='cpu-drop':result['actual_fault']=text;save();continue
        assert 'PAIRED_SLOT_PASS' in text and 'PHASE_FUNCTION_PASS' in text and 'ADVERSE_PASS' in text
        captures={}
        for ext in ['state','data','edge','full','pins','slot']:
            got=D/(tag+'.'+ext);previous=D/'reference'/key/ext
            assert got.read_bytes()==previous.read_bytes(),('production/qualified literal mismatch',tag,ext)
            captures[ext]=sha(got)
        result['cases'][tag]=dict(captures=captures,qualified_literal_match=True);save()
    for f in (Q/'obj').iterdir():
        if f.is_file() and f.name not in ['Vtb','Vtb__verFiles.dat']:f.unlink()
result['status']='PASS production transplant:7off+8on literal state/data/SYS/ports/MEMpin matches to qualified983; actual CPU dropped-offer fault caught'
save();print(result['status'],flush=True)
