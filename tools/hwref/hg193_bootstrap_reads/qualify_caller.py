#!/usr/bin/env python3
"""One gated small actual-transport component, positive plus live-owner fault."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
SOURCE='690b22e8e528f2d55e998967a9fb62b6a82ff333'
OWNER=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/hwref.json')
def write(p,v):
 p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(v,indent=2)+'\n');os.replace(t,p)
def proc():return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],nice=os.getpriority(os.PRIO_PROCESS,0))
def gate(p):
 while not p.exists():time.sleep(.1)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def owner(phase,worker):
 d=json.loads(OWNER.read_text());d.update(phase=phase,worker=worker,lease='D2tinycomponent NI10/j1/t1; L1free; no fullgame running',source=dict(production=SOURCE,profile=60,frozen_model='e38360b2ecbfbe187093e9a480d29352b906fddcdd54d0ed2fb1fd199a5c7557',unit='aa1651d6',caller_sources={n:sha(HERE/n)for n in ['caller.svh','tb_caller.sv','component_transport.sv']}));write(OWNER,d)

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--child');a=p.parse_args();out=a.out.resolve()
 os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  plan=json.loads((out/'plan.json').read_text());write(out/(a.child+'-child.json'),proc());gate(out/(a.child+'-release'))
  os.execv(plan[a.child][0],plan[a.child])
 assert not out.exists();out.mkdir(parents=True)
 files=['rtl/arm/arm_pkg.sv','rtl/arm/arm9_ram.sv','rtl/arm/arm9_mem.sv','rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv','sim/ds/a7_vram_read/cram_model.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/pocket/nds_psram.sv','rtl/ds/nds_io.sv']
 inputs=[]
 for n in files:
  q=out/'source'/n;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(subprocess.check_output(['git','show',SOURCE+':'+n],cwd=ROOT));inputs.append(q)
 for n in ['predicate.svh','caller.svh','tb_caller.sv','component_transport.sv']:
  q=out/'source'/n;q.write_bytes((HERE/n).read_bytes())
 model=out/'obj/Vtb_caller'
 plan=dict(compile=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_caller','--Mdir',str(model.parent),'-I'+str(out/'source'),*map(str,inputs),str(out/'source/component_transport.sv'),str(out/'source/tb_caller.sv')],positive=[str(model)],forbidden_owner=[str(model),'+forbidden_owner'])
 write(out/'plan.json',plan);write(out/'source-binding.json',dict(source=SOURCE,inputs={str(q.relative_to(out)):sha(q)for q in (out/'source').rglob('*')if q.is_file()},reference='Existing ldm_service real-pin transport adapted with actual nds_io +arm9_mem. No new production subsystem; simulation-only cost0ALM. Native690/profile60/e383 untouched.',scope='Actual transport/mem9 signal association; not CPU instruction execution or full game proof.'))
 controller=proc();write(out/'controller.json',controller);owner('D2 actualcaller component gated',dict(host='DesktopD2',controller=controller,child=None,jobs=1,threads=1));gate(out/'release')
 results={}
 for name in ['compile','positive','forbidden_owner']:
  with (out/(name+'.log')).open('w') as f:
   child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--out',str(out),'--child',name],stdout=f,stderr=subprocess.STDOUT)
   q=out/(name+'-child.json')
   while not q.exists():
    assert child.poll()is None;time.sleep(.1)
   identity=json.loads(q.read_text());assert identity['nice']==10
   write(out/'active.json',dict(phase=name,controller=controller,child=identity))
   owner('D2 actualcaller '+name,dict(host='DesktopD2',controller=controller,child=identity,jobs=1,threads=1))
   (out/(name+'-release')).touch();rc=child.wait()
  results[name]=dict(exit=rc,child=identity,reaped=True);write(out/'results.json',results)
  text=(out/(name+'.log')).read_text()
  if name=='forbidden_owner':assert rc!=0 and 'ACTUAL_FORBIDDEN_OWNER_OR_ASSOCIATION_REJECTED'in text and 'timeout'not in text.lower()
  else:assert rc==0,(name,text[-3000:])
  if name=='positive':assert 'ACTUAL_CALLER_PASS'in text
  if name=='compile':write(out/'model.json',dict(path=str(model),sha256=sha(model),source_binding_sha256=sha(out/'source-binding.json')))
 write(out/'complete.json',dict(results=results,actual_transport_positive=True,actual_live_fabric_master_fault_caught=True,default_enable=0,production_models=0))
 owner('Actualcaller component PASS; D2released; L1strictdiag not yet launched',dict(host=None,active_workers=0,controller=None,child=None,all_owned_children_reaped=True))
 print(json.dumps(results),flush=True)
if __name__=='__main__':main()
