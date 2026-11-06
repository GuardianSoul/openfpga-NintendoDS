#!/usr/bin/env python3
"""Execute a value-aware schedule against a passive pinned-reference trace.

Measured timestamps belong to the unchanged reference. Candidate issue,
completion, capacity pressure and margins are explicit schedule predictions.
No predicted delay is silently fed back into the reference's future inputs.
"""
import collections
import csv
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-public-witness18'
MASK=(1<<32)-1


def restoring(num,den):
    """Literal normal32/restart64 ordering, four restoring bits per SYS."""
    rem=num>>32;count=32;q=0;cycles=0
    if rem>=den:
        rem=0;count=64;cycles=1
    while count:
        for _ in range(4):
            if not count:break
            trial=(rem<<1)|((num>>(count-1))&1)
            bit=int(trial>=den)
            rem=(trial-den if bit else trial)&((1<<33)-1)
            q=((q<<1)|bit)&MASK;count-=1
        cycles+=1
    return q,cycles


def parse(path):
    rows=[];final=None
    for row in csv.reader(path.open()):
        if row and row[0]=='OBS':rows.append(row)
        elif row and row[0]=='OBSFINAL':final={row[i]:int(row[i+1])for i in range(1,len(row),2)}
    assert final is not None,'missing final observer coverage'
    groups=collections.defaultdict(list)
    for row in rows:groups[row[2]].append(row)
    return rows,groups,final


def verify(path):
    rows,g,final=parse(path)
    if len(g['REL'])!=len(g['START']) or final['releases']!=final['raw_releases']:
        raise RuntimeError('OBSERVER_DISCONNECTED: operand release/start join incomplete')
    assert len(g['REL'])==len(g['Q'])==final['starts']>0
    segments=[]
    for rel,start,result in zip(g['REL'],g['START'],g['Q']):
        cy=int(rel[1]);sid=int(rel[5]);clip=int(rel[4]);den=int(rel[7],16)
        nums=[int(x,16)for x in rel[12:]]
        assert len(nums)==9 and nums==[int(x,16)for x in start[7:]],'captured NUM release mismatch'
        assert int(start[1])==cy+1 and int(start[5])==int(result[5])==sid
        assert int(start[4])==int(result[4])==clip
        expected=[restoring(n,den)for n in nums]
        actual=[int(x,16)for x in result[6:]]
        assert actual==[q for q,_ in expected],('qualified quotient mismatch',sid)
        assert int(result[1])-int(start[1])==max(c for _,c in expected)+1
        comp=int(rel[6]);active=[i for i,n in enumerate(nums)if i!=comp and (n!=0 or den==0)]
        segments.append({'id':sid,'clip':clip,'case':int(rel[3]),'release_SYS':cy,
                         'last_NUM_ready_SYS':int(start[1]),'reference_consume_SYS':int(result[1]),
                         'comp':comp,'den':den,'NUM':nums,'reference_q':actual,
                         'normal_fields':[i for i,n in enumerate(nums)if (n>>32)<den],
                         'restart_fields':[i for i,n in enumerate(nums)if (n>>32)>=den],
                         'active_fields':active,'source_service_SYS':[c for _,c in expected],
                         'write_seq':int(rel[8]),'engine_seq':int(rel[9]),'model_seq':int(rel[10]),
                         'FIFO_level':int(rel[11])})
    return rows,g,final,segments


def schedules(segments,lanes):
    free=[0]*lanes;cohorts=[];records=[]
    for seg in segments:
        release=seg['last_NUM_ready_SYS']
        occupancy=sum(end>release for end in cohorts)
        jobs=[]
        for field in seg['active_fields']:
            lane=min(range(lanes),key=lambda k:(free[k],k))
            load=max(release,free[lane]);q,service=restoring(seg['NUM'][field],seg['den'])
            assert q==seg['reference_q'][field]
            finish=load+service
            # One edge after finish can capture q and load the next job.
            free[lane]=finish+1
            jobs.append({'field':field,'lane':lane,'load_SYS':load,'finish_SYS':finish,
                         'consumer_SYS':finish+1,'q':q,'service_SYS':service})
        ready=max([release+2]+[x['consumer_SYS']for x in jobs])
        cohorts.append(ready)
        records.append({'segment':seg['id'],'clip':seg['clip'],'case':seg['case'],
                        'jobs':jobs,'predicted_ready_SYS':ready,
                        'reference_consume_SYS':seg['reference_consume_SYS'],
                        'private_consumer_margin_SYS':seg['reference_consume_SYS']-ready,
                        'cohorts_live_at_release':occupancy,
                        'capacity2_admission_pressure':occupancy>=2})
    return records


def retained_flow(segments,lanes):
    """Executable one-cohort policy: pad fast results, hold for slow jobs.

    Preserve the reference's non-divider gaps within one clip. Subsequent
    segments move with their preceding dependencies. This is not a feedback
    simulation of the front/CPU or later clip starts.
    """
    shift=0;records=[]
    for seg in segments:
        release=seg['last_NUM_ready_SYS']+shift;free=[release]*lanes;jobs=[]
        for field in seg['active_fields']:
            lane=min(range(lanes),key=lambda k:(free[k],k))
            load=free[lane];q,service=restoring(seg['NUM'][field],seg['den'])
            assert q==seg['reference_q'][field]
            done=load+service+1;free[lane]=done
            jobs.append({'field':field,'lane':lane,'load_SYS':load,'ready_SYS':done})
        old_consume=seg['reference_consume_SYS']+shift
        ready=max([old_consume,release+2]+[x['ready_SYS']for x in jobs])
        shift+=ready-old_consume
        records.append({'segment':seg['id'],'shifted_NUM_ready_SYS_prediction':release,
                        'jobs':jobs,'padded_consume_SYS_prediction':ready,'accumulated_clip_delay_SYS_prediction':shift})
    return shift,records


def first(rows,condition,after):
    return next((r for r in rows if int(r[1])>=after and condition(r)),None)


def main():
    rows,g,final,segments=verify(B/'positive.log')
    neg=subprocess.run([sys.executable,__file__,'--verify',str(B/'disconnect.log')],capture_output=True,text=True)
    assert neg.returncode!=0 and 'OBSERVER_DISCONNECTED' in neg.stderr,neg.stdout+neg.stderr
    (B/'disconnect-validation.txt').write_text(neg.stdout+neg.stderr)
    nrows,_,_=parse(B/'disconnect.log')
    # The mutation changes the actual passive hook only. All independently
    # observed reference/public events and their timestamps must be identical.
    passive=[r for r in rows if r[2]!='REL']
    assert passive==nrows,'observer mutation perturbed the pinned reference'
    assert len(g['O'])==len(g['TAKE'])
    accepted_entries=[r for r in g['W']if int(r[5],16)<0x80]
    assert len(accepted_entries)==len(g['E'])==len(g['M'])
    for word,pop in zip(accepted_entries,g['E']):
        assert int(word[6],16)==(int(pop[6],16)&MASK),'accepted operand/engine pop mismatch'
    entry_by_seq={i+1:(w,e)for i,(w,e)in enumerate(zip(accepted_entries,g['E']))}
    submits=[r for r in g['M']if int(r[5])]
    assert len(submits)==len(g['TAKE'])
    clip_starts={int(r[4]):r for r in g['G']}
    clip_ends={int(r[4]):r for r in g['CEND']}
    jobs1=schedules(segments,1);jobs2=schedules(segments,2)
    heads=[r for r in g['PO']if int(r[5])==0];head_index=0;joins=[]
    for outcome,take,submit in zip(g['O'],g['TAKE'],submits):
        cid=int(outcome[4]);reject=int(outcome[5]);header=None
        if not reject:
            header=heads[head_index];head_index+=1
        if not cid:continue
        assert cid in clip_starts and cid in clip_ends
        start=clip_starts[cid];tc=int(take[1]);oc=int(outcome[1])
        last_word,last_pop=entry_by_seq[int(start[6])]
        assert tc>=oc+1
        publication=first(g['P'],lambda r:True,tc+1)
        count_read=first(g['READ'],lambda r:int(r[4],16)==0x81,tc+1)
        count_ack=first(g['ACK'],lambda r:int(r[4],16)==0x81,int(count_read[1])+1)if count_read else None
        busy_clear=first(g['P'],lambda r:not(int(r[4],16)&(1<<27)),tc+1)
        future_test=first(g['ACK'],lambda r:int(r[4],16)in(0x80,0x88,0x90),tc+1)
        members=[s for s in segments if s['clip']==cid]
        j={'clip':cid,'case':int(start[3]),'clip_start_SYS':int(start[1]),
           'write_seq_at_start':int(start[5]),'engine_seq_at_start':int(start[6]),
           'last_handler_operand':{'accepted_write_SYS':int(last_word[1]),
               'write_sequence':int(last_word[4]),'word_address_hex':last_word[5],
               'data_hex':last_word[6],'engine_pop_SYS':int(last_pop[1]),
               'engine_sequence':int(last_pop[4]),'engine_handler_index':int(last_pop[5])},
           'model_seq_at_start':int(start[7]),'FIFO_at_start':int(start[8]),
           'engine_lead_at_start':int(start[9]),'segments':[s['id']for s in members],
           'clip_done_SYS':int(clip_ends[cid][1]),'logical_submit_SYS':int(submit[1]),
           'engine_outcome_sample_SYS':oc,'OQ_take_SYS':tc,
           'debt_at_outcome_DS_ticks':int(outcome[8]),'pending_at_outcome':int(outcome[9]),
           'reject':bool(reject),'nv':int(outcome[6]),'ncl':int(outcome[7]),
           'first_post_take_public_state':publication,
           'first_post_take_count_read':count_read,'first_post_take_count_ack':count_ack,
           'first_post_take_busy_clear_state':busy_clear,'first_later_test_or_result_ack':future_test,
           'physical_header_accept_SYS':int(header[1])if header else None}
        for count,records in ((1,jobs1),(2,jobs2)):
            chosen=[x for x in records if x['clip']==cid]
            last=max([j['clip_start_SYS']]+[x['predicted_ready_SYS']for x in chosen])
            j[f'lanes{count}']={'last_arithmetic_ready_SYS_prediction':last,
                'reference_take_minus_last_arithmetic_SYS':tc-last,
                'first_count_read_minus_last_arithmetic_SYS':int(count_read[1])-last if count_read else None,
                'private_consumer_misses':sum(x['private_consumer_margin_SYS']<0 for x in chosen),
                'capacity2_admission_pressure':sum(x['capacity2_admission_pressure']for x in chosen)}
            delay,flow=retained_flow(members,count)
            # Outcome sample is the front's enqueue edge; its head cannot
            # retire before the next edge. This lower bound deliberately
            # ignores earlier queue heads and any additional front pressure.
            take_bound=max(int(submit[1]),oc+delay+1)
            j[f'lanes{count}']['retained_flow_policy_prediction']={
                'extra_clip_delay_SYS':delay,'segments':flow,
                'OQ_take_not_before_SYS':take_bound,
                'reference_public_take_miss_SYS':max(0,take_bound-tc),
                'scope':'Hold existing traversal/queue/commit gaps; actual later front/CPU feedback and later clip starts are not simulated.'}
        joins.append(j)
    assert head_index==len(heads)
    canonical=[j for j in joins if j['case']==1]
    assert len(canonical)==1 and canonical[0]['engine_lead_at_start']==0 and canonical[0]['FIFO_at_start']==0
    witness=[x for x in jobs1 if x['case']==1]
    assert len(witness)==2 and [len(x['jobs'])for x in witness]==[0,1]
    assert all(x['private_consumer_margin_SYS']>=0 for x in witness)
    rejects=[j for j in joins if j['reject']]
    assert rejects,'missing later reject coverage'
    assert final['max_fifo']==256 and final['late_clocks']>0
    assert g['FRAME'],'missing actual sort/frame-publication boundary'
    first_flow_miss={str(n):next((j for j in joins if j[f'lanes{n}']['retained_flow_policy_prediction']['reference_public_take_miss_SYS']>0),None)for n in (1,2)}
    payload={'kind':'PASSIVE_REFERENCE_MEASUREMENTS_AND_EXECUTABLE_SCHEDULE_PREDICTIONS',
      'reference':json.loads((B/'prepare.json').read_text())['reference'],
      'explicit_parameters':json.loads((B/'prepare.json').read_text())['explicit_parameters'],
      'route':'DSX1/CHEAP0/AHEAD1/GX_FAST;4096entrycache/SP_AW18;paired aligned SYS/FAST',
      'units':{'measured_timestamps':'67.027964MHz SYS edges','DS_timer_ticks_per_SYS':'1/2',
               'FAST_edges_per_SYS':2,'model_debt':'DS timer ticks, already normalized in front'},
      'scope':'No arithmetic RTL or candidate reference feedback. No new DS/native/game baseline. Existing input recipes only.',
      'coverage':final,'events':{k:len(v)for k,v in g.items()},
      'NUM_classes_observed':{'normal_segments':sum(not x['restart_fields']for x in segments),
                              'restart_segments':sum(bool(x['restart_fields'])for x in segments),
                              'denominator_zero_segments':sum(x['den']==0 for x in segments),
                              'maximum_useful_nonzero_fields':max(len(x['active_fields'])for x in segments)},
      'accepted_input_sha256':hashlib.sha256(json.dumps(accepted_entries,separators=(',',':')).encode()).hexdigest(),
      'candidate_state_and_ports':{
          'retained_flow_policy':'One active cohort, at most8 useful full-width divisions; no speculative next-cohort capture.',
          'optimistic_frozen_release_replay':'Allows active plus queued cohorts; explicitly checks capacity2 admission pressure. Its extra context storage is separate and unpriced.',
          'retained_payload_bits':{'NUM':9*64,'results':9*32,'denominator':32,'pending_mask':9},
          'ports':'One captured NUM/den load and one result capture per physical lane at SYS; result may be captured on the same edge as the next load. Source final quotient must be available before that edge.',
          'price':'Logical context budget only; existing NUM/result state may be reusable. Scheduler mux/control, RAM mapping and FAST/setup/hold remain unpriced/unproved.'},
      'disconnect_mutant':{'actual_binding':'release_hook = observer_disconnect ? 0 : dut.u_eng.g_cl.u_clip.seg_go',
          'validator_exit':neg.returncode,'caught':'OBSERVER_DISCONNECTED',
          'all_independent_reference_events_identical':True},
      'canonical_one_lane_witness':{'clip_join':canonical[0],'schedule':witness,
          'precision':'Full unsigned64/32 restoring result; overwritten plane field omitted; full NUM zero bypass only den>0.',
          'result':'All needed arithmetic ready by original reconstruction consumer; exact observed q. Padding to those original consumer edges leaves this observed clip dependency chain unchanged.'},
      'later_rejects':rejects,'clip_joins':joins,'segments':segments,
      'first_retained_flow_public_counterexample_predictions':first_flow_miss,
      'one_lane_schedule':jobs1,'two_lane_schedule':jobs2,
      'timing_limits':[
          'Only reference timestamps are measured; issue/completion/margins are software-schedule predictions.',
          'Private consume misses alone do not fail DS acceptance; first public count/read/store/test consumers are joined separately.',
          'The retained-flow policy propagates dependent segment delays; its first public counterexample is a prediction against reference visibility, not an executed candidate or a new DS busy-count timing rule.',
          'Margins to OQ/count are necessary arithmetic room, not usable end-to-end slack: traversal/commit/store work still intervenes.',
          'Future operand release dates come from the reference; a delayed candidate must reschedule its dependent future work. No full-stream proof from this passive replay.',
          'Finite capacity2 admission pressure is a predicted need for stall/buffering, not a trace of candidate CPU backpressure.',
          'Observed128 segments are all normal division with at most3 useful nonzero fields; no restart/den0 or8-useful-field feasibility is established.',
          'The observed later rejection is the existing gxcount tri_right_0 control-only empty clip, with no interpolation jobs. Rejection after nonzero interpolation is not covered.',
          'Frame is the Geometry sort publication boundary, not a full raster/video-frame deadline measurement.'],
      'hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in [B/'positive.log',B/'disconnect.log',B/'observer.sv']}}
    (B/'joined.json').write_text(json.dumps(payload,indent=2)+'\n')
    concise={k:payload[k]for k in ['kind','reference','explicit_parameters','route','units','scope','coverage','events','NUM_classes_observed','accepted_input_sha256','candidate_state_and_ports','disconnect_mutant','canonical_one_lane_witness','later_rejects','first_retained_flow_public_counterexample_predictions','timing_limits','hashes']}
    concise['schedule_summary']={str(n):{'segments':len(rs),'private_consumer_misses':sum(x['private_consumer_margin_SYS']<0 for x in rs),
            'capacity2_admission_pressure':sum(x['capacity2_admission_pressure']for x in rs)}for n,rs in [(1,jobs1),(2,jobs2)]}
    for n in (1,2):
        a=[j[f'lanes{n}']for j in joins if j['segments']]
        concise['schedule_summary'][str(n)]['raw_arithmetic_before_take_min_SYS']=min(x['reference_take_minus_last_arithmetic_SYS']for x in a)
    (B/'summary.json').write_text(json.dumps(concise,indent=2)+'\n')
    print(json.dumps({'coverage':final,'later_rejects':len(rejects),'witness':[(x['segment'],len(x['jobs']),x['private_consumer_margin_SYS'])for x in witness],
                      'frame_publications':len(g['FRAME']),'schedules':concise['schedule_summary']}))


if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='--verify':
        verify(Path(sys.argv[2]));print('PASS operand/result join')
    elif len(sys.argv)>1 and sys.argv[1]=='--retained':
        evidence=Path(sys.argv[2]);B=Path(sys.argv[3]);B.mkdir(parents=True,exist_ok=True)
        for name in ('positive.log','disconnect.log'):
            (B/name).write_bytes(gzip.decompress((evidence/(name+'.gz')).read_bytes()))
        for name in ('prepare.json','observer.sv'):(B/name).write_bytes((evidence/name).read_bytes())
        main()
        assert (B/'summary.json').read_bytes()==(evidence/'summary.json').read_bytes(),'retained evidence changed'
        print('PASS retained schedule/join/mutant replay; no simulator launched')
    else:main()
