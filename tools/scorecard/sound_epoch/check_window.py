#!/usr/bin/env python3
"""Check bounded capture coverage, never invent an inter-model epoch offset."""
from pathlib import Path
from collections import Counter
import json
def check_window(path):
 rows=[json.loads(l)for l in Path(path).read_text().splitlines()]
 assert rows[0]['kind']=='entry'and rows[0]['pc']==0x037f80a6
 assert rows[-1]['kind']=='end'and rows[-1]['reason']=='first80dc_plus256'
 retires=[r for r in rows if r['kind']=='retire'];anchor=next(i for i,r in enumerate(retires)if r['pc']==0x037f80dc)
 assert len(retires)==anchor+257 and rows[-1]['anchor_index']==anchor+1
 assert [r['index']for r in retires]==list(range(1,len(retires)+1))
 assert all(b['a7']>=a['a7']for a,b in zip(retires,retires[1:]))
 assert all(len(r['r'])==15 and len(r['timer_raw'])==16 for r in retires)
 assert retires[0]['pc']==0x037f80a6 and retires[0]['a7']==rows[0]['a7']
 return dict(status='PASS',records_by_kind=dict(Counter(r['kind']for r in rows)),retirements=len(retires),
             first80dc=retires[anchor],last_retirement=retires[-1],entry=rows[0],end=rows[-1],
             clock_semantics='C19 raw callback fields only; timer accesses are before the access; retirement register snapshots are after execution',
             hardware_limit='No DS phase inference, new native run, seed edit or PCM sample shift')
if __name__=='__main__':
 import sys
 print(json.dumps(check_window(sys.argv[1]),indent=2))
