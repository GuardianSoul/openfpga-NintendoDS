#!/usr/bin/env python3
"""Prepare and execute the single-worker, complete-frame OBJ closure fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

REPO=Path(__file__).resolve().parents[3]
MAIN=Path('/home/user/Git/NDS_Pocket')
OLD=Path('/home/user/Git/NDS_Pocket-codex-shell/build/load2d-run38-qualified-v2')
RTL=['gpu2d/gpu2d_pkg.sv','ds/nds_ram.sv','gpu2d/gpu2d_ram.sv','gpu2d/gpu2d_cache.sv',
     'gpu2d/gpu2d_bg.sv','gpu2d/gpu2d_obj.sv','gpu2d/gpu2d.sv']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
def files(root):return {str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file()}
def prepare(out):
    out.mkdir(parents=True,exist_ok=False)
    source=out/'source';source.mkdir()
    for name in RTL:
        p=source/'rtl'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(REPO/'rtl'/name,p)
    shutil.copytree(REPO/'sim/gpu2d',source/'sim/gpu2d')
    golden=out/'golden';shutil.copytree(OLD/'golden',golden)
    pinned=json.loads((MAIN/'docs/results/run38-load2d-core-20261031/plan.json').read_text())
    for name,h in pinned['golden_sha256'].items():
        assert sha(golden/name)==h,('golden changed',name)
    # Existing qualified unit adapter: GPU.cpp's DS line-latch callback is
    # outside standalone GPU2D, so reproduce it before the register updates.
    p=source/'sim/gpu2d/golden2d.cpp';t=p.read_text()
    for kind in ('true','false'):
        old=f'    p->a.UpdateRegistersPreDraw({kind}); p->b.UpdateRegistersPreDraw({kind});'
        assert t.count(old)==1
        t=t.replace(old,'    p->a.DsDispCntLine = p->a.DispCnt; p->b.DsDispCntLine = p->b.DispCnt;\n'+old)
    p.write_text(t)
    roots={38:MAIN/'build/hwref-return-20261031/trip20261031',
           39:MAIN/'build/coordinator/run39-replay-main/returns/objlimit-v2',
           40:MAIN/'build/coordinator/hwref-run40-20261101/returns/objwork-v1'}
    for run,root in roots.items():
        dest=out/'inputs'/f'run{run}';dest.mkdir(parents=True)
        prefix={38:'load2d',39:'objlimit_v2',40:'objwork_v1'}[run]
        for p in root.glob(prefix+'*'):
            if p.is_file():shutil.copy2(p,dest/p.name)
    write(out/'manifest.json',dict(base=subprocess.check_output(['git','-C',str(REPO),'rev-parse','HEAD'],text=True).strip(),
      source=files(source),golden=files(golden),inputs=files(out/'inputs'),
      fixture_adapter='Qualified DS23 DISPCNT line latch only; no producer/phase change',
      profile=dict(PERSIST=1,OAM_CPU=1,TEX_IDXW=7,TAG_MLAB=1),rules=pinned['build_command'][pinned['build_command'].index('-CFLAGS')+1].split(' -D')[1:],
      scope='20 stable full-frame fixtures; isolated2D, no CPU/DMA stress/deadline or game qualification'))
def seal(out):
    p=out/'manifest.json';m=json.loads(p.read_text());m['source']=files(out/'source');m['golden']=files(out/'golden');write(p,m)
def run(out):
    os.setpriority(os.PRIO_PROCESS,0,10)
    manifest=json.loads((out/'manifest.json').read_text())
    assert files(out/'source')==manifest['source'] and files(out/'golden')==manifest['golden']
    assert files(out/'inputs')==manifest['inputs']
    src=out/'source';g=out/'golden';obj=out/'obj';captures=out/'captures';captures.mkdir()
    includes=[src/'sim/gpu2d',src/'sim/gpu2d/melonds_shim',g]
    flags='-std=c++20 -O2 -fwrapv -include '+str(g/'Census.h')+' '+' '.join('-I'+str(p)for p in includes)+' '+' '.join('-D'+r for r in manifest['rules'])
    cpp=[src/'sim/gpu2d/objwork31/tb.cpp',src/'sim/gpu2d/golden2d.cpp',src/'sim/gpu2d/objwork31/cases.cpp',
         src/'sim/gpu2d/objwork31/load2d_run38.cpp',src/'sim/gpu2d/dump2d.cpp',g/'GPU2D.cpp',g/'GPU2D_Soft.cpp',g/'CensusHooks.cpp']
    cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','-O3','--threads','1',
         '--x-assign','fast','--x-initial','fast','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL',
         '--top-module','gpu2d','--Mdir',str(obj),'-GPERSIST=1','-GOAM_CPU=1','-GTEX_IDXW=7','-GTAG_MLAB=1','-CFLAGS',flags,
         *[str(src/'rtl'/p)for p in RTL],*[str(p)for p in cpp]]
    records=[]
    def execute(kind,argv,env=None):
        with (out/(kind+'.log')).open('w')as log:
            p=subprocess.Popen(argv,cwd=REPO,stdout=log,stderr=subprocess.STDOUT,env=env)
            rec=dict(stage=kind,pid=p.pid,controller=os.getpid(),nice=os.getpriority(os.PRIO_PROCESS,p.pid),argv=argv)
            records.append(rec);write(out/'processes.json',records);print(json.dumps(rec),flush=True)
            rec['exit']=p.wait();rec['log_sha256']=sha(out/(kind+'.log'));write(out/'processes.json',records)
        return rec['exit']
    if execute('build',cmd):raise SystemExit('build failed; inspect build.log')
    env=os.environ.copy();env.update(OBJWORK_INPUTS=str(out/'inputs'),OBJWORK_OUT=str(captures))
    status=execute('native',[str(obj/'Vgpu2d')],env)
    write(out/'result.json',dict(exit=status,model_sha256=sha(obj/'Vgpu2d'),captures=files(captures),
                              source=manifest['source'],golden=manifest['golden']))
    raise SystemExit(status)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['prepare','seal','run']);p.add_argument('output',type=Path);a=p.parse_args()
    dict(prepare=prepare,seal=seal,run=run)[a.operation](a.output.resolve())
