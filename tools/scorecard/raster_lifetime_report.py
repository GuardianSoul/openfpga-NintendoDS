#!/usr/bin/env python3
"""Measure final-sample service windows from actual fixed-run events."""
import argparse
import bisect
import csv
import hashlib
import json
from pathlib import Path
import re


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('run',type=Path)
    a=p.parse_args()
    assert (a.run/'run.json').exists(),'only analyze a completed bounded run'
    jobs=[];ready={};job=None;sample_events=0;writes=0
    with (a.run/'observer.csv').open() as f:
        for row in csv.reader(f):
            if not row or row[0].startswith('#'):continue
            if row[0]=='ROW':
                v=list(map(int,row[1:]))
                job=dict(cycle=v[0],video_frame=v[1],generation=v[2],row=v[3],
                         full=bool(v[4] and not v[5]),partial=bool(v[5]),render_late=bool(v[6]),delivery_late=bool(v[7]))
                jobs.append(job)
            elif row[0]=='LSAMPLE':
                v=list(map(int,row[1:]));sample_events+=1
                assert job and job['row']==v[2],(job,row)
                assert 'final_sample_SYS' not in job,('duplicate final sample',row)
                job['final_sample_SYS']=v[0]
                job['owner_valid_at_sample']=bool(v[3]);job['display_on_at_sample']=bool(v[4])
            elif row[0]=='LWRITE':
                v=list(map(int,row[1:]));writes+=1
                assert job and job['row']==v[2] and v[3]==v[2]+2,(job,row)
                assert v[0]>job['final_sample_SYS'],('overwrite before final sample',job,row)
                job['first_speculative_write_SYS']=v[0]
            elif row[0]=='LWIN':
                v=list(map(int,row[1:]))
                assert job and job['row']==v[2] and job.get('final_sample_SYS')==v[3],(job,row)
                job['next_raw_start_reported_SYS']=v[0]
            elif row[0]=='READY':
                cycle,video,gen,y,partial=map(int,row[1:])
                if not partial:ready.setdefault((gen,y),[]).append(cycle)
    metadata=json.loads((a.run/'run.json').read_text())
    key=metadata['variant']+('-capture' if metadata['capture_observer'] else '')
    model=json.loads((a.run.parent/f'model-{key}.json').read_text())
    header=next(x for x in model['sources'] if Path(x['path']).name=='raster_lifetime_observer.svh')
    pinned=Path(header['frozen_source']).read_bytes()
    assert hashlib.sha256(pinned).hexdigest()==header['sha256']
    expected_phase=0 if b'rl_cycle++' in pinned else 1
    windows=[]
    for job,nxt in zip(jobs,jobs[1:]):
        if 'final_sample_SYS' not in job or job['generation']!=nxt['generation']:continue
        # lv_go is a registered raw A-start: exactly one actual SYS edge.
        # Old instrumentation read ro_cycle before another block incremented
        # it. New instrumentation owns its counter and checks equality after
        # every edge. Bridge the known clock planes, never fit a tolerance.
        assert 'next_raw_start_reported_SYS' in job,job
        phase=nxt['cycle']-job['next_raw_start_reported_SYS']-1
        assert phase==expected_phase,('SYS counter bridge disagrees with pinned source',phase,job,nxt)
        sample=job['final_sample_SYS']+phase;target=job['row']+2
        candidates=ready.get((job['generation'],target),[])
        k=bisect.bisect_left(candidates,sample)
        available=candidates[k] if k<len(candidates) else None
        windows.append(dict(**job,next_row=nxt['row'],request_gap=nxt['row']-job['row'],
                            SYS_counter_bridge_phase=phase,normalized_final_sample_SYS=sample,
                            next_readiness_snapshot_SYS=nxt['cycle'],window_SYS=nxt['cycle']-sample,
                            target_ready_SYS=available,service_until_ready_SYS=None if available is None else available-sample,
                            target_ready_before_next_snapshot=available is not None and available<=nxt['cycle'],
                            next_full=nxt['full'],next_render_late=nxt['render_late'],next_delivery_late=nxt['delivery_late']))
    text=(a.run/'run.log').read_text()
    m=re.search(r'RLIFE checks=(\d+) errors=(\d+) windows=(\d+)',text)
    assert m and int(m[2])==0,'missing/failed live-consumer oracle'
    gap2=[x for x in windows if x['request_gap']==2]
    result=dict(run=str(a.run),run_metadata=metadata,
                observer_sha256=hashlib.sha256((a.run/'observer.csv').read_bytes()).hexdigest(),
                live_consumer_checks=int(m[1]),live_consumer_errors=int(m[2]),sample_events=sample_events,
                first_speculative_write_events=writes,measured_windows=len(windows),gap2_windows=len(gap2),
                gap2_full=sum(x['next_full'] for x in gap2),gap2_delivery_late=sum(x['next_delivery_late'] for x in gap2),
                gap2_render_late=sum(x['next_render_late'] for x in gap2),
                min_window_SYS=min((x['window_SYS'] for x in windows),default=None),windows=windows,
                timestamp_bridge=dict(lifetime_header_sha256=header['sha256'],phase_SYS=expected_phase,
                                      proof='Every measured pair verifies ROW - reported raw A-start = 1 hardware register edge + pinned observer counter phase; exact equality required.'),
                limits='Exact SYS event intervals, no phase/image alignment or unmeasured service guarantee. ROW is actual lv_go readiness snapshot, one clock after raw A-start. Includes startup; fixed-window subset is selected using pinned ROBS_WINDOW by the game report. Ready timestamps are observed full publications, not proof that every later consumer is correct; separate live-data oracle applies.')
    data=(json.dumps(result,indent=2)+'\n').encode();out=a.run/'lifetime-analysis.json'
    if out.exists():assert out.read_bytes()==data,'refuse to replace immutable analysis'
    else:out.write_bytes(data)
    print(json.dumps({k:v for k,v in result.items() if k not in ['windows','limits','run_metadata']}))


if __name__=='__main__':main()
