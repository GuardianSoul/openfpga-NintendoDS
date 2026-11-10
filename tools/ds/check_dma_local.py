#!/usr/bin/env python3
"""Prove the dmalocal observer discriminates live overlap from eventual results.

Builds the Pocket parameter set and a DMA9_RUN=0 negative in separate dirs.
Both must finish the ROM's counter/copy checks; only the negative may lose
the live-overlap criterion. This is a simulation regression, not a hardware
performance measurement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--tools', required=True)
    ap.add_argument('--bios', required=True)
    ap.add_argument('--out', default='build/dma-local-check')
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    # An aborted rerun must not leave a previous completion verdict behind.
    for name in ('summary.json', 'commands.json'):
        (out / name).unlink(missing_ok=True)
    env = os.environ.copy()
    tool_path = str(Path(a.tools).resolve())
    env['PATH'] = tool_path + os.pathsep + env['PATH']
    bios = Path(a.bios).resolve()
    for name in ('bios9.bin', 'bios7.bin', 'firmware.bin'):
        if not (bios / name).is_file():
            ap.error(f'missing {bios / name}')
    params = subprocess.check_output([sys.executable, 'tools/ds/pocket_params.py'], cwd=ROOT, text=True).splitlines()
    knobs = dict(p.split('=', 1) for p in params)
    if knobs['DS_FAST'] != '0':
        ap.error('this regression currently covers the Pocket CPU_FAST=0 clocking')
    if not re.search(r'(?:^|\s)-GA9_SOLO=5(?:\s|$)', knobs['DS_G']):
        ap.error('the preaccepted-token bound currently covers Pocket A9_SOLO=5 only')
    records = []

    def run(label, cmd, timeout):
        start = time.monotonic()
        with (out / (label + '.log')).open('w') as f:
            rc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode
        records.append(dict(label=label, command=cmd, rc=rc, seconds=round(time.monotonic() - start, 3)))
        (out / 'commands.json').write_text(json.dumps(records, indent=2) + '\n')
        return rc, (out / (label + '.log')).read_text()

    rc, _ = run('rom-build', ['make', 'build/ds-tests/dmalocal.nds', 'build/ds-tests/dmalocal_m7.nds',
                            'bootrom-check', f'TOOLS={tool_path}'], 600)
    if rc:
        sys.exit('ROM build failed; see ' + str(out / 'rom-build.log'))
    sources = list((ROOT / 'rtl').rglob('*.sv')) + [ROOT / p for p in
               ('sim/ds/tb_ds.cpp', 'sim/ds/ds.mk', 'sim/ds/ds_config.vlt', 'tools/ds/pocket_params.py',
                'sw/tests/tests.mk', 'build/ds-tests/dmalocal.nds', 'build/ds-tests/dmalocal_m7.nds')]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (out / 'input-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
    findings = []
    for held in (False, True):
        kind = 'held' if held else 'normal'
        cfg = dict(knobs)
        # Parameter changes do not invalidate a cached Make target by
        # themselves. Give each configuration its own fingerprinted dir.
        key = hashlib.sha256(json.dumps(knobs, sort_keys=True).encode()).hexdigest()[:12]
        cfg['DS_B'] = str(out / (kind + '-build-' + key))
        if held:
            cfg['DS_G'] += ' -GDMA9_RUN=0'
        rc, _ = run(kind + '-build', ['make', 'ds-sim', f'TOOLS={tool_path}',
                                     *(k + '=' + v for k, v in cfg.items())], 3600)
        if rc:
            sys.exit(f'{kind} simulation build failed; see {out}')
        exe = str(ROOT / cfg['DS_B'] / 'obj/Vnds_top')
        for suffix, extra in (('wram', []), ('delayed', ['--mlat', '80', '--mwlat', '56', '--jitter', '11', '--jseed', '7'])):
            rom = 'dmalocal_m7' if suffix == 'delayed' else 'dmalocal'
            cmd = [exe, '--rom', str(ROOT / f'build/ds-tests/{rom}.nds'), '--bios9', str(bios / 'bios9.bin'),
                   '--bios7', str(bios / 'bios7.bin'), '--firmware', str(bios / 'firmware.bin'),
                   '--frames', '120', '--stop-done', '--dma-local-check', '--quiet', *extra]
            rc, log = run(kind + '-' + suffix, cmd, 1800)
            arch = 'result: magic 52545344 checks 3 mask 00000007 done 1' in log
            match = re.search(r'dma-local: steps (\d+) live-during-DMA (\d+): (PASS|FAIL)', log)
            steps, live = (int(match[1]), int(match[2])) if match else (0, 0)
            ok = arch and steps == 4096 and ((rc == 1 and live == 0) if held else (rc == 0 and live >= 8))
            findings.append(dict(test=kind + '-' + suffix, architectural_pass=arch, steps=steps, live=live, pass_=ok))
            print(findings[-1], flush=True)
    unchanged = all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    summary = dict(pass_=unchanged and all(f['pass_'] for f in findings), sources_unchanged=unchanged,
                   parameters=knobs, findings=findings)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return 0 if summary['pass_'] else 1


if __name__ == '__main__':
    sys.exit(main())
