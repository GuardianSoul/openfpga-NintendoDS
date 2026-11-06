#!/usr/bin/env python3
"""NDSDiag on the Pocket model: the log read back at quit against the testbench's mirror (docs/diag.md).

    diag_check.py RUN.LOG LOG.ndg [--min-frames N]

RUN.LOG is a DIAG=1 run's output (run.py --core-param DIAG=1 --diag-out LOG.ndg): its "diagmon F c0 .. c48 |
v .." lines count the recorder's taps by name at each frame pulse. The log's frame records hold the same
events' accumulators, each sampled a fixed number of clocks (its scanner offset, under 64) after the pulse, so
a frame's total in the log is the mirror's over a window shifted by under 64 clk_sys clocks: one-bit events
may differ by at most 2 x 64, the clk_mem counts (crossed through nds_diag_xmem) by 2 x 64 x 3 + 16. The
cumulative counts must also agree within that at the last record (no drift), the values (DS frames,
polygons/vertices, underruns, GX entries) must equal the mirror's at that frame or a neighbour (the record copies them when it is written), and the
late-2D line histogram's total must equal the mirror's late lines at the last dump. Exits 1 on any mismatch.
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/ds'))
from diag_log import Log, EVENTS  # noqa: E402

NE1 = 42


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('run_log')
    ap.add_argument('ndg')
    ap.add_argument('--min-frames', type=int, default=4)
    a = ap.parse_args()
    mon = {}
    for l in open(a.run_log, errors='replace'):
        m = re.match(r'diagmon (\d+) ([\d ]+) \| (\d+) (\d+) (\d+) (\d+) late2d (\d+)', l)
        if m:
            c = [int(x) for x in m.group(2).split()]
            mon[int(m.group(1))] = (c, [int(m.group(i)) for i in range(3, 8)])
    lg = Log(a.ndg)
    recs = lg.frame_recs
    bad = 0
    print(f'{a.ndg}: {lg.ne} events, config {lg.config:08x}, {lg.frames} frames, {lg.seconds} seconds; '
          f'{len(recs)} frame records read back; mirror {len(mon)} frames')
    NT = len(EVENTS)
    if lg.ne != NT:
        print(f'FAIL: {lg.ne} events in the header, expected {NT}'); sys.exit(1)
    if len(recs) < a.min_frames:
        print(f'FAIL: {len(recs)} frame records (at least {a.min_frames})'); sys.exit(1)

    def tol(i):
        return 128 if i < NE1 else 2 * 64 * 3 + 16

    # the record numbered F is taken at frame pulse F (k: the mirror's numbering offset, found once)
    def err(k):
        e = 0
        for r in recs:
            f = r[0] + k
            if f in mon:
                e += sum(abs(r[1 + i] - mon[f][0][i]) for i in range(NT))
            else:
                e += 10 ** 9
        return e
    k = min(range(-2, 3), key=err)
    print(f'record F ~ mirror frame F{k:+d}')
    active = [0] * NT
    for ra, rb in zip(recs, recs[1:]):
        fa, fb = ra[0] + k, rb[0] + k
        if fa not in mon or fb not in mon:
            continue
        for i in range(NT):
            dl = (rb[1 + i] - ra[1 + i]) & 0xFFFFFFFF
            dm = mon[fb][0][i] - mon[fa][0][i]
            if dm:
                active[i] += 1
            if abs(dl - dm) > tol(i):
                bad += 1
                if bad <= 20:
                    print(f'  frames {fa}-{fb} {EVENTS[i]} ({i}): log {dl}, mirror {dm}')
    # no drift: first to last record (the mirror also counts during the recorder's reset, so not from 0)
    first, last = recs[0], recs[-1]
    f0, fl = first[0] + k, last[0] + k
    for i in range(NT):
        dl, dm = (last[1 + i] - first[1 + i]) & 0xFFFFFFFF, mon[fl][0][i] - mon[f0][0][i]
        if abs(dl - dm) > tol(i):
            bad += 1
            print(f'  frames {f0}-{fl} in all: {EVENTS[i]} ({i}): log {dl}, mirror {dm}')
    # values: word 1 {polygons, vertices}, 2 {GX entries, wfifo}, 3 {BG busy, underruns}, 4 DS frames
    for r in recs:
        f = r[0] + k
        cand = [mon[g][1] for g in (f, f + 1, f - 1) if g in mon]
        v = r[1 + NT:1 + NT + 6]
        ok = any(v[4] == c[0] and v[1] == c[1] and (v[3] & 0xFFFF) == (c[2] & 0xFFFF) and (v[2] >> 16) == c[3]
                 for c in cand)
        if cand and not ok:
            bad += 1
            if bad <= 30:
                print(f'  values at frame {f}: log ds {v[4]} gval {v[1]:08x} und {v[3] & 0xFFFF} used {v[2] >> 16}; '
                      f'mirror {cand}')
    l2d = sum(lg.lines[1]) if lg.nl > 1 else 0
    seen = [m[1][4] for m in mon.values()]
    if lg.seconds and l2d not in seen:
        bad += 1
        print(f'  late-2D line histogram total {l2d} is no mirror count ({sorted(set(seen))[:8]} ..)')
    quiet = [EVENTS[i] for i in range(NT) if not active[i]]
    print(f'events seen: {NT - len(quiet)}/{NT}; never active: {" ".join(quiet)}')
    print(f'histogram totals: {[sum(h) for h in lg.hist]}, late lines {[sum(x) for x in lg.lines]}')
    print('PASS' if not bad else f'FAIL: {bad} mismatches')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
