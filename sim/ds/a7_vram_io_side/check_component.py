#!/usr/bin/env python3
"""Replay sealed component source/model/state/order/I/O evidence without simulation."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import tarfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('archive', type=Path)
a = p.parse_args()
sha = lambda b: hashlib.sha256(b).hexdigest()
with tarfile.open(a.archive) as t:
    raw = {m.name: t.extractfile(m).read() for m in t if m.isfile()}
manifest = json.loads(raw['manifest.json'])
assert set(raw) == set(manifest) | {'manifest.json'}
for n, v in manifest.items():
    assert len(raw[n]) == v['bytes'] and sha(raw[n]) == v['sha256'], n
s = lambda n: raw[n].decode()
j = lambda n: json.loads(raw[n])
root = 'qualification/'
candidate = raw['source/rtl/ds/nds_fabric.sv']
models = ['before-early1', 'off-early1', 'on-early1', 'wrongowner-early1']
for model in models:
    prefix = root + model + '/'
    record = j(prefix + 'model.json')
    assert sha(raw[prefix + 'obj/Vtb_side']) == record['binary_sha256']
    for n, h in record['inputs'].items():
        rel = n.split('/build/vram-io-side-qual-v1/', 1)[1]
        assert sha(raw[root + rel]) == h, n
    if model != 'before-early1':
        actual = raw[prefix + 'rtl/ds/nds_fabric.sv']
        if model == 'wrongowner-early1':
            needle = b'wire a9_raw_ack = (A7_VRAM_IO_READ_SIDE && v7_ack) || '
            assert actual.count(needle) == 1
            actual = actual.replace(needle, b'wire a9_raw_ack = ')
        assert actual == candidate
assert raw[root + 'off-early1/rtl/ds/nds_arm7_port.sv'] == raw[root + 'before-early1/rtl/ds/nds_arm7_port.sv']
assert raw[root + 'off-early1/rtl/arm/arm7_ds.sv'] == raw[root + 'before-early1/rtl/arm/arm7_ds.sv']
assert b'parameter bit A7_VRAM_IO_READ_SIDE = 0' in candidate
for n in ['rtl/ds/nds_top.sv', 'rtl/pocket/core_top_ds.sv']:
    assert 'parameter bit A7_VRAM_IO_READ_SIDE = 0' in s('source/' + n)
assert '!a7_we' in candidate.decode().split('assign v7_io_read =', 1)[1].split(';', 1)[0]
results = j(root + 'results.json')
assert len(results) == 12
uninterrupted = resets = 0
gains = []
io_reads = 0
ordered_reads = 0
for idx, row in results.items():
    stems = {role: root + f'{int(idx):02d}-{role}-e1' for role in ['before', 'off', 'on']}
    for role, stem in stems.items():
        log = s(stem + '.log')
        assert sha(raw[stem + '.log']) == row['result'][role]['log_sha256']
        assert j(stem + '.process.json')['exit'] == 0 and j(stem + '.process.json')['reaped']
        assert 'PIN_MEMORY errors0/0/0' in log and '%Fatal:' not in log
        match = re.search(r'IO_SERVICE CE(\d+) ACK(\d+) side(\d+) reads(\d+) orphan(\d+) IRQ(\d+)', log)
        assert list(map(int, match.groups())) == row['result'][role]['io']
        pending = None
        for line in s(stem + '.io').splitlines():
            if line.startswith('CE '):
                assert pending is None
                m = re.fullmatch(r'CE (\d+) owner(\d+) cpu(\d) wr(\d) addr([0-9a-f]+) be([0-9a-f]+) wd([0-9a-f]+) expect([0-9a-f]+)', line)
                assert m, line
                pending = m.groups()
            elif line.startswith('ACK '):
                m = re.fullmatch(r'ACK (\d+) owner(\d+) data([0-9a-f]+)', line)
                assert pending is not None and int(m[1]) == int(pending[0]) + 1 and m[2] == pending[1]
                if pending[3] == '0':
                    assert m[3] == pending[7]
                pending = None
            else:
                assert line.startswith('SIDE ') and role == 'on'
        if not row['case'].get('resetmode'):
            assert pending is None
    for ext in ['state', 'data', 'edge', 'mon', 'physical', 'stage', 'ret', 'memstage', 'io']:
        assert raw[stems['before'] + '.' + ext] == raw[stems['off'] + '.' + ext], (idx, ext)
    if row['case'].get('resetmode'):
        for stem in stems.values():
            assert f"PASS_RESET mode{row['case']['resetmode']} physical0 logical0 ownercleared1" in s(stem + '.log')
            assert raw[stem + '.mon'] == raw[stems['before'] + '.mon']
            assert all(l.split()[1].startswith('04') for l in s(stem + '.mon').splitlines())
        resets += 1
        continue
    for ext in ['state', 'data']:
        assert raw[stems['before'] + '.' + ext] == raw[stems['on'] + '.' + ext], (idx, ext)
    for master in ['0 ', '1 ', '2 ', '3 ']:
        rows = lambda role: [l for l in s(stems[role] + '.mon').splitlines() if l.startswith(master)]
        assert rows('before') == rows('on')
    returned = lambda role: re.findall(r'^\d+ ([0-9a-f]+) ([0-9a-f]) ack1 .*data([0-9a-f]+)$', s(stems[role] + '.causal'), re.M)
    assert returned('before') == returned('on')
    ordered_reads += len(returned('on'))
    ends = {}
    for role, stem in stems.items():
        log = s(stem + '.log')
        m = re.search(r'PASS_SIDE CPUend(\d+) states(\d+).*?Gmax(\d+)', log)
        assert m and int(m[2]) == len(s(stem + '.state').splitlines())
        assert int(m[3]) <= 197
        ends[role] = int(m[1])
    gains.append(ends['before'] - ends['on'])
    io_reads += row['result']['on']['io'][3]
    uninterrupted += 1
fault = root + '99-wrongowner-e1'
assert j(root + 'faults.json')['wrongowner']['caught']
assert sha(raw[fault + '.log']) == j(root + 'faults.json')['wrongowner']['log_sha256']
assert j(fault + '.process.json')['exit'] != 0
assert 'wrong-owner ARM9 completion' in s(fault + '.log')
assert (uninterrupted, resets) == (8, 4)
print(json.dumps(dict(status='PASS', triples=12, uninterrupted=uninterrupted, resets=resets,
                     actual_mutations_caught=1, models=4, CPUend_gains_core=gains, enabled_IO_reads=io_reads, ordered_A7_read_returns=ordered_reads,
                     members=len(raw), archive_sha256=sha(a.archive.read_bytes())), indent=2))
