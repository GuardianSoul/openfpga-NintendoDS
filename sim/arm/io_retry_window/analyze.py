#!/usr/bin/env python3
"""Replay raw physical timer samples, response ownership and exact helper results."""
from pathlib import Path
from collections import Counter
import json,re
B=Path(__file__).resolve().parents[3]/'build/io-retry-window'
summary={}
for p in sorted(B.glob('*-case?-phase?.log')):
 t=p.read_text()
 if 'TEST PASSED' not in t or p.stem.startswith('mutant-'):continue
 # Legacy logs read the mutable cycle counter in different active blocks.
 # Canonical detail/replay witnesses use one stable falling-edge count.
 label_delta=2 if p.stem.startswith(('before-','window-','default-'))else 1
 rows=re.findall(r'^RESULT (\d+) c(\d+) r0(\w+) r1(\w+) r2(\w+) r3(\w+) cpsr(\w+)',t,re.M)
 acks=[(int(c),int(a,16),int(d,16),int(w),int(pc,16),int(ok)) for c,a,d,w,pc,ok in re.findall(r'^IO_ACK (\d+) addr(\w+) data(\w+) WB(\d) pc(\w+) ready(\d)',t,re.M)]
 events=[(int(c),int(w),int(be,16),int(wd,16),int(ctr),int(cnt,16),int(tick))for c,w,be,wd,ctr,cnt,tick in re.findall(r'^TIMER_EVENT (\d+) wr(\d) be(\w+) wd(\w+) counter(\d+) cnt(\w+) tick(\d)',t,re.M)]
 reads=[e for e in events if not e[1]]
 assert len(rows)==16 and len(acks)==len(reads)==80,(p,len(rows),len(acks),len(reads))
 assert all(a[0]-e[0]==label_delta and a[1]==0x04000108 and a[2]==(e[5]<<16|e[4])for a,e in zip(acks,reads)),p
 pairs=[]
 for i,x in enumerate(rows):
  raw=[int(v,16)for v in x[2:6]];a=acks[5*i:5*i+5]
  assert raw==[v[2]&65535 for v in a[:4]],(p,i,raw,a)
  assert raw[2]==raw[3] and a[4][2]>>16==0
  assert int(x[6],16)==(0x600000df if i==0 else 0x800000df),(p,i,x)
  pairs.append([(raw[1]-raw[0])&65535,(raw[2]-raw[1])&65535])
 summary[p.stem]=dict(samples=len(reads),ACKs=len(acks),pairs=sorted(set(map(tuple,pairs))),DS_matches=sum(x==[4,5]for x in pairs),live_WB_at_ACK=sum(a[3]for a in acks),read_read_coreclk=sorted(Counter(reads[5*i+1][0]-reads[5*i][0]for i in range(16)).items()))
print(json.dumps(summary,indent=2))
(B/'sample-accounting.json').write_text(json.dumps(summary,indent=2)+'\n')
