#!/usr/bin/env python3
"""One pinned binary: strict HG85 diagnostic then complete AC106 capture."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import struct
import subprocess
import sys
import time
import zlib

from build_game import gate,process,write
from verify_game_launch import validate
from check_resolved_route import check as check_resolved_route


def sha(path):
    h=hashlib.sha256()
    with path.open('rb')as stream:
        for data in iter(lambda:stream.read(1<<20),b''):h.update(data)
    return h.hexdigest()


def tap_prefix(directory):
    result={}
    for name in ['bus','cpu']:
        path=directory/'capture'/('capture.'+name+'.gz')
        decoder=zlib.decompressobj(16+zlib.MAX_WBITS);raw=bytearray();limit=16+40*65536
        with path.open('rb')as stream:
            while len(raw)<limit:
                block=stream.read(65536)
                if not block:break
                raw+=decoder.decompress(block,limit-len(raw))
        header=struct.unpack('<4I',raw[:16]);assert header==(0x33504453,1,40,1)
        data=raw[16:16+((len(raw)-16)//40)*40]
        assert data
        rows=list(struct.iter_unpack('<Q6IQ',data))
        result[name]=dict(header=header,prefix_events=len(rows),kinds=sorted({r[1]for r in rows}),
            scope='complete decoded prefix records only; not a gzip/footer/full-scene qualification')
    assert 100 in result['cpu']['kinds'], 'actual CPU retire tap emitted no events'
    return result


def run(base,child,start_at=0):
    work=base/'runtime-checks';plan=json.loads((work/'run-plan.json').read_text())
    if child is not None:
        case=plan['cases'][child];directory=work/case['name']
        write(directory/'child.json',process());gate(directory/'release')
        resource.setrlimit(resource.RLIMIT_CORE,(0,0));os.chdir(case['cwd'])
        os.execv('/usr/bin/stdbuf',['stdbuf','-oL',*case['argv']])
    assert not(work/'controller.json').exists() and not(work/'release').exists()
    assert os.getpriority(os.PRIO_PROCESS,0)>=10
    pin=json.loads((base/'model-pin.json').read_text());assert pin['build_exit']==0
    write(work/'controller.json',dict(controller=process(),model_sha256=pin['binary_sha256'],
        plan_sha256=sha(work/'run-plan.json'),launcher_sha256=sha(Path(__file__).resolve()),
        jobs=1,threads=1,phase='WAITING_RECORDED_RELEASE'))
    gate(work/'release')
    results=[json.loads((work/'hg85-boundary/terminal.json').read_text())]if start_at==1 else []
    for index,case in enumerate(plan['cases']):
        if index<start_at:continue
        directory=work/case['name']
        assert shutil.disk_usage(work).free>8*1024**3
        for name,digest in case['input_sha256'].items():assert sha(base/name)==digest,name
        guard=validate(base,pin,case['argv'],case['scene'])
        resolved=check_resolved_route(base)
        write(base/'resolved-route-proof.json',resolved)
        args={a[1:].split('=',1)[0]:a.split('=',1)[1]for a in case['argv']if '='in a}
        assert int(args['scene_capture_frames'])>=106 and int(args['frames'])<=int(args['scene_capture_frames'])
        assert int(args['scene_save_words'])*4==int(args['savsize']) and args['shots']and args['savout']
        write(directory/'launcher-guard.json',guard);write(directory/'argv.json',case['argv'])
        for name in ['capture','shots']:(directory/name).mkdir(exist_ok=True)
        log=directory/'native.log';start=time.monotonic();stopped=False;timed_out=False
        with log.open('w')as output:
            worker=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'--base',str(base),
                '--child',str(index)],stdout=output,stderr=subprocess.STDOUT)
            while not(directory/'child.json').exists():
                assert worker.poll()is None;time.sleep(.1)
            identity=json.loads((directory/'child.json').read_text());assert identity['pid']==worker.pid
            write(work/'active.json',dict(controller=process(),child=identity,case=case['name'],jobs=1,threads=1))
            (directory/'release').touch()
            while worker.poll()is None:
                text=log.read_text(errors='replace')
                if case['kind']=='strict_HG_boundary' and 'HG193_SD_PAIR_SOURCE_ADAPTER_APPLIED:'in text:
                    worker.terminate();stopped=True;break
                if time.monotonic()-start>case['wall_budget_seconds']:
                    worker.terminate();timed_out=True;break
                assert len(list(Path('/proc',str(worker.pid),'task').glob('*')))<=1
                time.sleep(.5)
            try:code=worker.wait(timeout=15)
            except subprocess.TimeoutExpired:worker.kill();code=worker.wait()
        text=log.read_text(errors='replace')
        if 'CAPTURE41_ACCEPTED_SOURCE_FIVE1_METADATA0_PASS'not in text:
            result_route='generated five hierarchy + compiled-source metadata0 graph; new SV assertions unbound'
        else:result_route='actual SV assertion marker'
        assert 'ROOT40_LDM_CAPTURE_PROFILE_OK'in text and 'SCENE_CAPTURE:'in text,'actual capture tap profile missing'
        assert 'COMBINED_WRAM_IMPORT_READBACK_PASS private16384 shared8192 total24576'in text
        taps=tap_prefix(directory)
        result=dict(case=case['name'],source=pin['source'],model_sha256=pin['binary_sha256'],exit_code=code,
            child=identity,reaped=True,wall_seconds=round(time.monotonic()-start,3),wall_timeout=timed_out,
            stopped_once_question_answered=stopped,actual_route_and_tap_checks=taps,
            route_proof=result_route,resolved_route=resolved,log_sha256=sha(log))
        if case['kind']=='strict_HG_boundary':
            clauses=dict(re.findall(r'HG193_CPU_CLAUSE phase=before-publication name=(\w+) pass=([01])',text))
            assert len(clauses)==26,'all actual26 clauses required'
            result.update(diagnostic_answered=True,clauses=clauses,
                failed_clauses=[n for n,v in clauses.items()if v=='0'],
                raw=dict(re.findall(r'HG193_CPU_RAW phase=before-publication name=(\w+) value=(\w+)',text)),
                history_published='HG193_SD_PAIR_SOURCE_ADAPTER_APPLIED:'in text,
                known_HG_failure_retained=code!=0 and 'HG193 combined drain:'in text,
                full_scene_qualification='NOT_CLAIMED; stopped/failed diagnostic')
            assert result['known_HG_failure_retained']or result['history_published']
        else:
            assert code==0 and not timed_out and 'video: 106 frames'in text and 'TIMEOUT'not in text
            states=[json.loads(line)for line in (directory/'capture/capture.states.jsonl').read_text().splitlines()]
            images=sorted((directory/'shots').glob('*.ppm'))
            assert [r['frame']for r in states]==list(range(107))and len(images)==106
            assert (directory/'save.bin').stat().st_size==int(next(a.split('=',1)[1]for a in case['argv']if a.startswith('+savsize=')))
            for path in (directory/'capture').glob('*.gz'):
                with gzip.open(path,'rb')as stream:
                    while stream.read(1<<20):pass # require the complete gzip footer
            result.update(full_capture_complete=True,frames=106,state_rows=107,images=106,
                correctness='UNKNOWN pending fixed-map reference/physical/CPU/PCM/save analysis; old known scene failures not waived')
        write(directory/'terminal.json',result);results.append(result)
        write(work/'results.json',dict(results=results,started_children_reaped=True,baseline_runs=0,WRAM_mutant_reruns=0))
    write(work/'complete.json',dict(results=results,all_owned_children_reaped=True))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',required=True,type=Path)
    p.add_argument('--child',type=int);p.add_argument('--start-at',type=int,choices=[0,1],default=0)
    a=p.parse_args();run(a.base.resolve(),a.child,a.start_at)
