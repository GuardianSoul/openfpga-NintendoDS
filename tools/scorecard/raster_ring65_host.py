#!/usr/bin/env python3
"""One changed ring model, original Corner39 actor/window, immutable baseline.

--prepare is source/input staging only. --build and --run are one serial
NI10/j1/t1 D1 chain; no baseline/native retry, no shared host writes or fit.
"""
import argparse,hashlib,json,os,resource,shutil,socket,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OLD=ROOT/'build/scenes62/extended-host';NEW=ROOT/'build/ring65/candidate-host';CASE=NEW/'results/corner'
BASE='2f86d1e69b0fc477d179375315acdefc1b438a68';LEAF='e2f68c15';RING='rtl/ds/nds_g3d_ring.sv'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def J(p):return json.loads(Path(p).read_text())
def write(p,d):
 p=Path(p);p.parent.mkdir(parents=True,exist_ok=True);t=p.with_name(p.name+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');t.replace(p)
def identity(p):return Path('/proc',str(p),'stat').read_text().split()[21]
def prepare():
 assert not NEW.exists(),'preserve prior attempt; no automatic overwrite'
 NEW.mkdir();oldmanifest=J(OLD/'production-manifest.json');diff=[];bind={}
 for rel,h in oldmanifest.items():
  src=OLD/'staged/production'/rel;assert sha(src)==h
  data=src.read_bytes();assert data==subprocess.check_output(['git','show',BASE+':'+rel],cwd=ROOT)
  dst=NEW/'staged/production'/rel;dst.parent.mkdir(parents=True,exist_ok=True)
  expected=subprocess.check_output(['git','show',LEAF+':'+rel],cwd=ROOT)
  if expected!=data:diff.append(rel)
  dst.write_bytes(expected);bind[rel]=sha(dst)
 assert diff==[RING],diff
 shutil.copytree(OLD/'staged/overlay',NEW/'staged/overlay');shutil.copy2(OLD/'staged/heavy59_profile.sv',NEW/'staged/heavy59_profile.sv')
 oldcmd=J(OLD/'build-command.json');cmd=[s.replace(str(OLD),str(NEW))for s in oldcmd];mdir=cmd.index('--Mdir')+1;cmd[mdir]=str(NEW/'obj')
 assert cmd[cmd.index('-j')+1]=='1'and cmd[cmd.index('--threads')+1]=='1'
 changed_compiled=[];compiled={}
 for oldpath,h in J(OLD/'compiled-inputs.json').items():
  assert sha(oldpath)==h
  newpath=oldpath.replace(str(OLD),str(NEW));compiled[newpath]=sha(newpath)
  if compiled[newpath]!=h:changed_compiled.append(newpath)
 assert changed_compiled==[str(NEW/'staged/production'/RING)],changed_compiled
 for p in cmd:
  if p.endswith(('.sv','.v','.cpp','.cc')):assert p.startswith(str(NEW))and Path(p).is_file(),p
 CASE.mkdir(parents=True);shutil.copytree(OLD/'results/corner/inputs',CASE/'inputs',copy_function=os.link)
 prep=J(OLD/'results/corner/preparation.json');shutil.copy2(OLD/'results/corner/preparation.json',CASE/'preparation.json')
 inputs={p.name:sha(p)for p in(CASE/'inputs').iterdir()if p.is_file()}
 oldrun=J(OLD/'results/corner/runtime-command.json');run=[x.replace(str(OLD),str(NEW))for x in oldrun]
 assert '+frames=39'in run and '+scene_capture_frames=39'in run and '+timeout_ms=2000'in run
 write(NEW/'build-command.json',cmd);write(CASE/'runtime-command.json',run);write(NEW/'compiled-inputs.json',compiled);write(NEW/'production-manifest.json',bind)
 relation=dict(source=subprocess.check_output(['git','rev-parse',LEAF],cwd=ROOT).decode().strip(),baseline=BASE,baseline_model_sha256=sha(OLD/'model.bin'),changed_production_files=diff,changed_compiled_files=changed_compiled,unchanged_profile58=True,old_build_command_sha256=sha(OLD/'build-command.json'),new_build_command_sha256=sha(NEW/'build-command.json'),source_manifests=dict(before=sha(OLD/'production-manifest.json'),after=sha(NEW/'production-manifest.json')),actor_unchanged=True,clock_unchanged=True,LLR=1,RPRI=1,NX2=0,RH_AT=2800,runtime_bounds=dict(frames=39,capture_frames=39,timeout_ms=2000,fixed_map='raw-5'),inputs=inputs,preparation_sha256=sha(CASE/'preparation.json'),old_runtime_command_sha256=sha(OLD/'results/corner/runtime-command.json'),runtime_command_sha256=sha(CASE/'runtime-command.json'))
 write(NEW/'source-relation.json',relation);print('PREPARED_RING_ONLY_DELTA',len(compiled),'compiled input hashes',flush=True)
def verify():
 r=J(NEW/'source-relation.json');assert sha(NEW/'build-command.json')==r['new_build_command_sha256']
 for p,h in J(NEW/'compiled-inputs.json').items():assert sha(p)==h,p
 for p,h in r['inputs'].items():assert sha(CASE/'inputs'/p)==h,p
 return r
def execute(cmd,cwd,log,kind,budget):
 assert os.getloadavg()[0]<24,'capacity gate; no automatic waiting/retry'
 assert shutil.disk_usage(NEW).free>4*1024**3
 t=time.monotonic();m=dict(phase=kind,controller_pid=os.getpid(),controller_starttime=identity(os.getpid()),host=socket.gethostname(),NI=os.nice(0),jobs=1,threads=1,command=cmd,wall_budget_seconds=budget)
 with Path(log).open('w')as f:
  p=subprocess.Popen(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
  m.update(child_pid=p.pid,child_starttime=identity(p.pid));write(NEW/'worker.json',m)
  try:rc=p.wait(timeout=budget)
  except subprocess.TimeoutExpired:
   assert identity(p.pid)==m['child_starttime'];p.terminate();rc=p.wait(timeout=15);m['wall_timeout']=True
 m.update(phase=kind+'_TERMINAL',exit=rc,reaped=True,seconds=time.monotonic()-t,child_pid=None);write(NEW/(kind.lower()+'-receipt.json'),m);write(NEW/'worker.json',m);assert rc==0,(kind,rc)
def build():
 r=verify();(NEW/'build.attempt').open('x').write(r['source']+'\n');execute(J(NEW/'build-command.json'),ROOT,NEW/'build.log','BUILD',1800)
 shutil.copy2(NEW/'obj/Vtb_ds_pocket',NEW/'model.bin');write(NEW/'model.json',dict(source=r['source'],sha256=sha(NEW/'model.bin'),baseline=r['baseline'],profile58_unchanged=True,ring_RTL_only_change=True));print('BUILT',sha(NEW/'model.bin'),flush=True)
def native():
 r=verify();m=J(NEW/'model.json');assert sha(NEW/'model.bin')==m['sha256']
 (CASE/'run.attempt').open('x').write(m['sha256']+'\n')
 for d in ['shots','capture']:(CASE/d).mkdir()
 execute(J(CASE/'runtime-command.json'),CASE/'inputs',CASE/'native.log','NATIVE',3600)
 verify();states=(CASE/'capture/capture.states.jsonl').read_text().splitlines();shots=list((CASE/'shots').glob('*.ppm'));assert len(states)==40 and len(shots)==39
 write(CASE/'capture-manifest.json',{p.name:dict(bytes=p.stat().st_size,sha256=sha(p))for p in(CASE/'capture').iterdir()if p.is_file()})
 write(CASE/'terminal.json',dict(source=r['source'],model_sha256=m['sha256'],image_count=len(shots),state_count=len(states),virtual_timeout_ms=2000,original_frames=39,fixed_map='raw-5',native_exit=0,reaped=True,not_yet_qualified=True));print('CORNER39_CAPTURED_NOT_YET_QUALIFIED',flush=True)
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--prepare',action='store_true');a.add_argument('--build',action='store_true');a.add_argument('--run',action='store_true');args=a.parse_args();os.setpriority(os.PRIO_PROCESS,0,10)
 if args.prepare:prepare()
 if args.build:build()
 if args.run:native()
