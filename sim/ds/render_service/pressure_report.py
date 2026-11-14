#!/usr/bin/env python3
"""Retain bounded pressure and one default-off test-only urgency experiment."""
from collections import Counter,deque
from pathlib import Path
import hashlib,io,json,re,sys,tarfile
import analyze
R=Path(__file__).resolve().parents[3]
def sha(b):return hashlib.sha256(b).hexdigest()
def summarize(path,log):
    counts=Counter();q=deque();owners=Counter();peak={};deps=[];snap=[];pub={};done={};misses=[];end=None;grants=Counter()
    for s in path.open():
        x=s.strip().split(',');k=x[0];counts[k]+=1
        assert k!='TRACE_CAP_REACHED'
        if k=='GRANT_SELECTED':grants[f'port{x[3]}_urgent{x[4]}']+=1
        if k=='VRAM_BLOCK':
            t,owner=int(x[1]),int(x[4])
            while q and q[0][0]<=t-4260:old=q.popleft();owners[old[1]]-=1
            q.append((t,owner));owners[owner]+=1
            if len(q)>peak.get('blocks',0):peak=dict(blocks=len(q),bytes=len(q)*32,first_SYS=q[0][0],last_SYS=t,owners=dict(owners))
        elif k=='DUE_DEPENDENCY':deps.append(list(map(int,x[1:])))
        elif k=='SNAPSHOT':snap.append(list(map(int,x[1:])))
        elif k=='PRODUCER_DONE':done[int(x[2]),int(x[3])]=int(x[1])
        elif k=='PUBLICATION':pub[int(x[2]),int(x[4])]=list(map(int,x[1:]))
        elif k=='TRAFFIC_DEADLINE_MISS':misses.append(list(map(int,x[1:6])))
        elif k=='END':end=list(map(int,x[1:]))
    text=log.read_text();f=re.search(r'CONSUMER_VALUE gen=(\d+) y=(\d+) x=(\d+)',text);failed=None
    if f:
        g,y,x=map(int,f.groups());s=next(v for v in reversed(snap)if v[1:3]==[g,y]);p=pub.get((g,y))
        failed=dict(generation=g,row=y,x=x,snapshot=s,latest_publication=p,completed_row_before_failure=done.get((g,y)),classification='PRODUCER_DEADLINE_PARTIAL'if p and p[-1]==1 and (g,y)not in done and s[5]<y else'CONSUMER_VALUE_NEEDS_INVESTIGATION')
    full=end is not None and 'COMPLETE_CONE_PASS'in text and f is None
    return dict(trace_sha256=sha(path.read_bytes()),events=counts,grants=grants,full_measurement_complete=full,complete_trace_accounting=analyze.analyze(path)if full else None,consumer_failure=failed,readiness_snapshots=len(snap),consumer_samples=counts['CONSUMER'],last_snapshot=snap[-1]if snap else None,physical_block_peak_4260SYS=peak,unfinished_due_dependency_event_count=len(deps),first_due_dependencies=deps[:8],traffic_miss_period_counts=Counter(v[0]for v in misses),traffic_miss_events=misses,prefix_scope='Fatal prefix is not drained ownership/pixel equivalence or full deadline acceptance; original live guards remain fatal.')
def main():
    I,C,U,P=map(lambda x:Path(x).resolve(),sys.argv[1:5]);P.mkdir(parents=True,exist_ok=True);assert not(P/'evidence.tar.gz').exists();payload={};cases={}
    def add(name,p):assert name not in payload;payload[name]=p.read_bytes()
    for name,B,action,fmt in [('indexed8',I,'pressure',4),('compressed4x4',C,'pressure',5),('prototype-off',U,'pressure',5),('prototype-on',U,'producer-hurry',5)]:
        src=json.loads((B/'source.json').read_text());model=json.loads((B/'model.json').read_text())
        assert sha((B/'source.json').read_bytes())==model['source_sha256']and sha((B/'obj/Vrender_service_tb').read_bytes())==model['binary_sha256']
        for f,h in src['files'].items():assert sha((B/f).read_bytes())==h
        param=int(re.search(r"b\[63:32\]=32'h([0-9a-f]+)",(B/'provider.sv').read_text()).group(1),16);assert(param>>26)&7==fmt
        cases[name]=dict(format=fmt,summary=summarize(B/(action+'.csv'),B/(action+'.log')),run=json.loads((B/(action+'.result.json')).read_text()),model=model)
    assert cases['indexed8']['summary']['full_measurement_complete']
    assert cases['compressed4x4']['summary']['consumer_failure']['classification']=='PRODUCER_DEADLINE_PARTIAL'
    assert cases['compressed4x4']['summary']['trace_sha256']==cases['prototype-off']['summary']['trace_sha256']
    assert cases['prototype-on']['summary']['consumer_failure']['row']==74
    limit=cases['compressed4x4']['summary']['last_snapshot'][0]
    for name in ['compressed4x4','prototype-on']:
        cases[name]['shared_traffic_misses_through_control_stop_SYS']=dict(Counter(v[0]for v in cases[name]['summary']['traffic_miss_events']if v[0]!=0 and v[2]<=limit))
    for label,B in [('indexed8',I),('compressed4x4',C),('prototype',U)]:
        src=json.loads((B/'source.json').read_text())
        for f in src['files']:add(label+'/source/'+f,B/f)
        for p in B.iterdir():
            if p.is_file()and p.suffix in ['.json','.log','.csv']and not p.name.startswith('pack-pressure'):add(label+'/runs/'+p.name,p)
        add(label+'/model',B/'obj/Vrender_service_tb')
    for p in(R/'sim/ds/render_service').iterdir():
        if p.is_file():add('harness/'+p.name,p)
    add('plan.json',R/'build/render-service-pressure-plan/plan.json')
    with tarfile.open(P/'evidence.tar.gz','w:gz',compresslevel=6)as t:
        for name,b in sorted(payload.items()):
            m=tarfile.TarInfo(name);m.size=len(b);m.mode=0o644;m.mtime=0;t.addfile(m,io.BytesIO(b))
    result=dict(packet_integrity_PASS=True,source=json.loads((I/'source.json').read_text())['source'],control_packet='e1dbb5fd:docs/results/render-service-e63-20261110',disposition='REJECT_URGENCY_AS_PRODUCER_DEADLINE_CORRECTION',production_RTL_changed=False,game_or_control_rerun=False,fit_run=False,policy_activation_qualified=False,cases=cases,archive_sha256=sha((P/'evidence.tar.gz').read_bytes()),members_sha256={k:sha(v)for k,v in payload.items()},format_label_history='Initial format4 executed the declared indexed8 input correctly. Agent temporarily reversed format names and ran format5; actual local decoder makes that legal compressed4x4. Old mistaken correction notes are retained and superseded here. No trace relabel changes its actual input bytes.',policy='One test-only existing port2 urgency input: due valid, completed rows<=due line, raster wait17/19, not reset/frame/abort. Off by default; existing2D urgency and native bounded2urgent/1normal/rotation/FIFO/refresh unchanged.',remaining_gate='Producer partial-row deadline and shared traffic failures remain open. Need upstream head-request/2D/VRAM attribution before another policy. No production RTL, same-seed area, current game or DS timing acceptance; no additional priority or input-load sweep.')
    (P/'result.json').write_text(json.dumps(result,indent=2)+'\n');print('FROZEN',len(payload),'members',round((P/'evidence.tar.gz').stat().st_size/2**20,2),'MiB')
    for name,c in cases.items():print(name,'complete',c['summary']['full_measurement_complete'],'failure',c['summary']['consumer_failure'],'peak',c['summary']['physical_block_peak_4260SYS'])
if __name__=='__main__':main()
