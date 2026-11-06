#!/usr/bin/env python3
"""Read-only decomposition of the native actual-offer/ACK/accept ledger."""
from collections import Counter
from pathlib import Path
import argparse,json,os
os.setpriority(os.PRIO_PROCESS,0,10)
p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path);a=p.parse_args()
hist={k:Counter()for k in ['ACK_to_accept_SYS','ACK_phase','offer_to_accept_SYS','offer_to_ACK_SYS','b9_request_edges_per_word','IF_wait_edges_per_word']};group=[];count=noack=0
for line in (a.run/'ldm4.edges').read_text().splitlines():
 w=line.split(',');assert len(w)==29
 group.append(w)
 if w[9]!='1':continue
 count+=1;last=group[-1];tick=int(last[0]);first=int(group[0][0]);hist['offer_to_accept_SYS'][tick-first]+=1
 hist['b9_request_edges_per_word'][sum(x[20]=='1'for x in group)]+=1;hist['IF_wait_edges_per_word'][sum(x[6]=='1'for x in group)]+=1
 ack=[x for x in group if x[10]=='1'and x[11]=='0'and int(x[12],16)==int(x[2],16)and x[13]=='1'and x[14]=='0'and x[15]=='1']
 assert len(ack)<=1,(count,'multiple physical responses')
 if ack:
  x=ack[0];hist['ACK_to_accept_SYS'][tick-int(x[0])]+=1;hist['ACK_phase'][int(x[4])]+=1;hist['offer_to_ACK_SYS'][int(x[0])-first]+=1
 else:noack+=1
 group=[]
assert not group,'unfinished logical word'
result={'words':count,'words_without_matching_data_ACK_in_offer_window':noack,'histograms':{k:dict(sorted(v.items()))for k,v in hist.items()},'scope':'Response predicate is actual P7 RP_MAIN owner/address and fabric f_ack (possibly a fabric line-buffer hit), not an external PSRAM completion; logical admission/payload identity additionally checked by native observer. ARM9 request edges record demand overlap, not ARM9 accepted words. No adjusted DS cycles or aggregate timing forecast.'}
out=a.run/'service.json';out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
