#!/usr/bin/env python3
"""One D3 worker, new late-field store relation only, NI10/jobs1/threads1."""
import argparse
import datetime
import hashlib
import json
import os
import resource
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-clip-pump16'
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
V='build/tools/oss-cad-suite/bin/verilator'
p=argparse.ArgumentParser();p.add_argument('mode',choices=['clip-red1','clip-red0','clip-mutant','caller','build']);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=B/a.mode;out.mkdir(parents=True,exist_ok=True)
print('CLIP_STORE_D3_PID',os.getpid(),a.mode,'NI10/j1/t1',flush=True)
def phase(stage,child=None,active=True):
 d=json.loads(S.read_text());d['phase']=stage;d['worker']={'active':active,'host':'Desktop','lease':'D3 clipstore','PID':os.getpid(),'child_PID':child,'nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t=S.with_suffix('.tmp');t.write_text(s);t.replace(S)
def run(cmd,log,stage):
 with log.open('w')as f:
  child=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);phase(stage,child.pid);rc=child.wait()
 phase(stage+' reaped',child.pid,False);return rc,child.pid

source=R/'rtl/gpu3d/gpu3d_gxvfin.sv'
if a.mode=='clip-mutant':
 text=source.read_text();needle='always_ff @(posedge clk2) if (mid)\n            outside_word[sf]';assert text.count(needle)==1
 source=out/'actual-outside-hold-phase-mutant.sv';source.write_text(text.replace(needle,needle.replace('if (mid)','if (!mid)')))
base=[V,'--cc','--build','--build-jobs','1','-j','1','--threads','1','--assert','-Wno-fatal','-MAKEFLAGS','VM_PARALLEL_BUILDS=0','--Mdir',str(out/'obj')]
if a.mode.startswith('clip-'):
 files=[R/'rtl/gpu3d/gpu3d_gxu_pkg.sv',R/'rtl/gpu3d/gpu3d_ram.sv',R/'rtl/gpu3d/gpu3d_gxdiv.sv',source,B/'before-clip.sv',B/'clip.sv',R/'sim/gpu3d/clip_store/clip.cpp']
 cmd=base+['--exe','--top-module','tb_clip_store','-GRED='+('0'if a.mode=='clip-red0'else'1'),'-GMUTANT='+('1'if a.mode=='clip-mutant'else'0'),'-CFLAGS',f'-std=c++20 -O1 -I{B}']+list(map(str,files));binary=out/'obj/Vtb_clip_store'
else:
 files=[R/'rtl/gpu3d/gpu3d_gxu_pkg.sv',R/'rtl/gpu3d/gpu3d_ram.sv']+sorted((R/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))+[R/f'rtl/gpu3d/gpu3d_{n}.sv'for n in ['gxlight','gxdiv','gxfront','gxeng','gxsort','geom']]+[source]
 if a.mode=='caller':
  files += [B/'before-clip.sv',B/'before-eng.sv',B/'before-geom.sv',B/'caller.sv',R/'sim/gpu3d/clip_store/caller.cpp']
  cmd=base+['--exe','--top-module','tb_scalar_caller','-CFLAGS','-std=c++20 -O1']+list(map(str,files));binary=out/'obj/Vtb_scalar_caller'
 else:
  cmd=base+['--top-module','gpu3d_geom','-GFF=1','-GLUNIT=1','-GVFIN=2','-GUSORT=1','-GGX_DSX=1','-GGX_SWAP_OVERLAP=1','-GGX_L44_READ=1','-GGX_DIV_P2X=1','-GGX_SCALAR_DIV_P2X=1','-GGX_CLIP_STORE_PUMP=1','-GGX_MAT_PAR=1','-GGX_ROM_DICT=1','-GENG_M10K=0','-GSPILL=1','-GSP_ON=4096','-GSP_AW=18']+list(map(str,files));binary=None
(out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
rc,child=run(cmd,out/'build.log',a.mode+' compile');assert rc==0,(out/'build.log').read_text()[-2200:]
run_rc=None;output=''
if binary:
 run_rc,child=run([str(binary)],out/'run.log',a.mode+' execution');output=(out/'run.log').read_text();print(output[-2000:],flush=True)
rec={'before':'97698ee421304616961056481a9353b9a9a10538','mode':a.mode,'PID':os.getpid(),'child_PID':child,'compile_exit':rc,'exit':run_rc,'command':cmd,'output':output,'source_hashes':{str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest()for f in files},'scope':'New5latefield storage timing/state/order relation; unchanged9lane math, fullcapacity, scalar14 and other accepted scopes not reopened.'}
if a.mode=='build':
 lib=out/'obj/Vgpu3d_geom__ALL.a';assert lib.is_file();rec['archive']={'path':str(lib),'bytes':lib.stat().st_size,'sha256':hashlib.sha256(lib.read_bytes()).hexdigest()}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
if a.mode=='clip-mutant':assert run_rc and 'CLIP_PUBLIC_CWD_MISMATCH'in output,output[-1800:]
elif binary:assert run_rc==0,output[-1800:]
phase(a.mode+' PASS',child,False)
