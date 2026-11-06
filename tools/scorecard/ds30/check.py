#!/usr/bin/env python3
"""Read the original arm7time CSV from a completed native MAIN dump."""
from pathlib import Path
import argparse,csv,hashlib,io,json,struct
META_NAMES=['magic','version','error','csv_bytes','source_csv','source_buf','source_name','cpsr','sp',
 'CP15Control','DCacheable','ICacheable','WriteBufferable','DPermission','IPermission','DTCM','ITCM',
 *['Region'+str(i)for i in range(8)],'EXMEMCNT','VRAMCNT_ABCD','VRAMCNT_EFG_WRAM','POWCNT1','DISPCNT_A','DISPCNT_B','IME','IE']
def check_rom(rom,original,m):
 sha=lambda b:hashlib.sha256(b).hexdigest()
 assert sha(original)==m['retained_producer_SHA256']['arm7time.nds']
 assert len(rom)==len(original),'ROM layout/length changed'
 for b in m['preserved_bodies']:
  assert sha(rom[b['ROM_offset']:b['ROM_offset']+b['bytes']])==b['sha256'],'original kernel/helper byte identity: '+b['name']
 off,entry,base,size=struct.unpack_from('<4I',rom,0x30)
 assert size==m['ARM7_image_bytes']and sha(rom[off:off+size])==m['ARM7_image_SHA256'],'entire original ARM7 image identity'
 for p in m['patches']:
  off,size=p['ROM_offset'],p['bytes']
  assert sha(original[off:off+size])==p['before_sha256']and sha(rom[off:off+size])==p['after_sha256'],'declared patch bytes'
 changed=[i for i,(a,b)in enumerate(zip(original,rom))if a!=b]
 assert len(changed)==m['actual_changed_bytes']
 assert all(any(p['ROM_offset']<=i<p['ROM_offset']+p['bytes']for p in m['patches'])for i in changed),'undeclared ROM change'
 assert sha(rom)==m['ROM_SHA256'],'complete adapter identity'
 return dict(status='PASS original kernel/helper/ARM7 bytes and exact patch fences',preserved_bodies=len(m['preserved_bodies']),changed_bytes=len(changed))
def check(path,manifest):
 m=json.loads(Path(manifest).read_text());data=Path(path).read_bytes();assert len(data)==4*1024*1024,'complete MAIN dump required'
 off=0x3d0000;words=struct.unpack_from('<33I',data,off);meta=dict(zip(META_NAMES,words))
 assert meta['magic']==0x30335441 and meta['version']==1 and meta['error']==0
 assert 0<meta['csv_bytes']<=4096 and 0x02000000<=meta['source_csv']<0x02400000
 rows=list(csv.DictReader(io.StringIO(data[off+256:off+256+meta['csv_bytes']].decode())))
 assert [(r['kernel'],r['arg'])for r in rows]==[(r['kernel'],r['arg'])for r in m['DS_rows']],'all original31 rows in order required'
 for r in rows:assert int(r['arm7_cycles_per_op_x100'])>=0,'original ARM7 returned failure'
 for r in m['preserved_bodies']:
  if (r['cpu']==7 and r['address']<0x03700000)or(r['cpu']==9 and 0x02000000<=r['address']<0x02400000):
   blob=data[r['address']&0x3fffff:(r['address']&0x3fffff)+r['bytes']]
   assert hashlib.sha256(blob).hexdigest()==r['sha256'],'live MAIN code identity '+r['name']
 return dict(status='ROW/MAIN-CODE PASS; timing and data/state acceptance pending',context_at_completion=meta,
             rows=[dict(**r,DS_x100=int(d['arm7_cycles_per_op_x100']),core_over_DS=int(r['arm7_cycles_per_op_x100'])/int(d['arm7_cycles_per_op_x100']))for r,d in zip(rows,m['DS_rows'])],
             limits=m['limits'])
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('dump',type=Path);p.add_argument('manifest',type=Path);a=p.parse_args();print(json.dumps(check(a.dump,a.manifest),indent=2))
