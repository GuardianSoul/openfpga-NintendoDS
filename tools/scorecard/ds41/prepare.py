#!/usr/bin/env python3
"""Prepare DS41 source/input maps only. Never compile or start a simulator."""
from pathlib import Path
import argparse,hashlib,json,struct,csv,tarfile,sys,re
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools/hwref'))
from check_iophase import expected_code,fnv
from check_arm7thumb import Elf
SHA='863fb5496442218b5f62d0dcd3d8d26065b695b3a6a785b4e74f1bae36592c6b'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,default=ROOT/'docs/results/hwref-run41-20261101/evidence.tar.gz');p.add_argument('--out',type=Path,required=True);a=p.parse_args();assert sha(a.evidence)==SHA
out=a.out.resolve();assert not out.exists(),'fresh output required';out.mkdir(parents=True)
with tarfile.open(a.evidence)as t:
 names={x.name:x for x in t.getmembers()if x.isfile()};manifest=json.loads(t.extractfile(names['artifact-manifest.json']).read())
 for n,v in manifest.items():
  b=t.extractfile(names[n]).read();assert len(b)==v['bytes']and hashlib.sha256(b).hexdigest()==v['sha256']
 for n in manifest:
  if n.startswith(('raw/','normal/','source/'))or n=='analysis.json':
   q=out/'captured'/n;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(t.extractfile(names[n]).read())
analysis=json.loads((out/'captured/analysis.json').read_text());assert analysis['complete_cases']==4 and analysis['rows']==64 and analysis['code_words']==312
elf=Elf(out/'captured/normal/iophase.elf');assert sha(elf.path)=='fcefbb2b78fc3aa53adf43523e91b97c0643bd6dbbe6047a6f1449cb3649c9a2'
assert elf.sym('code')==0x01ff8020 and elf.sym('ctx')==0x02ff0000
config=analysis['context']['initial'];keys=['ctrl','dc','ic','wb','dp','ip','dtcm','itcm']+['region'+str(i)for i in range(8)];cp=[config[k]for k in keys]
assert cp==[0x5507d,0x42,0x42,2,0x06330033,0x66600060,0x02ff000a,0x20,0x04000033,0x0200002b,0,0,0x02ff001f,0x01ff801d,0xffff001d,0x17]
rows=[];bodies=[];maps=[]
for case in range(4):
 root=out/'captured/raw';code=list(csv.DictReader((root/f'case{case}.code.csv').open()));w,first,last=expected_code(case%2,case//2)
 assert [int(x['word'],0)for x in code]==w and len(w)<=80
 blob=struct.pack('<'+'I'*len(w),*w);(out/f'case{case}.bin').write_bytes(blob);bodies.append(w+[0]*(80-len(w)))
 raw=list(csv.DictReader((root/f'case{case}.trials.csv').open()));regs=list(csv.DictReader((root/f'case{case}.registers.csv').open()));assert len(raw)==16 and len(regs)==32
 for rep,row in enumerate(raw):
  assert int(row['case'])==case and int(row['rep'])==rep
  pair=[x for x in regs if int(x['rep'])==rep];assert[x['tag']for x in pair]==['before','restored'];rk=['tm2cnt','tm2val','dispcnt','bg0cnt','dispstat_stable']
  rows.append([int(row['r'+str(i)],0)for i in range(4)]+[int(row['cpsr'],0)]+[int(x[k],0)for x in pair for k in rk])
 access=[]
 for index,word in enumerate(w):
  if first<=index<last and word in [0xe1d400b0,0xe1d410b0,0xe1c450b2,0xe1d420b0,0xe1d430b0]:access.append(dict(pc=0x01ff8020+index*4,word=word,kind='write-stop'if word==0xe1c450b2 else'read-count',address=0x0400010a if word==0xe1c450b2 else 0x04000108))
 assert len(access)==5
 maps.append(dict(case=case,prefix=case%2,gap=case//2,entry=0x01ff8020,words=len(w),bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest(),fnv=fnv(blob),leaf_first=0x01ff8020+4*first,leaf_end=0x01ff8020+4*last,accesses=access))
fmt=lambda a:'{'+','.join('0x%xu'%x for x in a)+'}'
text='#include "protocol.h"\nconst u32 kernel_words[4]={77,78,78,79};\nconst u32 kernels[4][80]={' + ','.join(fmt(w)for w in bodies)+'};\nconst u32 expected_cp15[16]='+fmt(cp)+';\nconst struct Expected expected[64]={'+','.join('{'+fmt(r[:4])+',0x%xu,'%r[4]+fmt(r[5:10])+','+fmt(r[10:15])+'}'for r in rows)+'};\n'
(out/'tables.c').write_text(text)
(out/'arm7.S').write_text('.arm\n.global _start\n_start:\nmsr cpsr_c,#0xdf\nldr r0,=0x04000208\nmov r1,#0\nstr r1,[r0]\n1:b 1b\n')
# Copy the immutable sources into a private job root; compiler inputs are
# concrete/reviewable without executing any compiler or native model.
for name in ['boot.S','invoke.S','driver.c','protocol.h','adapter.ld','witness.svh','check.py','check_witness.py','Makefile']:
 q=Path(__file__).parent/name;assert q.exists();(out/name).write_bytes(q.read_bytes())
(out/'input-map.json').write_text(json.dumps(dict(cases=maps,expected_context_rows=rows,cp15=cp,source_evidence_sha256=SHA,captured_code_words=312,expected_native_delta_vector=[[4,5]]*4,expected_samples=64,record_layout={'DTCM_base':0x02ff0100,'MAIN_dump':0x023d0000,'bytes':6976,'header_words':16,'case_context_words':128,'trial_words':20,'trials':64,'live_code_words':320},limits=['Minimal caller/idle ARM7 replace Calico. DS stack/subdisplay/background not captured.','Saved full CPSR precedes original memset; only IRQ/mode control is a measured leaf constraint.','Absolute TM2 counts are retained and reported, not normalized or made an interval acceptance margin.','No new store wait, original instruction changed or timing parameter fitted.']),indent=2)+'\n')
(out/'prepared.json').write_text(json.dumps(dict(status='SOURCE/INPUT READY ONLY: NOT COMPILED, NOT HOST/RTL QUALIFIED',source_sha256={n:sha(out/n)for n in ['boot.S','invoke.S','driver.c','protocol.h','adapter.ld','witness.svh','check.py','check_witness.py','Makefile','tables.c','arm7.S']},input_map_sha256=sha(out/'input-map.json'),ELF_sha256=sha(elf.path),queued='Compiler, positive/negative fixtures and any necessary native execution await explicit coordinator worker lease.'),indent=2)+'\n');print('SOURCE/INPUT READY312 words,64 original contexts,full4case vector; NO BUILD/RUN')
