#!/usr/bin/env python3
"""Match an actual common PC/order, without fitting either model's clock."""
from pathlib import Path
import csv,json
def compare(window,setup):
 w=[json.loads(l)for l in Path(window).read_text().splitlines()]
 r=[x for x in w if x['kind']=='retire'];a=next(i for i,x in enumerate(r)if x['pc']==0x037f80dc);r=r[a:]
 with Path(setup).open()as f:
  assert next(f).startswith('#SND_SETUP_V2 ')
  native=[{k:int(v)for k,v in x.items()}for x in csv.DictReader(f)if not x['cycle'].startswith('#')]
 n=[x for x in native if x['cpu_retire']and 0x037f0000<=x['cpu_pc']<0x03810000]
 assert len(r)==257 and n[0]['cpu_pc']==0x037f80dc
 assert [x['pc']for x in r]==[x['cpu_pc']for x in n[:257]],'common retirement PC/order differs'
 pairs=[dict(index=i,pc=x['pc'],C19_retirement=x['index'],C19_ARM7Timestamp=x['a7'],C19_SysTimestamp=x['sys'],native_clk_sys=y['cycle'])for i,(x,y)in enumerate(zip(r,n[:257]))]
 return dict(status='PASS',common_PC_count=257,first=pairs[0],last=pairs[-1],pairs=pairs,
             observation_limit='Native cpu_domain debug stream prioritizes ARM9 on simultaneous retirements; only the observed ARM7-visible PC/order is compared, not a lossless native register trace.',
             epoch_limit='No timestamp offset, clock phase, sample shift or DS hardware target is fitted.')
if __name__=='__main__':
 import sys
 print(json.dumps(compare(sys.argv[1],sys.argv[2]),indent=2))
