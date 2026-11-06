#!/usr/bin/env python3
"""Flag memories that Quartus implemented as logic (nds-fit #357/#362).

    tools/fit/ramcheck.py FIT_RPT [--rtl DIR] [--min-alms N]

A module that declares an array with a `ramstyle` attribute is meant to
become RAM (MLAB or M10K). In the fit report's "Fitter Resource Utilization
by Entity" table, every instance of such a module should then use memory
ALMs (MLAB) or block memory bits (M10K). An instance that uses neither but
takes ALMs was built from registers and LUTs instead: gpu2d_mlab_be's
per-byte-write array became 205 ALMs of logic that way, which neither
Verilator nor the Yosys proxy showed. Exit 1 if anything is flagged.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def ram_modules(rtl):
    mods = set()
    for f in Path(rtl).rglob('*.sv'):
        cur = None
        for line in f.read_text(errors='replace').splitlines():
            code = line.split('//')[0]
            m = re.match(r'\s*module\s+(\w+)', code)
            if m:
                cur = m.group(1)
            m2 = re.search(r'\(\*\s*ramstyle\s*=\s*"([^"]*)"', code)
            if cur and m2 and 'logic' not in m2.group(1).lower():     # "logic" asks for flops on purpose
                mods.add(cur)
            if re.match(r'\s*endmodule\b', code):
                cur = None
    return mods


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rpt')
    ap.add_argument('--rtl', default=str(ROOT / 'rtl'))
    ap.add_argument('--min-alms', type=float, default=4.0)
    a = ap.parse_args()
    mods = ram_modules(a.rtl)
    text = Path(a.rpt).read_text(errors='replace').splitlines()
    try:
        start = next(i for i, l in enumerate(text) if l.startswith('; Fitter Resource Utilization by Entity'))
    except StopIteration:
        print('no "Fitter Resource Utilization by Entity" table in', a.rpt)
        return 2
    head = None
    bad = 0
    checked = 0
    for line in text[start:]:
        if not line.startswith(';'):
            if head and line.startswith('+'):
                continue
            if head:
                break
            continue
        cols = [c.strip() for c in line.strip().strip(';').split(';')]
        if head is None:
            if cols and cols[0].startswith('Compilation Hierarchy Node'):
                head = cols
            continue
        node = cols[0].lstrip('|').rstrip('|')
        m = re.match(r'(\w+):([\w.\[\]]+)$', node.split('|')[-1] if '|' in node else node)
        if not m or m.group(1) not in mods:
            continue

        def num(name):
            k = next(i for i, h in enumerate(head) if h.startswith(name))
            return float(cols[k].split()[0].replace(',', ''))
        alms, mem_alms, bits = num('ALMs needed'), num('ALMs used for memory'), num('Block Memory Bits')
        checked += 1
        if mem_alms == 0 and bits == 0 and alms >= a.min_alms:
            print(f'{m.group(1)}:{m.group(2)}: {alms:.1f} ALMs, no MLAB and no block memory: built as logic')
            bad += 1
    print(f'ramcheck: {checked} RAM-module instances checked, {bad} built as logic')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
