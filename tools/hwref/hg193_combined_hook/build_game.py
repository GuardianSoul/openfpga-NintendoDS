#!/usr/bin/env python3
"""Execute ONE approved, source-bound game build behind recorded PID gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import check_observed


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    temp=path.with_suffix('.tmp')
    temp.write_text(json.dumps(value,indent=2)+'\n')
    temp.replace(path)


def process():
    stat=Path('/proc/self/stat').read_text().split(') ',1)[1].split()
    return dict(pid=os.getpid(),starttime=stat[19],nice=os.getpriority(os.PRIO_PROCESS,0))


def gate(path):
    while not path.exists():
        time.sleep(0.2)


def main(base, child):
    plan=json.loads((base/'game-build-plan.json').read_text())
    if child:
        write(base/'compiler-child.json',process())
        gate(base/'compiler.release')
        os.chdir(plan['cwd'])
        os.execv(plan['argv'][0],plan['argv'])
    assert not (base/'build-start.json').exists(), 'ONE build already started'
    assert not (base/'build.release').exists(), 'record controller before release'
    assert os.getpriority(os.PRIO_PROCESS,0)>=10, 'NI10 required'
    assert plan['argv'][plan['argv'].index('-j')+1]=='1'
    assert plan['argv'][plan['argv'].index('--threads')+1]=='1'
    check_observed.check(base)
    pending=json.loads((base/'model-pin.pending.json').read_text())
    assert pending['composition_sha256']==sha(base/'composition.json')
    assert pending['game_build_plan_sha256']==sha(base/'game-build-plan.json')
    identity=process()
    write(base/'build-start.json',dict(controller=identity,source=pending['source'],
        composition_sha256=pending['composition_sha256'],
        argv_sha256=hashlib.sha256(json.dumps(plan['argv']).encode()).hexdigest(),
        compiler_sha256=sha(Path(plan['argv'][0])),phase='WAITING_RECORDED_CONTROLLER_RELEASE'))
    gate(base/'build.release')
    check_observed.check(base)
    with (base/'game-build.log').open('w') as log:
        compiler=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),
            '--base',str(base),'--compiler-child'],stdout=log,stderr=subprocess.STDOUT)
        while not (base/'compiler-child.json').exists():
            assert compiler.poll() is None, 'compiler child exited before gate'
            time.sleep(0.1)
        child_identity=json.loads((base/'compiler-child.json').read_text())
        assert child_identity['pid']==compiler.pid
        write(base/'build-active.json',dict(controller=identity,compiler=child_identity,
            argv=plan['argv'],cwd=plan['cwd'],jobs=1,threads=1,phase='COMPILING'))
        (base/'compiler.release').touch()
        code=compiler.wait()
    receipt=dict(controller=identity,compiler=child_identity,build_exit=code,
        log_sha256=sha(base/'game-build.log'),models_executed=0)
    write(base/'build-complete.json',receipt)
    if code:
        raise SystemExit(code)
    for name,digest in json.loads((base/'composition.json').read_text())['copies_sha256'].items():
        assert sha(base/name)==digest, ('input changed during build',name)
    binary=Path(plan['argv'][plan['argv'].index('--Mdir')+1])/'Vtb_ds_pocket'
    assert binary.is_file()
    with binary.open('rb') as stream:
        assert stream.read(4)==b'\x7fELF'
    pin=dict(pending,state='ACTUAL_GAME_BUILD_COMPLETE_RUNTIME_UNKNOWN',build_exit=0,
        binary_path=str(binary),binary_sha256=sha(binary),build_receipt_sha256=sha(base/'build-complete.json'))
    write(base/'model-pin.json',pin)
    print(json.dumps(pin,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',required=True,type=Path)
    parser.add_argument('--compiler-child',action='store_true')
    args=parser.parse_args()
    main(args.base.resolve(),args.compiler_child)
