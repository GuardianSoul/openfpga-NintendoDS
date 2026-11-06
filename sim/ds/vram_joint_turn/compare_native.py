#!/usr/bin/env python3
"""Retain every original53 native/DS timing sample and exact slope comparison."""
import argparse
from collections import Counter
import csv
from fractions import Fraction
import hashlib
import json
from pathlib import Path


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def groups(path):
    result = {}
    with path.open(newline='') as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 636, (path, len(rows))
    for row in rows:
        key = row['case'], int(row['offset_bytes'])
        g = result.setdefault(key, {'words': int(row['words']), 'lengths': {}})
        assert g['words'] == int(row['words'])
        samples = g['lengths'].setdefault(int(row['blocks']), {})
        rep = int(row['rep'])
        assert rep not in samples
        samples[rep] = int(row['ticks'])
    assert len(result) == 53
    for g in result.values():
        assert set(g['lengths']) == {256, 1024}
        assert all(set(s) == {-1, 0, 1, 2, 3, 4} for s in g['lengths'].values())
    return result


def observation(group):
    lengths = []
    for blocks, reps in sorted(group['lengths'].items()):
        samples = [reps[r] for r in range(5)]
        lengths.append(dict(blocks=blocks, warm=reps[-1], samples=samples,
                            min=min(samples), max=max(samples), span=max(samples)-min(samples)))
    slope = Fraction(lengths[1]['min'] - lengths[0]['min'], 768)
    paired = [Fraction(group['lengths'][1024][r]-group['lengths'][256][r], 768) for r in range(5)]
    return dict(lengths=lengths, slope_fraction=str(slope), cycles_per_block=float(slope),
                paired_rep_slopes=[float(x) for x in paired],
                observed_envelope=[float(Fraction(lengths[1]['min']-lengths[0]['max'],768)),
                                   float(Fraction(lengths[1]['max']-lengths[0]['min'],768))])


def compare(native, ds):
    n, d = groups(native), groups(ds)
    assert n.keys() == d.keys()
    rows = []
    for (case, offset), group in n.items():
        assert group['words'] == d[case, offset]['words']
        nn, dd = observation(group), observation(d[case, offset])
        ns, dslope = Fraction(nn['slope_fraction']), Fraction(dd['slope_fraction'])
        status = 'equal' if ns == dslope else 'below_DS' if ns < dslope else 'above_DS'
        rows.append(dict(case=case, offset_bytes=offset, words=group['words'], native=nn, DS=dd,
                         native_minus_DS_fraction=str(ns-dslope), status=status))
    return dict(native_csv_sha256=digest(native), DS_csv_sha256=digest(ds), rows=rows,
                counts=dict(Counter(r['status'] for r in rows)),
                clock='33513982 Hz timer/system ticks; two ARM9 clocks per tick',
                method='(minimum1024 - minimum256)/768; warmup excluded; all five samples retained',
                precision='Exact rational timer-tick slopes; envelope spans all short/long measured sample combinations, as retained DS audit. Paired slopes also retained. Neither range is a confidence interval or acceptance margin',
                scope='All53 original forms; numeric comparison only. Functional/capture PASS does not accept timing, dynamic ownership or DS/native context equality.')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('native', type=Path)
    p.add_argument('ds', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    result = compare(a.native, a.ds)
    a.output.write_text(json.dumps(result, indent=2)+'\n')
    with a.output.with_suffix('.csv').open('w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['case', 'offset_bytes', 'words', 'native_SYS_per_block', 'DS_SYS_per_block', 'native_minus_DS_exact', 'DS_observed_low', 'DS_observed_high', 'status'])
        for r in result['rows']:
            w.writerow([r['case'], r['offset_bytes'], r['words'], r['native']['slope_fraction'], r['DS']['slope_fraction'], r['native_minus_DS_fraction'], *r['DS']['observed_envelope'], r['status']])
    print(json.dumps(result['counts']))


if __name__ == '__main__':
    main()
