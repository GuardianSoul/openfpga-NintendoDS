#!/usr/bin/env python3
"""Build the actual pumped GX_FAST geometry source in one allocated worker."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser()
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
files=[ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv',ROOT/'rtl/gpu3d/gpu3d_ram.sv']
files+=sorted((ROOT/'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))
files+=[ROOT/f'rtl/gpu3d/gpu3d_{n}.sv' for n in ['gxlight','gxvfin','gxdiv','gxfront','gxeng','gxsort','geom']]
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','gpu3d_geom','--Mdir',str(out/'obj'),'-GFF=1','-GLUNIT=1','-GVFIN=2','-GUSORT=1','-GGX_DSX=1','-GGX_SWAP_OVERLAP=1','-GGX_L44_READ=1','-GGX_DIV_P2X=1','-GSPILL=1','-GSP_ON=4096','-GSP_AW=18']+list(map(str,files))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
receipt={'exit':r.returncode,'pid':os.getpid(),'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('PRODUCTION_BUILD_PASS' if not r.returncode else 'PRODUCTION_BUILD_FAIL',flush=True)
raise SystemExit(r.returncode)
