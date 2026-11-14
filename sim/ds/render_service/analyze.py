#!/usr/bin/env python3
"""Cross accepted boundaries in a completed, uncapped component transcript."""
from collections import Counter
import hashlib,json
from pathlib import Path
import sys

def stats(v):
    v=sorted(v)
    return dict(n=len(v),min=v[0],mean=sum(v)/len(v),p95=v[(len(v)-1)*95//100],max=v[-1]) if v else dict(n=0)

def analyze(p):
    counts=Counter();reads={};last=set();first=set();port2=[];vram=[]
    blocks={};returns=Counter();physical=set();snapshots=[];pub={};done={}
    req={'T':{},'P':{}};ret={'T':set(),'P':set()};consumers=0;cancels=[];end=None
    grants=Counter();h=hashlib.sha256();last_time={};native_cycles={};block_start={};block_end={}
    physical_detail=[];physical_sys={};cache_latency={'T':[],'P':[]};full_lead=[];producer_lead=[]
    dependency_wait=Counter();dependency=None;dependency_start=None
    stage_hold=0;stage_start=None;stage_max=0;traffic=[]
    with p.open('rb')as f:
        for raw in f:
            h.update(raw)
            if raw.startswith(b'#'):continue
            a=raw.decode().strip().split(',');k=a[0];counts[k]+=1
            assert k!='TRACE_CAP_REACHED','incomplete capped transcript'
            if k=='GRANT_SELECTED':grants[f'port{a[3]}_urgent{a[4]}']+=1
            elif k=='NATIVE_ACCEPT':
                cyc,t,port=int(a[1]),int(a[2]),int(a[3]);addr=int(a[4],16);n,we,i=map(int,a[5:8])
                if port==2:port2.append((addr,n,we,t))
                if not we:
                    assert i not in reads
                    reads[i]=(port,addr,n,t)
                    native_cycles[i]=cyc
            elif k=='NATIVE_BEAT':
                i,port=int(a[3]),int(a[4]);addr=int(a[5],16);beat,islast=int(a[6]),int(a[7])
                assert i in reads and reads[i][:2]==(port,addr)
                assert int(a[2])>=reads[i][3]
                if beat==0:assert i not in first;first.add(i)
                if islast:
                    assert i not in last and beat==reads[i][2]-1;last.add(i);last_time[i]=int(a[2])
                assert beat==0 or islast
            elif k=='BLOCK_ACCEPT':
                i,owner,cl=int(a[3]),int(a[4]),int(a[5]);addr=int(a[7],16)
                assert i not in blocks and owner in [0,1,2] and (cl==-1 if owner==0 else cl in [0,1,2])
                blocks[i]=(owner,cl,addr)
                block_start[i]=int(a[1])
            elif k=='VRAM_BLOCK':
                i,owner,cl=int(a[3]),int(a[4]),int(a[5]);addr=int(a[6],16)
                assert i not in physical and blocks[i]==(owner,cl,addr)
                physical.add(i);vram.append((addr,8,0,int(a[2])));physical_detail.append(('block',i,owner,cl))
                physical_sys[i]=int(a[1])
            elif k=='VRAM_CPU':
                addr=int(a[4],16);we,blk=int(a[5]),int(a[6]);vram.append((addr&~7 if blk else addr,8 if blk else 1,we,int(a[2])))
                physical_detail.append(('cpu_or_capture',int(a[3]),we,blk))
            elif k=='BLOCK_BEAT':
                i,owner,beat=int(a[2]),int(a[3]),int(a[4])
                assert i in blocks and blocks[i][0]==owner and returns[i]==beat
                returns[i]+=1
                if beat==3:block_end[i]=int(a[1])
            elif k in ['TREQ','PREQ']:
                typ='T'if k=='TREQ'else'P';i=int(a[3]);assert i not in req[typ]
                req[typ][i]=(int(a[1]),int(a[2]),int(a[4],16))
            elif k in ['TRET','PRET']:
                typ='T'if k=='TRET'else'P';i=int(a[3]);assert i in req[typ] and i not in ret[typ]
                assert int(a[1])>=req[typ][i][0];ret[typ].add(i)
                cache_latency[typ].append(int(a[1])-req[typ][i][0])
            elif k=='DEPENDENCY':
                cyc=int(a[1])
                if dependency is not None:
                    dt=cyc-dependency_start
                    for name,value in [('texture_wait17',dependency[4]),('palette_wait19',dependency[5])]:
                        if value:dependency_wait[name]+=dt
                dependency=list(map(int,a[1:7]));dependency_start=cyc
            elif k=='FRAME':
                if dependency is not None:
                    dt=int(a[1])-dependency_start
                    for name,value in [('texture_wait17',dependency[4]),('palette_wait19',dependency[5])]:
                        if value:dependency_wait[name]+=dt
                dependency=None;dependency_start=None
            elif k=='STAGE':
                cyc=int(a[1]);hold=int(a[4])
                if stage_start is not None:
                    dt=cyc-stage_start;stage_hold+=dt;stage_max=max(stage_max,dt)
                stage_start=cyc if hold else None
            elif k=='TRAFFIC_DEADLINE_MISS':traffic.append(list(map(int,a[1:6])))
            elif k=='PRODUCER_DONE':done[int(a[2]),int(a[3])]=int(a[1])
            elif k=='PUBLICATION':
                if int(a[5])==0:pub[int(a[2]),int(a[4])]=int(a[1])
            elif k=='SNAPSHOT':
                cyc,g,y,have=map(int,a[1:5]);assert have==1
                assert (g,y)in done and done[g,y]<cyc,('producer deadline',g,y,done.get((g,y)),cyc)
                assert (g,y)in pub and pub[g,y]<=cyc,('publication deadline',g,y,pub.get((g,y)),cyc)
                producer_lead.append(cyc-done[g,y]);full_lead.append(cyc-pub[g,y])
                snapshots.append((cyc,g,y))
            elif k=='CONSUMER':consumers+=1
            elif k=='CANCEL':cancels.append(list(map(int,a[1:])))
            elif k=='END':end=list(map(int,a[1:]))
    assert end is not None and len(cancels)==2 and end[4]==end[5]
    assert first==last==set(reads) and len(reads)==end[4]
    assert sum(v[2]for v in reads.values())==end[1]
    assert len(vram)==len(port2)
    for i,(v,n)in enumerate(zip(vram,port2)):
        assert v[:3]==n[:3],('physical port2 FIFO owner/address/count',i,v,n)
    assert physical==set(blocks) and set(returns)==set(blocks) and all(v==4 for v in returns.values())
    assert all(ret[t]==set(req[t])for t in ['T','P'])
    assert len(snapshots)==200 and consumers==end[3]==51200
    physical_latency={};block_latency={};resolver_latency={};words_by_port=Counter();native_latency={}
    for i,(port,addr,n,t)in reads.items():
        words_by_port[port]+=n;native_latency.setdefault(str(port),[]).append(last_time[i]-t)
    for v,n,d in zip(vram,port2,physical_detail):
        assert n[3]>=v[3]
        key=f'owner{d[2]}_class{d[3]}' if d[0]=='block' else f'state{d[1]}_write{d[2]}_block{d[3]}'
        physical_latency.setdefault(key,[]).append(n[3]-v[3])
    for i,(owner,cl,addr)in blocks.items():
        block_latency.setdefault(f'owner{owner}_class{cl}',[]).append(block_end[i]-block_start[i])
        resolver_latency.setdefault(f'owner{owner}_class{cl}',[]).append(physical_sys[i]-block_start[i])
    return dict(PASS=True,path=str(p),sha256=h.hexdigest(),events=counts,grants=grants,
                native_reads=len(reads),native_words=end[1],native_active_owners_through_last_beat=True,
                physical_port2_joins=len(vram),accepted_block_joins=len(blocks),texture_demands=len(req['T']),palette_demands=len(req['P']),
                snapshots=len(snapshots),consumer_samples=consumers,pixel_checks=end[2],cancellations=cancels,
                physical_offer_to_native_accept_ps={k:stats(v)for k,v in physical_latency.items()},
                native_accept_to_last_beat_ps={k:stats(v)for k,v in native_latency.items()},
                native_read_words_by_port=words_by_port,
                original_block_accept_to_last_return_SYS={k:stats(v)for k,v in block_latency.items()},
                original_block_accept_to_physical_offer_SYS={k:stats(v)for k,v in resolver_latency.items()},
                ordered_cache_demand_to_return_SYS={k:stats(v)for k,v in cache_latency.items()},
                producer_finished_before_snapshot_SYS=stats(producer_lead),full_published_before_snapshot_SYS=stats(full_lead),
                frontend_wait_SYS=dependency_wait,staging_hold_SYS=stage_hold,staging_hold_max_event_interval_SYS=stage_max,
                traffic_miss_period_counts=Counter(v[0]for v in traffic),
                interpretation='Synthetic accepted-boundary overlap only; waits overlap, physical intervals include setup/queueing, no game or DS timing acceptance',
                SYS_deadline_labels='Independent observer counter, checked against settled fixture counter each falling edge',
                time_units='MEM/V absolute ps formatted from $time with1ns recording resolution; SYS boundary decisions use exact edge counters')

if __name__=='__main__':
    for name in sys.argv[1:]:
        p=Path(name);d=analyze(p);p.with_suffix('.analysis.json').write_text(json.dumps(d,indent=2)+'\n')
        print(json.dumps({k:d[k]for k in ['path','PASS','native_reads','native_words','accepted_block_joins','snapshots','consumer_samples','traffic_miss_period_counts']}))
