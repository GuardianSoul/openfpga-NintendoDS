#!/usr/bin/env python3
"""Analyze the completed AC106 capture with frozen readers and fixed maps."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import textwrap
import time

from build_game import write


def sha(path):
    h=hashlib.sha256()
    with path.open('rb')as f:
        for data in iter(lambda:f.read(1<<20),b''):h.update(data)
    return h.hexdigest()


def analyze(base):
    os.setpriority(os.PRIO_PROCESS,0,10)
    case=base/'runtime-checks/ac106';start=time.monotonic()
    pin=json.loads((base/'model-pin.json').read_text());terminal=json.loads((case/'terminal.json').read_text())
    assert terminal['exit_code']==0 and terminal['reaped'] and terminal['full_capture_complete']
    assert sha(Path(pin['binary_path']))==terminal['model_sha256']==pin['binary_sha256']
    assert terminal['source']==pin['source']
    manifest={p.name:dict(bytes=p.stat().st_size,sha256=sha(p))for p in (case/'capture').iterdir()if p.is_file()}
    write(case/'capture-manifest.json',manifest)
    library=base/'checker-bindings'
    expected=json.loads((base/'capture-source-check.json').read_text())['observable']['qualified_reader_sha256']
    for name,digest in expected.items():assert sha(library/name)==digest
    sys.path.insert(0,str(library));import storage_pair_capture_analyze as reader
    from storage_pair_capture_causal import Causal
    from storage_pair_root40_gate_compare import ldm_check
    comp=case/'comparison';comp.mkdir(exist_ok=True)
    if not(comp/'B1').exists():(comp/'B1').symlink_to(case,target_is_directory=True)
    reader.B=comp;reader.Causal=lambda _:Causal(1)
    worker=dict(PID=os.getpid(),starttime=Path('/proc/self/stat').read_text().split(') ',1)[1].split()[19],NI=10,jobs=1,threads=1)
    write(case/'analysis-status.json',dict(worker,phase='PHYSICAL_CAUSAL'))
    service,streams=reader.bus('B1');write(case/'service.json',service)
    with gzip.open(case/'streams.json.gz','wt')as f:json.dump(streams,f)
    write(case/'analysis-status.json',dict(worker,phase='ROOT40_LDM'))
    write(case/'ldm.json',ldm_check(reader.rows(case/'capture/capture.bus.gz')))
    # Execute exactly the qualified CPU replay block: no new decoding,
    # timestamp normalization or register-hash implementation.
    repo=Path(__file__).resolve().parents[3]
    old=repo/'docs/results/scenes63-20261102/host/compare-scenes63-prefix.py'
    text=old.read_text();begin=text.index('        states=[json.loads(s)for s in ')
    end=text.index("        write(base/'CPU-state-replay.json',cpu)",begin)
    end=text.index('\n',end)+1;block=textwrap.dedent(text[begin:end])
    mix=lambda h,v:((h^v)*1099511628211)&((1<<64)-1)
    scope=dict(base=case,json=json,a=reader,FRAMES=106,mix=mix,write=write)
    write(case/'analysis-status.json',dict(worker,phase='CPU_STATE_REPLAY'))
    exec(compile(block,'qualified-scenes63-CPU-replay','exec'),scope)
    cpu=scope['cpu'];assert cpu['all_snapshots_equal']
    write(case/'CPU-replay-source-binding.json',dict(source_path=str(old),source_sha256=sha(old),
        exact_block_sha256=hashlib.sha256(block.encode()).hexdigest(),body_rewritten=False,
        scope='Only frame/model/path/source binding differs; CPU replay and its actual RF-bit control unchanged'))
    write(case/'analysis-status.json',dict(worker,phase='FIXED_REFERENCE_IMAGES_SAVE_CADENCE'))
    prior=repo/'docs/results/scenes63-20261102/results/ac/preparation.json'
    prep=json.loads(prior.read_text());reference=base/'reference-ac106'
    refbinding=json.loads((base/'reference-ac106-binding.json').read_text())
    for name,digest in refbinding['files_sha256'].items():assert sha(reference/name)==digest,name
    assert sha(reference/'ready.json')==prep['ready_sha256']
    def ppm(p):
        h=p.read_bytes().split(b'\n',3);assert h[:3]==[b'P6',b'256 384',b'255']
        assert len(h[3])==256*384*3;return h[3]
    def pixels(a,b):return [sum(a[i:i+3]!=b[i:i+3]for i in range(j,j+256*192*3,3))for j in [0,256*192*3]]
    frames=[]
    for row in prep['frame_pairs']:
        image=case/'shots'/f'f{row["raw"]:03d}.ppm';ref=reference/'mel/shots'/f'f{row["reference"]:06d}.ppm'
        result=dict(row,native_sha256=sha(image),reference_available=ref.exists())
        if ref.exists():
            raw=ppm(ref);mapped=bytearray(raw)
            for i in range(256*192*3,len(mapped),3):
                for c in [0,2]:mapped[i+c]=((raw[i+c]>>3)<<3)|(raw[i+c]>>5)
            result.update(reference_sha256=sha(ref),strict_pixels=pixels(ppm(image),raw),Pocket_precision_pixels=pixels(ppm(image),mapped))
        frames.append(result)
    settled=[r for r in frames if r['settled']and r['reference_available']]
    log=(case/'native.log').read_text()
    release=re.search(r'import: released at (\d+), video frame (\d+)',log);assert release
    actual_release=int(release[2]);fixed_release=prep['frozen_prior_release_video']
    vm=re.search(r'^vmcheck: (\d+) words read, (\d+) CPU reads from the block buffer, (\d+) mismatches$',log,re.M)
    video=re.search(r'^video: 106 frames, (\d+) errors;.*; underruns (\d+)$',log,re.M);assert vm and video
    times={int(k):int(v)for v,k in re.findall(r'\[(\d+)\] video frame (\d+):',log)}
    swaps={int(k):int(v)for v,k in re.findall(r'g3d swaps: (\d+) at video frame (\d+)',log)}
    census={int(f):int(c)for f,c in [x.split()for x in (reference/'mel/swaps.txt').read_text().splitlines()if x.strip()]}
    lo,hi=fixed_release+4,106;clo,chi=lo-fixed_release,hi-fixed_release
    cadence=dict(native_boundaries=[lo,hi],Census_boundaries=[clo,chi],
        native_scene_updates=swaps[hi]-swaps[lo],Census_scene_updates=census[chi]-census[clo],
        common_virtual_seconds=(times[hi]-times[lo])*1e-12,
        scope='Original fixed boundaries; no re-matching to new actual release; proxies are not DS gameplay/PCM truth')
    checks=dict(fixed_frame_pairs=all(not any(r['Pocket_precision_pixels'])for r in settled),
        original_release=actual_release==fixed_release,video_clean=video.groups()==('0','0'),VM_no_mismatch=vm[3]=='0',
        physical_protocol=service['error_count']==0,causal_order=service['causal']['error_count']==0,
        CPU_capture_integrity=cpu['all_snapshots_equal'],save_initial_equal=(case/'save.bin').read_bytes()==(reference/'exp/save.bin').read_bytes(),
        save_Census_terminal_equal=(case/'save.bin').read_bytes()==(reference/'final-save.bin').read_bytes(),
        scene_update_proxy=cadence['native_scene_updates']==cadence['Census_scene_updates'])
    report=dict(source=pin['source'],model_sha256=pin['binary_sha256'],frames=frames,checks=checks,
        failed=[n for n,v in checks.items()if not v],actual_release=actual_release,fixed_release=fixed_release,
        cadence=cadence,PCM_samples_retained=len(streams['audio']),reference_ready_sha256=prep['ready_sha256'],
        old_fixed_map_preparation_sha256=sha(prior),elapsed_analysis_seconds=time.monotonic()-start,
        current_profile60='Runtime COMBINED binding checks execute before WRAM pass; legacy kind63 heavy58 witness was not compiled. No claim old58 witness fired.',
        known_assertion_gap='Two standalone extra assertions unbound in this ELF; resolved-five/metadata-default proof and Python launch contract retained.',
        limits=['Capture integrity is not DS/Census architectural trajectory equivalence.',
            'No qualified reference PCM; sample stream preserved without sound-law acceptance.',
            'No frame/phase normalization or blanket tolerance; earlier known failures remain open.'])
    write(case/'observable-comparison.json',report)
    write(case/'analysis-status.json',dict(worker,phase='COMPLETE',failed=report['failed'],elapsed_seconds=time.monotonic()-start))
    print(json.dumps({k:report[k]for k in ['source','model_sha256','failed','actual_release','fixed_release','PCM_samples_retained']},indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',required=True,type=Path)
    a=p.parse_args();analyze(a.base.resolve())
