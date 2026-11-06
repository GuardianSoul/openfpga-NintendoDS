#!/usr/bin/env python3
"""Price one reservation/request overlap from retained source and trace only."""
import collections,hashlib,json,os,statistics,struct
from pathlib import Path
R=Path(__file__).resolve().parents[2];B=R/'build/ring65'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def stats(v):return dict(count=len(v),min_ps=min(v),median_ps=statistics.median(v),max_ps=max(v))if v else dict(count=0)
def main():
 os.setpriority(os.PRIO_PROCESS,0,10)
 bounds=next(x for x in json.loads((B/'later-producer-cache-summary.json').read_text())if x['y']==131);lo,hi=bounds['start'],bounds['end']
 events=list(struct.iter_unpack('<Q6IQ',(B/'later-window.bin').read_bytes()))
 offered={};accepted=collections.deque();sysreads=collections.deque();phys=[];sys=[];first=None
 for t,k,p,a,d,x,y,z in events:
  if p==6 and k==1:offered[p]=(t,a)
  if p==6 and k==2 and not x&256:
   assert (x>>4)&15==8;offer=offered.pop(p,None);accepted.append(dict(offer=offer,take=t,addr=a,left=8))
  if p==6 and k==3 and accepted:
   v=accepted[0];v['left']-=1
   if not v['left']:
    accepted.popleft()
    if lo<=v['take']<=hi and 0x1a0000<=v['addr']<0x1c0000:phys.append(dict(**v,last=t))
  if p==6 and k==10:
   if x&4 and first is None:first=(t,a)
   if x&2:
    sysreads.append(dict(offer=first,ack=t,addr=a,left=8));first=None
   if x&1 and sysreads:
    v=sysreads[0];v['left']-=1
    if not v['left']:
     sysreads.popleft()
     if lo<=v['ack']<=hi and 0x1a0000<=v['addr']<0x1c0000:sys.append(dict(**v,last=t))
 assert len(phys)==len(sys)==173,(len(phys),len(sys))
 fills=next(x for x in json.loads((B/'later-producer-cold-fill-binding.json').read_text())if x['y']==131)
 assert sum(x['new_keys']for x in fills['details'])==173 and all(x['fill_keys_equal_new_keys']for x in fills['details'])
 sources=['rtl/ds/nds_g3d_pair_cache.sv','rtl/ds/nds_g3d_store_pair.sv','rtl/ds/nds_g3d_sd_records.sv','rtl/ds/nds_g3d_sp_arb.sv','rtl/pocket/nds_sdram_bus.sv']
 out=dict(status='SOURCE_PRICE_ONLY_NO_RTL_MODEL_OR_FIT',source='2f86d1e69b0fc477d179375315acdefc1b438a68',inputs={str(p.relative_to(R)):sha(p)for p in [B/'later-window.bin',B/'later-producer-cache-summary.json',B/'later-producer-cold-fill-binding.json']+[R/n for n in sources]},line131=bounds,cold_record_binding=fills,physical_blocks=phys,system_blocks=sys,observed_service=dict(physical_offer_to_take=stats([v['take']-v['offer'][0]for v in phys]),physical_take_to_eighth_return=stats([v['last']-v['take']for v in phys]),system_ack_to_eighth_return=stats([v['last']-v['ack']for v in sys])),proposal=dict(file='rtl/ds/nds_g3d_pair_cache.sv',change='Assert m_req in the reserve_done half of C_RESERVE as well as C_REQ; select physical owner while reservation invalidation writes. Handle any ACK on reserve_done by entering C_FILL with beat0, otherwise C_REQ. No speculative record, additional owner, FIFO, storage, or request before captured bank/id/generation/way.',local_price=dict(removed_serial_SYS_per_cold_fill=1,observed_cold_fills=173,local_SYS_bubbles=173,local_time_ps=173*14919,line_deficit_SYS=9513-4260,deficit_fraction=173/(9513-4260)),scope='Local serial-bubble price only. Earlier requests can change arbitration phase; no claimed native saving, deadline closure, or global time bound.',physical_contract='All8words retained incl tag/inverse/FORMAT/zero; cache publication waits validated eighth return. sp_arb owner holds8 returns; ring port0 first at free boundary, other3 rotate. Existing physical port6 priority/refresh/write chains/CDC unchanged. No finite unconditional global service bound exists under unbounded higher-priority traffic; measured per-block bounds retained above.',qualification_needed=['Logical bank/id/generation/address/data order and exactly one request per cold fill under stalls/cancel/reset/invalidation','No payload write before reservation invalidates selected way; no hit to replaced tag/new payload mixture','All8 physical words and validation before publication; invalidated/cancelled fills drain without publishing','Actual early-ACK/owner/generation or reservation fault caught; original RPRI/ring deadlines and full affected native gate retain regressions']),decision='Smallest source-local overlap is only173SYS/5253SYS local bubbles (3.29% of deficit); insufficient alone. No implementation launched. No capacity/hash change or paired-front revival.')
 out['input_limitation']='The retained later window zeros data payloads, retaining original times/kinds/ports/addresses/control. This price counts eight returns and binds service, not payload values; existing full physical/causal replay and source validation remain separate.'
 (B/'cold-record-delivery-price.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:out[k]for k in ['status','observed_service','decision']}))
if __name__=='__main__':main()
