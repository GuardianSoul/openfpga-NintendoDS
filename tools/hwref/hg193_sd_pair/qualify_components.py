#!/usr/bin/env python3
"""Reparse bounded component logs; a printed success alone is insufficient."""
import argparse
import hashlib
import gzip
import json
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def qualify(base, retained=False):
    worker = json.loads((base / 'worker.json').read_text())
    assert worker['NI'] == 10 and worker['jobs'] == worker['threads'] == 1
    steps = worker['steps']
    assert len(steps) >= 24
    assert worker['child'] is None or worker['child']['name'] == 'offline-qualification'
    checks = {}

    def positive(index, marker=None):
        step = steps[index]
        log = (base / 'steps' / f'{index:03d}/run.log').read_text()
        assert step['exit'] == 0 and step['reaped'], step['name']
        assert not any(s in log for s in ('%Error', '%Fatal', 'Assertion failed', 'timeout')), step['name']
        if marker:
            assert log.count(marker) == 1, (step['name'], marker)
        checks[step['name']] = dict(result='PASS', pid=step['pid'], reaped=True,
                                   log_sha256=sha(base / 'steps' / f'{index:03d}/run.log'))
        return log

    def negative(index, marker):
        step = steps[index]
        log = (base / 'steps' / f'{index:03d}/run.log').read_text()
        assert step['exit'] != 0 and step['reaped'], step['name']
        assert marker in log, (step['name'], marker)
        assert 'timeout' not in log and 'invalid record was published' not in log
        assert 'SOURCE_ADAPTER_APPLIED' not in log and 'PUBLICATION_HELD_DRAINED_PASS' not in log
        checks[step['name']] = dict(result='EXPECTED_PRODUCTION_OR_PUBLICATION_GUARD_REJECTION',
                                   guard=marker, pid=step['pid'], reaped=True,
                                   log_sha256=sha(base / 'steps' / f'{index:03d}/run.log'))

    positive(1)
    positive(2, 'HG193_ACTUAL_RECORD_GUARD_VALID_PASS records5')
    negative(3, 'SD_RECORD_STALE_OR_CORRUPT_RETURN')
    negative(4, 'SD_RECORD_STALE_OR_CORRUPT_RETURN')
    positive(7)
    positive(16)
    absent = positive(17, 'HG193_DEFAULT_NO_IMPORT_PASS')
    positive(18)
    enabled = positive(19, 'HG193_DEFAULT_NO_IMPORT_PASS')
    valid = positive(20, 'HG193_PUBLICATION_HELD_DRAINED_PASS words131072 context3712 preserved32plus64')
    negative(21, 'HG193 requires the held/drained pre-release line193 hook')
    negative(22, 'SD pair publication has pending ingress/canonical/cache/transport work or running clocks')
    negative(23, 'HG193 descriptor/continuation differs')
    fingerprints = [re.findall(r'HG193_DEFAULT_BEFORE signature=([0-9a-f]{16})', log)
                    for log in (absent, enabled, valid)]
    assert [len(v) for v in fingerprints] == [2, 2, 1]
    assert len(set(sum(fingerprints, []))) == 1, fingerprints
    resolved = json.loads((base / 'resolved-gpu-parameters.json').read_text())
    tree = base / 'full-adapter.tree.json'
    raw = tree.read_bytes() if tree.exists() else gzip.decompress(tree.with_suffix('.json.gz').read_bytes())
    assert hashlib.sha256(raw).hexdigest() == resolved['full_elaboration_json_sha256']
    assert len(resolved['parameters']) == 60
    fixture = json.loads((base / 'publication-fixture.json').read_text())
    for name, digest in fixture['files_sha256'].items():
        assert sha(base / name) == digest, ('fixture changed after stage', name)
    model_paths = [
        ('canonical', 'records', 'Vtb_record_guards'),
        ('publication_default', 'publication-default', 'Vtb_ds_pocket'),
        ('publication_enabled', 'publication-enabled', 'Vtb_ds_pocket')]
    if retained:
        cleanup = json.loads((base / 'cleanup.json').read_text())
        assert cleanup['state'] == 'ALL_COMPONENT_CHILDREN_REAPED_PRIVATE_COMPILER_SCRATCH_REMOVED'
        assert sha(base / 'full-adapter.tree.json.gz') == cleanup['full_elaboration_gzip_sha256']
        models = {name: cleanup['models'][name]['sha256'] for name, _, _ in model_paths}
    else:
        models = {name: sha(base / 'scratch' / sub / binary) for name, sub, binary in model_paths}
    result = dict(
        state='SCOPED_COMPONENT_QUALIFIED_READY_FOR_COORDINATOR_COMPOSITION',
        source=resolved['source'], profile_fields=58, actual_gpu_parameters=60,
        adapter_base='8b6aeadc',
        adapter_fix='simulation-only g_sparb owner references bound to actual pair u_arb',
        checks=checks, default_before_signature=fingerprints[0][0],
        controller=dict(host=worker['host'], pid=worker['controller'],
                        start_ticks=worker['controller_start_ticks'], NI=10, jobs=1, threads=1),
        model_sha256=models, full_elaboration_json_sha256=resolved['full_elaboration_json_sha256'],
        packet_sha256=sha(base / 'payload/sd-packets.hex'),
        adapter_include_sha256=sha(base / 'payload/hg193_sd_pair.svh'),
        fixture_sha256=sha(base / 'publication-fixture.json'),
        publication='Held SYS/FAST; all connected external ports drained;131072 physical words/guards, lists/banks/generation,3712 context and cold unpublished raster/ring read back; sort epoch/cursors retained',
        snapshots='actual versioned96live/64frozen ABI;64 captured live words restored; distinct omitted32live+64frozen preserved independently',
        default_control='separately compiled adapter-absent and enabled-but-not-called fixtures; identical2869-path/table/ring/snapshot/owner fingerprints before and after idle hold',
        scope='actual frozen GPU with all60 constants resolved from full actual frozen core_top/profile58 elaboration; isolated component IO/clocks/backing, no CPU or game',
        fixture_input='nonzero mixed-version snapshots plus distinct invalid current-writer sort entries; wait actual engine idle after natural reset; ordinary GPU IO replay',
        prior_failed_trials='0 unsupported compiler XML option;5 omitted staged profile file;6 actual old arbiter paths;9/11 finish fall-through;12/15 non-idle reset phase. Retained, excluded from acceptance; source/fixture corrected, final16..23 required clean.',
        not_claimed=['combined CPU/cache/transport hook qualification', 'whole HG model/frame proof',
                     'first-use/export/probe', 'production RTL change', 'default feature enable'])
    if retained:
        original = json.loads((base / 'qualification.json').read_text())
        for field in ('checks', 'default_before_signature', 'model_sha256',
                      'full_elaboration_json_sha256', 'packet_sha256', 'adapter_include_sha256', 'fixture_sha256'):
            assert result[field] == original[field], ('retained evidence differs', field)
        return dict(state='RETAINED_COMPONENT_EVIDENCE_REPLAY_PASS', models_executed=0,
                    checks=len(checks), original_qualification_sha256=sha(base / 'qualification.json'),
                    compiler_scratch_removed=True)
    (base / 'qualification.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--retained', action='store_true')
    args = parser.parse_args()
    result = qualify(args.base.resolve(), args.retained)
    print(json.dumps(result, indent=2))
