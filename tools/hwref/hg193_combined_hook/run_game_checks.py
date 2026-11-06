#!/usr/bin/env python3
"""Sequential qualification using the single approved actual game binary."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

from build_game import gate, process, write
from verify_game_launch import validate


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(base, child):
    directory=base/'qualification'
    plan=json.loads((directory/'run-plan.json').read_text())
    if child is not None:
        case=plan['cases'][child]
        target=directory/case['name']
        write(target/'child.json',process())
        gate(target/'release')
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        os.chdir(plan['cwd'])
        # Line buffering makes bounded success markers observable immediately.
        os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*case['argv']])
    assert not (directory/'controller.json').exists(), 'qualification already started'
    assert not (directory/'release').exists(), 'record controller before release'
    assert os.getpriority(os.PRIO_PROCESS,0)>=10
    pin=json.loads((base/'model-pin.json').read_text())
    assert pin['build_exit']==0
    write(directory/'controller.json',dict(controller=process(),plan_sha256=sha(directory/'run-plan.json'),
        model_sha256=pin['binary_sha256'],launcher_sha256=sha(Path(__file__).resolve()),
        phase='WAITING_RECORDED_RELEASE',jobs=1,threads=1))
    gate(directory/'release')
    results=[]
    for number,case in enumerate(plan['cases']):
        for name,digest in plan['input_files_sha256'].items():
            assert sha(base/name)==digest, ('scene input changed',name)
        guard=validate(base,pin,case['argv'],case['scene'])
        target=directory/case['name'];target.mkdir()
        write(target/'launcher-guard.json',guard)
        write(target/'argv.json',case['argv'])
        log=target/'runtime.log'
        started=time.monotonic();stopped=False;timed_out=False
        with log.open('w') as output:
            worker=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(base),
                '--child',str(number)],stdout=output,stderr=subprocess.STDOUT)
            while not (target/'child.json').exists():
                assert worker.poll() is None
                time.sleep(.1)
            identity=json.loads((target/'child.json').read_text())
            assert identity['pid']==worker.pid
            write(directory/'active.json',dict(controller=process(),child=identity,case=case['name'],
                argv=case['argv'],jobs=1,threads=1))
            (target/'release').touch()
            while worker.poll() is None:
                text=log.read_text(errors='replace')
                if case['kind']=='positive_stop_at_release' and case['expect'] in text:
                    worker.terminate();stopped=True;break
                if time.monotonic()-started>3600:
                    worker.terminate();timed_out=True;break
                time.sleep(.5)
            try:
                code=worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill();code=worker.wait()
        text=log.read_text(errors='replace')
        positive='COMBINED_WRAM_IMPORT_READBACK_PASS private16384 shared8192 total24576' in text
        if case['kind']=='actual_memory_negative':
            passed=code!=0 and case['expect'] in text and not positive
        elif case['kind']=='positive_stop_at_release':
            passed=stopped and positive and 'import: stubs done at ' in text and 'Error' not in text
        else:
            passed=(code==0 and positive and 'HG193_SD_PAIR_SOURCE_ADAPTER_APPLIED:' in text
                and 'import: released at ' in text and 'video: 85 frames' in text
                and 'TIMEOUT' not in text and '%Error' not in text)
        result=dict(case=case['name'],kind=case['kind'],passed=passed,exit_code=code,
            stopped_after_question_answered=stopped,wall_timeout=timed_out,
            elapsed_seconds=round(time.monotonic()-started,3),child=identity,
            log_sha256=sha(log),argv_sha256=sha(target/'argv.json'),
            actual_wram_readback=positive,model_sha256=pin['binary_sha256'],
            full_scene_equality='UNKNOWN; no matched architectural/pixel oracle in this check')
        write(target/'result.json',result);results.append(result)
        write(directory/'results.json',dict(results=results,all_pass=all(r['passed'] for r in results),
            full_scene_qualification='UNKNOWN',all_started_children_reaped=True))
        if not passed:
            raise SystemExit('Qualification stopped at actual failure: '+case['name'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',required=True,type=Path)
    parser.add_argument('--child',type=int)
    args=parser.parse_args()
    run(args.base.resolve(),args.child)
