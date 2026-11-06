#!/usr/bin/env python3
"""One gated NI10/j1/t1 Laptop component chain; private scratch only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def ticks(pid):
    return Path('/proc', str(pid), 'stat').read_text().split()[21]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    parser.add_argument('--child', type=Path)
    args = parser.parse_args()
    base = args.base.resolve()
    if args.child:
        spec = json.loads(args.child.read_text())
        while not Path(spec['release']).exists():
            time.sleep(.1)
        os.execvpe(spec['argv'][0], spec['argv'], os.environ)
    assert socket.gethostname() == 'zero-laptop'
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    worker = dict(host=socket.gethostname(), lease='L1', controller=os.getpid(),
                  controller_start_ticks=ticks(os.getpid()), NI=os.getpriority(os.PRIO_PROCESS, 0),
                  jobs=1, threads=1, state='WAITING_INITIAL_RELEASE', child=None, steps=[])
    save(base / 'worker.json', worker)
    started = time.monotonic()
    while not (base / 'release.json').exists():
        assert time.monotonic()-started < 900, 'initial release expired'
        time.sleep(.2)
    release = json.loads((base / 'release.json').read_text())
    assert release['authorized_by'] == 'coordinator' and release['lease'] == 'L1'
    assert release['controller'] == os.getpid()
    worker['state'] = 'RELEASED'
    save(base / 'worker.json', worker)
    number = 0
    try:
        while True:
            plan_path = base / 'steps' / f'{number:03d}.json'
            if not plan_path.exists():
                if (base / 'STOP').exists():
                    break
                assert time.monotonic()-started < 3600, 'component chain watchdog'
                time.sleep(.25)
                continue
            assert os.getloadavg()[0] <= 24, 'load above assigned capacity'
            plan = json.loads(plan_path.read_text())
            assert plan['jobs'] == plan['threads'] == 1
            work = base / 'steps' / f'{number:03d}'
            work.mkdir(exist_ok=False)
            gate = work / 'go'
            command = dict(argv=plan['argv'], release=str(gate))
            save(work / 'command.json', command)
            with (work / 'run.log').open('w') as log:
                child = subprocess.Popen([sys.executable, __file__, '--base', str(base),
                                          '--child', str(work / 'command.json')],
                                         cwd=plan.get('cwd', str(base)), stdout=log,
                                         stderr=subprocess.STDOUT)
                entry = dict(name=plan['name'], pid=child.pid, start_ticks=ticks(child.pid),
                             argv=plan['argv'], cwd=plan.get('cwd', str(base)),
                             log=str(work / 'run.log'), released=False)
                worker.update(state='CHILD_RECORDED_BEFORE_RELEASE', child=entry)
                save(base / 'worker.json', worker)
                gate.touch()
                entry['released'] = True
                worker['state'] = 'RUNNING'
                save(base / 'worker.json', worker)
                then = time.monotonic()
                try:
                    child.wait(timeout=plan.get('wall_seconds', 900))
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
                entry.update(exit=child.returncode, reaped=True,
                             wall_seconds=round(time.monotonic()-then, 3),
                             log_sha256=hashlib.sha256((work / 'run.log').read_bytes()).hexdigest())
            worker['steps'].append(entry)
            worker.update(state='STEP_REAPED_WAITING_NEXT', child=None)
            save(base / 'worker.json', worker)
            number += 1
    finally:
        worker.update(state='CONTROLLER_FINISHED', wall_seconds=round(time.monotonic()-started, 3), child=None)
        save(base / 'worker.json', worker)


if __name__ == '__main__':
    main()
