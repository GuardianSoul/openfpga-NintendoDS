#!/usr/bin/env python3
"""Read sealed passive records. Counter partitions cover inclusive offer/ACK edges."""
import collections,csv,io,json,pathlib,statistics,sys
W=pathlib.Path(__file__).resolve().parents[2];O=W/'build/title-waits'
R_NAMES=['fabric_before_VRAM_or_return','idle_g_req_priority','idle_posted_write_buffer','idle_block_return_drain','idle_single_capture','idle_dispatch','cache_hit','posted_write_fence','miss_dispatch','VM_request_accept_wait','critical_fill_wait','block_resolver_or_fence','block_VM_accept_wait','other_VRAM_state','DMA_ACK','VRAM_ACK_handoff','unmapped','registered_hit_service']
W_NAMES=['unused','DMA_ACK','posted_slot_busy','posted_enqueue','main_service','fabric_admission','other_fabric','unused7']
def summary(a):
 return {'n':len(a),'min':min(a),'median':statistics.median(a),'max':max(a),'sum':sum(a)} if a else {'n':0}
def parse(path):
 raw=path.read_text();raw=raw[:raw.rfind('\n')+1];rows=list(csv.reader(io.StringIO(raw)));counts=collections.Counter();rc=collections.Counter();hit_causes=collections.Counter();miss_causes=collections.Counter();wc=collections.Counter();inv=collections.Counter();rs=[];ws=[];groups=[];fills=0;poison=0;v=[];mo=[];mt=[];returns=[];q=collections.Counter()
 for r in rows:
  if not r or r[0].startswith('#'):continue
  counts[r[0]]+=1
  if r[0]=='R':
   assert len(r)==24,r
   vals=list(map(int,r[6:]));duration=int(r[4]);assert sum(vals)==duration
   c=dict(zip(R_NAMES,vals));rc.update(c);rs.append(duration)
   if c['cache_hit'] or c['registered_hit_service']:hit_causes.update(c)
   if c['miss_dispatch']:miss_causes.update(c)
   if int(r[5],16)==0x06860000:groups.append({'first_R_cycle':int(r[1])-duration+1,'reads':0,'read_wait_cycles':0,'causes':collections.Counter()})
   if groups:groups[-1]['reads']+=1;groups[-1]['read_wait_cycles']+=duration;groups[-1]['causes'].update(c)
  elif r[0]=='W':
   vals=list(map(int,r[6:]));assert len(vals)==8 and sum(vals)==int(r[4]);wc.update(dict(zip(W_NAMES,vals)));ws.append(int(r[4]))
  elif r[0]=='I':
   assert len(r)==14
   cycle,frame,live,st,lv=int(r[1]),int(r[2]),int(r[3]),int(r[4]),int(r[5]);tag=int(r[6],16);fill=int(r[11]);writers=[]
   if int(r[7]):writers.append(('cw',int(r[8],16)>>3))
   if int(r[9]):writers.append(('vm',int(r[10],16)>>3))
   assert writers
   aliases=any(line==tag for _,line in writers);fill_alias=any(line==fill for _,line in writers)
   inv['any_write']+=1;inv['two_writers']+=int(len(writers)==2)
   if lv:
    inv['valid_cache_invalidations']+=1;inv['valid_alias' if aliases else 'valid_unrelated']+=1
    inv['valid_unrelated_during_read']+=int(not aliases and live)
   if st in [9,10]:
    inv['fill_write_events']+=1;inv['fill_matching' if fill_alias else 'fill_unrelated']+=1
    inv['first_poison_unrelated']+=int(not fill_alias and int(r[12])==0)
   inv['writes_during_read']+=live
  elif r[0]=='FILL':fills+=1
  elif r[0]=='FEND':poison+=int(r[4])
  elif r[0]=='V':v.append(r)
  elif r[0]=='MO':mo.append(r)
  elif r[0]=='MT':mt.append(r)
  elif r[0]=='D':returns.append(r)
  elif r[0]=='Q':q.update({'cycles':1,'main_arb_none':int(r[3]=='0'),'main_arb_A':int(r[3]=='1'),'main_arb_B':int(r[3]=='2'),'PSRAM_busy':int(r[4]),'PW_on':int(r[5]),'MR_ACK':int(r[6])})
 # No time/phase search: VM acceptance, MEM offer and MEM take are FIFO-ordered.
 prefix=min(len(v),len(mo),len(mt));bad=[];lat=[]
 for i in range(prefix):
  if not ((int(v[i][4],16)&(~7 if int(v[i][6]) else -1))==int(mo[i][2],16)==int(mt[i][2],16)):bad.append(i)
  else:lat.append(int(mt[i][1])-int(mo[i][1]))
 return {'record_counts':dict(counts),'read_causes':dict(rc),'read_causes_of_eventual_hits':dict(hit_causes),'read_causes_of_eventual_misses':dict(miss_causes),'read_transaction_cycles_inclusive':summary(rs),'write_causes':dict(wc),'write_transaction_cycles_inclusive':summary(ws),'readback_groups':groups,'invalidations':dict(inv),'fills':fills,'poisoned_completed_fills':poison,'destination_PW_cycles_overlapping':dict(q),'VM_FIFO_join':{'V':len(v),'MO':len(mo),'MT':len(mt),'paired':prefix,'address_mismatch_indices':bad[:20],'MO_to_MT_ps_rounded_to_ns':summary(lat)},'limits':['R/W partitions include first offer and final ACK edges; elapsed time is duration minus1.','Q/invalidations are overlapping diagnostics, not an exclusive stall partition.','MEM event $time is integer ns displayed in ps; queue intervals have nanosecond timestamp resolution.','Block VM address is aligned down to8words by the pinned OCT1 splitter before FIFO comparison.','VM FIFO join must be qualified before reporting physical queue timing; unmatched window-boundary entries remain explicit.','Changing invalidation could move producer/service timing; counts are not a speedup estimate.']}
if __name__=='__main__':
 mode=sys.argv[1] if len(sys.argv)>1 else 'observe';d=parse(O/f'title-final-waits-off-capture-{mode}/observer.csv.waits.csv');(O/f'analysis-{mode}.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps({k:v for k,v in d.items() if k!='readback_groups'},indent=2))
