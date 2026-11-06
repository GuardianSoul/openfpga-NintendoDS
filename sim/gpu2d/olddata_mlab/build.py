#!/usr/bin/env python3
"""Build the actual selected 2D production model in one Laptop worker."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
files=[ROOT/'rtl/gpu2d/gpu2d_pkg.sv',ROOT/'rtl/ds/nds_ram.sv']+[ROOT/f'rtl/gpu2d/gpu2d_{n}.sv' for n in ['ram','cache','bg','obj']]+[ROOT/'rtl/gpu2d/gpu2d.sv']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','gpu2d','--Mdir',str(out/'obj'),'-GPERSIST=1','-GOAM_CPU=1','-GWST_RF=1','-GMOSAIC=1','-GTAG_MLAB=0','-GTEX_IDXW=6']+list(map(str,files))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
(out/'receipt.json').write_text(json.dumps({'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'source_hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}},indent=2)+'\n')
print('PRODUCTION_BUILD_PASS' if r.returncode==0 else 'PRODUCTION_BUILD_FAIL',flush=True)
raise SystemExit(r.returncode)
