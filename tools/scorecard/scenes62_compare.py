#!/usr/bin/env python3
"""Read-only race24 reference gates and independently replayed CPU/state capture."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import time
from scenes62 import ROOT,OUT,HEAVY,SOURCE,MODEL,REF,sha,write
LIB=OUT/'checker-lib'
BINDING=json.loads((OUT/'frozen-checker-binding.json').read_text())
for name,value in BINDING['files'].items():assert sha(LIB/name)==value,name
sys.path.insert(0,str(LIB))
import storage_pair_capture_analyze as a
from storage_pair_capture_causal import Causal
from storage_pair_root40_gate_compare import ldm_check


def ppm(path):
    h=path.read_bytes().split(b'\n',3)
    assert h[:3]==[b'P6',b'256 384',b'255'] and len(h[3])==256*384*3
    return h[3]


def pixels(x,y):
    return [sum(x[i:i+3]!=y[i:i+3]for i in range(k,k+256*192*3,3))for k in (0,256*192*3)]


def mix(h,v):return ((h^v)*1099511628211)&((1<<64)-1)


def main():
    os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();base=OUT/'race'
    terminal=json.loads((base/'terminal.json').read_text());assert terminal['exit']==0 and terminal['reaped']
    assert not Path(f'/proc/{terminal["PID"]}').exists()
    assert sha(HEAVY/'model.bin')==MODEL and terminal['source']==SOURCE
    prep=json.loads((base/'preparation.json').read_text());reference=REF/prep['reference']
    assert sha(reference/'ready.json')==prep['ready_sha256']
    for name,value in prep['inputs'].items():assert sha(base/'inputs'/name)==value,name
    captures=json.loads((base/'capture-manifest.json').read_text())
    for name,row in captures.items():assert sha(base/'capture'/name)==row['sha256'],name
    worker=dict(host=os.uname().nodename,PID=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10,jobs=1,threads=1)
    def phase(value):write(base/'analysis-status.json',dict(worker,phase=value,elapsed_seconds=time.monotonic()-start))
    if '--finish-only' in sys.argv:
        binding=json.loads((base/'analysis-prefix-binding.json').read_text())
        assert sha(base/'capture-manifest.json')==binding['raw_manifest_sha256']
        for name,value in binding['files'].items():assert sha(base/name)==value,name
        service=json.loads((base/'service.json').read_text())
        with gzip.open(base/'streams.json.gz','rt')as f:extra=json.load(f)
        ldm=json.loads((base/'ldm.json').read_text())
        profile=json.loads((base/'profile-witness.json').read_text())['profile']
        cpu=json.loads((base/'CPU-state-replay.json').read_text())
    else:
        phase('CURRENT_ALL_PORT_PHYSICAL_CAUSAL_AND_FULL58_PROFILE')
        comp=base/'comparison';comp.mkdir(exist_ok=True);alias=comp/'B1'
        if not alias.exists():alias.symlink_to(base,target_is_directory=True)
        assert alias.resolve()==base
        a.B=comp;a.Causal=lambda _:Causal(1)
        service,extra=a.bus('B1');write(base/'service.json',service)
        with gzip.open(base/'streams.json.gz','wt')as f:json.dump(extra,f)
        profile=json.loads((OUT/'readiness.json').read_text())['profile'];witness=[]
        def witnessed():
            for row in a.rows(base/'capture/capture.bus.gz'):
                if row[1]==63:witness.append(row)
                yield row
        ldm=ldm_check(witnessed());write(base/'ldm.json',ldm)
        assert len(witness)==len(profile)==58
        for i,(name,value)in enumerate(sorted(profile.items())):
            rr=[r for r in witness if r[3]==i];assert len(rr)==1 and rr[0][4:6]==(value,value),name
        write(base/'profile-witness.json',dict(profile=profile,records=witness,all58_exact=True))
        phase('INDEPENDENT_RAW_CPU_TO_FRAME_STATE_REPLAY')
        states=[json.loads(s)for s in (base/'capture/capture.states.jsonl').read_text().splitlines()]
        assert [s['frame']for s in states]==list(range(25))
        def blank():return dict(retired=0,writes=0,pc=0,psr=0,seq=1469598103934665603,regs=[0]*64)
        cpus=[blank(),blank()];bad=[blank(),blank()];mutated=False;fault_frame=None;count=0;previous=0;check=[]
        def consume(cpu,row):
            t,k,p,addr,data,*_=row
            if k==100:
                cpu['retired']+=1;cpu['pc']=addr;cpu['psr']=data;cpu['seq']=mix(mix(cpu['seq'],addr),data)
            elif k in (101,102):
                cpu['writes']+=1;cpu['regs'][addr&63]=data;cpu['seq']=mix(mix(mix(cpu['seq'],k),addr),data)
        def project(cpu):
            h=1469598103934665603
            for i,v in enumerate(cpu['regs']):h=mix(h,(i<<32)|v)
            return dict(retired=cpu['retired'],writes=cpu['writes'],pc=cpu['pc'],psr=cpu['psr'],sequence_fnv64=f'{cpu["seq"]:x}',register_fnv64=f'{h:x}')
        records=iter(a.rows(base/'capture/capture.cpu.gz'));pending=next(records,None)
        for state in states:
            while pending is not None and pending[0]<=state['time_ps']:
                row=pending;assert row[0]>=previous;previous=row[0];count+=1
                if row[2]in (0,1):
                    consume(cpus[row[2]],row);fault=list(row)
                    if not mutated and row[1]in (101,102):fault[4]^=1;mutated=True
                    consume(bad[row[2]],fault)
                pending=next(records,None)
            actual=[project(c)for c in cpus]
            check.append(dict(frame=state['frame'],time_ps=state['time_ps'],equal=actual==state['cpu']))
            if mutated and fault_frame is None and [project(c)for c in bad]!=state['cpu']:fault_frame=state['frame']
        # Drain through the gzip footer; finite capture may have same-boundary debt.
        tail=0
        while pending is not None:tail+=1;pending=next(records,None)
        assert fault_frame is not None
        cpu=dict(records_replayed=count,endpoint_records_after_final_state=tail,states=check,all25_equal=all(x['equal']for x in check),
            per_CPU=[{k:v for k,v in c.items()if k!='regs'}for c in cpus],actual_RF_value_bit_mutation_caught_at_frame=fault_frame,
            scope='Independent capture-integrity replay at original frame timestamps, not equivalence with Census CPU execution or DS timing. No event normalization.')
        write(base/'CPU-state-replay.json',cpu)
    phase('FIXED_CENSUS23_IMAGES_SAVE_CADENCE_AND_GUARDS')
    frames=[]
    for row in prep['frame_pairs']:
        n=row['raw'];image=ppm(base/'shots'/f'f{n:03d}.ppm');r=dict(row,native_sha256=sha(base/'shots'/f'f{n:03d}.ppm'))
        ref=reference/'mel/shots'/f'f{row["reference"]:06d}.ppm'
        r['reference_available']=ref.is_file()
        if ref.is_file():
            raw=ppm(ref);projected=bytearray(raw)
            for i in range(256*192*3,len(projected),3):
                for c in (0,2):projected[i+c]=((raw[i+c]>>3)<<3)|(raw[i+c]>>5)
            r.update(reference_sha256=sha(ref),strict_pixels=pixels(image,raw),Pocket_precision_pixels=pixels(image,projected))
        frames.append(r)
    write(base/'frames.json',frames)
    log=(base/'native.log').read_text();assert not re.search(r'(^FAIL$|%Error|never released|^TIMEOUT$)',log,re.M)
    vm=re.search(r'^vmcheck: (\d+) words read, (\d+) CPU reads from the block buffer, (\d+) mismatches$',log,re.M)
    video=re.search(r'^video: 24 frames, (\d+) errors;.*; underruns (\d+)$',log,re.M);assert vm and video
    assert tuple(map(int,vm.group(2,3)))==tuple(map(int,video.groups()))==(0,0)
    assert f'save: exported {prep["native_save_bytes"]} bytes, reader errors 0, runs 1'in log
    release=re.search(r'import: released at (\d+), video frame (\d+)',log);assert release
    times={int(n):int(t)for t,n in re.findall(r'\[(\d+)\] video frame (\d+):',log)}
    swaps={int(n):int(c)for c,n in re.findall(r'g3d swaps: (\d+) at video frame (\d+)',log)}
    census={int(f):int(c)for f,c in [line.split()for line in (reference/'mel/swaps.txt').read_text().splitlines()if line.strip()]}
    lo,hi=10,24;clo,chi=4,18;duration=(times[hi]-times[lo])*1e-12
    cadence=dict(native_boundaries=[lo,hi],Census_boundaries=[clo,chi],timestamp_boundaries_ps=[times[lo],times[hi]],
        common_virtual_seconds=duration,native_scene_updates=swaps[hi]-swaps[lo],Census_scene_updates=census[chi]-census[clo],
        native_updates_per_second=(swaps[hi]-swaps[lo])/duration,Census_updates_per_second=(census[chi]-census[clo])/duration,
        scope='Fixed original boundaries. Native sort-completion and Census flush-count proxies; no gameplayFPS or DS cadence closure.')
    save=dict(bytes=(base/'save.bin').stat().st_size,sha256=sha(base/'save.bin'),initial_equal=(base/'save.bin').read_bytes()==(reference/'exp/save.bin').read_bytes(),
        Census100_terminal_equal=(base/'save.bin').read_bytes()==(reference/'final-save.bin').read_bytes())
    samples=extra['audio'];audio=dict(samples=len(samples),first=samples[0]if samples else None,last=samples[-1]if samples else None,
        PCM_sequence_sha256=hashlib.sha256(json.dumps(samples,separators=(',',':')).encode()).hexdigest(),
        qualified_reference_PCM=False,comparison='OPEN_REFERENCE_COVERAGE_GAP; raw PCM values/order/times retained without sample alignment.')
    settled=[x for x in frames if x['settled']and x['reference_available']];assert len(settled)==14
    image=ppm(base/'shots/f010.ppm');fault=bytearray(image);fault[0]^=128;assert pixels(image,fault)==[1,0]
    checks=dict(original14_fixed_pairs=all(not any(x['Pocket_precision_pixels'])for x in settled),save_initial_and_Census_terminal=save['initial_equal']and save['Census100_terminal_equal'],
        original_release_video=int(release[2])==6,physical_protocol=service['error_count']==0,causal_order=service['causal']['error_count']==0,
        no_observed_ring_expirations=not service['causal']['ring_expirations'],CPU_state_capture_integrity=cpu['all25_equal'],full58_profile=True,
        fixed_window_scene_update_count=cadence['native_scene_updates']==cadence['Census_scene_updates'])
    report=dict(source=SOURCE,profile=profile,model_sha256=MODEL,reference=prep['reference'],reference_ready_sha256=prep['ready_sha256'],
        disposition='PASS_SCOPED_RACE24_REFERENCE_OBSERVABLES_WITH_COVERAGE_GAPS'if all(checks.values())else'OPEN_CURRENT_SOURCE_RACE24_GAPS',
        checks=checks,failed=[k for k,v in checks.items()if not v],release=dict(time_ps=int(release[1]),video_frame=int(release[2])),
        save=save,audio=audio,cadence=cadence,CPU_state_replay=cpu,frames=frames,
        producer_records=len(extra['commits']),consumed_logical_records=len(extra['logical_stream']),display_deadlines=len(extra['deadlines']),
        service=service,ldm=ldm,native_VM=dict(words=int(vm[1]),CPU_block_reads=int(vm[2]),mismatches=int(vm[3])),
        reference_coverage_gaps=['No qualified per-clock CPU/state trajectory: independent native capture replay is integrity, not architectural reference equivalence.',
            'No Census23 raw PCM export; current raw audio remains OPEN.',
            'Census terminal state after100softwareframes is not the24-frame native terminal; no state epoch shift.',
            'Captured order is physically/causally validated, not compared to an unavailable Census record stream.'],
        mutation_controls=dict(actual_RF_value_bit=cpu['actual_RF_value_bit_mutation_caught_at_frame'],actual_frame10_pixel='CAUGHT_ONE_TOP_PIXEL'),wall_seconds=time.monotonic()-start,
        scope='ONE affected-source race24 finite gate, not complete final scene/DS/audio/current all-six qualification. No baseline/compile/model rerun or frame/input/epoch/sample shifts.')
    write(base/'comparison.json',report);phase('TERMINAL_'+report['disposition'])
    print(json.dumps(dict(disposition=report['disposition'],checks=checks,PCM_samples=len(samples),wall_seconds=report['wall_seconds'])),flush=True)


if __name__=='__main__':main()
