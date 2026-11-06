#!/usr/bin/env python3
"""Explicit bounded backend proof/replay; no full-CPU baseline or fit."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OSS = Path('build/tools/oss-cad-suite/bin')
VENDOR = Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mode',choices=['behavioral','native','mutant'],required=True)
    p.add_argument('--out',type=Path,required=True)
    a = p.parse_args()
    # Codex may inherit a negative nice value. Set the absolute priority;
    # adding10 would leave this below the required NI10.
    os.setpriority(os.PRIO_PROCESS,0,10)
    resource.setrlimit(resource.RLIMIT_CPU,(300,300))
    out = a.out.resolve()
    out.mkdir(parents=True,exist_ok=False)
    source = out/'source';source.mkdir()
    before = subprocess.check_output(['git','-C',str(ROOT),'show','d42fa30e:rtl/arm/arm9_ram.sv'],text=True)
    (source/'reference.sv').write_text(before.replace('module arm9_ram #(','module arm9_ram_ref #('))
    candidate = (ROOT/'rtl/arm/arm9_ram.sv').read_text()
    if a.mode == 'mutant':
        old = '.data(a_d[t*LANE_W+20 +: LANE_W-20]),'
        new = ".data(a_d[t*LANE_W+20 +: LANE_W-20] ^ ((LANE_W-20)'(1))),"
        assert candidate.count(old)==1
        candidate = candidate.replace(old,new)
    (source/'candidate.sv').write_text(candidate)
    (source/'tb.sv').write_bytes((ROOT/'sim/arm/ram_tag_tail/tb.sv').read_bytes())
    files = [str(source/'tb.sv'),str(source/'reference.sv'),str(source/'candidate.sv')]
    if a.mode == 'behavioral':
        build = [str(OSS/'verilator'),'--binary','--timing','-j','1','--threads','1',
                 '-Wno-fatal','--top-module','tb','--Mdir',str(out/'obj'),*files]
        run = [str(out/'obj/Vtb')]
    else:
        build = [str(OSS/'iverilog'),'-g2012','-DALTERA_RESERVED_QIS','-s','tb',
                 '-o',str(out/'model.vvp'),*files,str(VENDOR)]
        run = [str(OSS/'vvp'),str(out/'model.vvp')]
    jobs = []
    for phase,cmd in [('build',build),('run',run)]:
        started = time.monotonic()
        with (out/(phase+'.log')).open('wb') as f:
            child = subprocess.Popen(cmd,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
            # Short per-owner file, never send routine PID churn to chat.
            status = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
            d = json.loads(status.read_text())
            d['worker'] = dict(host='Desktop',active=True,PID=os.getpid(),child_PID=child.pid,NI=10)
            d['phase'] = 'tagtail '+a.mode+' '+phase+'; immutable production2835f3c5'
            b = (json.dumps(d,separators=(',',':'))+'\n').encode();assert len(b)<=2048
            tmp = status.with_suffix('.json.tmp');tmp.write_bytes(b);tmp.replace(status)
            code = child.wait(timeout=300)
        jobs.append(dict(phase=phase,argv=cmd,PID=child.pid,NI=10,exit=code,
                         elapsed=time.monotonic()-started,reaped=True))
        if phase=='build' and code:
            break
    log = (out/'run.log').read_text() if (out/'run.log').exists() else ''
    ok = len(jobs)==2 and jobs[0]['exit']==0
    ok = ok and ((jobs[-1]['exit']!=0 and 'CANDIDATE_A' in log) if a.mode=='mutant'
                 else (jobs[-1]['exit']==0 and 'PASS_BOTH_TAGS' in log))
    result = dict(mode=a.mode,status='PASS' if ok else 'FAIL',jobs=jobs,
                  source_sha256={p.name:sha(p) for p in sorted(source.iterdir())},
                  controller_PID=os.getpid(),NI=os.getpriority(os.PRIO_PROCESS,0))
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    d = json.loads(status.read_text());d['worker']=dict(host='Desktop',active=False,PID=None)
    d['phase']='tagtail '+a.mode+' '+result['status']+'; fit1202 pending'
    tmp=status.with_suffix('.json.tmp');tmp.write_text(json.dumps(d,separators=(',',':'))+'\n');tmp.replace(status)
    print(json.dumps(result))
    raise SystemExit(0 if ok else 1)


if __name__=='__main__':
    main()
