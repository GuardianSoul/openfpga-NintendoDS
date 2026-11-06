#!/usr/bin/env python3
"""nds_controls with its A/B/X/Y in Touch Mode at the defaults against the
version before the gestures (tb_controls_eq.sv), then a planted bug it must
catch.

    sim/pocket_ds/controls_eq.py [OLD_REV]     (default 11be2ed7, before the gestures)
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
SRCS = ['rtl/pocket/nds_cdc.sv', 'rtl/pocket/psx_pocket_pad_combo.sv', 'rtl/pocket/nds_controls.sv',
        'sim/pocket_ds/tb_controls_eq.sv']
MUTANTS = [
    # B/X/Y held back from the game in touch mode although they are Button
    ('rtl/pocket/nds_controls.sv', "assign g_on[gi] = gest[3 * gi +: 3] != 3'd0;", "assign g_on[gi] = 1'b1;"),
]


def run(d):
    obj = d / 'obj'
    cmd = [str(TOOLS / 'verilator'), '--binary', '--timing', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
           '--top-module', 'tb_controls_eq', '--Mdir', str(obj), *[str(d / s) for s in SRCS], str(d / 'old.sv')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + (r.stdout + r.stderr)[-800:]
    r = subprocess.run([str(obj / 'Vtb_controls_eq')], capture_output=True, text=True)
    print('   ', next((l for l in r.stdout.splitlines() if 'cycles' in l), ''))
    return 'PASS' if 'EQUIVALENT' in r.stdout and 'NOT' not in r.stdout else 'FAIL: ' + r.stdout.strip().splitlines()[0]


def tree(name, old):
    d = ROOT / 'build/controls_eq' / name
    shutil.rmtree(d, ignore_errors=True)
    for s in SRCS:
        (d / s).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / s, d / s)
    (d / 'old.sv').write_text(old)
    return d


def main():
    rev = sys.argv[1] if len(sys.argv) > 1 else '11be2ed7'
    old = subprocess.run(['git', '-C', str(ROOT), 'show', f'{rev}:rtl/pocket/nds_controls.sv'],
                         capture_output=True, text=True, check=True).stdout
    old = old.replace('module nds_controls (', 'module nds_controls_old (')
    res = run(tree('ref', old))
    print('reference:', res)
    if res != 'PASS':
        sys.exit(1)
    missed = 0
    for i, (f, o, n) in enumerate(MUTANTS):
        d = tree(f'mut{i}', old)
        s = (d / f).read_text()
        assert s.count(o) == 1, o
        (d / f).write_text(s.replace(o, n))
        res = run(d)
        caught = res.startswith('FAIL')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{n[:60]}] {res[:100]}')
    shutil.rmtree(ROOT / 'build/controls_eq', ignore_errors=True)
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
