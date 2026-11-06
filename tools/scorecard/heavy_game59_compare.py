#!/usr/bin/env python3
"""Read-only current-heavy24 comparison; never shifts timestamps or reruns a model."""
from datetime import datetime, timezone
import gzip
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import struct
import sys
import time

from heavy_game59 import ROOT,OUT,STAGED,GAME,CONTROL,OLD_MODEL,CONTROL_MODEL,sha,write
from storage_control56_compare import sequence,pixels,ppm
from c549_fetch_game52_compare import cpu_pair,snapshot_pair
sys.path.insert(0,str(Path(__file__).with_name('game52_lib')))
import storage_pair_capture_analyze as a
from storage_pair_capture_causal import Causal
from storage_pair_root40_gate_compare import ldm_check


def main():
    if os.getpriority(os.PRIO_PROCESS,0)<10:os.setpriority(os.PRIO_PROCESS,0,10)
    start=time.monotonic()
    worker=dict(PID=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],
        host=os.uname().nodename,NI=os.getpriority(os.PRIO_PROCESS,0),jobs=1,threads=1)
    def phase(s):write(OUT/'analysis-status.json',dict(worker,phase=s,elapsed_seconds=time.monotonic()-start))
    phase('VERIFY_PINNED_SOURCE_INPUT_MODEL_CAPTURE_AND_PROFILE')
    bound=json.loads((OUT/'bound-source.json').read_text());profile=bound['profile']
    terminal=json.loads((OUT/'terminal.json').read_text());assert terminal['exit']==0 and terminal['all_children_reaped']
    model=terminal['model_sha256'];assert sha(OUT/'model.bin')==model
    control=CONTROL if (CONTROL/'model.bin').is_file() else OUT/'controls/control56'
    assert sha(GAME/'model.bin')==OLD_MODEL and sha(control/'model.bin')==CONTROL_MODEL
    prep=json.loads((OUT/'host-preparation.json').read_text())
    for name,h in prep['files'].items():assert sha(STAGED/name)==h,name
    production=json.loads((OUT/'production-manifest.json').read_text())
    for name,h in production.items():assert sha(STAGED/'production'/name)==h,name
    captures=json.loads((OUT/'capture-manifest.json').read_text())
    for name,row in captures.items():
        p=OUT/'capture'/name;assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256'],name
        if name.endswith('.gz'):
            with gzip.open(p,'rb') as f:assert struct.unpack('<4I',f.read(16))==(0x33504453,1,40,1)
    old_binding=json.loads((control/'game52-cache-binding.json').read_text())
    assert sha(GAME/'comparison-streams.json.gz')==old_binding['reused_cache_sha256']
    assert json.loads((GAME/'capture-manifest.json').read_text())['capture.bus.gz']['sha256']==old_binding['raw_capture_sha256']
    with gzip.open(GAME/'comparison-streams.json.gz','rt') as f:_,old=json.load(f)
    phase('CHECK_CURRENT_ALL_PORT_PHYSICAL_CAUSAL_AND_FULL58_PROFILE')
    comparison=OUT/'comparison';comparison.mkdir(exist_ok=True)
    alias=comparison/'B1'
    if not alias.exists():alias.symlink_to(OUT,target_is_directory=True)
    assert alias.resolve()==OUT
    a.B=comparison;a.Causal=lambda ignored:Causal(1)
    service,extra=a.bus('B1');write(OUT/'current-service.json',service)
    with gzip.open(OUT/'current-streams.json.gz','wt') as f:json.dump(extra,f)
    rows=[]
    def witnessed():
        for row in a.rows(OUT/'capture/capture.bus.gz'):
            if row[1]==63:rows.append(row)
            yield row
    ldm=ldm_check(witnessed());write(OUT/'current-ldm.json',ldm)
    assert len(rows)==len(profile)==58
    for i,(name,value) in enumerate(sorted(profile.items())):
        found=[r for r in rows if r[3]==i];assert len(found)==1 and found[0][4:6]==(value,value),name
    write(OUT/'actual-profile-witness.json',dict(profile=profile,records=rows,all58_actual_constants_exact=True))
    phase('COMPARE_ARCHITECTURAL_CPU_PAYLOAD_ORDER_AND_RAW_TIMESTAMPS')
    cpu=cpu_pair(GAME,OUT);write(OUT/'CPU-comparison.json',cpu)
    contexts={}
    for key,row in cpu.items():
        first=row['first_semantic_difference']
        if first is None:continue
        index=first['index'];context={}
        for label,path in [('game52',GAME),('current',OUT)]:
            records=(r for r in a.rows(path/'capture/capture.cpu.gz') if r[2]==int(key))
            context[label]=list(itertools.islice(records,max(0,index-12),index+13))
        contexts[key]=dict(first_index=index,records=context,scope='Actual original ordinal, no polling/input/epoch normalization.')
    write(OUT/'first-semantic-context.json',contexts)
    phase('COMPARE_ORIGINAL_FIXED_CENSUS_IMAGES_MEMORY_STATE_SAVE_PCM_AND_DEADLINES')
    states=[[json.loads(s) for s in (p/'capture/capture.states.jsonl').read_text().splitlines()] for p in (GAME,OUT)]
    assert all([s['frame'] for s in ss]==list(range(25)) for ss in states)
    changed=[]
    for i,(x,y) in enumerate(zip(*states)):
        if x!=y:changed.append(dict(frame=i,changed_fields=[k for k in x if x[k]!=y[k]],game52=x,current=y))
    frames=[]
    for n in range(24):
        old_image=ppm(GAME/'shots'/f'f{n:03d}.ppm');new_image=ppm(OUT/'shots'/f'f{n:03d}.ppm')
        row=dict(raw_frame=n,original_reference=n-5,paired_pixels=pixels(old_image,new_image))
        if n>=10:
            reference=ppm(GAME/'controls/reference/mel/shots'/f'f{n-5:06d}.ppm');projected=bytearray(reference)
            for i in range(256*192*3,len(projected),3):
                for c in (0,2):projected[i+c]=((reference[i+c]>>3)<<3)|(reference[i+c]>>5)
            row['current_Pocket_precision_pixels']=pixels(new_image,projected)
            row['game52_Pocket_precision_pixels']=pixels(old_image,projected)
        frames.append(row)
    write(OUT/'frames.json',frames)
    audio=sequence(old['audio'],extra['audio']);logical=sequence(old['logical_stream'],extra['logical_stream'])
    producer=sequence(old['commits'],extra['commits']);deadlines=sequence(old['deadlines'],extra['deadlines'])
    def payload_hash(rows):
        h=hashlib.sha256()
        for r in rows:h.update(struct.pack('<9I',*r[1:]))
        return h.hexdigest()
    logical['payload_sha256']={k:payload_hash(v['logical_stream']) for k,v in [('game52',old),('current',extra)]}
    save=dict(game52_bytes=(GAME/'save.bin').stat().st_size,current_bytes=(OUT/'save.bin').stat().st_size,
        byte_equal=(GAME/'save.bin').read_bytes()==(OUT/'save.bin').read_bytes(),game52_sha256=sha(GAME/'save.bin'),current_sha256=sha(OUT/'save.bin'))
    imports={};native_guards={}
    for label,p in [('game52',GAME),('current',OUT)]:
        log=(p/'native.log').read_text();imports[label]=[s for s in log.splitlines() if s.startswith('import:')]
        assert len(imports[label])==3 and not re.search(r'(^FAIL$|%Error|never released|^TIMEOUT$)',log,re.M),label
        vm=re.search(r'^vmcheck: (\d+) words read, (\d+) CPU reads from the block buffer, (\d+) mismatches$',log,re.M)
        video=re.search(r'^video: 24 frames, (\d+) errors;.*; underruns (\d+)$',log,re.M)
        assert vm and video and int(vm[1])>0 and tuple(map(int,vm.group(2,3)))==(0,0),label
        assert tuple(map(int,video.groups()))==(0,0),label
        assert 'save: exported 262144 bytes, reader errors 0, runs 1' in log,label
        finish=re.search(r'\$finish at ([^;]+);',log);assert finish,label
        native_guards[label]=dict(VM_words=int(vm[1]),CPU_block_buffer_reads=int(vm[2]),VM_mismatches=int(vm[3]),video_errors=int(video[1]),underruns=int(video[2]),save_export_bytes=262144,save_reader_errors=0,actual_finish=finish[1])
    # Real retained-record faults distinguish intentional timestamp changes
    # from a changed architectural value; originals are never rewritten.
    sample=None
    for r in a.rows(GAME/'capture/capture.cpu.gz'):
        if r[1] in (101,102):sample=list(r);break
    assert sample is not None
    timed=sample.copy();timed[0]+=1;data=sample.copy();data[4]^=1
    timed_result=sequence([sample],[timed]);data_result=sequence([sample],[data])
    assert timed_result['timed_differences']==1 and timed_result['payload_order_differences']==0
    assert data_result['payload_order_differences']==1
    image=ppm(OUT/'shots/f010.ppm');bad=bytearray(image);bad[0]^=0x80;assert pixels(image,bad)==[1,0]
    functional=dict(original14_Census_fixed_pairs=all(not any(r['current_Pocket_precision_pixels']) for r in frames if r['raw_frame']>=10),
        exact_save=save['byte_equal'] and save['current_bytes']==262144,
        physical_protocol=service['error_count']==0,causal_record_data_order=service['causal']['error_count']==0,
        no_observed_ring_expirations=not service['causal']['ring_expirations'],
        observed_LDM_endpoints=ldm['status']=='PASS_OBSERVED_LDM_ENDPOINTS',full58_profile=True)
    architectural=dict(CPU_semantic_sequence=all(r['first_semantic_difference'] is None for r in cpu.values()),
        exact_frame_memory_register_state=not changed,producer_payload_order=producer['payload_order_differences']==0,
        logical_payload_order=logical['payload_order_differences']==0)
    gaps=[k for k,v in functional.items() if not v]+[k for k,v in architectural.items() if not v]
    report=dict(source=bound['source'],profile=profile,model_sha256=model,control_source='b50a215bfea9b23f5c9b0491125404f559610337',control_model_sha256=OLD_MODEL,
        disposition='PASS_FINITE_FIXED_FRAME_DATA_GATES' if not gaps else 'OPEN_CURRENT_SOURCE_OBSERVABLE_ATTRIBUTION',
        functional_checks=functional,architectural_comparisons=architectural,unresolved=gaps,
        CPU=cpu,changed_states=changed,images_changed=sum(any(r['paired_pixels']) for r in frames),
        failing_fixed_pairs=sum(any(r['current_Pocket_precision_pixels']) for r in frames if r['raw_frame']>=10),
        audio=audio,logical=logical,producer=producer,deadlines=deadlines,save=save,import_events=imports,native_guards=native_guards,
        raw_timestamp_policy='CPU timing intentionally changed; exact CPU timestamp equality is not an acceptance gate. All actual event/import/frame/PCM/packet/deadline stamps retained and reported, no shifts. Data/state/order/frame/save/audio differences require actual attribution.',
        raw_PCM_scope='Full raw PCM values/order/timestamps comparison retained; no independent audio/DS cadence acceptance or automatic timing waiver.',
        prior_scopes='Control56 matched-source external-pair acceptance remains closed. This is a new current source/profile; old MAINhit/helper-context gaps and final six-scene/DS/audio/fit/67MHz gates remain open.',
        mutation_controls=dict(actual_RF_value_bit=data_result,actual_CPU_timestamp_plus1ps=timed_result,actual_frame10_pixel='CAUGHT'),
        reused_control_raw_binding=old_binding,wall_seconds=time.monotonic()-start,at_UTC=datetime.now(timezone.utc).isoformat())
    write(OUT/'comparison.json',report)
    first=dict(source=bound['source'],functional_gaps=[k for k,v in functional.items() if not v],
        first_CPU_semantic={k:r['first_semantic_difference'] for k,r in cpu.items()},
        first_CPU_time_or_data={k:r['first_time_or_data_difference'] for k,r in cpu.items()},
        first_frame_state=changed[0] if changed else None,first_failing_fixed_pair=next((r for r in frames if r['raw_frame']>=10 and any(r['current_Pocket_precision_pixels'])),None),
        first_logical=logical['first_payload_order_difference'],first_audio=audio['first_timed_difference'])
    write(OUT/'first-source-gap.json',first);phase('TERMINAL_'+report['disposition'])
    print(json.dumps(dict(disposition=report['disposition'],functional=functional,architectural=architectural,failing_fixed_pairs=report['failing_fixed_pairs'],wall_seconds=report['wall_seconds'])),flush=True)


if __name__=='__main__':
    try:main()
    except Exception as e:
        write(OUT/'analysis-failure.json',dict(error=type(e).__name__,message=str(e),at_UTC=datetime.now(timezone.utc).isoformat(),scope='Read-only parser failed; preserve exact failure and data. Never rerun a native model to repair an offline parser.'))
        raise
