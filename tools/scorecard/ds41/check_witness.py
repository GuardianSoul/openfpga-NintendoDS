#!/usr/bin/env python3
"""Audit the passive DS41 transport/sample/commit witness independently of DS timing fit."""
from pathlib import Path
import argparse,json,collections
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prepared',type=Path,required=True);p.add_argument('--trace',type=Path,required=True);p.add_argument('--record',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
m=json.loads((a.prepared/'input-map.json').read_text());record=json.loads(a.record.read_text());events=[json.loads(l)for l in a.trace.read_text().splitlines()];assert events[0]['event']=='schema'and events[-1]['event']=='final'
assert events[-1]['records']==len(events)-2 and len(events)<50003
by=collections.defaultdict(list)
for e in events:
 if e.get('row'):by[e['row']].append(e)
assert set(by)==set(range(1,65)),'missing protected row'
results=[]
for row in range(1,65):
 e=by[row];case=(row-1)//16;expected=m['cases'][case]['accesses'];native=record['rows'][row-1]['native_r0_r1_r2_r3']
 typ=lambda t:[v for v in e if v['event']==t]
 issue=typ('IO_ISSUE');grants=typ('FAB_GRANT');ack=typ('FAB_ACK');samples=typ('SYS_SAMPLE');commits=typ('SYS_COMMIT');after=typ('TIMER_AFTER')
 assert len(issue)==len(grants)==len(ack)==9,('physical descriptor multiplicity',row,len(issue),len(grants),len(ack))
 assert all(v['cpu']==0 for v in issue)and all(v['owner']==1 for v in grants),'wrong access owner'
 shape=[(v['write'],v['be'])for v in issue];assert shape==[(1,12),(1,3),(1,12),(0,15),(0,15),(1,12),(0,15),(0,15),(0,15)],('actual IO order',row,shape)
 assert all(int(v['address'],16)==0x04000108 for v in issue),'wrong IO word address'
 assert len(samples)==5 and len(commits)==len(after)==4,('timer sample/commit coverage',row)
 assert [v['value']for v in samples[:4]]==native,'returned CPU data differs from actual timer samples'
 assert [v['control']for v in after]==[0,0,128,0],'actual committed timer controls differ'
 assert after[-1]['counter']==native[2],'stopped value differs from actual write edge result'
 logical=[]
 for v in expected:
  pc=f'{v["pc"]:08x}';present=[x for x in typ('CPU_PRESENT')if x['pc']==pc];ret=[x for x in typ('RETIRE')if x['pc']==pc]
  assert present and len(ret)<=1,('CPU logical access/merged-retire multiplicity',row,pc,len(present),len(ret))
  # arm_cpu merges the two CPUs' debug outputs and prioritizes ARM7.
  # Missing merged retire records are a declared diagnostic coverage gap,
  # not missing device accesses: every logical PC, bus descriptor, sampled
  # value and exported architectural result is independently required.
  assert all(int(x['address'],16)==v['address']for x in present),'CPU issued wrong address'
  assert all(x['be']==(12 if v['kind']=='write-stop'else 3)for x in present),'logical halfword byte enables differ'
  logical.append(dict(pc=pc,present_cycles=len(present),merged_retire=ret[0]if ret else None))
 assert all(v['next_control']==w['control']and v['next_counter']==w['counter']for v,w in zip(commits,after)),'actual post-write state differs from selected transition'
 results.append(dict(case=case,rep=(row-1)%16,physical_IO=9,logical=logical,read_sample_edges=[s['sc']for s in samples[:4]],stop_commit_edge=commits[-1]['sc'],returned=native,scope='All CPU presentations/ready cycles retained; no ready pulse is silently equated with retirement. Source-specific event order, not a DS pipeline law.'))
a.out.write_text(json.dumps(dict(status='PASS passive owner/sample/commit-to-raw-data audit; merged retire diagnostic is partial',rows=results,events=len(events)-2,logical_accesses=320,merged_retire_seen=sum(x['merged_retire']is not None for row in results for x in row['logical']),retire_scope='Merged ARM9/ARM7 debug mux loses simultaneous ARM9 retire events; do not use it as a lossless architectural timeline. CPU logical requests,9physical transactions/row,samples/commits and actual result bytes are all required.'),indent=2)+'\n');print('PASS64 rows of passive descriptor/sample/commit witness')
