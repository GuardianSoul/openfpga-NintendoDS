#!/usr/bin/env python3
"""Run one coordinator-allocated, serial P7 receiver contract gate."""
from pathlib import Path
import argparse, hashlib, json, os, resource, subprocess, sys

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--guard',type=Path,required=True,help='Pinned worker_guard.py/sim_ownership.py directory')
p.add_argument('--verilator',default='build/tools/oss-cad-suite/bin/verilator')
a=p.parse_args(); D=a.output.resolve(); S=D/'source'
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
save=lambda name,obj:(D/name).write_text(json.dumps(obj,indent=2)+'\n')
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
assert sha(a.guard/'sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
sys.path.insert(0,str(a.guard)); from worker_guard import guard,wait_owned
def start(pid):return Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
assert not (D/'controller.json').exists()
for name,h in json.loads((D/'inputs.json').read_text())['source_sha256'].items():
    assert sha(D/name)==h,name
controller=dict(host=os.uname().nodename,pid=os.getpid(),starttime=start(os.getpid()),NI=10,jobs=1,threads=1,
                driver_sha256=sha(Path(__file__)),guard_sha256=sha(a.guard/'worker_guard.py'))
save('controller.json',controller)
def call(command,stem,fault=None):
    guard(); command=list(map(str,command)); log=D/(stem+'.log')
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('w') as f:
        child=subprocess.Popen(command,cwd=D,stdout=f,stderr=subprocess.STDOUT)
        row=dict(pid=child.pid,starttime=start(child.pid),command=command,NI=os.getpriority(os.PRIO_PROCESS,child.pid))
        save('active.json',row); print('START',stem,child.pid,flush=True)
        rc=wait_owned(child)
    row.update(exit=rc,reaped=True); save(stem+'.process.json',row)
    text=log.read_text()
    if fault:
        assert rc!=0 and fault in text and 'timeout'not in text.lower(),(stem,rc,text[-2000:])
    else:assert rc==0,(stem,rc,text[-2000:])
    return dict(exit=rc,log_sha256=sha(log))
results={}
try:
    for role in ['before','normal','drop-capture','consume-wins']:
        Q=D/role; Q.mkdir()
        p7=D/('p7-before-ports.sv'if role=='before'else f'p7-{role}.sv')
        sources=[*sorted(S.glob('*.sv')),p7]
        call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',
              '--top-module','slot_tb','--Mdir',Q/'obj',*sources],role+'/build')
        model=Q/'obj/Vslot_tb'
        save(role+'/model.json',dict(sha256=sha(model),inputs={str(f.relative_to(D)):sha(f)for f in sources}))
        scenarios=[4]if role=='before'else(range(5)if role=='normal'else[0])
        for scenario in scenarios:
            for pressure in ([0,1]if role in ['before','normal']else[0]):
                key=f's{scenario}-p{pressure}'; stem=role+'/'+key
                fault='P7_SLOT_ACCEPTED_OWNER_DROPPED'if role in ['drop-capture','consume-wins']else None
                result=call([model,f'+out={D/stem}',f'+scenario={scenario}',f'+pressure={pressure}'],stem,fault)
                if fault:result['caught']=fault
                else:
                    assert 'P7_SLOT_PASS'in(D/(stem+'.log')).read_text()
                    result['captures']={ext:sha(D/(stem+'.'+ext))for ext in ['data','edge','pins']}
                    if role=='normal'and scenario==4:
                        assert result['captures']==results['before/'+key]['captures'],('literal valid0 equivalence',key)
                results[stem]=result;save('results.json',results)
    save('complete.json',dict(status='PASS receiver-only protocol/physical-payload/defaultoff/actual-fault gate',
         positive_cases=12,actual_faults=2,controller=controller,
         scope='No CPU producer or DS service timing qualification; paired source and shared deadline/native gates remain open.'))
    print('P7_RECEIVER_COMPLETE',flush=True)
finally:
    # Keep FETCH small: a completed model needs its executable and original
    # input receipt, not the generated compiler/PCH scratch.
    removed=[]
    for role in ['before','normal','drop-capture','consume-wins']:
        receipt=D/role/'model.json'; obj=D/role/'obj'
        if not receipt.exists():continue
        assert sha(obj/'Vslot_tb')==json.loads(receipt.read_text())['sha256']
        for f in obj.iterdir():
            if f.is_file()and f.name not in ['Vslot_tb','Vslot_tb__verFiles.dat']:
                removed.append(dict(path=str(f.relative_to(D)),bytes=f.stat().st_size));f.unlink()
    save('compiler-cleanup.json',dict(removed=removed,freed_bytes=sum(x['bytes']for x in removed)))
    save('terminal.json',dict(controller=controller,complete=(D/'complete.json').exists()))
