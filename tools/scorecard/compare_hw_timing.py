#!/usr/bin/env python3
"""Pair focused DS30/35 timing adapters; retain context and every raw best."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def require(ok, message):
    if not ok:
        raise ValueError(message)


def slope(short, long, operations, rounded):
    require(type(short) is int and type(long) is int and 0 < short < long and operations > 0,
            'positive ordered timer observations required')
    return ((long - short) * 100 + (operations // 2 if rounded else 0)) // operations


def observation(label, value, short, long, target, rounded, ds_bests=None):
    derived = slope(short, long, 768, rounded)
    require(value == derived, 'reported slope contradicts raw bests: ' + label)
    return dict(label=label, native_x100=value, ds_x100=target, difference_x100=value - target,
                same_rounded_value=value == target, native_bests=[short, long], ds_bests=ds_bests,
                extra_operations=768, rounding='nearest' if rounded else 'truncate',
                status='paired observation; context limits retained, no automatic timing PASS')


def analyze(directory):
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    manifest = json.loads((directory / 'manifest.json').read_text())
    execution = json.loads((directory / 'native-execution.json').read_text())
    by_name = {r['name']: r for r in execution['runs']}
    require(set(by_name) == {'ds30', 'ds35'} and len(execution['runs']) == 2, 'two completed controls required')
    native = {}
    for name, checks in [('ds30', 19), ('ds35', 3)]:
        record = by_name[name]
        log = directory / (name + '-native/run.log')
        require(record['exit'] == 0 and record['runtime_files_unchanged'] and
                sha(log) == record['log_sha256'] and sha(directory / 'manifest.json') == record['manifest_sha256'],
                'failed/changed native evidence: ' + name)
        text = log.read_text()
        require(re.findall(r'^PASS$', text, re.M) == ['PASS'] and text.count('Verilog $finish') == 1 and
                not re.search(r'\b(?:ERROR|FAIL|TIMEOUT|Assertion failed)\b|%Error', text), 'native did not finish cleanly')
        verdict = re.findall(r'^result: magic (\w+) checks (\d+) mask (\w+) done (\d+)$', text, re.M)
        require(len(verdict) == 1 and tuple(int(v, b) for v, b in zip(verdict[0], (16, 10, 16, 10))) ==
                (0x52545344, checks, (1 << checks) - 1, 1), 'canonical coverage missing')
        rows = re.findall(r'^value (\d+) (\d+)$', text, re.M)
        require([int(i) for i, v in rows] == list(range(checks)), 'missing/duplicate native value')
        native[name] = [int(v) for i, v in rows]
    a7 = {(r['kernel'], int(r['arg'])): int(r['arm7_cycles_per_op_x100']) for r in manifest['hardware']['a7']['rows']}
    a7_keys = [('ldr_wram', 0), ('str_wram', 0), ('ldr_vram_c', 0), ('ldr_vram_c', 1), ('str_vram_c', 0), ('str_vram_c', 1)]
    rows = [observation(f'{key[0]} arg{key[1]}', native['ds30'][i], native['ds30'][6 + 2*i],
                        native['ds30'][7 + 2*i], a7[key], False) for i, key in enumerate(a7_keys)]
    ds = manifest['hardware']['mem']['rows'][0]
    require((int(ds['n1']), int(ds['n2'])) == (256, 1024), 'DS35 operation counts differ')
    ds_times = [int(ds['t1']), int(ds['t2'])]
    require(slope(*ds_times, 768, True) == int(ds['cyc_per_access_x100']), 'DS35 archived slope contradicts bests')
    rows.append(observation('LDM8UNC', *native['ds35'], int(ds['cyc_per_access_x100']), True, ds_bests=ds_times))
    require(native['ds30'][18] == 1, 'ARM7 helper did not complete')
    return dict(source=execution['source'], profile=execution['profile'], model_sha256=execution['model_sha256'],
                rows=rows, limits=manifest['limits'], matched=manifest['matched'],
                execution_sha256=sha(directory / 'native-execution.json'),
                adapter_manifest_sha256=sha(directory / 'manifest.json'),
                scope='source-form/count/phase matched observations; no new DS capture or blanket tolerance',
                expected_data_operations_not_observed=manifest['expected_data_operations'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
