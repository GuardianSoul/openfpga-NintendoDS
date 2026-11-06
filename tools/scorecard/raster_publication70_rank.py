#!/usr/bin/env python3
"""Rank the retained line131 path; never open a raw trace or run a model."""
import collections,gzip,hashlib,json,os
from pathlib import Path
R=Path(__file__).resolve().parents[2];B=R/'build/turn69r1';D=R/'docs/results/raster-publication70-boundary-20261102';T=14919
def sha(b):return hashlib.sha256(b).hexdigest()
def main():
 os.setpriority(os.PRIO_PROCESS,0,10)
 service=(B/'native-service.json').read_bytes();v=json.loads(service);r=next(x for x in v['target_generation']['lines']if x['line']==131);t0=r['request'];te=r['EOF'];N=(te-t0)//T
 p=B/'candidate-host/results/corner/streams.json.gz';data=p.read_bytes();binding=json.loads((p.parent/'analysis-prefix-binding.json').read_text());assert sha(data)==binding['files']['streams.json.gz'];s=json.loads(gzip.decompress(data))
 uses=[x for x in s['uses']if t0<=x[0]<=te];records=[x for x in s['logical_stream']if t0<=x[0]<=te];groups=[]
 for x in uses:
  key=[x[1],x[3],x[2],x[5]]
  if groups and groups[-1]['key']==key:groups[-1]['times'].append(x[0])
  else:groups.append(dict(key=key,times=[x[0]]))
 assert len(groups)==len(records)==325 and [g['key']for g in groups]==[x[1:5]for x in records]
 retry=set();back=set();prev=t0;parts=collections.Counter();selected=[];fill_selected=[]
 for g,x in zip(groups,records):
  assert all(z-y==2*T for y,z in zip(g['times'],g['times'][1:]))
  first,last=[(q-t0)//T for q in [g['times'][0],g['times'][-1]]];consume=(x[0]-t0)//T
  emit=max(last+1,(prev-t0)//T);assert consume>=emit+1
  retry.update(range(first,last));back.update(range(emit+1,consume));g.update(consume=x[0],earliest_emit=t0+emit*T,present_notready_cycles=consume-emit-1);prev=x[0]
  if len(g['times'])==1:continue
  ff=[f for f in s['fills']if[f[1],f[3],f[2],f[4]]==g['key']and g['times'][0]<=f[0]<=g['times'][-1]];assert len(ff)==1;f=ff[0]
  pp=[p for p in v['canonical_blocks']if[p['cache'][k]for k in ['type','bank','id','generation']]==g['key']and p['last_SYS']==f[0]-2*T];assert len(pp)==1;p=pp[0];a,z=g['times'][0],g['times'][-1];phy=p['physical']
  bounds=[('before_offer',a,p['offer'][0]),('offer_to_ACK',p['offer'][0],p['ack']),('ACK_to_physical_take',p['ack'],phy['take']),('physical_service',phy['take'],phy['last_physical']),('physical_to_SYS',phy['last_physical'],p['last_SYS']),('SYS_to_fill',p['last_SYS'],f[0]),('fill_to_success_query',f[0],z)]
  for k,l,h in bounds:parts[k]+=max(0,min(z,h)-max(a,l))
  selected.append(p);fill_selected.append(f)
 assert len(retry)==5786 and len(back)==2020 and not retry&back and sum(parts.values())==5786*T and len(selected)==173
 evidence=dict(source=v['source'],model=v['model_sha256'],SYS_ps=T,line=r,query_groups=groups,records=records,selected_packets=selected,selected_fills=fill_selected,source_service_sha256=sha(service),cached_streams_sha256=sha(data))
 payload=json.dumps(evidence,separators=(',',':')).encode();compressed=gzip.compress(payload,mtime=0);(D/'line131-evidence.json.gz').write_bytes(compressed)
 summary=dict(source=v['source'],model=v['model_sha256'],line=131,bank=1,generation=23846,request_ps=t0,EOF_ps=te,total_SYS=N,target_SYS=4260,ratio=N/4260,excess_SYS=N-4260,
  partition_SYS=dict(cache_retry=5786,downstream_PS_notready=2020,other_setup_hit_handoff_traversal=1064),
  retry_subpartition_ps=dict(parts),retry_subpartition_SYS={k:x/T for k,x in parts.items()},records=dict(total=325,headers=75,vertices=250,cold_refills=173,header_refills=sum(p['cache']['type']==0 for p in selected),vertex_refills=sum(p['cache']['type']==1 for p in selected)),
  source_proof='F_SH/F_VRD two-cycle retry; successful query produces no earlier than next edge and registered ps_valid accepts no earlier than the following edge. Emit=max(last_query+1,previous_accept); held output intervals are [emit+1,accept). Source F_HDR/F_VOUT/out_free and PSREG1 must remain pinned. Raster compute/texture/edge reasons within !ps_ready are not individually measured.',
  limits=['This exact timestamp accounting is not a retiming prediction. Removing all retries leaves3084observed other cycles, not a qualified all-hot cadence.',
          'Physical-time terms retain ps precision; fractional SYS values reflect MEM/SYS clocks, not measurement tolerance.',
          'The1064residual contains useful handoff/traversal and any unobserved waits; do not label it pure raster compute.',
          'Ring publication alone cannot close4610excess SYS; improving only the588before-offer+84offer/ACK+346publication+155query SYS cannot close it either.'],
  next_speed_action='Source-price demand-aware refill timing/retention using the exact173late records and existing idle query/loader ports: move their physical service ahead of first demand, without changing cache hash/capacity,8word quantum, physical arbitration or publication. Check actual service lead and live-bank dependencies before selecting a candidate; no bare four-line gate or hot guarantee.',
  dependency='The same publication70 model must split actual store/header/vertex readiness, front state/bk_full, raster pipeline/texture/palette/edge causes, final-pass staging holds and LLR stalls on this exact request-to-EOF interval. Then choose a deadline-gain candidate with unchanged pixel/CPU/PCM/save gates; do not polish rejected ring timing alone.',
  diagnostic_batch=dict(additional_models=0,detail_window_ps=[324400000000,325850000000],lines=list(range(125,133)),events='75..79: per-line mutually-exclusive store state counts; overlapping wait masks; front state/bk_full; pipeline reason masks; finalpass/LLR/canonical service terms; no extra full trace'),
  evidence_sha256=sha(compressed),evidence_bytes=len(compressed),status='RETAINED_TIMESTAMPS_EXACT_ACCOUNTING_NO_SPEED_ACCEPTANCE')
 (D/'line131-ranking.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary['partition_SYS']));print(json.dumps(summary['retry_subpartition_SYS']))
if __name__=='__main__':main()
