#!/usr/bin/env python3
"""One changed-source original DS30 plus affected canonical ARM7 measurement."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import resource
import subprocess
import sys
import time

R = Path(__file__).resolve().parents[3]
SOURCE = '00ef4ef98981dc64b9a8e33deb99b5f04b2e3388'
BASE = '2f86d1e69b0fc477d179375315acdefc1b438a68'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--prepared', type=Path, required=True)
p.add_argument('--allocated', action='store_true', required=True)
p.add_argument('--await-release', action='store_true')
a = p.parse_args()
G = a.prepared.resolve()
os.chdir(G / 'source')
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
sys.dont_write_bytecode = True
sys.path.insert(0, str(R / 'sim/arm/ncnb_store'))
from worker_guard import guard, wait_owned

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def read(name):
    return json.loads((G / name).read_text())

def save(name, value):
    path = G / name
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)

assert sha(R / 'sim/arm/ncnb_store/sim_ownership.py') == '64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
assert not (G / 'controller.json').exists()
save('controller.json', dict(pid=os.getpid(), starttime=Path('/proc/self/stat').read_text().split()[21], NI=10))
print('GATED', read('controller.json'), flush=True)
while a.await_release and not (G / 'release').exists():
    time.sleep(.2)
(G / 'tmp').mkdir(exist_ok=True)
os.environ['TMPDIR'] = str(G / 'tmp')
source = read('source-manifest.json')
before = read('donor-source-manifest.json')
delta = read('source-delta.json')
assert source['source'] == SOURCE and before['source'] == BASE
assert set(source['files']) == set(before['files']) and len(source['files']) == 1190
assert {n for n in source['files'] if source['files'][n] != before['files'][n]} == set(delta)
for n, d in delta.items():
    assert d == dict(before=before['files'][n], after=source['files'][n])

def verify_source():
    for n, h in source['files'].items():
        assert sha(G / 'source' / n) == h, n

verify_source()
for n, h in read('additional-donor-inputs.json').items():
    assert sha(G / n) == h, n
control = read('control-manifest.json')
unit_control = read('unita7-control-manifest.json')
for directory, hashes in [('run', control['expanded_sha256']), ('unita7-run', unit_control['expanded_inputs_sha256'])]:
    for n, h in hashes.items():
        assert sha(G / directory / n) == h, (directory, n)
assert sha(G / 'ds30/arm7-ds30.nds') == '5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e'
profile = read('profile.json')
assert profile == dict(control['profile'], A7_VRAM_IO_READ_SIDE=1) and len(profile) == 59

def call(argv, tag, cwd):
    guard()
    argv = list(map(str, argv))
    start = time.monotonic()
    with (G / (tag + '.log')).open('w') as output:
        child = subprocess.Popen(argv, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
        row = dict(pid=child.pid, starttime=Path('/proc', str(child.pid), 'stat').read_text().split()[21],
                   NI=os.getpriority(os.PRIO_PROCESS, child.pid), argv=argv, cwd=str(cwd), log=str(G / (tag + '.log')))
        save(tag + '.active.json', row)
        with (G / 'processes.jsonl').open('a') as f:
            f.write(json.dumps(row) + '\n')
        print('STAGE', tag, child.pid, row['starttime'], flush=True)
        rc = wait_owned(child)
    row.update(exit=rc, reaped=True, wall_seconds=time.monotonic() - start)
    save(tag + '.process.json', row)
    assert rc == 0, (tag, (G / (tag + '.log')).read_text()[-3500:])
    return row

old = '/home/user/Git/NDS_Pocket-codex-native58/build/joined-native58'
build = read('donor-build-command.json')
assert build['source'] == BASE and build['profile'] == control['profile']
cmd = [x.replace(old, str(G)) for x in build['argv']]
cmd[cmd.index('--Mdir') + 1] = str(G / 'model')
cmd.insert(cmd.index('--Mdir'), '-I' + str(G / 'host-overlay'))
indices = [i for i, x in enumerate(cmd) if x.startswith('+define+TB_CORE_PARAMS=')]
assert len(indices) == 1
cmd[indices[0]] += ', .A7_VRAM_IO_READ_SIDE(1)'
assert cmd[cmd.index('-j') + 1] == cmd[cmd.index('--threads') + 1] == '1'
save('build-inputs.json', dict(source=SOURCE, baseline=BASE, profile=profile, argv=cmd, delta=delta,
    host={str(p.relative_to(G)): sha(p) for p in (G / 'host-overlay').rglob('*') if p.is_file()}))
call(cmd, 'build', G / 'source')
model = G / 'model/Vtb_ds_pocket'
save('model.json', dict(source=SOURCE, sha256=sha(model), profile=profile))

def routes(log):
    text = log.read_text()
    assert text.count('NATIVE58_ENABLED_OWNED_ROUTES_PASS') == 1
    assert text.count('VRAM_IO59_PUBLIC_ROUTE_PASS') == 1

original_run = '/home/user/Git/NDS_Pocket-codex-hwref/build/ds30-native58-20261102/results/original-ds30'
run = [str(model)] + [x.replace(original_run + '/run', str(G / 'run')).replace(original_run + '/ds30', str(G / 'ds30-capture')).replace('/home/user/Git/NDS_Pocket-codex-hwref/build/ds30-native58-20261102/ds30/run-assets/ds30_expected.hex', str(G / 'ds30/run-assets/ds30_expected.hex')) for x in control['argv'][1:]]
run += ['+vramcause=' + str(G / 'vram')]
manifest = dict(source=SOURCE, model_sha256=sha(model), ROM_sha256=control['ROM_sha256'], profile=profile,
    argv=run, cwd=str(G / 'run'), expanded_sha256=control['expanded_sha256'],
    controller=read('controller.json'), state='CHANGED SOURCE; DS timing authority; no equality to old timing asserted')
save('manifest.json', manifest)
process = call(run, 'run', G / 'run')
manifest.update(process=process, exit=0, log_sha256=sha(G / 'run.log'))
save('manifest.json', manifest)
routes(G / 'run.log')
call([sys.executable, G / 'ds30/check_observer.py', '--prepared', G / 'ds30', '--prefix', G / 'ds30-capture',
      '--run-manifest', G / 'manifest.json', '--log', G / 'run.log'], 'check', G / 'source')
check = json.loads((G / 'check.log').read_text())
save('ds30-result.json', dict(check=check, old_rows=read('control-check.json')['rows'], timing='compare actual rows with DS; no blanket tolerance'))

ucmd = read('unita7-control-model.json')['argv']
run = [str(model)] + [x.replace(old + '/results/unita7/run', str(G / 'unita7-run')) for x in ucmd[1:]]
unit = dict(source=SOURCE, model_sha256=sha(model), ROM_sha256=unit_control['rom_sha256'], profile=profile,
            argv=run, cwd=str(G / 'unita7-run'), expanded_sha256=unit_control['expanded_inputs_sha256'])
save('unita7-manifest.json', unit)
unit['process'] = call(run, 'unita7', G / 'unita7-run')
routes(G / 'unita7.log')
spec = importlib.util.spec_from_file_location('native_guard59', G / 'native_guard.py')
ng = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ng)
result = ng.validate((G / 'unita7.log').read_text(), 22, 'unita7')
assert result['accepted'], result
unit.update(guards=result, log_sha256=sha(G / 'unita7.log'))
save('unita7-result.json', unit)
verify_source()
save('completion.json', dict(status='PASS originalDS30 body/context/physical guards and canonical22 state/model/VM/video; timing separate',
    source=SOURCE, model_sha256=sha(model), profile=profile, ds30_rows=check['rows'], unita7_values=result['values']))
print('VRAM_IO59_COMPLETE', flush=True)
