#!/usr/bin/env python3
"""Run the sealed native52 DS30 binary only after coordinator L3 transfer.

No build, probe, qualification, cache fallback, or background launch occurs.
Without --execute, only print the bound command and release requirements.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

SOURCE = '2246c468c0d9bbd968ccdff7823f32df1c8d8f5f'
MODEL = '39d8736293ad327a24f79cf8e26189147bcf0aa9c6366b4e2deae098daa6f670'
ROM = '5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e'
CASES = {'unitcpu', 'unita7', 'unitmem', 'a7fetch39', 'ds41', 'post-itcm32'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def hexfile(path, data):
    data += bytes(-len(data) % 4)
    path.write_text(''.join('%08x\n' % int.from_bytes(data[i:i+4], 'little')
                            for i in range(0, len(data), 4)))


def workers(base):
    sys.path.insert(0, str(base))
    from sim_ownership import belongs_to_nds
    rows = {}
    for line in subprocess.check_output(['ps', '-eo', 'pid=,ppid=,stat=,comm=,args='], text=True).splitlines():
        p, parent, state, name, args = line.split(None, 4)
        rows[int(p)] = dict(ppid=int(parent), state=state, name=name, args=args)
    return [pid for pid, row in rows.items()
            if row['state'][0] not in 'ZT' and row['name'].startswith(('Vtb', 'Vnds', 'verilator_bin', 'cc1', 'clang'))
            and belongs_to_nds(pid, rows)]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, required=True)
    p.add_argument('--release', type=Path, required=True)
    p.add_argument('--execute', action='store_true')
    a = p.parse_args()
    base = a.base.resolve()
    prepared = base / 'ds30'
    plan = read(prepared / 'runtime-plan.json')
    inputs = read(base / 'inputs.json')
    native = read(base / 'results/unitcpu/model.json')
    out = base / 'results/original-ds30-last'
    assets = out / 'run'
    prefix = out / 'ds30'
    model = Path(native['argv'][0])
    cmd = [str(model), f'+rom={assets}/rom.hex', f'+romsize={(prepared / "arm7-ds30.nds").stat().st_size}',
           f'+bios9={assets}/bios9.hex', f'+bios7={assets}/bios7.hex',
           f'+fw={assets}/firmware.hex', f'+boot={assets}/boot.hex',
           f'+fwsize={(base / "runtime/firmware.bin").stat().st_size}',
           '+frames=160', '+timeout_ms=3000', '+vmcheck', '+g3dperf', '+progress',
           f'+ds30_observe={prefix}', f'+ds30_expected={prepared}/run-assets/ds30_expected.hex']
    if not a.execute:
        print(json.dumps(dict(state='SOURCE-ONLY; NOT LAUNCHED', host=native['host'], cwd=str(assets),
                              argv=cmd, wall_seconds=7200, release=str(a.release),
                              prerequisite='six cases complete, Sound complete, explicit coordinator L3 transfer'), indent=2))
        return
    assert socket.gethostname() == native['host'] == 'zero-laptop', 'exact binary resides on Laptop'
    assert plan['source'] == inputs['source'] == native['source'] == SOURCE
    assert inputs['profile'] == plan['profile'] and len(inputs['profile']) == 54
    for name, digest in plan['bound_files'].items():
        assert sha(base / name) == digest, ('changed bound input', name)
    assert sha(model) == native['sha256'] == MODEL
    assert sha(prepared / 'arm7-ds30.nds') == ROM
    for name, digest in inputs['runtime_sha256'].items():
        path = base / ('source' if '/' in name else 'runtime') / name
        assert sha(path) == digest, ('runtime changed', name)
    chain = read(base / 'results/chain.json')
    assert chain['source'] == SOURCE and chain['profile'] == inputs['profile']
    assert chain.get('native_sequence_complete') is True and chain.get('active') is None
    assert not chain.get('error') and not chain.get('remaining_observed_pids')
    completed = {c['name']: c for c in chain['completed']}
    assert CASES <= completed.keys()
    for name in CASES:
        c = completed[name]
        assert c['exit'] == 0 and all(c[k] is True for k in ('accepted', 'native_finish', 'models_clean', 'VM', 'video'))
        m = read(base / 'results' / name / 'manifest.json')
        n = read(base / 'results' / name / 'model.json')
        assert m['source'] == SOURCE and m['profile'] == inputs['profile'] and m['exit'] == 0
        assert m['log_sha256'] == sha(base / 'results' / name / 'run.log')
        assert n['sha256'] == MODEL and n['argv'][0] == str(model) and n['source'] == SOURCE
    release = read(a.release)
    assert release['authorized_by'] == 'coordinator' and release['lease'] == 'L3'
    assert release['transferred_to'] == 'hwref-ds30' and release['explicit_transfer'] is True
    assert release['source'] == SOURCE and release['model_sha256'] == MODEL
    assert release['six_case_chain_sha256'] == sha(base / 'results/chain.json')
    assert release['sound_complete'] is True and release['sound_worker_reaped'] is True
    sound = Path(release['sound_receipt'])
    assert sound.is_file() and sha(sound) == release['sound_receipt_sha256']
    assert os.getloadavg()[0] <= 24, 'Laptop capacity unavailable; return to coordinator'
    assert len(workers(base)) < 3, 'NDS worker capacity unavailable'
    # Keep the existing cache inode leased; never invoke the build machinery.
    with model.parent.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        out.mkdir(exist_ok=False)
        assets.mkdir()
        for name in ('bios9', 'bios7', 'firmware'):
            hexfile(assets / (name + '.hex'), (base / 'runtime' / (name + '.bin')).read_bytes())
        hexfile(assets / 'rom.hex', (prepared / 'arm7-ds30.nds').read_bytes())
        boot = (base / 'source/sw/boot/bootrom.bin').read_bytes()
        scpu = (base / 'source/sw/scpu/cache.bin').read_bytes()
        hexfile(assets / 'boot.hex', boot + bytes(8192-len(boot)) + scpu + bytes(4096-len(scpu)))
        shutil.copyfile(base / 'source/sw/scpu/mbox.hex', assets / 'mbox.hex')
        shutil.copyfile(base / 'source/build/boot/bootrom.hex', assets / 'bootrom.mif')
        manifest = dict(source=SOURCE, model_sha256=MODEL, ROM_sha256=ROM, profile=inputs['profile'],
                        argv=cmd, cwd=str(assets), host=socket.gethostname(), frames=160,
                        simulated_timeout_ms=3000, wall_watchdog_seconds=7200,
                        release=release, release_sha256=sha(a.release),
                        plan_sha256=sha(prepared / 'runtime-plan.json'),
                        uptime=subprocess.check_output(['uptime'], text=True).strip(),
                        expanded_sha256={p.name: sha(p) for p in assets.iterdir()}, state='STARTING')
        os.setpriority(os.PRIO_PROCESS, 0, 10)
        started = time.monotonic()
        with (out / 'run.log').open('w') as log:
            child = subprocess.Popen(cmd, cwd=assets, stdout=log, stderr=subprocess.STDOUT)
            manifest['pid'] = child.pid
            save(out / 'manifest.json', manifest)
            try:
                while child.poll() is None:
                    assert time.monotonic()-started < 7200, 'wall watchdog; incomplete, no timing verdict'
                    assert len(workers(base)) <= 3, 'NDS capacity exceeded; stop owned PID only'
                    tasks = Path('/proc', str(child.pid), 'task')
                    try:
                        assert len(list(tasks.iterdir())) <= 1
                    except FileNotFoundError:
                        if child.poll() is None:
                            raise
                    time.sleep(.5)
                manifest['exit'] = child.wait()
            except BaseException as exc:
                manifest['incomplete_reason'] = repr(exc)
                raise
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
                manifest.update(exit=child.returncode, reaped=True,
                                wall_seconds=round(time.monotonic()-started, 3), state='REAPED; CHECK REQUIRED')
                save(out / 'manifest.json', manifest)
        assert manifest['exit'] == 0, 'native incomplete/failed; inspect raw log'
        # Dedicated checker retains 50 bodies/32 pairs/31 CSV/context and finish/VM/model/video guards.
        with (out / 'check.json').open('w') as result:
            subprocess.run([sys.executable, str(prepared / 'check_observer.py'), '--prepared', str(prepared),
                            '--prefix', str(prefix), '--run-manifest', str(out / 'manifest.json'),
                            '--log', str(out / 'run.log')], stdout=result, check=True)
        manifest.update(state='BODY/CONTEXT/ROW/GUARDS PASS; TIMING SEPARATE', log_sha256=sha(out / 'run.log'),
                        checker_sha256=sha(out / 'check.json'))
        save(out / 'manifest.json', manifest)


if __name__ == '__main__':
    main()
