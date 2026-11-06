"""One-slot before/current record-service equivalence and a real RTL fault."""
from pathlib import Path
import argparse,hashlib,json,os,resource,subprocess,time

r=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('mode',choices=['build','check']);a=p.parse_args()
b=r/'build/record-pack34';b.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before=subprocess.check_output(['git','show','15655ceb:rtl/ds/nds_g3d_store.sv'],cwd=r,text=True)
before=before[before.index('module nds_g3d_record_ram ('):].replace('module nds_g3d_record_ram (','module nds_g3d_record_ram_before (',1)
(b/'before.sv').write_text(before)
v=Path('build/tools/oss-cad-suite/bin/verilator')
def capacity():
    subprocess.run(['uptime'],check=True)
    ps=subprocess.check_output(['ps','-eo','pid,comm,stat'],text=True)
    heavy=[x for x in ps.splitlines()[1:] if len(x.split())==3 and not x.split()[2].startswith(('T','Z')) and (x.split()[1].startswith(('Vtb','Vnds','verilator_bin','quartus')) or x.split()[1] in ['cc1plus','clang','clang-23'])]
    print('actual heavy workers',heavy,flush=True);assert len(heavy)<3,'global worker limit'
def call(cmd,log,expected=0):
    capacity()
    with log.open('w') as f:
        proc=subprocess.Popen(list(map(str,cmd)),cwd=b,stdout=f,stderr=subprocess.STDOUT)
        with (b/'processes.jsonl').open('a') as q:q.write(json.dumps({'pid':proc.pid,'NI':os.getpriority(os.PRIO_PROCESS,proc.pid),'argv':list(map(str,cmd)),'time':time.time()})+'\n')
        print('OWN PID',proc.pid,'NI',os.getpriority(os.PRIO_PROCESS,proc.pid),log.name,flush=True)
        rc=proc.wait(timeout=240)
    text=log.read_text();print('terminal',proc.pid,rc,flush=True)
    if expected==0:assert rc==0,text[-2400:]
    else:assert rc!=0 and 'packing differs from previous RTL data' in text,text[-2400:]
    return text
def compile(store,out,log):
    call([v,'--binary','--timing','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_g3d_record_ram','--Mdir',out,r/'rtl/gpu3d/gpu3d_ram.sv',store,b/'before.sv',r/'sim/ds/tb_g3d_record_pack_eq.sv'],log)
if a.mode=='build':
    compile(r/'rtl/ds/nds_g3d_store.sv',b/'obj',b/'build.log')
    print('BUILD PASS; test not started; candidate fit may queue now',flush=True)
else:
    text=call([b/'obj/Vtb_g3d_record_ram'],b/'equivalence.log')
    assert 'PASS_RECORD_RAM' in text
    s=(r/'rtl/ds/nds_g3d_store.sv').read_text();old="{5'd0, p_wdata[19:0]}";assert s.count(old)==1
    mutant=b/'mutant.sv';mutant.write_text(s.replace(old,"{6'd0, p_wdata[18:0]}"))
    compile(mutant,b/'mutant-obj',b/'mutant-build.log')
    call([b/'mutant-obj/Vtb_g3d_record_ram'],b/'mutant.log',1)
    proof={'status':'PASS_BOUNDARY_EQUIVALENCE','before':'15655cebb9d636e79982c86d8f92c78179414c3a','current_RTL_sha256':sha(r/'rtl/ds/nds_g3d_store.sv'),'fixture_sha256':sha(r/'sim/ds/tb_g3d_record_pack_eq.sv'),'results':[l for l in text.splitlines() if l.startswith('PASS')],'actual_RTL_mutant':'Drop retained vertex tail bit19; before/current data comparator rejects it','scope':'All65536 private word addresses with legal producer padding, full32-bit ACK response equality, exact ACK/rvalid cycles, held/consecutive writes and read reset. Not a native game or DS timing measurement.','logs':{n:sha(b/n) for n in ['build.log','equivalence.log','mutant-build.log','mutant.log']},'worker':'one Desktop NI10 j1/t1; all children terminal'}
    (b/'qualification.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps(proof),flush=True)
