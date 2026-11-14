#!/usr/bin/env python3
"""Read-only joint service diagnosis; old frozen private run is the output control.

Intervals are exact pre-NBA SYS [begin,end). No means are used as deadline
promises. F5/staging measurements are checked against the separate raw hold
trace and per-generation row counters; work fingerprints are diagnostics, not
proof that all graphics inputs or DS state match.
"""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path

STATES=['IDLE','WREQ_UNUSED','WRITE','READ_REQUEST','READ_DATA','STAGE_COPY','LINE_COPY']
SERVICE=[('state',3),('read_y',8),('read_block',5),('need',8),('target',8),('st_full',4),('wdone',9),('read_on',1),('drop',1),('nx2_on',1),('copy_ok',1),('read_ok',1),('write_pick',1),('late_copy_ok',1),('late_copy_pending',1),('wsafe',9),('owner_y',8),('copy_aborted',1),('late_copy_aborted',1)]
BLOCK=[('y',8),('x',8),('clear_ready',1),('state',3),('need',8),('read_y',8),('wdone',9),('st_full',4),('read_on',1),('drop',1),('nx2_on',1)]
FPHOLD=[('fst',4),('y',8),('x',8),('ack',1),('clear_pending',1),('FPCLR',1),('active',1),('reset',1),('fp_frame',1),('global_frame',1),('state',3)]
GATE=[('ready',1),('loader_go',1),('loader_restart',1),('y_gap',1),('y_only',1),('loader_y',9),('y',8),('limit',9)]
MASK=(1<<64)-1
OFFSET=0x14650fb0739d0383
PRIME=0x100000001b3
SHA=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def decode(value,fields):
    n=int(value,16);out={}
    for name,width in fields:
        out[name]=n&((1<<width)-1);n>>=width
    assert n==0,('unaccounted_key_bits',value,fields)
    return out


def report(run,control,default=None):
    path=run/'service.csv'
    counts=Counter();bygen=defaultdict(Counter);block=Counter();rawblock=Counter();hist=Counter();rawhist=Counter()
    genrows={};genhist={};work=defaultdict(lambda:[0,OFFSET]);inputs={};joint=defaultdict(Counter)
    last_end=None;first=None;end=None;service_n=0;block_intervals=[];framewait=[];gate_intervals=[];finals=[]
    service_intervals=[];config=None
    with path.open() as f:
        for row in csv.reader(f):
            if not row or row[0].startswith('#'):continue
            kind=row[0];counts[kind]+=1
            if kind=='CONFIG':config=dict(zip(row[1::2],map(int,row[2::2])));continue
            if kind in ['SERVICE','BLOCK','FPHOLD','GATE']:
                start,stop,g=map(int,row[1:4]);assert stop>start
                dt=stop-start
                if kind=='SERVICE':
                    v=decode(row[4],SERVICE);s=STATES[v['state']];bygen[g]['engine_'+s]+=dt
                    assert last_end is None or start==last_end,('service_gap',start,last_end)
                    first=start if first is None else first;last_end=stop;service_n+=dt
                    pending=bool(v['st_full']&(1<<(v['wdone']&3)))
                    if pending:
                        bygen[g]['oldest_stage_full_SYS']+=dt;bygen[g]['pending_by_engine_'+s]+=dt
                        if v['state']==0 and not v['write_pick']:
                            reason='late_copy' if v['late_copy_pending'] and v['late_copy_ok'] else 'read_line' if v['read_on'] and not v['drop'] else 'stage_copy' if v['copy_ok'] else 'new_read' if v['read_ok'] else 'unexplained'
                            bygen[g]['idle_writer_preempted_'+reason]+=dt
                            assert reason!='unexplained',v
                    service_intervals.append((start,stop,g,v))
                    if v['read_on'] and v['state'] in [0,3,4]:
                        cls='drop' if v['drop'] else 'needed' if v['read_y']==v['need'] else 'ahead' if v['read_y']>v['need'] else 'passed'
                        bygen[g]['read_service_'+cls]+=dt
                        if pending:bygen[g]['oldest_pending_read_'+cls]+=dt

                elif kind=='BLOCK':
                    v=decode(row[4],BLOCK);k=(g,v['y'],v['clear_ready']);block[k]+=dt;hist[g,v['y'],v['state']]+=dt
                    bygen[g]['F5_stage_only_SYS' if v['clear_ready'] else 'F5_stage_and_clear_SYS']+=dt
                    block_intervals.append(dict(begin=start,end=stop,generation=g,**v))
                elif kind=='FPHOLD':
                    v=decode(row[4],FPHOLD)
                    if v['fst']==config['F5'] and not(v['reset'] or v['fp_frame'] or v['global_frame']):
                        assert v['active'];clear=not v['clear_pending'] or v['ack'] if v['FPCLR'] else v['ack']
                        rawblock[g,v['y'],int(clear)]+=dt;rawhist[g,v['y'],v['state']]+=dt
                    else:bygen[g]['unqualified_hold_SYS']+=dt
                else:
                    v=decode(row[4],GATE);assert v['y']>v['limit'] and v['y_gap']
                    bygen[g]['store_y_only_SYS' if v['y_only'] else 'store_y_and_other_SYS']+=dt
                    gate_intervals.append(dict(begin=start,end=stop,generation=g,**v))
            elif kind=='GENROW':
                cycle,g,y,*values=map(int,row[1:]);assert (g,y)not in genrows
                f5,advance,stage,clear,both,calc=values
                assert f5==advance+stage+clear+both
                genrows[g,y]=dict(cycle=cycle,F5=f5,advance=advance,stage=stage,clear=clear,both=both,calculation=calc)
                bygen[g].update(F5_total_SYS=f5,F5_advance_SYS=advance,F5_clear_only_SYS=clear,finalpass_calculation_SYS=calc)
            elif kind=='GENHIST':
                _,g,y,s,n=map(int,row[1:]);assert(g,y,s)not in genhist;genhist[g,y,s]=n
            elif kind=='JOINT':
                _,g,mask,n=map(int,row[1:]);joint[g][mask]+=n
            elif kind=='WORK':
                _,g,y,typ=map(int,row[1:5]);data=int(row[5],16);assert typ!=3 or data==0
                n,h=work[g]
                for word in [typ,data&MASK,data>>64]:h=((h^word)*PRIME)&MASK
                work[g]=[n+1,h]
            elif kind=='INPUT':
                _,g,n=map(int,row[1:4]);assert g not in inputs
                inputs[g]=dict(work_records=n,work_hash=row[4],texture_requests=int(row[5]),texture_stream_fingerprint=row[6],palette_requests=int(row[7]),palette_stream_fingerprint=row[8])
            elif kind=='FRAMEWAIT':framewait.append(dict(cycle=int(row[1]),generation=int(row[2]),vcount=int(row[3]),flags=row[4],line215=int(row[5]),frame_go=int(row[6])))
            elif kind=='FINAL':finals.append(dict(zip(['cycle','generation','y','F5','advance','stage','clear','both','calculation'],map(int,row[1:]))))
            elif kind=='END':end=list(map(int,row[1:]))
    assert config and end and service_n==end[2] and last_end==end[0]+1
    assert block==rawblock,'qualified F5 disagrees with independently recorded raw hold signal'
    assert hist==rawhist
    for (g,y),v in genrows.items():
        assert block[g,y,1]==v['stage'] and block[g,y,0]==v['both']
        assert sum(genhist.get((g,y,s),0)for s in range(7))==v['stage']+v['both']
        for s in range(7):assert genhist.get((g,y,s),0)==hist[g,y,s]
    assert all((g,y)in genrows for g,y,_ in block)
    for g,i in inputs.items():assert work[g]==[i['work_records'],int(i['work_hash'],16)]
    for g,c in joint.items():
        assert c[1]+c[3]==bygen[g]['F5_stage_only_SYS']+bygen[g]['F5_stage_and_clear_SYS']
        assert c[2]+c[3]==bygen[g]['store_y_only_SYS']
    # Join separate actual F5 hold intervals to the engine's owner/address
    # intervals; the row counters alone do not supply this joint service data.
    cursor=0
    for b in block_intervals:
        while cursor<len(service_intervals) and service_intervals[cursor][1]<=b['begin']:cursor+=1
        i=cursor;covered=0
        while i<len(service_intervals) and service_intervals[i][0]<b['end']:
            lo,hi,g,v=service_intervals[i];dt=min(hi,b['end'])-max(lo,b['begin']);i+=1
            if dt<=0:continue
            assert g==b['generation'] and v['state']==b['state']
            covered+=dt
            cls=STATES[v['state']]
            if v['state'] in [0,3,4] and v['read_on']:
                cls+='_'+('DROP' if v['drop'] else 'NEEDED' if v['read_y']==v['need'] else 'AHEAD' if v['read_y']>v['need'] else 'PASSED')
            elif v['state'] in [5,6]:
                aborted=v['copy_aborted'] if v['state']==5 else v['late_copy_aborted']
                cls+='_'+('ABORTED' if aborted else 'LIVE')
            label='F5_stage_only_' if b['clear_ready'] else 'F5_joint_stage_clear_'
            bygen[g][label+cls]+=dt
        assert covered==b['end']-b['begin']
    # Use the retained exact endpoint as the observer non-interference control.
    a=json.loads((run/'analysis.json').read_text());b=json.loads((control/'analysis.json').read_text())
    exact={name:a[name]==b[name] for name in ['functional_digest','capture_digest','counts','owners_wrong_row_wrong_gen_unknown_prefix']}
    exact['fixed_images']=[s['sha256']for s in a['fixed_shots']]==[s['sha256']for s in b['fixed_shots']]
    exact['observer_raw']=SHA(run/'observer.csv')==SHA(control/'observer.csv')
    exact['capture_raw']=SHA(run/'capture.csv')==SHA(control/'capture.csv')
    assert all(exact.values()),('passive_control_mismatch',exact)
    def clip_service(begin,stop,generation):
        out=Counter()
        for lo,hi,g,v in service_intervals:
            if g!=generation or hi<=begin or lo>=stop:continue
            out[STATES[v['state']]]+=min(hi,stop)-max(lo,begin)
        return dict(out)
    # Five residual gap2 delivery windows use exact final-consumer/readiness
    # edges from the old frozen control; output equivalence is already checked.
    life=json.loads((control/'lifetime-analysis.json').read_text())
    residual_windows=[]
    for w in life['windows']:
        if w.get('request_gap')!=2 or not w.get('next_delivery_late'):continue
        lo=w['normalized_final_sample_SYS'];hi=w['next_readiness_snapshot_SYS'];g=w['generation']
        residual_windows.append(dict(window=w,actual_service_SYS=clip_service(lo,hi,g),actual_segments=[dict(begin=max(a,lo),end=min(b,hi),generation=gen,**v)for a,b,gen,v in service_intervals if gen==g and a<hi and b>lo]))
    assert len(residual_windows)==life['gap2_delivery_late']
    cohort=[];delayed_frame_guards=[]
    if default:
        old=json.loads((default/'analysis.json').read_text())
        key=lambda r:(r['video_frame'],r['generation'],r['y'])
        o={key(r):r for r in old['rows']};n={key(r):r for r in a['rows']}
        done={};frames={};oldframes={}
        for target,dest in [(run,frames),(default,oldframes)]:
            for line in (target/'observer.csv').read_text().splitlines():
                r=line.split(',')
                if r[0]=='FRAME':dest[int(r[3])]=int(r[1])
                if target==run and r[0]=='DONE':done[int(r[3]),int(r[4])]=int(r[1])
        for k in sorted(o.keys()&n.keys()):
            if (o[k]['kind'],n[k]['kind'])!=('full','render-late'):continue
            vf,g,y=k;completion=done[g,y];lo=frames[g]
            blocks=[z for z in block_intervals if z['generation']==g and z['begin']<completion and z['end']>lo]
            qualified=sum(max(0,min(completion,z['end'])-max(lo,z['begin']))for z in blocks if z['clear_ready'])
            joint_clear=sum(max(0,min(completion,z['end'])-max(lo,z['begin']))for z in blocks if not z['clear_ready'])
            cohort.append(dict(video_frame=vf,generation=g,y=y,consumer=n[k]['cycle'],completion=completion,completion_delta_SYS=completion-o[k]['done_cycle'],frame_start_delta_SYS=frames[g]-oldframes[g],observed_F5_stage_only_before_completion_SYS=qualified,observed_F5_joint_stage_clear_before_completion_SYS=joint_clear,service_since_frame_SYS=clip_service(lo,completion,g)))
        assert len(cohort)==638
        for g in sorted({r['generation']for r in cohort}):
            start=next(z for z in framewait if z['cycle']==oldframes[g]-1 and z['line215'])
            finish=next(z for z in framewait if z['cycle']==frames[g] and z['frame_go'])
            decode_flags=lambda z:{name:(int(z['flags'],16)>>i)&1 for i,name in enumerate(['geometry_enable','render_enable','simulated_hold','sort_done','raster_busy','hold_window_open','store_build','swap_busy','frame_hold','frame_request'])}
            before,after=decode_flags(start),decode_flags(finish)
            assert before['frame_request'] and before['frame_hold'] and before['swap_busy'] and not before['store_build']
            assert after['swap_busy'] and not after['hold_window_open'] and not after['frame_hold']
            delayed_frame_guards.append(dict(generation=g,delta_SYS=frames[g]-oldframes[g],line215=start,frame_start=finish,hold_guard_at215=before,guard_at_actual_start=after))
    result=dict(source='1d90 production RTL; passive joint service probe',run=str(run),control=str(control),service_sha256=SHA(path),config=config,counts=dict(counts),sampled_SYS=service_n,exact_endpoint_control=exact,remaining_gap2_delivery_windows=residual_windows,strict_full_to_render_late_actual_service=cohort,delayed_frame_guard_witnesses=delayed_frame_guards,generations={g:dict(c)for g,c in sorted(bygen.items())},input_fingerprints=inputs,joint_masks={g:dict(c)for g,c in joint.items()},frame_wait_events=framewait,actual_block_intervals=block_intervals,actual_store_gate_intervals=gate_intervals,final_rows=finals,limits='Measured SYS occupancy and actual output opportunities, not additive causal speed credit. Fingerprints are diagnostic; dynamic work/content may differ across profiles. Existing private run only checks passive non-interference. No shifted image alignment, parameter sweep, hardware price, DS or playability acceptance.')
    dest=run/'service-analysis.json';encoded=json.dumps(result,indent=2)+'\n'
    if dest.exists():assert dest.read_text()==encoded,'refuse analysis overwrite'
    else:dest.write_text(encoded)
    print('PASS_SERVICE',service_n,'SYS; raw-qualified F5 and work-stream checks; existing frozen output exact')
    for g,c in sorted(bygen.items()):print('GEN',g,'stage-only',c['F5_stage_only_SYS'],'both',c['F5_stage_and_clear_SYS'],'store-y-only',c['store_y_only_SYS'],'pending-ahead-read',c['oldest_pending_read_ahead'])
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path);p.add_argument('--control',type=Path,required=True);p.add_argument('--default',type=Path);a=p.parse_args();report(a.run.resolve(),a.control.resolve(),a.default.resolve() if a.default else None)
