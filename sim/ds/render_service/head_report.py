#!/usr/bin/env python3
"""Retain the frozen attribution and one bounded head-admission result."""
from collections import Counter
from pathlib import Path
import hashlib,io,json,sys,tarfile
from pressure_report import summarize

R=Path(__file__).resolve().parents[3]
def sha(b):return hashlib.sha256(b).hexdigest()
def summarize_head(trace,log):
    out=summarize(trace,log);accept={};ret=Counter();loans=[];target={}
    for s in trace.open():
        a=s.rstrip().split(',');k=a[0]
        if k=='HEAD_BORROW':loans.append([int(a[1]),int(a[2]),int(a[3]),int(a[4],16)])
        elif k=='BLOCK_ACCEPT':accept[int(a[1])]=[int(a[3]),int(a[4]),int(a[6],16)]
        elif k=='BLOCK_BEAT':ret[int(a[2])]+=1
        elif k=='PRODUCER_DONE'and a[2]=='3'and 69<=int(a[3])<=75:target[a[3]]=int(a[1])
    for t,g,pick,block in loans:assert accept[t][1:]==[1+pick,block]
    out['loans']=dict(accepted=len(loans),palette=sum(v[2]for v in loans),returned_four_beats=sum(ret[accept[v[0]][0]]==4 for v in loans),first=loans[0]if loans else None,last=loans[-1]if loans else None)
    out['selected_producer_rows_done_SYS']=target
    return out

def main():
    B,C,A,P=[Path(x).resolve()for x in sys.argv[1:5]];P.mkdir(parents=True,exist_ok=True);assert not(P/'evidence.tar.gz').exists()
    payload={}
    def add(name,p):assert name not in payload;payload[name]=p.read_bytes()
    source=json.loads((B/'source.json').read_text());model=json.loads((B/'model.json').read_text());assert model['source_sha256']==sha((B/'source.json').read_bytes())
    for p,h in source['files'].items():assert sha((B/p).read_bytes())==h;add('model/'+p,B/p)
    add('model/Vrender_service_tb',B/'obj/Vrender_service_tb');assert sha(payload['model/Vrender_service_tb'])==model['binary_sha256']
    for p in B.iterdir():
        if p.is_file()and p.suffix in ['.json','.log','.csv']and not p.name.startswith('pack-head'):add('runs/'+p.name,p)
    for p in A.iterdir():
        if p.is_file()and p.suffix in ['.json','.log','.txt']:add('attribution/'+p.name,p)
    for p in (R/'sim/ds/render_service').iterdir():
        if p.is_file():add('harness/'+p.name,p)
    add('before/source.json',C/'source.json');add('before/provider.sv',C/'provider.sv')
    cases={}
    for name in ['head-off','head-on','head-owner']:
        run=json.loads((B/(name+'.result.json')).read_text());s=summarize_head(B/(name+'.csv'),B/(name+'.log'))
        assert s['trace_sha256']==run['trace_sha256']
        cases[name]=dict(run=run,summary=s)
    before=sha((C/'pressure.csv').read_bytes());assert before==cases['head-off']['summary']['trace_sha256']
    for name in ['head-off','head-on']:
        s=cases[name]['summary'];assert s['consumer_failure']['classification']=='PRODUCER_DEADLINE_PARTIAL'and s['consumer_failure']['snapshot'][0]==770325
        assert s['consumer_failure']['row']==74 and s['consumer_failure']['latest_publication']==[769923,3,0,74,1]
    assert cases['head-on']['summary']['loans']['accepted']>0
    assert cases['head-owner']['run']['PASS']and cases['head-owner']['summary']['loans']['accepted']>0
    with tarfile.open(P/'evidence.tar.gz','w:gz',compresslevel=6)as t:
        for name,b in sorted(payload.items()):
            m=tarfile.TarInfo(name);m.size=len(b);m.mode=0o644;m.mtime=0;t.addfile(m,io.BytesIO(b))
    result=dict(packet_integrity_PASS=True,source=source['source'],before_packet='5b479c6c:docs/results/render-pressure-e63-20261110',before_trace_sha256=before,model=model,
        disposition='REJECT_HEAD_ADMISSION_LEASE_AS_DEADLINE_FIX',production_RTL_changed=False,fit_run=False,game_or_control_rerun=False,
        original_guards_preserved=True,actual_borrow_owner_fault_caught=True,cases=cases,
        attribution=json.loads((A/'gates.json').read_text()),cost_plan=json.loads((A/'controller-plan.json').read_text()),
        archive_sha256=sha((P/'evidence.tar.gz').read_bytes()),members_sha256={k:sha(v)for k,v in payload.items()},
        next_action='No further priority sweep. This lease cannot fix row74 and does not close shared traffic. For a larger redesign, separately measure 2D-job guaranteed remaining service and simultaneous palette head demand, and whether P2/FIFO service can meet both. Root owns native/pin/controller cost/activation; no physical controller edit inferred.')
    (P/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('FROZEN',len(payload),'members',round((P/'evidence.tar.gz').stat().st_size/2**20,2),'MiB')
    for k,c in cases.items():print(k,c['summary']['loans'],c['summary']['traffic_miss_period_counts'],c['summary']['selected_producer_rows_done_SYS'])
if __name__=='__main__':main()
