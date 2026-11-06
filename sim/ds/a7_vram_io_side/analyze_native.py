#!/usr/bin/env python3
"""Classify changed-source originalDS30 demands against its actual checked rows."""
from pathlib import Path
from collections import Counter
import argparse
import bisect
import csv
import json


def load(path):
    rows=[];end=None
    with path.open()as f:
        reader=csv.DictReader(f)
        for r in reader:
            if r['event']=='END':end=(int(r['edge']),int(r['time_ps']));continue
            assert None not in r and None not in r.values(),(path,r)
            rows.append({k:v if k=='event'else int(v,16)if v.startswith('0x')else int(v)for k,v in r.items()})
    assert end==(len(rows),0),(path,len(rows),end)
    assert all(a['edge']<b['edge']and a['time_ps']<b['time_ps']for a,b in zip(rows,rows[1:])),path
    return rows


def hist(values):return dict(sorted(Counter(values).items()))


def analyze(root):
    cpu=load(root/'vram.cpu.csv');mem=load(root/'vram.mem.csv')
    bycmd={}
    for cmd in [27,283,28,284]:
        rows=[r for r in cpu if r['cmd']==cmd]
        row_edges=[r['edge']for r in rows]
        samples=[i for i,r in enumerate(rows)if r['pipefire']and r['dmrq']and r['esub']==1 and r['dok'] and r['daddr']==0x06000100
                 and (0x037f8800<=r['pc']<0x037f8914 if (cmd&255)==27 else 0x037f8920<=r['pc']<0x037f8a38)]
        assert len(samples)==7040,(cmd,len(samples))
        reads=(cmd&255)==27
        demand=[];start=0
        for si in samples:
            s=rows[si]
            candidates=[i for i in range(start,si+1)if rows[i]['dreq']and rows[i]['daddr']==0x06000100 and rows[i]['pc']==s['pc']]
            assert candidates,(cmd,si,s)
            di=candidates[0];d=rows[di]
            assert s['time_ps']>=d['time_ps']
            op=dict(pc=s['pc'],demand_edge=d['edge'],sample_edge=s['edge'],demand_ps=d['time_ps'],sample_ps=s['time_ps'],
                    demand_to_sample=s['edge']-d['edge'],read=reads,
                    IF_wait=sum(r['ifwait']for r in rows[di:si+1]),
                    P7_owner_at_demand=dict(busy=d['busy'],busy_write=d['busyw'],read=d['rpv'],IF=d['rpi'],posted_write=d['wbv']))
            if reads:
                fi=next((i for i in range(di,si+1)if rows[i]['freq']and not rows[i]['fwe']and rows[i]['fa']==0x06000100),None)
                assert fi is not None,(cmd,si,'missing actual read demand')
                ai=next((i for i in range(fi,si+1)if rows[i]['freq']and not rows[i]['fwe']and rows[i]['fa']==0x06000100 and rows[i]['fack']),None)
                assert ai is not None,(cmd,si,'missing matching read ACK')
                f=rows[fi];ack=rows[ai]
                ci=next((i for i in range(fi,ai+1)if rows[i]['creq']and not rows[i]['cwe']and rows[i]['ccpu']and rows[i]['ca']==0x40),None)
                assert ci is not None,(cmd,si,'missing owned VRAM-port demand')
                vi=next((i for i in range(ci,ai+1)if rows[i]['vst']==0 and not rows[i]['greq']
                         and rows[i]['bwleft']==0 and not(rows[i]['caphold']and not rows[i]['cwpair'])
                         and rows[i]['creq']and not rows[i]['cack']),None)
                assert vi is not None,(cmd,si,'missing actual IDLE CPU admission')
                c=rows[ci];v=rows[vi]
                admission=next((i for i in range(fi,ai+1)if rows[i]['v7start']or rows[i]['grant']&4),None)
                # grant is combinational and need not represent this target
                # outside idle. Retain the raw row for source-bound attribution.
                op.update(demand_to_fabric=f['edge']-d['edge'],fabric_to_ACK=ack['edge']-f['edge'],
                          ACK_to_sample=s['edge']-ack['edge'],fabric_edge=f['edge'],ACK_edge=ack['edge'],
                          returned=ack['frd'],sampled=s['drd'],data_return=s['dret'],data_held=s['dheld'],
                          fabric_rows_with_ARM9_IO_owner=sum(r['fst']!=0 and r['target']==7 and r['mst']==1 for r in rows[fi:ai]),
                          before_ack_display_req=sum(r['greq']for r in rows[fi:ai]),
                          before_ack_display_words=sum(r['bwleft']>0 for r in rows[fi:ai]),
                          CRB_selected_hit=any(r['cbhit']and not r['greq']and r['creq']and not r['cwe']for r in rows[fi:ai+1]),
                          fabric_to_VRAM_port=c['edge']-f['edge'],VRAM_port_to_admission=v['edge']-c['edge'],
                          VRAM_admission_to_ACK=ack['edge']-v['edge'],
                          admitted_CB_hit=v['cbhit'],admitted_resolved=v['cres'],admitted_CB_tag=v['cbtag'],
                          resolved_before_admission_stall=dict(display_req=sum(r['greq']for r in rows[ci:vi]),
                              display_tail_only=sum(not r['greq']and r['bwleft']>0 for r in rows[ci:vi]),
                              capture_only=sum(not r['greq']and not r['bwleft']and r['caphold']and not r['cwpair']for r in rows[ci:vi]),
                              non_idle=sum(r['vst']!=0 for r in rows[ci:vi])),
                          raw_admission_edge=rows[admission]['edge']if admission is not None else None)
                assert op['returned']==op['sampled'],(cmd,op)
            else:
                captures=[i for i in range(di,si+1)if rows[i]['dreq']and rows[i]['dwe']and rows[i]['dreg']==0
                          and rows[i]['daddr']==0x06000100 and not rows[i]['wbv']]
                assert len(captures)==1,(cmd,si,'store WB captures',captures)
                cap=rows[captures[0]]
                op.update(WB_capture_edge=cap['edge'],demand_to_WB_capture=cap['edge']-d['edge'],
                          WB_capture_to_CPU_sample=s['edge']-cap['edge'])
            demand.append(op);start=si+1
        if not reads:
            physical_ack=[i for i,r in enumerate(rows)if r['freq']and r['fwe']and r['fa']==0x06000100 and r['fack']]
            assert len(physical_ack)==len(demand),(cmd,'write ACK coverage',len(physical_ack))
            for op,ai in zip(demand,physical_ack):
                ack=rows[ai]
                fi=next(i for i in range(bisect.bisect_right(row_edges,op['WB_capture_edge']),ai+1)if rows[i]['edge']>op['WB_capture_edge']and rows[i]['freq']and rows[i]['fwe']and rows[i]['fa']==0x06000100)
                ci=next(i for i in range(fi,ai+1)if rows[i]['creq']and rows[i]['cwe']and rows[i]['ccpu']and rows[i]['ca']==0x40)
                vi=next(i for i in range(ci,ai+1)if rows[i]['vst']==0 and not rows[i]['greq']and rows[i]['bwleft']==0
                        and not(rows[i]['caphold']and not rows[i]['cwpair'])and rows[i]['creq']and not rows[i]['cack'])
                f,c,v=rows[fi],rows[ci],rows[vi]
                op.update(fabric_edge=f['edge'],ACK_edge=ack['edge'],WB_capture_to_fabric=f['edge']-op['WB_capture_edge'],
                          fabric_to_VRAM_port=c['edge']-f['edge'],VRAM_port_to_admission=v['edge']-c['edge'],
                          VRAM_admission_to_ACK=ack['edge']-v['edge'],
                          transport_busy_wait=sum(r['vmreq']and r['vmwe']and not r['vmack']and r['xpbusy']for r in rows[vi:ai]),
                          display_req_before_admission=sum(r['greq']for r in rows[ci:vi]),
                          display_tail_before_admission=sum(not r['greq']and r['bwleft']>0 for r in rows[ci:vi]),
                          fabric_rows_with_ARM9_IO_owner=sum(r['fst']!=0 and r['target']==7 and r['mst']==1 for r in rows[fi:ci]))
            packets=[];pending=None
            for m in mem:
                if m['cmd']!=cmd:continue
                owned=m['valid']and m['we']and m['addr']==0x10040
                if owned and pending is None:
                    pending=dict(first_edge=m['edge'],first_ps=m['time_ps'],wait_states=Counter())
                if pending is None:continue
                assert owned and m['data']==0 and m['be']==15 and m['n']==1,(cmd,m)
                if m['gvalid']and m['grant']==2 and m['c_ready']:
                    assert 'admit_edge'not in pending
                    pending.update(admit_edge=m['edge'],admit_ps=m['time_ps'])
                if 'admit_edge'not in pending:pending['wait_states'][m['mcst']]+=1
                if m['take']:
                    assert 'admit_edge'in pending and m['edge']==pending['admit_edge']+1
                    pending.update(take_edge=m['edge'],take_ps=m['time_ps'],wait_mem_clocks=pending['admit_edge']-pending['first_edge'])
                    pending['wait_states']=dict(pending['wait_states']);packets.append(pending);pending=None
            assert pending is None and len(packets)==len(demand),(cmd,len(packets),pending)
            edge_ps={r['edge']:r['time_ps']for r in rows}
            for i,(op,packet)in enumerate(zip(demand,packets)):
                op['physical_store']=packet
                packet['MC_admit_minus_P7_ACK_ps']=packet['admit_ps']-edge_ps[op['ACK_edge']]
                packet['MC_admit_minus_WB_capture_ps']=packet['admit_ps']-edge_ps[op['WB_capture_edge']]
                if op['demand_to_WB_capture']:
                    assert i>0 and demand[i-1]['ACK_edge']>=op['demand_edge']
                    prev=demand[i-1]
                    op['previous_write_blocker']=dict(IO_rows=prev['fabric_rows_with_ARM9_IO_owner'],
                        transport_busy=prev['transport_busy_wait'],display_req=prev['display_req_before_admission'],
                        display_tail=prev['display_tail_before_admission'],ACK_edge=prev['ACK_edge'])
        # Each rep is warm1 + short4 + warm1 + long16. Keep every rep and
        # every sample rather than reproducing only the published best slope.
        groups=[]
        at=0
        for rep in range(5):
            for kind,n in [('warm-short',64),('short',256),('warm-long',64),('long',1024)]:
                group=demand[at:at+n];assert len(group)==n
                groups.append(dict(rep=rep,kind=kind,count=n,first=group[0]['demand_edge'],last=group[-1]['sample_edge'],
                                   service_hist=hist(x['demand_to_sample']for x in group),
                                   fabric_ACK_hist=hist(x['fabric_to_ACK']for x in group)if reads else None,
                                   ACK_sample_hist=hist(x['ACK_to_sample']for x in group)if reads else None))
                at+=n
        assert at==len(demand)
        timer=[r for r in rows if r['pipefire']and r['dmrq']and r['esub']==1 and r['dok']
               and r['daddr']in [0x04000100,0x04000104]]
        stamps=[];ti=0
        while ti<len(timer):
            first=timer[ti:ti+3];assert len(first)==3
            assert [r['daddr']for r in first]==[0x04000104,0x04000100,0x04000104]
            hi,lo,hi2=[r['drd']&65535 for r in first];ti+=3;last=first[-1]
            if hi!=hi2:
                retry=timer[ti:ti+2];assert len(retry)==2
                assert [r['daddr']for r in retry]==[0x04000100,0x04000104]
                lo,hi=[r['drd']&65535 for r in retry];ti+=2;last=retry[-1]
            stamps.append(dict(first_edge=first[0]['edge'],last_edge=last['edge'],value=(hi<<16)|lo))
        assert len(stamps)==20,(cmd,len(stamps))
        short=[];long=[]
        for rep in range(5):
            for idx,kind in [(0,'short'),(2,'long')]:
                t0,t1=stamps[4*rep+idx:4*rep+idx+2]
                group=next(g for g in groups if g['rep']==rep and g['kind']==kind)
                assert t0['last_edge']<group['first']<=group['last']<t1['first_edge']
                elapsed=(t1['value']-t0['value'])&0xffffffff
                group.update(raw_timer_start=t0,raw_timer_end=t1,raw_timer_elapsed_SYS=elapsed)
                (short if kind=='short'else long).append(elapsed)
        reconstructed=(min(long)-min(short))*100//(12*64)
        expected=json.loads((root/'check.log').read_text())['rows']
        expected=next(r for r in expected if r['kernel']==('ldr_vram_c'if reads else'str_vram_c')and int(r['arg'])==(cmd>>8))
        assert reconstructed==int(expected['arm7_cycles_per_op_x100']),(cmd,reconstructed,expected)
        bycmd[str(cmd)]=dict(count=len(demand),reads=reads,IF_wait=sum(x['IF_wait']for x in demand),
                            demand_sample=hist(x['demand_to_sample']for x in demand),
                            demand_fabric=hist(x['demand_to_fabric']for x in demand)if reads else None,
                            fabric_ACK=hist(x['fabric_to_ACK']for x in demand)if reads else None,
                            ACK_sample=hist(x['ACK_to_sample']for x in demand)if reads else None,
                            fabric_to_VRAM_port=hist(x['fabric_to_VRAM_port']for x in demand),
                            VRAM_port_to_admission=hist(x['VRAM_port_to_admission']for x in demand),
                            VRAM_admission_to_ACK=hist(x['VRAM_admission_to_ACK']for x in demand),
                            raw_short_SYS=short,raw_long_SYS=long,minimum_short_SYS=min(short),minimum_long_SYS=min(long),
                            reconstructed_published_x100=reconstructed,
                            physical_store_wait_mem=hist(x['physical_store']['wait_mem_clocks']for x in demand)if not reads else None,
                            blocked_store_previous_paths=hist(str(tuple(x['previous_write_blocker'][k]>0 for k in ['IO_rows','transport_busy','display_req','display_tail']))for x in demand if 'previous_write_blocker'in x)if not reads else None,
                            groups=groups,operations=demand)
    return dict(scope='Exact recorded pre-edge source clocks; no timestamp shifts, fitted waits or DS internal-edge claim. Counts include real original warmups.',
                CPU_rows=len(cpu),MEM_rows=len(mem),commands=bycmd)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);a=p.parse_args()
    result=analyze(a.root)
    (a.root/'causal-analysis.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:{x:y for x,y in v.items()if x not in ['groups','operations']}for k,v in result['commands'].items()},indent=2))
