#!/usr/bin/env python3
"""Check additive CPU-domain forwarding and elaborate all affected routes."""
from pathlib import Path
import argparse, hashlib, json, os, resource, subprocess, time
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--verilator',default='build/tools/oss-cad-suite/bin/verilator')
a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
base='76616273fe9229532d46939be25fe680d18bd816'
before=subprocess.check_output(['git','show',base+':rtl/arm/cpu_domain.sv'],cwd=R).decode()
source=(R/'rtl/arm/cpu_domain.sv').read_text()
additions=[
 '  parameter bit A7_MUL_META = 0, // passive original-F-owner MUL context and execution advances\n',
 '  output arm_pkg::a7_mul_context_t a7_mul_request,\n  output arm_pkg::a7_mul_advance_t a7_mul_advance,\n',
 ' .A7_MUL_META(A7_MUL_META),',
 '      .a7_mul_request, .a7_mul_advance,\n',
 "    assign a7_mul_request = '0;\n    assign a7_mul_advance = '0;\n"]
def equivalent(s):
 for v in additions:
  if s.count(v)!=1:return False
  s=s.replace(v,'')
 return s==before
assert equivalent(source)
faults={
 'producer_disconnected':source.replace('.a7_mul_request, .a7_mul_advance,','.a7_mul_request(), .a7_mul_advance(),'),
 'enable_ignored':source.replace('.A7_MUL_META(A7_MUL_META)',".A7_MUL_META(1'b0)")}
for name,value in faults.items():
 assert value!=source and not equivalent(value),name
 (D/(name+'.sv')).write_text(value)
(D/'before.sv').write_text(before);(D/'production.sv').write_text(source)
files=[R/'rtl/arm'/(n+'.sv')for n in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds cpu_domain cdc_req cdc_fifo cdc_a7'.split()]
files +=[R/f for f in ['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_arm7_port_min.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']]
S=D/'source';S.mkdir()
for f in files:(S/f.name).write_bytes(f.read_bytes())
q=dict(base=base,controller=os.getpid(),controller_starttime=Path('/proc/self/stat').read_text().split()[21],
 erased_original_exact=True,actual_source_faults_caught=list(faults),source_SHA256={f.name:hashlib.sha256(f.read_bytes()).hexdigest()for f in files},stages=[])
for route,solo,fast in [('shared',0,0),('split',3,0),('independent',5,0),('fast',5,1)]:
 for enabled in [0,1]:
  tag=route+str(enabled);cmd=[a.verilator,'--lint-only','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--top-module','cpu_domain','--Mdir',str(D/'obj'),'-GA9_SOLO='+str(solo),'-GCPU_FAST='+str(fast),'-GA7_MUL_META='+str(enabled),*map(lambda f:str(S/f.name),files)]
  start=time.monotonic()
  with(D/(tag+'.log')).open('w')as out:
   proc=subprocess.Popen(cmd,cwd=R,stdout=out,stderr=subprocess.STDOUT)
   row=dict(tag=tag,PID=proc.pid,starttime=Path('/proc',str(proc.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,proc.pid),cmd=cmd)
   row['exit']=proc.wait(timeout=60);row.update(reaped=True,wall_seconds=round(time.monotonic()-start,3))
  q['stages'].append(row);(D/'results.json').write_text(json.dumps(q,indent=2)+'\n')
  assert row['exit']==0,(tag,(D/(tag+'.log')).read_text()[-1600:])
  print(tag,'PASS',flush=True)
q['status']='PASS original control exact; forwarding connected; two actual source faults caught; eight route elaborations'
(D/'results.json').write_text(json.dumps(q,indent=2)+'\n');print(q['status'],flush=True)
