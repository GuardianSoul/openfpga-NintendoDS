#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import collections,csv,json,pathlib,statistics
W=pathlib.Path(__file__).resolve().parents[2];O=W/'build/title-waits';P=O/'title-final-waits-off-capture-observe/observer.csv.waits.csv'
def stats(v):return {'n':len(v),'min':min(v),'median':statistics.median(v),'max':max(v),'sum':sum(v)} if v else {'n':0}
v=[];mo=[];mt=[];dd=[];ff=[];rr={};fe=[]
with P.open() as f:
 for r in csv.reader(f):
  if not r or r[0].startswith('#'):continue
  if r[0]=='V':v.append(r)
  elif r[0]=='MO':mo.append(r)
  elif r[0]=='MT':mt.append(r)
  elif r[0]=='D':dd.append(r)
  elif r[0]=='FILL':ff.append(r)
  elif r[0]=='FEND':fe.append(r)
  elif r[0]=='R':rr[int(r[3])]=r
assert len(v)==len(mo)==len(mt)
fill_pairs=[]
for a,b,c in zip(v,mo,mt):
 expected=int(a[4],16)&(~7 if int(a[6]) else -1)
 assert expected==int(b[2],16)==int(c[2],16)
 if int(a[3])==9:fill_pairs.append((a,b,c))
assert len(fill_pairs)==len(ff)==len(fe) and len(dd)==8*len(ff)
queue=[];cross=[];first=[];critical=[];tail=[];checked=0;mc_initial=collections.Counter()
for i,((a,b,c),f,e) in enumerate(zip(fill_pairs,ff,fe)):
 data=dd[8*i:8*i+8];assert [int(d[3]) for d in data]==list(range(8))
 assert int(a[4],16)>>3==(int(f[3],16)&0xfffff)>>5==(int(e[3],16)&0xfffff)>>5
 rid=int(f[2]);r=rr[rid];off=(int(f[3],16)>>2)&7;crit=data[off]
 assert int(r[1])==int(crit[1])+2,('critical_return_to_DMA_ACK',rid,r,crit)
 checked+=1;queue.append(int(c[1])-int(b[1]));cross.append(int(b[1])-int(a[2]));first.append(int(data[0][2])-int(c[1]));critical.append(int(crit[2])-int(c[1]));tail.append(int(data[-1][1])-int(data[0][1]));mc_initial[(b[5],b[6])]+=1
out={'verdict':'PASS ordered exact physical-address and critical-word event binding','VM_requests':len(v),'DMA_source_fills':len(ff),'critical_word_to_DMA_ACK_exact_SYS':2,'critical_checks':checked,'units':'MEM timestamp intervals:ps, sampled $time has1ns resolution; SYS intervals exact independent clocks','VM_ack_to_MEM_offer_ps':stats(cross),'MEM_offer_to_take_ps':stats(queue),'MEM_take_to_first_return_ps':stats(first),'MEM_take_to_requested_critical_return_ps':stats(critical),'SYS_first_to_last_fillword':stats(tail),'MC_state_and_refresh_at_offer':{str(k):z for k,z in mc_initial.items()},'limits':['MC state is captured at offer only, not a cycle partition of subsequent physical wait.','Intervals overlap read-side RFIL counters and must not be added as independent CPU/DMA lost time.','No interpolation or image/phase search is used: queues are FIFO and addresses/word indices must agree exactly.']}
(O/'physical-binding.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
