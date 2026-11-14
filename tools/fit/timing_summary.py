#!/usr/bin/env python3
"""Summarise tools/fit/timing_receipt.tcl's timing_receipt.txt for result.txt.

    tools/fit/timing_summary.py timing_receipt.txt [--cones N]

Per clock and analysis (setup, hold): the corner with the lowest TNS, its
WNS, TNS and failing-endpoint count, the worst path's clock relationship
(launch -> latch, requirement), and the N cones with the most negative TNS
in that corner. Lines start with TIMING / TCONE so result.txt readers can
pick them out. Clocks with no failing endpoint in any corner get one line.
"""
import argparse
import re
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('receipt')
    ap.add_argument('--cones', type=int, default=5)
    a = ap.parse_args()
    tot = {}                      # (kind, corner, clock) -> (wns, tns, n, capped)
    worst = {}                    # (kind, corner, clock) -> (req, launch, latch)
    cones = defaultdict(list)     # (kind, corner, clock) -> [(tns, n, cone)]
    for line in open(a.receipt):
        f = line.split()
        if not f:
            continue
        if f[0] in ('SETUP', 'HOLD'):
            m = re.match(r'(\S+) (\S+) (\S+) wns (\S+) tns (\S+) failing (\d+)', line)
            if m:
                wns = None if m[4] == '-' else float(m[4])
                tot[(m[1], m[2], m[3])] = (wns, float(m[5]), int(m[6]), '(capped)' in line)
        elif f[0] == 'WORST':
            m = re.match(r'WORST (\S+) (\S+) (\S+) slack \S+ req (\S+) launch (\S+) latch (\S+)', line)
            if m:
                worst[(m[1], m[2], m[3])] = (m[4], m[5], m[6])
        elif f[0] == 'CONE':
            m = re.match(r'CONE (\S+) (\S+) (\S+) (\S+) tns (\S+) failing (\d+)', line)
            if m:
                cones[(m[1], m[2], m[3])].append((float(m[5]), int(m[6]), m[4]))
    clocks = sorted({(k, c) for k, _, c in tot})
    for kind, clock in clocks:
        rows = [(v, cor) for (k, cor, c), v in tot.items() if k == kind and c == clock]
        (wns, tns, n, capped), corner = min(rows, key=lambda r: (r[0][1], r[0][0] if r[0][0] is not None else 0))
        if n == 0:
            w = min((r[0][0] for r in rows if r[0][0] is not None), default=None)
            print(f'TIMING {kind} {clock}: wns {w if w is not None else "-"} tns 0 failing 0 (all corners)')
            continue
        req, la, lt = worst.get((kind, corner, clock), ('-', '-', '-'))
        print(f'TIMING {kind} {clock} [{corner}]: wns {wns:.3f} tns {tns:.3f} failing {n}{" (capped)" if capped else ""};'
              f' worst {la} -> {lt} req {req}')
        for ct, cn, cone in sorted(cones[(kind, corner, clock)])[:a.cones]:
            print(f'TCONE {kind} {clock} {cone}: tns {ct:.3f} failing {cn}')


if __name__ == '__main__':
    main()
