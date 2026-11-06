#!/usr/bin/env python3
"""Execute one prepared load2d fixture only after an explicit worker allocation.

A measured mismatch is evidence, not an execution failure. Reference parity
and complete raw16 captures remain mandatory before drawing that conclusion.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from load2d_run38 import compare,sha,stamp

def verify(root,plan):
    for directory,key in [('source','source_sha256'),('golden','golden_sha256'),('ds','ds_sha256'),('census','census_sha256')]:
        if not plan[key]:raise ValueError('empty input hash set: '+key)
        for name,h in plan[key].items():
            if sha(root/directory/name)!=h:raise ValueError('prepared input changed: '+directory+'/'+name)
    if sha(root/'preparer.py')!=plan['preparer_snapshot_sha256']:raise ValueError('prepared generator changed')
    cmd=plan['build_command']
    if plan['build_jobs']!=1 or plan['threads']!=1 or cmd[cmd.index('-j')+1]!='1' or cmd[cmd.index('--threads')+1]!='1':
        raise ValueError('single allocated worker requires jobs1/threads1')
    if Path(plan['run_environment']['RUN38_OUT']).resolve()!=(root/'captures').resolve():raise ValueError('capture output outside prepared root')

def classify(native_exit,result):
    if native_exit not in (0,1):raise ValueError('native fixture failed, exit '+str(native_exit))
    if not result['fixture_reference_valid']:raise ValueError('fixture gold differs from qualified Census19 captures')
    return 'MEASURED_MATCH_DS' if result['core_matches_DS'] else 'MEASURED_DIFFERENCE_DS'

def run(plan_path,allocation,run_timeout=180):
    os.nice(max(0,10-os.nice(0)))
    plan_path=plan_path.resolve();root=plan_path.parent;plan=json.loads(plan_path.read_text());verify(root,plan)
    if not allocation.strip():raise ValueError('missing worker allocation')
    if run_timeout<=0:raise ValueError('timeout must be positive')
    for path in [root/'native-result.json',root/'native.log',root/'core-comparison.json']:
        if path.exists():raise ValueError('preserve previous evidence: '+str(path))
    if any((root/'captures').iterdir()):raise ValueError('preserve existing captures')
    build_path=root/'build-result.json'
    if build_path.exists():
        b=json.loads(build_path.read_text())
        if b.get('exit')!=0 or b.get('host')!=socket.gethostname() or b['plan_sha256']!=sha(plan_path) or sha(b['model'])!=b['model_sha256']:
            raise ValueError('build changed/failed or belongs to another host; prepare fresh output')
    else:
        b=dict(host=socket.gethostname(),allocation=allocation,plan_sha256=sha(plan_path),runner_sha256=sha(__file__),command=plan['build_command'],launcher_pid=os.getpid(),launcher_nice=os.nice(0),exit=None)
        with (root/'build.log').open('w') as log:
            p=subprocess.Popen(b['command'],stdout=log,stderr=subprocess.STDOUT,cwd=root)
            b['pid']=p.pid;stamp(build_path,b);b['exit']=p.wait()
        b['log_sha256']=sha(root/'build.log')
        if b['exit']==0:
            b['model']=plan['run_command'][0];b['model_sha256']=sha(b['model'])
        stamp(build_path,b)
        if b['exit']!=0:return 1
    env=os.environ.copy();env.update(plan['run_environment'])
    m=dict(host=socket.gethostname(),allocation=allocation,launcher_nice=os.nice(0),plan_sha256=sha(plan_path),build_manifest_sha256=sha(build_path),model_sha256=b['model_sha256'],runner_sha256=sha(__file__),command=plan['run_command'],run_environment=plan['run_environment'],run_timeout_seconds=run_timeout,hardware_capture=False,exit=None,status='RUNNING')
    with (root/'native.log').open('w') as log:
        p=subprocess.Popen(plan['run_command'],stdout=log,stderr=subprocess.STDOUT,cwd=root,env=env)
        m['pid']=p.pid;stamp(root/'native-result.json',m)
        try:m['exit']=p.wait(timeout=run_timeout)
        except subprocess.TimeoutExpired:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
            m['exit']=p.returncode;m['status']='TIMEOUT'
        except KeyboardInterrupt:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
            m['exit']=p.returncode;m['status']='INTERRUPTED'
    m['log_sha256']=sha(root/'native.log')
    if m['status'] in ('TIMEOUT','INTERRUPTED'):
        stamp(root/'native-result.json',m);return 1
    try:
        if m['exit'] not in (0,1):raise ValueError('native fixture failed, exit '+str(m['exit']))
        result=compare(root,root/'native.log');m['status']=classify(m['exit'],result)
        m['comparison_sha256']=sha(root/'core-comparison.json')
        m['fixture_reference_valid']=result['fixture_reference_valid'];m['core_matches_DS']=result['core_matches_DS']
        m['interpretation']='Complete six-scene measurement; native exit1 can mean retained core-vs-Census pixel differences. No general OBJ budget or full-system deadline qualification.'
    except (ValueError,OSError,KeyError) as e:
        m['status']='INVALID_MEASUREMENT';m['measurement_error']=str(e)
    stamp(root/'native-result.json',m);print(m['status'],flush=True)
    return 0 if m['status'].startswith('MEASURED_') else 1

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--plan',type=Path,required=True);p.add_argument('--allocation',required=True)
    p.add_argument('--run-timeout',type=int,default=180)
    a=p.parse_args();return run(a.plan,a.allocation,a.run_timeout)
if __name__=='__main__':sys.exit(main())
