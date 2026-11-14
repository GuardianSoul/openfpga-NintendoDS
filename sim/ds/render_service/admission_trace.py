#!/usr/bin/env python3
"""Join frozen cache launch/accepted owners to physical offer and native return."""
from pathlib import Path
from collections import Counter
import hashlib,json,sys
from analyze import stats

def analyze_prefix(p):
 blocks={};physical={};beats={};launches={1:[],2:[]};last_r={1:0,2:0};pending={};active={};vram=[];native=[];reads={};last={};events=Counter();deps=[];posts=[];misses=[]
 for s in p.open():
  a=s.rstrip().split(',');k=a[0];events[k]+=1
  if k=='DEPENDENCY':
   cyc=int(a[1]);deps.append(a)
   for own,j in [(1,13),(2,14)]:
    rv=int(a[j])
    if rv and not last_r[own]:
     assert own not in pending
     pending[own]=dict(start=cyc,epoch=int(a[2]),frontend_y=int(a[3]),completed=int(a[4]),wait17=int(a[5]),wait19=int(a[6]),head=int(a[7 if own==1 else 8],16),state=int(a[9 if own==1 else 10]))
    last_r[own]=rv
  elif k=='BLOCK_ACCEPT':
   cyc,gen,i,owner,cl=map(int,a[1:6]);blocks[i]=dict(accepted=cyc,gen=gen,owner=owner,origin=cl,block=int(a[6],16),address=int(a[7],16),texture_queue_n=int(a[8]))
   if owner:
    assert owner in pending,(i,owner,cyc);l=pending.pop(owner);l.update(id=i,accepted=cyc,wait=cyc-l['start']);launches[owner].append(l)
   active[i]=cyc
  elif k=='VRAM_BLOCK':
   cyc,t,i,owner,cl=map(int,a[1:6]);physical[i]=(cyc,t);vram.append((int(a[6],16),8,0,t,i))
  elif k=='VRAM_CPU':
   cyc,t,st=map(int,a[1:4]);addr=int(a[4],16);we,blk=map(int,a[5:7]);vram.append((addr&~7 if blk else addr,8 if blk else 1,we,t,None))
  elif k=='BLOCK_BEAT':
   if int(a[4])==3:beats[int(a[2])]=int(a[1]);active.pop(int(a[2]))
  elif k=='NATIVE_ACCEPT':
   cyc,t,port=map(int,a[1:4]);addr=int(a[4],16);n,we,i=map(int,a[5:8])
   if port==2:native.append((addr,n,we,t,i))
   if not we:reads[i]=(port,addr,n,t)
  elif k=='NATIVE_BEAT':
   if int(a[7]):last[int(a[3])]=int(a[2])
  elif k=='SYS_POST':posts.append((int(a[1]),int(a[2]),int(a[3],16)))
  elif k=='TRAFFIC_DEADLINE_MISS':misses.append(a)
 assert len(vram)>=len(native)and len(vram)-len(native)<=1
 nids={}
 for v,n in zip(vram,native):
  assert v[:3]==n[:3]
  if v[4]is not None:nids[v[4]]=n[4]
 # Reconstruct only documented fixture input offers; validate every actual
 # accepted owner against them. Native/controller state is never guessed.
 ds={int(a[1]):a for a in deps};ac={b['accepted']:i for i,b in blocks.items()};end_cycle=max(ds)
 cache_start={}
 for own in [1,2]:
  for l in launches[own]:cache_start.setdefault(l['start'],[]).append((own,l['id']))
 stop={}
 for i,t in beats.items():stop.setdefault(t,[]).append(i)
 first_d=min(b['accepted']for b in blocks.values()if b['owner']==0);traffic_at=first_d-1
 dq=False;dn=0;live={};rv={1:0,2:0};waiting={};dep=None;categories={1:Counter(),2:Counter()};head_wait=Counter();late_wait=Counter();validated=0
 for cyc in range(traffic_at,end_cycle+1):
  if cyc in ds:
   dep=ds[cyc];rv={1:int(dep[13]),2:int(dep[14])}
  for own,i in cache_start.get(cyc,[]):waiting[own]=i
  ncache=sum(blocks[i]['owner']!=0 for i in live)
  i=ac.get(cyc);owner=blocks[i]['owner']if i is not None else None
  if owner is not None:
   if owner==0:assert dq,('fixture 2D offer',cyc)
   else:assert not dq and ncache<2 and rv[owner]and(owner==1 or not rv[1]),('cache admission guards',cyc,owner,dq,ncache,rv)
   validated+=1
  for own,wi in waiting.items():
   if wi==i:continue
   gate='cache_TNF_full'if ncache>=2 else'texture_first'if own==2 and rv[1]else'2D_first'if dq else'VRAM_admission_or_crossing'
   categories[own][gate]+=1
  if dep is not None and int(dep[6]):
   hb=int(dep[8],16);wi=waiting.get(2);matches=[j for j in live if blocks[j]['owner']==2 and(blocks[j]['block']&16383)==hb]
   if wi is not None and(blocks[wi]['block']&16383)==hb:
    gate='cache_TNF_full'if ncache>=2 else'texture_first'if rv[1]else'2D_first'if dq else'VRAM_admission_or_crossing';cause='palette_head_preACK_'+gate
   elif matches:
    j=matches[0]
    cause='palette_head_accepted_before_offer'if j not in physical or cyc<physical[j][0] else'palette_head_after_physical_offer'
   else:cause='palette_head_lookup_or_other_ordered_dependency'
   head_wait[cause]+=1
   if cyc>=end_cycle-8*4260:late_wait[cause]+=1
  if i is not None:
   live[i]=cyc
   if owner:assert waiting.pop(owner)==i
  for j in stop.get(cyc,[]):live.pop(j)
  if owner==0:dn+=1;dq=False
  elif not dq and dn<64*(1+(cyc-traffic_at)//4260):dq=True
 result={};worst=[]
 for own in [0,1,2]:
  ids=[i for i,b in blocks.items()if b['owner']==own]
  d={k:[]for k in ['accepted_to_offer_SYS','offer_to_native_ps','native_to_last_ps','accepted_to_last_block_SYS']}
  for i in ids:
   b=blocks[i]
   if i in physical:d['accepted_to_offer_SYS'].append(physical[i][0]-b['accepted'])
   if i in nids:
    ni=nids[i];d['offer_to_native_ps'].append(reads[ni][3]-physical[i][1])
    if ni in last:d['native_to_last_ps'].append(last[ni]-reads[ni][3])
   if i in beats:d['accepted_to_last_block_SYS'].append(beats[i]-b['accepted'])
  if own:
   ls=launches[own];d['cache_launch_to_accepted_SYS']=[l['wait']for l in ls]
   for l in sorted(ls,key=lambda x:-x['wait'])[:6]:
    i=l['id'];worst.append(dict(l,owner=own,accepted_block=blocks[i],physical=physical.get(i),returned=beats.get(i)))
  result[own]={k:stats(v)for k,v in d.items()}
 return dict(source=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),events=events,intervals=result,worst_cache_admissions=worst,outstanding_cache_requests=pending,outstanding_blocks=active,complete_physical_joins=len(nids),validated_accepted_fixture_owners=validated,cache_pending_preACK_gate_SYS=categories,palette_wait19_head_stage_SYS=head_wait,palette_wait19_last8lines_stage_SYS=late_wait,scope='Frozen fatal prefix, not complete equivalence or full drain. Cache request start from original r_v rising edge, joined to actual accepted owner/block; fixture2D offers reconstructed from exact source and ALL accepted owners validated; no current-grant attribution.')
if __name__=='__main__':
 p=Path(sys.argv[1]);r=analyze_prefix(p);out=Path(sys.argv[2]);out.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({k:r[k]for k in ['validated_accepted_fixture_owners','cache_pending_preACK_gate_SYS','palette_wait19_head_stage_SYS','palette_wait19_last8lines_stage_SYS']},indent=2))
