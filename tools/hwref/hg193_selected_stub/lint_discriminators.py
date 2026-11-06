#!/usr/bin/env python3
"""Elaborate read-only next-point observations; never build/run a game model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import time

OWNER=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/hwref.json')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(d,indent=2)+'\n');os.replace(t,p)
def proc():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19],NI=os.getpriority(os.PRIO_PROCESS,0))
def gate(p):
 while not p.exists():time.sleep(.1)
def main():
 p=argparse.ArgumentParser();p.add_argument('--parent',type=Path,required=True);p.add_argument('--observations',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--child',action='store_true');a=p.parse_args();parent=a.parent.resolve();obs=a.observations.resolve();out=a.out.resolve();os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(out/'child.json',proc());gate(out/'child.release');plan=json.loads((out/'plan.json').read_text());os.chdir(plan['cwd']);os.execv(plan['argv'][0],plan['argv'])
 assert not out.exists();out.mkdir(parents=True)
 for n in ['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']:shutil.copytree(parent/n,out/n)
 for n in ['matcher.svh','bridge-history.svh','missing-discriminators.svh']:shutil.copyfile(obs/n,out/'include'/n)
 hook=out/'include/hg193_combined_hook.svh';old=hook.read_text();mark='`include "hg193_actual_caller.svh"';inc=mark+'\n`include "bridge-history.svh"\n`include "missing-discriminators.svh"';assert old.count(mark)==1;new=old.replace(mark,inc)
 call=' hg193_actual_caller_point();\n';extra=call+' hg193_missing_discriminators();\n';assert new.count(call)==1;new=new.replace(call,extra);hook.write_text(new)
 assert new.replace(inc,mark).replace(extra,call)==old
 assert (out/'include/hg193_combined_drain.svh').read_bytes()==(parent/'include/hg193_combined_drain.svh').read_bytes()
 original=json.loads((parent/'game-build-plan.json').read_text());argv=[x.replace(str(parent)+'/',str(out)+'/')for x in original['argv']];assert '--binary'in argv;argv[argv.index('--binary')]='--lint-only';tb=str(out/'observed-overlay/tb_native52_import.sv');argv.insert(argv.index(tb),str(out/'include/matcher.svh'))
 assert '--binary'not in argv and '--lint-only'in argv
 write(out/'plan.json',dict(argv=argv,cwd=original['cwd'].replace(str(parent),str(out)),source=original['source'],full_profile=original['full_profile'],operation='SV_HIERARCHY_ELABORATION_ONLY_NO_CPP_BUILD_OR_MODEL',guard_reconstructs_parent=True))
 inputs={str(p.relative_to(out)):sha(p)for n in ['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']for p in(out/n).rglob('*')if p.is_file()};write(out/'input-binding.json',inputs)
 controller=proc();write(out/'controller.json',dict(controller=controller,qualifier_sha256=sha(Path(__file__).resolve())));d=json.loads(OWNER.read_text());d.update(phase='D2192observation+selectedstub hierarchy lint gated; no model',worker=dict(host='DesktopD2',controller=controller,child=None,jobs=1,threads=1),lease='D2oneSVlint; L1free; no game native/probe');write(OWNER,d);gate(out/'release')
 with(out/'lint.log').open('w')as f:
  child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--parent',str(parent),'--observations',str(obs),'--out',str(out),'--child'],stdout=f,stderr=subprocess.STDOUT)
  while not(out/'child.json').exists():assert child.poll()is None;time.sleep(.1)
  identity=json.loads((out/'child.json').read_text());assert identity['NI']==10
  write(out/'active.json',dict(controller=controller,child=identity));d=json.loads(OWNER.read_text());d['worker']['child']=identity;write(OWNER,d);(out/'child.release').touch();rc=child.wait()
 write(out/'complete.json',dict(exit=rc,child=identity,reaped=True,game_model_built=False,game_native_runs=0,raw_scans=0,guard_reconstructs_parent=True,log_sha256=sha(out/'lint.log')))
 assert rc==0,(out/'lint.log').read_text()[-3000:]
 assert not(out/'private-game-obj/Vtb_ds_pocket').exists()
 d=json.loads(OWNER.read_text());d.update(phase='192observationSVhierarchy lintPASS; default0/originalguards; D2released',worker=dict(host=None,active_workers=0,controller=None,child=None,all_owned_children_reaped=True),lease='D2free/L1free; no pending game/model/probe');write(OWNER,d)
 print((out/'complete.json').read_text())
if __name__=='__main__':main()
