#!/usr/bin/env python3
"""One private passive diagnostic on frozen3a; never rerun the control."""
import argparse,hashlib,json,os,resource,shutil,socket,subprocess,time
from pathlib import Path
R=Path(__file__).resolve().parents[2];OLD=R/'build/turn69r1/candidate-host';NEW=R/'build/publication70/candidate-host';CASE=NEW/'results/corner';SOURCE='3a5722f4568c092caa5f4d24a4c0fdff61892884';QUAL=R/'build/publication70/qualified-v2'
def J(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v):p.parent.mkdir(parents=True,exist_ok=True);q=p.with_name(p.name+'.tmp');q.write_text(json.dumps(v,indent=2)+'\n');q.replace(p)
def ident(p):return Path('/proc',str(p),'stat').read_text().split()[21]
def owner(phase,worker):
 worker=[{k:v for k,v in m.items()if k in ['pid','starttime','controller_pid','controller_starttime','host','NI','jobs','threads']}for m in worker]
 p=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');v=J(p);v.update(phase='PUBLICATION70_'+phase,source=SOURCE,model_sha256=J(NEW/'model.json')['sha256']if(NEW/'model.json').exists()else'PASSIVE_MODEL_PENDING',worker=worker,lease='D1 one NI10/j1/t1; no Laptop/fit/second worker',updated_at=time.time());q=p.with_suffix('.tmp');q.write_text(json.dumps(v,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(p)
def capacity():
 assert os.getloadavg()[0]<24
 assert shutil.disk_usage(R).free>6*1024**3
 h=J(Path('/home/user/Git/NDS_Pocket/build/coordinator/units/hwref.json'))
 assert 'build'not in h['phase'].lower()or h.get('model_sha256')and 'built'in h['phase'].lower(),h
 snap=subprocess.check_output(['ps','-eo','pid,ppid,ni,etime,args'],text=True)
 put(NEW/'capacity.json',dict(time=time.time(),load=os.getloadavg(),free=shutil.disk_usage(R).free,hwref=h,processes=[x for x in snap.splitlines()if any(k in x for k in ['verilator','cc1plus','Vtb_ds','Vnds','quartus_'])and 'exec_command'not in x]))
def prepare():
 q=J(QUAL/'qualification.json');assert q['actual_observer_event_fault_caught']and q['verdict'].startswith('PASS_')
 assert not NEW.exists(),'preserve each attempt';NEW.mkdir(parents=True)
 manifest=J(OLD/'production-manifest.json');assert J(OLD/'source-relation.json')['source']==SOURCE
 for rel,h in manifest.items():assert sha(OLD/'staged/production'/rel)==h
 shutil.copytree(OLD/'staged',NEW/'staged')
 ob=NEW/'staged/overlay/sim/pocket_ds/publication70';ob.mkdir()
 for name in ['observer.sv','observer.cpp','fields.h','schema.json','source-contract.json','qualification.json','namespace.json']:shutil.copy2(QUAL/name,ob/name)
 capture=NEW/'staged/overlay/sim/pocket_ds/storage_pair_capture.cpp';s=capture.read_text();needle='extern "C" void pair_capture_state_begin(int f,unsigned long long t){';assert s.count(needle)==1;s=s.replace(needle,needle+'publication70_boundary(f,t);');s='extern "C" void publication70_boundary(int,unsigned long long);\n'+s;capture.write_text(s)
 cmd=[x.replace(str(OLD),str(NEW))for x in J(OLD/'build-command.json')]+[str(ob/'observer.sv'),str(ob/'observer.cpp')]
 compiled={p.replace(str(OLD),str(NEW)):sha(Path(p.replace(str(OLD),str(NEW))))for p in J(OLD/'compiled-inputs.json')}
 for p in [ob/'observer.sv',ob/'observer.cpp',ob/'fields.h']:compiled[str(p)]=sha(p)
 changes=[p for p,h in J(OLD/'compiled-inputs.json').items()if sha(Path(p.replace(str(OLD),str(NEW))))!=h];assert changes==[str(OLD/'staged/overlay/sim/pocket_ds/storage_pair_capture.cpp')]
 put(NEW/'compiled-inputs.json',compiled);put(NEW/'production-manifest.json',manifest);put(NEW/'build-command.json',cmd)
 CASE.mkdir(parents=True);shutil.copytree(OLD/'results/corner/inputs',CASE/'inputs',copy_function=os.link);shutil.copy2(OLD/'results/corner/preparation.json',CASE/'preparation.json')
 run=[x.replace(str(OLD),str(NEW))for x in J(OLD/'results/corner/runtime-command.json')];put(CASE/'runtime-command.json',run)
 put(NEW/'source-relation.json',dict(source=SOURCE,control_model=J(OLD/'model.json')['sha256'],production_unchanged=True,profile58_unchanged=True,actor_input_clock_map_unchanged=True,only_changes='Input-only observer SV/C++/field header plus void frame-boundary sink hook in existing capture C++',source_contract=J(QUAL/'source-contract.json'),qualification=q,inputs={p.name:sha(p)for p in(CASE/'inputs').iterdir()if p.is_file()},compiled=len(compiled),frames=39,states=40,one_candidate_only=True))
 print('PREPARED_PASSIVE_ONLY',len(compiled),flush=True)
def verify():
 r=J(NEW/'source-relation.json');assert r['production_unchanged']
 for p,h in J(NEW/'compiled-inputs.json').items():assert sha(Path(p))==h,p
 for p,h in J(NEW/'production-manifest.json').items():assert sha(NEW/'staged/production'/p)==h
 for p,h in r['inputs'].items():assert sha(CASE/'inputs'/p)==h
 return r
def execute(cmd,cwd,kind,budget):
 capacity();t=time.monotonic();m=dict(kind=kind,controller_pid=os.getpid(),controller_starttime=ident(os.getpid()),host=socket.gethostname(),NI=os.nice(0),jobs=1,threads=1,command=cmd)
 with(NEW/(kind.lower()+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)));m.update(pid=p.pid,starttime=ident(p.pid));put(NEW/'worker.json',m);owner(kind,[m])
  try:rc=p.wait(timeout=budget)
  except subprocess.TimeoutExpired:
   assert ident(p.pid)==m['starttime'];p.terminate();rc=p.wait(timeout=15);m['timeout']=True
 m.update(exit=rc,reaped=True,seconds=time.monotonic()-t);put(NEW/(kind.lower()+'-receipt.json'),m);owner(kind+'_TERMINAL',[]);assert rc==0,(kind,rc)
def lint():
 verify();cmd=J(NEW/'build-command.json');cmd=[x for x in cmd if x!='--binary'];cmd.insert(1,'--lint-only');execute(cmd,R,'LINT',600)
def build():
 verify();assert J(NEW/'lint-receipt.json')['exit']==0;(NEW/'build.attempt').open('x').write(SOURCE+'\n');execute(J(NEW/'build-command.json'),R,'BUILD',1800);shutil.copy2(NEW/'obj/Vtb_ds_pocket',NEW/'model.bin');put(NEW/'model.json',dict(source=SOURCE,sha256=sha(NEW/'model.bin'),control=J(OLD/'model.json')['sha256'],profile58=True,passive_only=True));print('BUILT_PASSIVE',sha(NEW/'model.bin'),flush=True)
def run():
 verify();m=J(NEW/'model.json');assert sha(NEW/'model.bin')==m['sha256'];(CASE/'run.attempt').open('x').write(m['sha256']+'\n')
 for p in ['shots','capture']:(CASE/p).mkdir()
 execute(J(CASE/'runtime-command.json'),CASE/'inputs','NATIVE',3600);verify();put(CASE/'capture-manifest.json',{p.name:dict(bytes=p.stat().st_size,sha256=sha(p))for p in(CASE/'capture').iterdir()if p.is_file()});put(CASE/'terminal.json',dict(source=SOURCE,model_sha256=m['sha256'],reaped=True,native_exit=0,image_count=len(list((CASE/'shots').glob('*.ppm'))),state_count=len((CASE/'capture/capture.states.jsonl').read_text().splitlines())))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare','lint','build','run']);a=p.parse_args();os.setpriority(os.PRIO_PROCESS,0,10);globals()[a.action]()
