#!/usr/bin/env python3
"""nds_vram alone with randomized traffic (sim/ds/tb_vram.sv), plus the
deliberate bugs in its block pipelining that the test must catch (AGENTS.md).

    sim/ds/vram_test.py [--seeds N] [--blocks B] [--mutate]

The whole-chip checks (screens_test, test-ds) don't catch these: their 2D
fetches and CPU accesses rarely overlap a block still streaming in.
"""
import argparse
import concurrent.futures as cf
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
BUILD = ROOT / 'build/vram_tb'

MUTANTS = [
    # a new block while two are streaming: words of three blocks interleave in the count
    ("(VR_PF && pf_left != 4'd0 ? bw_left == 5'd0 : bw_left <= 5'd8)",
     "1'b1"),
    # CPU access while block words still come: its read takes a block word
    ("else if (bw_left != 5'd0) ;", "else if (1'b0) ;"),
    # an unmapped block's zero beats while a mapped one still streams
    ("end else if (bw_left == 5'd0) st <= S_GZERO;",
     "end else st <= S_GZERO;"),
    # the second block's words counted only once the first is done
    ("bw_left <= bw_left + (bw_acc ? 5'd8 : 5'd0)", "bw_left <= (bw_acc ? 5'd8 : bw_left)"),
]


def build(name, rtl):
    obj = BUILD / name
    env = dict(os.environ, PATH=f'{TOOLS}:{os.environ["PATH"]}')
    r = subprocess.run(['verilator', '--binary', '--timing', '-O2', '-Wno-fatal', '-Wno-WIDTHEXPAND',
                        '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--top-module', 'tb_vram', '--Mdir', str(obj),
                        str(ROOT / 'rtl/gpu2d/gpu2d_pkg.sv'), str(rtl), str(ROOT / 'sim/ds/tb_vram.sv')],
                       env=env, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'{name}: build failed\n{r.stderr[-2000:]}')
    return obj / 'Vtb_vram'


def run(exe, seeds, blocks):
    for s in range(1, seeds + 1):
        result = subprocess.run([str(exe), f'+seed={s}', f'+blocks={blocks}'], capture_output=True, text=True,
                                timeout=600)
        out = result.stdout
        if result.returncode != 0 or 'TEST PASSED' not in out:
            first = next((l for l in out.splitlines() if l.startswith(('ERROR', 'stuck'))), 'failed')
            return f'seed {s}: {first}'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seeds', type=int, default=4)
    ap.add_argument('--blocks', type=int, default=3000)
    ap.add_argument('--mutate', action='store_true')
    a = ap.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    src = ROOT / 'rtl/ds/nds_vram.sv'
    text = src.read_text()
    if a.mutate:
        for old, _ in MUTANTS:
            assert text.count(old) == 1, old
    fail = run(build('ref', src), a.seeds, a.blocks)
    print(f'reference: {"FAIL " + fail if fail else "PASS"}')
    if fail or not a.mutate:
        sys.exit(1 if fail else 0)

    def one(i):
        old, new = MUTANTS[i]
        assert text.count(old) == 1, old
        d = BUILD / f'mut{i}'
        d.mkdir(exist_ok=True)
        (d / 'nds_vram.sv').write_text(text.replace(old, new))
        return run(build(f'mut{i}/obj', d / 'nds_vram.sv'), a.seeds, a.blocks)

    missed = 0
    with cf.ThreadPoolExecutor(4) as ex:
        for i, res in enumerate(ex.map(one, range(len(MUTANTS)))):
            print(f'mutation {i} [{MUTANTS[i][1]}]: {"caught: " + res if res else "MISSED"}')
            missed += res is None
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
