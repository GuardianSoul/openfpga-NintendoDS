#!/usr/bin/env python3
"""Stream native60 packet hashes; replay all four observable guest contracts."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from compare_native import compare, digest


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def check(root, manifest, raw_replay):
    def j(name):
        return json.loads((root/name).read_text())
    source, model, profile = j('source-manifest.json'), j('model.json'), j('profile.json')
    assert source['source'] == model['source'] == 'aeaa0cb386d2fbd6f8d2505f8033015956da54b5'
    assert len(source['files']) == 1171
    assert sum(n.startswith('rtl/') for n in source['files']) == 159
    assert profile == model['profile'] and len(profile) == 60
    assert profile == dict(j('native59-manifest.json')['profile'], VRAM_CUT_WRITE_TURN=1)
    assert manifest['model/Vtb_ds_pocket']['sha256'] == model['sha256'] == 'fe889b553d710a7c7ab838c33ba5ff62d86fd763fc0e126d86d623ac9c2794da'
    for name, sha in source['files'].items():
        assert manifest['source/'+name]['sha256'] == sha, name
    for name, sha in model['host_sha256'].items():
        assert manifest[name]['sha256'] == sha, name
    assert manifest['build-command.json']['sha256'] == model['build_command_sha256']
    delta = j('production-delta-from59.json')
    before = j('native59-source-manifest.json')['files']
    changed = {n for n in source['files'] if n.startswith('rtl/') and before.get(n) != source['files'][n]}
    assert changed == set(delta['RTL']) and len(changed) == 18
    assert 'rtl/gpu3d/gpu3d_gxrom_adict.sv' in changed
    argv = j('build-command.json')['argv']
    assert argv[argv.index('-j')+1] == argv[argv.index('--threads')+1] == '1'
    assert any(x.endswith('/source/rtl/gpu3d/gpu3d_gxrom_adict.sv') for x in argv)
    for name in ['ds30', 'unita7', 'unitmem', 'ldm53-live']:
        receipt = j('runs/'+name+'/manifest.json')
        assert receipt['source'] == model['source'] and receipt['model_sha256'] == model['sha256']
        assert receipt['profile'] == profile
        proc = j('runs/'+name+'/run.process.json')
        assert proc['reaped'] and proc['exit'] == 0 and proc['NI'] == 10
        text = (root/'runs'/name/'run.log').read_text()
        assert text.count('NATIVE60_WRITE_TURN_ROUTE_PASS') == 1
        marker = 'NATIVE60_LDM53_ACTIVE_PASS' if name == 'ldm53-live' else 'NATIVE60_LDM53_INACTIVE_PASS'
        assert text.count(marker) == 1
    sys.path.insert(0, str(root/'ds30'))
    observer = module('ds30_packet_check', root/'ds30/check_observer.py')
    ds30 = observer.validate(root/'runs/ds30/ds30-capture', root/'ds30', root/'runs/ds30/manifest.json', root/'runs/ds30/run.log')
    assert ds30 == j('runs/ds30/result.json') == j('runs/ds30/check.log')
    guard = module('native60_guard', root/'native_guard.py')
    for name, count in [('unita7',22), ('unitmem',32), ('ldm53-live',3)]:
        result = guard.validate((root/'runs'/name/'run.log').read_text(), count, name)
        assert result['accepted'] and json.loads(json.dumps(result)) == j('runs/'+name+'/result.json')['guards']
    sys.path.insert(0, str(root/'ldm53-control/tools/scorecard/ldm53'))
    # The DS30 checker imports a module named check; load the distinct LDM
    # checker explicitly so it cannot inherit that import from sys.modules.
    functional = module('ldm53_packet_check', root/'ldm53-control/tools/scorecard/ldm53/check.py')
    out = root/'functional-replay'
    out.mkdir(exist_ok=True)
    with contextlib.redirect_stdout(sys.stderr):
        fun = functional.check_native_main((root/'runs/ldm53-live/main.bin').read_bytes(), root/'ldm53-control/normal', out)
    saved = j('runs/ldm53-live/functional-checked.json')
    assert all(saved[k] == v for k, v in fun.items()), '53 functional replay differs'
    timing = compare(root/'runs/ldm53-live/decoded/times.csv', root/'reference-inputs/DS40-times.csv')
    assert timing == j('runs/ldm53-live/native-vs-DS53.json')
    ds_audit = j('reference-inputs/DS40-ldm-analysis.json')['groups']
    for row, audit in zip(timing['rows'], ds_audit):
        assert (row['case'], row['offset_bytes']) == (audit['case'], audit['offset_bytes'])
        assert row['DS']['slope_fraction'] == audit['slope_fraction']
        assert row['DS']['observed_envelope'] == audit['observed_envelope']
    raw, binding = j('runs/ldm53-live/raw-checked.json'), j('runs/ldm53-live/binding.json')
    assert raw['trace_sha256'] == manifest['runs/ldm53-live/ldm53.csv']['sha256']
    assert raw['binding_sha256'] == manifest['runs/ldm53-live/binding.json']['sha256']
    assert (raw['records'], raw['calls'], raw['detailed_calls']) == (7452827,742,106)
    assert binding['top_profile'] == profile and len(binding['profile']) == 10
    assert binding['model_sha256'] == model['sha256']
    assert binding['compiled_observer_sha256'] == manifest['host-observer/sim/pocket_ds/ldm53_observer.sv']['sha256']
    if raw_replay:
        subprocess.run([sys.executable, root/'host-observer/tools/scorecard/ldm53_observer.py', 'verify',
                        '--trace', root/'runs/ldm53-live/ldm53.csv', '--binding', root/'runs/ldm53-live/binding.json',
                        '--roi', root/'host-inputs/ldm53_roi_first_timed.hex', '--out', root/'raw-replayed.json'], check=True, stdout=sys.stderr)
    old = j('reference-inputs/native58-unitmem-manifest.json')['values']
    now = j('runs/unitmem/result.json')['guards']['values']
    dma = {k: [v,now[k]] for k,v in old.items() if v != now[k]}
    assert dma == {'25':[423,418], '26':[447,451], '28':[212,213]}
    return dict(status='PASS portable hashes/all4 observable guards; DS timing and dynamic ownership remain unqualified',
                model_sha256=model['sha256'], members=len(manifest)+1, raw=raw, numeric53=timing['counts'],
                unitmem_changes_from_native58=dma, raw_semantic_replay='repeated' if raw_replay else 'retained completed full verifier tied to exact raw/binding SHA; not repeated')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive', type=Path)
    p.add_argument('--verify-raw', action='store_true', help='Also extract and reparse the original1.24GB raw trace')
    a = p.parse_args()
    with tempfile.TemporaryDirectory(prefix='nds-native60-replay-', dir=a.archive.resolve().parent) as temp:
        root = Path(temp)
        with tarfile.open(a.archive, 'r|*') as tar:
            first = tar.next()
            assert first.name == 'packet-manifest.json' and first.isfile()
            manifest = json.load(tar.extractfile(first))
            seen = set()
            while member := tar.next():
                assert member.isfile() and member.name in manifest and member.name not in seen, member.name
                seen.add(member.name)
                target = root/member.name
                assert target.resolve().is_relative_to(root)
                assert member.size == manifest[member.name]['bytes']
                large = member.name.startswith(('source/', 'model/')) or member.name.endswith(('vram.cpu.csv', 'vram.mem.csv', 'vram.events.csv', 'causal-analysis.json'))
                keep = not large and (a.verify_raw or member.name != 'runs/ldm53-live/ldm53.csv')
                if keep:
                    target.parent.mkdir(parents=True, exist_ok=True)
                out = target.open('wb') if keep else None
                sha = hashlib.sha256()
                with tar.extractfile(member) as f:
                    while chunk := f.read(1024*1024):
                        sha.update(chunk)
                        if out:
                            out.write(chunk)
                if out:
                    out.close()
                assert sha.hexdigest() == manifest[member.name]['sha256'], member.name
            assert seen == manifest.keys()
        result = check(root, manifest, a.verify_raw)
        result['archive_sha256'] = digest(a.archive)
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
