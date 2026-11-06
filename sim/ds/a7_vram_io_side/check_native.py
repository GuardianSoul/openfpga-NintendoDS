#!/usr/bin/env python3
"""Offline replay of changed-source originalDS30 and canonical ARM7 evidence."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import re
import sys
import tarfile
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('archive', type=Path)
a = p.parse_args()
sha = lambda b: hashlib.sha256(b).hexdigest()
with tarfile.open(a.archive) as t:
    raw = {m.name: t.extractfile(m).read() for m in t if m.isfile()}
j = lambda n: json.loads(raw[n])
manifest = j('packet-manifest.json')
assert set(raw) == set(manifest) | {'packet-manifest.json'}
for n, v in manifest.items():
    assert len(raw[n]) == v['bytes'] and sha(raw[n]) == v['sha256'], n
source = j('actual/source-manifest.json')
before = j('actual/donor-source-manifest.json')
assert source['source'] == '00ef4ef98981dc64b9a8e33deb99b5f04b2e3388'
assert before['source'] == '2f86d1e69b0fc477d179375315acdefc1b438a68'
delta = j('actual/source-delta.json')
assert len(source['files']) == 1190 and set(source['files']) == set(before['files'])
assert {n for n in source['files'] if source['files'][n] != before['files'][n]} == set(delta)
assert set(delta) == {'rtl/ds/nds_fabric.sv', 'rtl/ds/nds_top.sv', 'rtl/pocket/core_top_ds.sv'}
for n in manifest:
    if n.startswith('source/'):
        assert sha(raw[n]) == source['files'][n.removeprefix('source/')], n
for n, d in delta.items():
    assert d == dict(before=before['files'][n], after=source['files'][n])
profile = j('actual/profile.json')
assert profile == dict(j('actual/control-manifest.json')['profile'], A7_VRAM_IO_READ_SIDE=1)
assert len(profile) == 59
model = j('actual/model.json')
assert model['source'] == source['source'] and model['profile'] == profile
assert sha(raw['model/Vtb_ds_pocket']) == model['sha256']
assert sha(raw['prepared/arm7-ds30.nds']) == '5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e'
assert sha(raw['unita7.nds']) == j('actual/unita7-control-manifest.json')['rom_sha256']
for n in ['manifest.json', 'unita7-manifest.json']:
    receipt = j('actual/' + n)
    assert receipt['source'] == source['source'] and receipt['model_sha256'] == model['sha256']
    assert receipt['profile'] == profile
assert j('actual/manifest.json')['expanded_sha256'] == j('actual/control-manifest.json')['expanded_sha256']
assert j('actual/unita7-manifest.json')['expanded_sha256'] == j('actual/unita7-control-manifest.json')['expanded_inputs_sha256']
build = j('actual/build-inputs.json')
assert build['source'] == source['source'] and build['profile'] == profile
assert build['argv'][build['argv'].index('-j') + 1] == build['argv'][build['argv'].index('--threads') + 1] == '1'
assert len([x for x in build['argv'] if x.startswith('+define+TB_CORE_PARAMS=') and '.A7_VRAM_IO_READ_SIDE(1)' in x]) == 1
runroot = str(Path(build['argv'][build['argv'].index('--Mdir') + 1]).parent)
oldroot = '/home/user/Git/NDS_Pocket-codex-native58/build/joined-native58'
donor = j('actual/donor-build-command.json')
assert donor['source'] == before['source'] and donor['profile'] == j('actual/control-manifest.json')['profile']
expected = [x.replace(oldroot, runroot) for x in donor['argv']]
expected[expected.index('--Mdir') + 1] = runroot + '/model'
expected.insert(expected.index('--Mdir'), '-I' + runroot + '/host-overlay')
indices = [i for i, x in enumerate(expected) if x.startswith('+define+TB_CORE_PARAMS=')]
assert len(indices) == 1
expected[indices[0]] += ', .A7_VRAM_IO_READ_SIDE(1)'
assert build['argv'] == expected, 'compiler/configuration delta exceeds the named flag and owned paths'
oldrun = '/home/user/Git/NDS_Pocket-codex-hwref/build/ds30-native58-20261102/results/original-ds30'
expected = [runroot + '/model/Vtb_ds_pocket'] + [x.replace(oldrun + '/run', runroot + '/run').replace(oldrun + '/ds30', runroot + '/ds30-capture').replace('/home/user/Git/NDS_Pocket-codex-hwref/build/ds30-native58-20261102/ds30/run-assets/ds30_expected.hex', runroot + '/ds30/run-assets/ds30_expected.hex') for x in j('actual/control-manifest.json')['argv'][1:]]
expected += ['+vramcause=' + runroot + '/vram']
assert j('actual/manifest.json')['argv'] == expected
expected = [runroot + '/model/Vtb_ds_pocket'] + [x.replace(oldroot + '/results/unita7/run', runroot + '/unita7-run') for x in j('actual/unita7-control-model.json')['argv'][1:]]
assert j('actual/unita7-manifest.json')['argv'] == expected
for n, h in build['host'].items():
    assert sha(raw[n]) == h, n
for n in ['run', 'unita7']:
    text = raw['actual/' + n + '.log'].decode()
    assert text.count('VRAM_IO59_PUBLIC_ROUTE_PASS') == text.count('NATIVE58_ENABLED_OWNED_ROUTES_PASS') == 1
    receipt = j('actual/' + n + '.process.json')
    assert receipt['exit'] == 0 and receipt['reaped'] and receipt['NI'] == 10
    assert re.search(r'^vmcheck: [1-9]\d* words read, [1-9]\d* CPU reads from the block buffer, 0 mismatches$', text, re.M)

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

with tempfile.TemporaryDirectory(prefix='nds-io59-replay-') as temp:
    root = Path(temp)
    for n, b in raw.items():
        if not n.startswith(('prepared/', 'actual/', 'drivers/')):
            continue
        target = root / n
        assert target.resolve().is_relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b)
    sys.path.insert(0, str(root / 'prepared'))
    observer = module('ds30_observer_check59', root / 'prepared/check_observer.py')
    check = observer.validate(root / 'actual/ds30-capture', root / 'prepared', root / 'actual/manifest.json', root / 'actual/run.log')
    assert check == j('actual/check.log')
    guard = module('native_guard59', root / 'drivers/native_guard.py')
    unit = guard.validate((root / 'actual/unita7.log').read_text(), 22, 'unita7')
    assert unit['accepted'] and json.loads(json.dumps(unit)) == j('actual/unita7-result.json')['guards']
    analyzer = module('vram_analyzer59', root / 'drivers/analyze_native.py')
    causal = analyzer.analyze(root / 'actual')
    assert json.loads(json.dumps(causal)) == j('actual/causal-analysis.json')
old = j('actual/control-check.json')['rows']
assert [(x['kernel'], x['arg'], x['DS_x100']) for x in check['rows']] == [(x['kernel'], x['arg'], x['DS_x100']) for x in old]
comparison = [dict(kernel=new['kernel'], arg=new['arg'], before=int(prev['arm7_cycles_per_op_x100']),
                   after=int(new['arm7_cycles_per_op_x100']), DS=new['DS_x100']) for prev, new in zip(old, check['rows'])]
print(json.dumps(dict(status='PASS observable body/context/model/VM/video and canonical22; timing separate',
    archive_sha256=sha(a.archive.read_bytes()), model_sha256=model['sha256'], original31=comparison,
    canonical22=unit['values'], causal_counts={k:v['count'] for k,v in causal['commands'].items()}), indent=2))
