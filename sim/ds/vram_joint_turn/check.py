#!/usr/bin/env python3
"""Replay the sealed joint read-side/write-turn component; no simulation."""
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
s = lambda n: raw[n].decode()
j = lambda n: json.loads(raw[n])
manifest = j('manifest.json')
assert set(raw) == set(manifest) | {'manifest.json'}
for n, v in manifest.items():
    assert len(raw[n]) == v['bytes'] and sha(raw[n]) == v['sha256'], n
source = 'c445c240e4138f347ea256d98f9f20e3eca68e50'
transport = '91e199821ba08799b8b1f6eb398ed62d3830aaef2e8463412ac6723d4b9e6df2'
prior = j('qualification/prior-proof.json')
assert prior['triples'] == 27 and prior['production']['rtl/pocket/nds_sdram_bus.sv'] == transport
for role in ['before', 'off', 'on', 'payload-mutant']:
    root = 'qualification/' + role + '/'
    model = j(root + 'model.json')
    assert model['source'] == source and model['read_side'] == model['IO_read_side'] == model['VRAM_owned_ACK'] == 1
    assert sha(raw[root + 'obj/Vtb_side']) == model['binary_sha256']
    for n, h in model['inputs'].items():
        rel = n.split('/build/vram-joint-c445-v1/', 1)[1]
        assert sha(raw['qualification/' + rel]) == h, n
    b = raw[root + 'rtl/pocket/nds_sdram_bus.sv']
    if role == 'payload-mutant':
        needle = b"b_wdata <= cut_turn ? (s_wdata ^ 32'd1) : s_wdata;"
        assert b.count(needle) == 1
        b = b.replace(needle, b'b_wdata <= s_wdata;')
    assert sha(b) == transport
    for n in model['inputs']:
        rel = n.split('/' + role + '/', 1)[1]
        if role != 'payload-mutant' or rel != 'rtl/pocket/nds_sdram_bus.sv':
            assert raw[root + rel] == raw['qualification/before/' + rel], (role, rel)
results = j('qualification/results.json')
assert len(results) == 12
states = reads = writes = full = resets = 0
gains = []
max_wait = 0
for idx, case in results.items():
    stems = {r: f'qualification/{int(idx):02d}-{r}' for r in ['before', 'off', 'on']}
    endpoints = {}
    for role, stem in stems.items():
        log = s(stem + '.log')
        assert sha(raw[stem + '.log']) == case['result'][role]['log_sha256']
        assert 'PIN_MEMORY errors0/0/0' in log and '%Fatal:' not in log
        receipt = j(stem + '.process.json')
        assert receipt['exit'] == 0 and receipt['reaped'] and receipt['NI'] == 10
        counts = list(map(int, re.search(r'JOINT_TURN pending(\d+) performed(\d+) captured(\d+) physical(\d+) remaining(\d+)', log).groups()))
        assert counts == case['result'][role]['turn'] and counts[2] == counts[3] and counts[4] == 0
        if role != 'on':
            assert counts[1] == 0
        captured = re.findall(r'^CAPTURE (\d+) addr([0-9a-f]+) be([0-9a-f]+) data([0-9a-f]+) turn(\d)$', s(stem + '.turn'), re.M)
        assert len(captured) == counts[2] and all(int(x[4]) in [0, 1] for x in captured)
        actual = re.findall(r'^VRAM ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+)$', s(stem + '.physical'), re.M)
        actual = [(addr, be, data) for addr, data, be in actual if 0x10040 <= int(addr, 16) < 0x10060]
        assert actual == [(addr, be, data) for clock, addr, be, data, turn in captured]
        if case['case'].get('resetmode'):
            assert 'PASS_RESET mode' + str(case['case']['resetmode']) in log
        else:
            match = re.search(r'PASS_SIDE CPUend(\d+) states(\d+) writes(\d+).*?Gmax(\d+)', log)
            assert match and int(match[2]) == len(s(stem + '.state').splitlines())
            assert int(match[4]) <= 197
            endpoints[role] = list(map(int, match.groups()))
    for ext in ['state','data','edge','mon','physical','stage','ret','memstage','io','causal','turn']:
        assert raw[stems['before'] + '.' + ext] == raw[stems['off'] + '.' + ext], (idx, ext)
    if case['case'].get('resetmode'):
        resets += 1
        if case['case']['resetmode'] == 3:
            assert all(v['turn'][2] == 0 for v in case['result'].values())
        else:
            assert case['result']['before']['turn'][2] == case['result']['off']['turn'][2] == 35
            assert case['result']['on']['turn'][2] == 36
        continue
    for ext in ['state', 'data']:
        assert raw[stems['before'] + '.' + ext] == raw[stems['on'] + '.' + ext]
    for ext, prefixes in [('mon', ['0 ', '1 ', '2 ', '3 ']), ('physical', ['CAP ', 'VRAM ', 'MAIN '])]:
        for prefix in prefixes:
            rows = lambda r: [l for l in s(stems[r] + '.' + ext).splitlines() if l.startswith(prefix)]
            assert rows('before') == rows('on'), (idx, ext, prefix)
    returned = lambda r: re.findall(r'^\d+ ([0-9a-f]+) ([0-9a-f]) ack1 .*data([0-9a-f]+)$', s(stems[r] + '.causal'), re.M)
    assert returned('before') == returned('on')
    reads += len(returned('on'))
    states += endpoints['on'][1]
    writes += endpoints['on'][2]
    gains.append(endpoints['before'][0] - endpoints['on'][0])
    max_wait = max(max_wait, endpoints['on'][3])
    full += 1
fault = j('qualification/fault.json')
assert fault['caught'] and sha(raw['qualification/99-payload-mutant.log']) == fault['log_sha256']
assert 'physical CPU descriptor data/order changed' in s('qualification/99-payload-mutant.log')
assert j('qualification/99-payload-mutant.process.json')['exit'] != 0
assert (full, resets, states, reads, writes, max_wait) == (10, 2, 19500, 3011, 3412, 31)
print(json.dumps(dict(status='PASS', source=source, archive_sha256=sha(a.archive.read_bytes()),
    triples=12, uninterrupted=full, resets=resets, state_rows=states, ordered_VRAM_read_returns=reads,
    ordered_CPU_physical_writes=writes, maximum_2D_wait=max_wait, fixed_2D_deadline=197,
    CPUend_gains_core=gains, models=4, actual_payload_mutation_caught=True,
    reset_accepted_prefix={'before_off':35,'joint_on':36}, prior27=prior['artifact']['sha256']), indent=2))
