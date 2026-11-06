#!/usr/bin/env python3
"""Run explicitly selected prepared peripheral cases on one allocated worker."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1<<20),b''):h.update(b)
    return h.hexdigest()

def stamp(path,data):path.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')

def metrics(text,case):
    if 'Verilator: cpu ' not in text or re.search(r'SERVICE_FAIL|%Error|%Fatal|\bTIMEOUT\b',text):
        raise ValueError('incomplete/failing native service run')
    if len(re.findall(r'^SERVICE_PASS$',text,re.M))!=1:raise ValueError('missing/duplicate SERVICE_PASS')
    def row(tag):
        rows=re.findall('^'+tag+r' (.+)$',text,re.M)
        if len(rows)!=1:raise ValueError('missing/duplicate '+tag)
        return {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',rows[0])}
    service,reply=row('SERVICE'),row('SERVICE_REPLY')
    required={'wifi','aux','memlat','wifi_transactions','aux_transactions','timer_due','timer_steps','spi_events','spi_age_max','engine_hold_ticks','firmware_hold_ticks','wifi_latency_max','aux_latency_max','wifi_spi_overlap','aux_spi_overlap','spi_fast_events','spi_fast_age_max','fast_engine_hold_ticks'}
    if not required<=service.keys():raise ValueError('missing service counters')
    expected={k:int(v) for k,v in (p.removeprefix('+service_').split('=',1) for p in case['command'] if p.startswith('+service_'))}
    if any(service[k]!=expected[k] for k in ('wifi','aux','memlat')):raise ValueError('wrong service configuration')
    if reply['bytes']<16 or reply['mismatches']!=0 or reply['irq_old']<1 or reply['irq_old']!=reply['irq_new']:
        raise ValueError('reply/IRQ failure or missing coverage')
    if service['spi_fast_events']<16:raise ValueError('missing fastest-baud coverage')
    if service['spi_events']<reply['bytes']:raise ValueError('missing SPI events')
    if not 0<=service['timer_due']-service['timer_steps']<=1:raise ValueError('timer event loss')
    if service['wifi'] and (service['wifi_transactions']<4 or service['timer_steps']<1 or service['wifi_spi_overlap']<1):raise ValueError('no WiFi overlap coverage')
    if service['aux'] and (service['aux_transactions']<6 or service['aux_spi_overlap']<1):raise ValueError('no AUX overlap coverage')
    return {'service':service,'reply':reply,'scope':'settled bytes/IRQ totals and explicit service counters; clock differences reported, no DS timing equivalence claim'}


def baseline_proof(proof_path,plan,names):
    """A failing mutant is meaningful only after this same case passes unchanged."""
    if len(names)!=1:raise ValueError('mutant requires one baseline-matched case')
    proof_path=Path(proof_path).resolve();base_root=proof_path.parent.parent
    proof=json.loads(proof_path.read_text());base_path=base_root/'plan.json';base=json.loads(base_path.read_text())
    if base.get('mutant') or base['source_sha']!=plan['source_sha'] or proof.get('exit')!=0 or proof.get('case',{}).get('name')!=names[0]:
        raise ValueError('mutant baseline is failed, mistargeted or another source')
    if proof['plan_sha256']!=sha(base_path) or proof['log_sha256']!=sha(proof_path.parent/'run.log'):
        raise ValueError('mutant baseline evidence changed')
    for name,h in base['source_sha256'].items():
        if sha(base_root/'source'/name)!=h:raise ValueError('baseline source changed: '+name)
    changed={n for n in set(base['source_sha256'])|set(plan['source_sha256']) if base['source_sha256'].get(n)!=plan['source_sha256'].get(n)}
    if changed!={'sim/ds_dev/service_eq/nds_spi_service_sys.sv'}:raise ValueError('mutant differs outside intended service wrapper')
    metrics((proof_path.parent/'run.log').read_text(),proof['case'])
    return {'path':str(proof_path),'sha256':sha(proof_path),'plan_sha256':sha(base_path),'case':names[0]}


def run(plan_path,names,allocation,baseline=None):
    os.nice(max(0,10-os.nice(0)))
    plan_path=plan_path.resolve();root=plan_path.parent;plan=json.loads(plan_path.read_text())
    control=None
    if plan.get('mutant'):
        if baseline is None:raise ValueError('mutant requires --baseline-proof from the passing unchanged case')
        control=baseline_proof(baseline,plan,names)
    for name,h in plan['source_sha256'].items():
        if sha(root/'source'/name)!=h:raise ValueError('prepared source changed: '+name)
    selected=[]
    for name in names:
        matches=[c for c in plan['cases'] if c['name']==name]
        if len(matches)!=1:raise ValueError('unknown/duplicate case: '+name)
        if (root/name).exists():raise ValueError('case exists; preserve evidence: '+name)
        selected+=matches
    if len(set(names))!=len(names):raise ValueError('duplicate requested case')
    build_path=root/'build-result.json'
    if build_path.exists():
        build=json.loads(build_path.read_text())
        if build.get('exit')!=0 or sha(build['model'])!=build['model_sha256'] or build['plan_sha256']!=sha(plan_path) or build.get('host')!=socket.gethostname():
            raise ValueError('existing build failed or changed; prepare a new output')
    else:
        cmd=plan['build_command']
        if cmd[cmd.index('-j')+1]!='1' or cmd[cmd.index('--threads')+1]!='1':raise ValueError('worker budget requires jobs1/threads1')
        build={'host':socket.gethostname(),'command':cmd,'allocation':allocation,'plan_sha256':sha(plan_path),'runner_sha256':sha(__file__),'launcher_pid':os.getpid(),'launcher_nice':os.nice(0),'exit':None}
        with (root/'build.log').open('w') as log:
            p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);build['pid']=p.pid;stamp(build_path,build)
            build['exit']=p.wait()
        model=root/'obj/Vtb_spi_eq'
        build['log_sha256']=sha(root/'build.log')
        if build['exit']==0:build.update(model=str(model),model_sha256=sha(model))
        stamp(build_path,build)
        if build['exit']!=0:return 1
    failure=False
    for case in selected:
        out=root/case['name'];out.mkdir()
        m={'host':socket.gethostname(),'allocation':allocation,'launcher_nice':os.nice(0),'case':case,'plan_sha256':sha(plan_path),'build_manifest_sha256':sha(build_path),
           'model_sha256':build['model_sha256'],'baseline_positive_control':control,'runner_sha256':sha(__file__),'exit':None,'hardware_capture':False}
        with (out/'run.log').open('w') as log:
            p=subprocess.Popen(case['command'],stdout=log,stderr=subprocess.STDOUT,cwd=root)
            m['pid']=p.pid;stamp(out/'manifest.json',m);m['exit']=p.wait()
        m['log_sha256']=sha(out/'run.log')
        text=(out/'run.log').read_text()
        if plan.get('mutant'):
            marker={'drop-spi-done':'SERVICE_FAIL watchdog','corrupt-wifi-read':'SERVICE_FAIL WiFi RAM'}[plan['mutant']]
            m['expected_mutant_caught']=m['exit']!=0 and marker in text
            failure|=not m['expected_mutant_caught']
        elif m['exit']==0:
            try:m['metrics']=metrics(text,case)
            except (ValueError,KeyError) as e:m['measurement_error']=str(e);failure=True
        else:failure=True
        stamp(out/'manifest.json',m)
        print(case['name'],'exit',m['exit'],'expected mutant caught',m.get('expected_mutant_caught'),flush=True)
        if failure:break
    return int(failure)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--plan',type=Path,required=True);p.add_argument('--case',action='append',required=True)
    p.add_argument('--allocation',required=True,help='record the coordinator machine/worker allocation')
    p.add_argument('--baseline-proof',type=Path,help='passing unchanged case manifest, required for mutant plans')
    a=p.parse_args();return run(a.plan,a.case,a.allocation,a.baseline_proof)
if __name__=='__main__':sys.exit(main())
