#!/usr/bin/env python3
"""Replay a bounded result packet without a model build or native run."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, resource, subprocess, tarfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--packet', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (30, 30))
resource.setrlimit(resource.RLIMIT_AS, (512*1024**2, 512*1024**2))
resource.setrlimit(resource.RLIMIT_FSIZE, (64*1024**2, 64*1024**2))
D = a.output.resolve()
D.mkdir(parents=True, exist_ok=False)
with tarfile.open(a.packet) as t:
    members = t.getmembers()
    assert all(m.isfile() or m.isdir() for m in members)
    assert sum(m.size for m in members) < 32*1024**2
    t.extractall(D, filter='data')
manifest = json.loads((D/'manifest.json').read_text())
for name, digest in manifest['files'].items():
    assert hashlib.sha256((D/name).read_bytes()).hexdigest() == digest, name
commands = [
    ['python3', D/'src/sim/arm/a7_mul_service/analyze.py', D/'component', '--out', D/'analysis-replayed.json'],
    ['python3', D/'src/sim/arm/a7_mul_native/test_check.py', D/'native', '--out', D/'oracle-replayed.json'],
]
for command in commands:
    subprocess.run(list(map(str, command)), check=True, timeout=20)
analysis = json.loads((D/'analysis-replayed.json').read_text())
saved = json.loads((D/'component/analysis.json').read_text())
assert analysis == saved
assert json.loads((D/'oracle-replayed.json').read_text()) == json.loads((D/'native/oracle-test.json').read_text())
if (D/'runtime/runtime.json').exists():
    runtime = json.loads((D/'runtime/runtime.json').read_text())
    assert runtime['exit'] == 0 and runtime['reaped'] and runtime['scoped_function_context_PASS']
    assert hashlib.sha256((D/'runtime/main.bin').read_bytes()).hexdigest() == runtime['raw_dump_SHA256']
    assert hashlib.sha256((D/'runtime/run.log').read_bytes()).hexdigest() == runtime['log_SHA256']
    for name, path in [('native_check', D/'src/sim/arm/a7_mul_native/check.py'),
                       ('native_guard', D/'runtime/original-native-guard.py')]:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if name == 'native_check':
            comparison = module.check(D/'native', (D/'runtime/main.bin').read_bytes())
            comparison.update(core_source=runtime['source'], model_SHA256=runtime['model_SHA256'], profile=runtime['profile'])
            assert comparison == json.loads((D/'runtime/comparison.json').read_text())
        else:
            guard = module.validate((D/'runtime/run.log').read_text(), 1, 'mixed-MUL-new')
            assert json.loads(json.dumps(guard)) == json.loads((D/'runtime/original-guard.json').read_text())
            assert not guard['accepted'] and guard['vm_counts'] == [0, 0, 0] and guard['PASS']
    subprocess.run(['python3', str(D/'src/sim/arm/a7_mul_native/test_check.py'), str(D/'native'),
                    '--dump', str(D/'runtime/main.bin'), '--out', str(D/'native-faults-replayed.json')], check=True, timeout=20)
    assert json.loads((D/'native-faults-replayed.json').read_text()) == json.loads((D/'runtime/oracle-test.json').read_text())
print('REPLAY PASS', len(manifest['files']), 'pinned inputs; no native execution claim')
