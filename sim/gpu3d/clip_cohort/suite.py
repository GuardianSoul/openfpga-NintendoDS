#!/usr/bin/env python3
"""One allocated worker; sequential remaining affected checks, no native run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
print('COHORT_SUITE_PID', os.getpid(), 'NI10/j1/t1', flush=True)
paths = ['rtl/gpu3d/gpu3d_gxdiv.sv', 'rtl/gpu3d/gpu3d_gxvfin.sv', 'rtl/gpu3d/gpu3d_gxeng.sv', 'scripts/build_ds.sh']
hashes = {n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in paths}
stages = [('red0', 'clip.py', ['--red', '0']),
          ('mutant', 'clip.py', ['--red', '1', '--mutant']),
          ('caller', 'caller.py', [])]
for name, script, args in stages:
    print('COHORT_CHECK', name, flush=True)
    (out/'suite-phase.json').write_text(json.dumps(dict(stage=name, PID=os.getpid(), time=time.time()))+'\n')
    subprocess.run([sys.executable, str(Path(__file__).with_name(script)), '--out', str(out/name), *args], cwd=ROOT, check=True)
    assert hashes == {n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in paths}, 'source changed during suite'
(out/'suite-receipt.json').write_text(json.dumps(dict(exit=0, PID=os.getpid(), nice=10, jobs=1, threads=1, source_sha256=hashes, stages=[s[0] for s in stages]), indent=2)+'\n')
print('COHORT_SUITE_PASS', flush=True)
