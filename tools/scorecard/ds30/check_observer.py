#!/usr/bin/env python3
"""Check actual DS30 body/context endpoint files; no model/compiler invocation."""
from pathlib import Path
import argparse,hashlib,json,re,struct
from check import check
sha=lambda b:hashlib.sha256(b).hexdigest()
def physical(cpu,address,wc):
 if cpu==9 and address<0x02000000:return address&0x7fff
 if cpu==7 and address>>24==3:
  if address&0x800000 or wc==0:return address&0xffff
  return (0x10000+(address&0x3fff))if wc==1 else(0x14000+(address&0x3fff))if wc==2 else(0x10000+(address&0x7fff))
 return address&0x3fffff
def body_check(blob,rows,manifest,wc):
 assert len(rows)==25 and len(blob)==manifest['total_body_bytes'],'complete body packet required'
 for i,(row,expected)in enumerate(zip(rows,manifest['bodies'])):
  assert (row['index'],row['cpu'],row['address'],row['bytes'],row['file_offset'])==(i,expected['cpu'],expected['address'],expected['bytes'],expected['file_offset'])
  assert row['wramcnt']==wc and row['physical']==physical(row['cpu'],row['address'],wc),'actual backing/mapping differs'
  at=row['file_offset'];assert sha(blob[at:at+row['bytes']])==expected['sha256'],'live body bytes differ: '+expected['name']
def validate(prefix,prepared,run_manifest,log):
 m=json.loads((prepared/'hook-manifest.json').read_text());runtime=json.loads(run_manifest.read_text())
 assert runtime['source']==m['source']and runtime['ROM_sha256']==m['ROM_SHA256']
 assert re.fullmatch('[0-9a-f]{64}',runtime['model_sha256'])
 events=[json.loads(s)for s in Path(str(prefix)+'.jsonl').read_text().splitlines()]
 assert events[0]['evidence']=='actual_native'and events[0]['trigger']=='direct_ARM9_preposedge_retirement_postNBA1ps_snapshot'
 assert all(events[0]['parameters'][k]==v for k,v in m['required_profile'].items())
 assert all(runtime['profile'][k]==events[0]['parameters'][k]for k in m['required_profile']if k in runtime['profile'])
 assert events[-1]['event']=='complete'and events[-1]['calls']==events[-1]['returns']==32
 contexts={e['stage']:e for e in events if e['event']=='checkpoint'};assert set(contexts)=={'ping','endpoint'}
 assert contexts['ping']['r0']==0x123456
 for stage,ctx in contexts.items():
  assert ctx['pc']==m['checkpoints'][stage]and len(ctx['cp15'])==16 and ctx['wramcnt']in range(4)
  rows=[e for e in events if e['event']=='body'and e['stage']==stage]
  body_check(Path(str(prefix)+'.'+stage+'.bodies.bin').read_bytes(),rows,m,ctx['wramcnt'])
 calls=[e for e in events if e['event']=='command_call'];returns=[e for e in events if e['event']=='command_return']
 assert [e['r0']for e in calls]==m['commands']and len(returns)==32 and returns[0]['r0']==0x123456
 assert all(r['r0']!=0x3ffffff and c['clock']<r['clock']for c,r in zip(calls,returns))
 assert all(a['clock']<b['clock']for a,b in zip(returns,calls[1:]))
 # Context preservation is a native self-consistency gate, not DS live-state equality.
 first=calls[1]
 assert all(e['cp15']==first['cp15']and e['wramcnt']==first['wramcnt']for e in calls[1:]+returns[1:])
 main=Path(str(prefix)+'.main.bin');rows=check(main,prepared/'adapter-manifest.json')
 words=struct.unpack_from('<33I',main.read_bytes(),0x3d0000);end=contexts['endpoint']
 assert list(words[9:25])==end['cp15']and words[25]==end['EXMEMCNT']and (words[27]>>24)&3==end['wramcnt']
 assert words[28]==end['POWCNT1']and words[32]==end['IE9']and words[8]==end['sp']
 assert len(rows['rows'])==31 and [int(e['arm7_cycles_per_op_x100'])for e in rows['rows']]==[e['r0']for e in returns[1:]]
 text=log.read_text();assert text.count('DS30_OBSERVER_ENDPOINT_OK bodies50 calls32 returns32')==1
 assert text.count('Verilog $finish')==1 and not re.search('DS30_OBSERVER_ERROR|DS30_OBSERVER_INCOMPLETE|^TIMEOUT$|^FAIL$|%Error|%Fatal|Assertion failed',text,re.M)
 assert re.search(r'^video: [1-9]\d* frames, 0 errors;.*underruns 0$',text,re.M)
 assert re.search(r'^models: sdram errors 0, cram errors 0/0; cart words [1-9]\d*, 0 on clk_bus edges$',text,re.M)
 assert re.search(r'^vmcheck: .*0 mismatches$',text,re.M)
 return dict(status='LOADED BODY/CONTEXT/ROW/PHYSICAL GUARDS PASS; timing remains separate',source=m['source'],model_SHA256=runtime['model_sha256'],body_snapshots=50,command_pairs=32,context=contexts,rows=rows['rows'],DS_live_context_equal=False)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prefix',type=Path,required=True);p.add_argument('--prepared',type=Path,required=True);p.add_argument('--run-manifest',type=Path,required=True);p.add_argument('--log',type=Path,required=True);a=p.parse_args();print(json.dumps(validate(a.prefix,a.prepared,a.run_manifest,a.log),indent=2))
