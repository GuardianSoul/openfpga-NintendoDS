#!/usr/bin/env python3
"""Finite joint IF observation sets. Times are actual F/1 anchor ticks.

No instruction-price subtraction. One common IF propagation delay is absorbed
in phase. An unknown *different* delay per bank would be indistinguishable
from a prescaler phase offset and is explicitly outside the two hypotheses.
"""
import json

PERIOD = 64


def outcomes(phase, offset, clear_before, clear_after, read_before, read_after):
    """All joint sticky-IF outcomes for all integer clear/read sample times.

    Inclusive endpoints deliberately admit simultaneous anchor/IO events;
    both clear-before-overflow and clear-after-overflow ties are retained.
    The IF word transaction samples both banks together.
    """
    result = set()
    for clear in range(clear_before, clear_after + 1):
        for sample in range(read_before, read_after + 1):
            for clear_tie in (0, 1):
                for sample_tie in (0, 1):
                    lo, hi = clear + clear_tie, sample - sample_tie
                    if hi < lo:
                        result.add(0)
                        continue
                    bits = 0
                    for bank, edge in enumerate((phase, phase + offset)):
                        first = lo + (edge - lo) % PERIOD
                        if first <= hi:
                            bits |= 1 << bank
                    result.add(bits)
    return result


def candidates(rows):
    answer = {}
    for offset in (0, 10, -10):
        live = list(range(PERIOD))
        for r in rows:
            live = [p for p in live if r['bits'] in outcomes(p, offset, *r['bounds'])]
        answer[str(offset)] = live
    return answer


def enumerate_bounds(bounds):
    sets = {d: [[outcomes(p, d, *b) for b in bounds]
                for p in range(PERIOD)] for d in (0, 10, -10)}
    intersections = {}
    for d in (10, -10):
        # Full Cartesian observation vectors are represented as products of
        # per-row finite sets; two products overlap iff every row overlaps.
        pairs = [(a, b) for a in range(PERIOD) for b in range(PERIOD)
                 if all(x & y for x, y in zip(sets[0][a], sets[d][b]))]
        intersections[str(d)] = pairs
    return dict(period=64, phases_per_hypothesis=64, offsets=[0, 10, -10],
                enable_edge_carries=[0, 64], carry_scope='startup only; wait >=512 F/1 ticks before clearing/sampling',
                bounds=bounds, observation_sets={str(d): [[sorted(s) for s in v] for v in a] for d, a in sets.items()},
                common_vs_offset_intersections=intersections,
                scope='observable joint IF edge phase; no arbitrary independent per-bank IF delay')


def enumerate_design():
    # This is a schedule precondition, not a promised DS instruction cost.
    # Every actual capture is reclassified from its own returned bounds.
    result = enumerate_bounds([(i, i + 6, i + 9, i + 15) for i in range(PERIOD)])
    assert not any(result['common_vs_offset_intersections'].values()), 'proposed schedule does not discriminate'
    return result


if __name__ == '__main__':
    print(json.dumps(enumerate_design(), separators=(',', ':')))
