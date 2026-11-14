#!/usr/bin/env python3
"""arm9_core (A9_CORE=1) against arm_core (A9_CORE=0) in the DS build's ARM9 configuration
(docs/arm9-stall.md): every run_tests.py test on the reference with retire traces (+trace0/+trace1),
then on the candidate in lockstep against them (+ref0/+ref1: PC, CPSR, r0-r14 per retired instruction).

usage: lockstep.py REF_SIM CAND_SIM BUILD ASSETS OUT [--only a,b]
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
import run_tests  # noqa: E402


def main():
    ref, cand, build, assets, out = sys.argv[1:6]
    only = None
    if '--only' in sys.argv:
        only = set(sys.argv[sys.argv.index('--only') + 1].split(','))
    os.makedirs(out, exist_ok=True)
    bad = 0
    for name, args, _desc in run_tests.tests(build, assets):
        if only and name not in only:
            continue
        tr = [f'+trace0={out}/{name}.0.csv', f'+trace1={out}/{name}.1.csv']
        r = subprocess.run([ref] + args + tr, capture_output=True, text=True)
        rpass = 'TEST PASSED' in r.stdout
        rf = [f'+ref0={out}/{name}.0.csv', f'+ref1={out}/{name}.1.csv']
        c = subprocess.run([cand] + args + rf, capture_output=True, text=True)
        cpass = 'TEST PASSED' in c.stdout
        mm = [l for l in c.stdout.splitlines() if 'LOCKSTEP' in l or l.startswith('  r')][:4]
        n0 = sum(1 for _ in open(f'{out}/{name}.0.csv')) if os.path.exists(f'{out}/{name}.0.csv') else 0
        ok = not mm and (cpass or not rpass)    # a difference: a lockstep mismatch, or the candidate fails what the reference passes
        bad += not ok
        print(f"{'SAME' if ok else 'DIFF'}  {name:18s} ref {'PASS' if rpass else 'FAIL'} cand {'PASS' if cpass else 'FAIL'} "
              f"ref retired ctx0 {n0}" + ('' if not mm else ' | ' + ' / '.join(mm)), flush=True)
    print(f'{bad} differ')


main()
