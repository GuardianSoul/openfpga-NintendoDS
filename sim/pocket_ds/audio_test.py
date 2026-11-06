#!/usr/bin/env python3
"""nds_audio_interp test (tb_audio_interp.sv), then planted bugs it must catch."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
SRC = ['rtl/pocket/nds_audio_interp.sv', 'sim/pocket_ds/tb_audio_interp.sv']
MUTANTS = [
    ("out_l <= s_l[26:11];", "out_l <= in_l;"),                               # sample-and-hold again
    ("out_r <= s_r[26:11];", "out_r <= s_r[27:12];"),                       # the sum off by a bit
    ("p_l <= in_l; p_r <= in_r;", "p_r <= in_r;"),                             # previous sample not kept
    ("else if (ph != 12'd2048) ph <= ph + 1'b1;", "else ph <= ph + 1'b1;"),  # phase wraps on a late sample
]


def run(d):
    r = subprocess.run([str(TOOLS / 'verilator'), '--binary', '--timing', '-Wno-fatal', '--top-module', 'tb_audio_interp',
                        '--Mdir', str(d / 'obj'), *[str(d / s) for s in SRC]], capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + r.stderr[-500:]
    out = subprocess.run([str(d / 'obj/Vtb_audio_interp')], capture_output=True, text=True).stdout
    return 'PASS' if 'TEST PASSED' in out else 'FAIL ' + out.strip().splitlines()[0]


def tree(name, old=None, new=None):
    d = ROOT / 'build/audio_interp' / name
    shutil.rmtree(d, ignore_errors=True)
    for s in SRC:
        (d / s).parent.mkdir(parents=True, exist_ok=True)
        t = (ROOT / s).read_text()
        if old and s.endswith('nds_audio_interp.sv'):
            assert t.count(old) == 1, old
            t = t.replace(old, new)
        (d / s).write_text(t)
    return d


def main():
    res = run(tree('ref'))
    print('reference:', res)
    missed = 0 if res == 'PASS' else 1
    for i, (old, new) in enumerate(MUTANTS):
        r = run(tree(f'mut{i}', old, new))
        caught = r.startswith('FAIL')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{new}] {r[:70]}')
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
