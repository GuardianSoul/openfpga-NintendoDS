#!/usr/bin/env python3
"""nds_vram's posted writes with the card's settings (sim/ds/tb_vram_wb.sv) at VR_WBQ 0 and the queue depths given,
plus deliberate bugs in the write queue that the test must catch (AGENTS.md).

    sim/ds/vram_wb_test.py [--seeds N] [--units U] [--wbq 0,4] [--mutate]

Prints each depth's write-unit clocks (request to ack) and run length, so the queue's effect is measured on the
same traffic (same seed: the same random stream until the timing differs).
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
BUILD = ROOT / 'build/vram_wb_tb'

MUTANTS = [   # (with VR_WBQ 4)
    # the queue's read pointer never moves: the buffer refills with the same queued word
    ("            if (wb_pop && wq_n != '0) wq_rd <= wq_rd + 1'b1;\n", ""),
    # the buffer empties when its word leaves although words are queued: they are never posted
    ("        end else if (VR_WBQ != 0 && wb_pop && wq_n != '0) {wb_view, wb_off, wb_d, wb_he} <= wq_q;\n",
     "        end else if (VR_WBQ != 0 && wb_pop && wq_n != '0) wb_v <= 1'b0;\n"),
    # a write is taken into a full queue (it overwrites the oldest queued word)
    ("wire         wb_room = !wb_v || (VR_WBQ != 0 && wq_n != (QW+1)'(VR_WBQ));", "wire         wb_room = !wb_v || VR_WBQ != 0;"),
]
MUTANTS_HPAIR = [   # (with VR_WBQ 4 and --hpair)
    # the pair's halves taken from the wrong writes (the staged half's high half always)
    ("hp_he[1] ? hp_d : c_wdata[31:16]", "c_wdata[31:16]"),
    # a write of the other half of a different word merges too
    ("&& c_view == hp_view && c_off[19:2] == hp_off;", ";"),
    # reads do not wait for the staged half
    ("                else if (VR_HPAIR && hp_v) ;                              // reads and the rest wait for the staged half\n", ""),
]
DEFINES = []


def build(name, rtl, wbq):
    obj = BUILD / name
    env = dict(os.environ, PATH=f'{TOOLS}:{os.environ["PATH"]}')
    r = subprocess.run(['verilator', '--binary', '--timing', '-O2', '-j', '4', '-Wno-fatal', '-Wno-WIDTHEXPAND',
                        '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', f'+define+TB_WBQ={wbq}', *[f'+define+{d}' for d in DEFINES], '--top-module', 'tb_vram_wb',
                        '--Mdir', str(obj), str(ROOT / 'rtl/gpu2d/gpu2d_pkg.sv'), str(rtl), str(ROOT / 'sim/ds/tb_vram_wb.sv')],
                       env=env, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'{name}: build failed\n{r.stderr[-2000:]}')
    return obj / 'Vtb_vram_wb'


def run(exe, seeds, units):
    stats = []
    for s in range(1, seeds + 1):
        out = subprocess.run([str(exe), f'+seed={s}', f'+units={units}'], capture_output=True, text=True,
                             timeout=900).stdout
        if 'TEST PASSED' not in out:
            first = next((l for l in out.splitlines() if l.startswith(('ERROR', 'stuck'))), 'failed')
            return f'seed {s}: {first}', stats
        m = re.search(r'writes (\d+), ([\d.]+) clk request to ack\), posts (\d+), clocks (\d+)', out)
        p = re.search(r'pairs merged (\d+)', out)
        stats.append((int(m.group(1)), float(m.group(2)), int(m.group(4)), int(m.group(3)), int(p.group(1)) if p else 0))
    return None, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seeds', type=int, default=4)
    ap.add_argument('--units', type=int, default=20000)
    ap.add_argument('--wbq', default='0,4')
    ap.add_argument('--mutate', action='store_true')
    ap.add_argument('--hpair', action='store_true', help='VR_HPAIR 1 (tb TB_HPAIR) and its mutants')
    a = ap.parse_args()
    global BUILD
    if a.hpair:
        DEFINES.append('TB_HPAIR'); MUTANTS[:] = MUTANTS_HPAIR; BUILD = BUILD.with_name(BUILD.name + '-hpair')
    BUILD.mkdir(parents=True, exist_ok=True)
    src = ROOT / 'rtl/ds/nds_vram.sv'
    bad = False
    for q in [int(x) for x in a.wbq.split(',')]:
        fail, st = run(build(f'q{q}', src, q), a.seeds, a.units)
        if fail:
            bad = True
            print(f'VR_WBQ {q}: FAIL {fail}')
        else:
            print(f'VR_WBQ {q}: PASS; write unit {sum(x[1] for x in st) / len(st):.2f} clk request to ack, '
                  f'run {sum(x[2] for x in st) / len(st):.0f} clocks, posts {sum(x[3] for x in st) / len(st):.0f}, pairs merged {sum(x[4] for x in st) / len(st):.0f} ({len(st)} seeds)')
    if bad or not a.mutate:
        sys.exit(1 if bad else 0)
    text = src.read_text()
    missed = 0
    for i, (old, new) in enumerate(MUTANTS):
        assert text.count(old) == 1, old
        d = BUILD / f'mut{i}'
        d.mkdir(exist_ok=True)
        (d / 'nds_vram.sv').write_text(text.replace(old, new))
        fail, _ = run(build(f'mut{i}/obj', d / 'nds_vram.sv', 4), a.seeds, a.units)
        print(f'mutant {i}: {"caught (" + fail + ")" if fail else "MISSED"}')
        missed += fail is None
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
