#!/usr/bin/env python3
"""Attribute the rejected witness's residual from existing saved edges only."""
from pathlib import Path
from collections import Counter
import argparse, csv, hashlib, json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('base', type=Path)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
sha = lambda b: hashlib.sha256(b).hexdigest()
result = json.loads((a.base/'results.json').read_text())
inputs = {'results.json': sha((a.base/'results.json').read_bytes())}
for name, digest in result['fixture_SHA256'].items():
    assert sha((a.base/'source'/name).read_bytes()) == digest, name
def read(name):
    b = (a.base/name).read_bytes()
    inputs[name] = sha(b)
    return b.decode().splitlines()
def hist(values): return dict(sorted(Counter(values).items()))
rows = []
for case in range(3):
    for n in [4, 16]:
        for suffix in ['state', 'data']:
            lanes = [read(f'k1-c{case}-r1-p{policy}-n{n}.{suffix}') for policy in [0, 1]]
            assert [[l.split(',', 1)[1] for l in v] for v in lanes][0] == [[l.split(',', 1)[1] for l in v] for v in lanes][1]
    prefix = f'k1-c{case}-r1-p1-n16'
    edges = list(csv.DictReader(read(prefix+'.edge')))
    state = [v.split(',') for v in read(prefix+'.state')]
    retires = [(int(v[0]), int(v[1], 16)) for v in state]
    first = [t for t, pc in retires if pc == 0x02fcd004]
    last = [t for t, pc in retires if pc == 0x02fcd100]
    assert len(first) == len(last) == 16
    # Follow each original E-owned F from its first offer through consumption.
    owned = None
    windows = []
    for r in edges:
        t = int(r['cycle'])
        if owned is None and r['ir'] == '1' and r['e_mul'] == '1':
            owned = (t, r['pc'], r['ia'])
            assert int(r['ia'], 16) == int(r['pc'], 16)+8
        if owned:
            assert (r['pc'], r['ia']) == owned[1:], (case, t, 'owner changed')
            assert r['redirect'] == '0'
            if r['consume'] == '1':
                assert r['ph'] == '1' and r['io'] == '1'
                windows.append(t-owned[0])
                owned = None
    assert owned is None and len(windows) == 1024
    boundaries = []
    for i in range(15):
        span = [r for r in edges if last[i] <= int(r['cycle']) < first[i+1]
                and r['pc'] == '02fcd108' and r['ia'] == '02fcd004']
        offer = next(r for r in span if r['ir'] == '1' and r['iseq'] == '0')
        logical = next(r for r in span if r['flow_v'] == '1' and r['flow_left'] == '0')
        consumed = next(r for r in span if r['consume'] == '1')
        physical = next(r for r in span if r['fr'] == '1' and r['fa'] == '02fcd000')
        word0 = next(r for r in span if r['rv'] == '1' and r['fq'] == 'e3a01003')
        critical = next(r for r in span if r['rv'] == '1' and r['fq'] == 'e0030291')
        assert offer['fr'] == '0', 'old packet still occupies launch edge'
        assert int(physical['cycle']) == int(offer['cycle'])+1
        assert critical['cycle'] == consumed['cycle'] and consumed['iq'] == critical['fq']
        assert int(consumed['cycle'])-int(logical['cycle']) == 2
        boundaries.append(dict(last_MUL_retire=last[i], next_first_MUL_retire=first[i+1],
                               N_offer=int(offer['cycle']), packet_request=int(physical['cycle']),
                               logical_wait_done=int(logical['cycle']), word0=int(word0['cycle']),
                               critical_word=int(critical['cycle']), consume=int(consumed['cycle'])))
    row = result['cases'][f'1-{case}-1']
    stride = [first[i+1]-first[i] for i in range(15)]
    # Finite body-local witness: 64 ops at9/10, or32 of each, with32SYS loop work.
    op_sum = [64*18, 64*20, 32*(18+20)][case]
    assert set(stride) == {op_sum+32}
    assert row['policies']['1']['slope']-row['DS'] == 1/64
    rows.append(dict(case_id=case, local_MUL_offer_to_consume_SYS=hist(windows),
                     loop_stride_SYS=hist(stride), loop_residual_SYS=32,
                     DS_finite_loop_residual_A7=15, candidate_finite_loop_residual_A7=16,
                     boundary_count=len(boundaries), boundaries=boundaries,
                     candidate_slope=row['policies']['1']['slope'], DS_slope=row['DS']))
output = dict(status='REJECTED timing witness; no production enable', source=result['source'],
              model_SHA256=result['model_SHA256'], rows=rows, inputs=inputs,
              conclusion='45 taken-loop N refills: packet idle at new offer, launch next SYS, wait done two SYS before actual critical word, consume on that same word. No post-ready CPU bubble or old-tail delay; TURN cannot fix these intervals. The nine-cycle local counter has no demonstrated DS service implementation and remains test-only.',
              remaining='Source-backed prepare/commit/finish service and contention/non-MUL checks; exact-image native guest ready separately. No blanket I-to-N, PC-specific exception, padding or subtraction.')
a.out.write_text(json.dumps(output, indent=2)+'\n')
print(output['status'], '45 boundaries; exact state/data sequences retained')
