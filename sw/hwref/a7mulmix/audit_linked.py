#!/usr/bin/env python3
"""Pin the reviewed SDK helper, Thumb arguments and wrapper call boundary."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,struct,tarfile
S=Path(__file__).resolve().parent;R=S.parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path);a=p.parse_args();D=a.run.resolve();sdk=D/'sdk'
spec=importlib.util.spec_from_file_location('mix_sdk_checker',S/'check.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
sha=lambda b:hashlib.sha256(b).hexdigest();layout=json.loads((D/'layout.json').read_text())
assert c.sdk(sdk/'a7mulmix7.elf',sdk/'a7mulmix.elf',sdk/'build-id.h')==layout
# Reuse the exact already-qualified ITCM helper, including initialized code.
prior=R/'docs/results/a7mulphase-completion-20261102';q=json.loads((prior/'qualification.json').read_text());b=(prior/'evidence.tar.gz').read_bytes();assert sha(b)==q['archive']['sha256']
with tarfile.open(prior/'evidence.tar.gz')as t:old=json.load(t.extractfile('layout.json'))
assert layout['helper']==old['helper']
h=c.elf.elf_symbol(sdk/'a7mulmix.elf','mm_quiet');words=struct.unpack('<64I',h['body'])
assert words[0]==0xe92d4010 and words[1:4]==(0xe10fc000,0xe38c3080,0xe121f003)
assert words[-2:]==(0x04000100,2*33513982)
# Every in-function branch stays in ITCM; no external BL or BLX occurs.
branches=[]
for i,w in enumerate(words[:-2]):
 if(w>>25)&7==5:
  assert not(w&(1<<24));off=w&0xffffff;off=off-(1<<24)if off&(1<<23)else off;target=h['address']+4*i+8+4*off
  assert h['address']<=target<h['address']+h['size'];branches.append(target)
def thumb_halfwords(name,offset,count):
 fn=c.elf.elf_symbol(sdk/'a7mulmix7.elf',name);return struct.unpack_from('<'+'H'*count,fn['body'],offset)
measure=c.elf.elf_symbol(sdk/'a7mulmix7.elf','measure');base=measure['address']&~1;body=measure['body']
assert 0x03800000<=base<base+measure['size']<=0x0380f000
# Reviewed exact compiler output. Changed compiler/control flow requires a
# new audit, not a silent address-normalized match of an arbitrary caller.
assert thumb_halfwords('measure',0x15a,6)==(0x9b04,0x2101,0x9300,0x9a03,0xab0c,0x9805)
assert thumb_halfwords('measure',0x18a,7)==(0x9b04,0x4659,0x9300,0x9a03,0x003b,0x9805,0x9509)
calls=[]
for off in [0x166,0x198]:
 first,second=struct.unpack_from('<HH',body,off);assert first&0xf800==0xf000 and second&0xf800==0xf800
 high=first&0x7ff;high=high-0x800 if high&0x400 else high;target=base+off+4+(high<<12)+((second&0x7ff)<<1);calls.append(dict(pc=base+off,target=target))
assert calls[0]['target']==calls[1]['target']
veneer=c.elf.elf_symbol(sdk/'a7mulmix7.elf','__mm_invoke_from_thumb');assert veneer['address']&~1==calls[0]['target']
assert struct.unpack_from('<HH',veneer['body'])==(0x4778,0xe7fd)
branch=struct.unpack_from('<I',veneer['body'],4)[0];assert branch>>24==0xea;off=branch&0xffffff;off=off-(1<<24)if off&0x800000 else off
assert(veneer['address']&~1)+12+4*off==layout['wrapper']['entry']
# SP frame20+16+308 preserves 8B alignment; warm/timed snapshots are at
# private-SP+48/+176. Entry/Rs2/Rs6 are cached at SP+20/+12/+16 before timing.
assert thumb_halfwords('measure',0,2)==(0xb5f0,0x46de)
assert 0xb5e0 in thumb_halfwords('measure',0,16)and 0xb0cd in thumb_halfwords('measure',0,16)
faults=[]
bad=bytearray(h['body']);struct.pack_into('<I',bad,len(bad)-8,0x02000000)
assert sha(bad)!=old['helper']['SHA256'];faults.append('actual helper I/O-base literal changed to MAIN rejected by qualified-helper equality')
bad=bytearray(c.elf.elf_symbol(sdk/'a7mulmix7.elf','mm_invoke')['body']);struct.pack_into('<I',bad,20,0xe59d6024)
try:c.wrapper_code(bytes(bad))
except ValueError:faults.append('actual linked fifth-argument stack offset mutation rejected')
else:raise AssertionError('wrapper offset mutation survived')
out=dict(PASS=True,arm7_ELF_SHA256=layout['arm7_elf_SHA256'],arm9_ELF_SHA256=layout['arm9_elf_SHA256'],
 prior_helper_archive_SHA256=q['archive']['sha256'],helper_exact_previous=True,helper_SHA256=sha(h['body']),helper_branches=branches,
 helper_review='IRQ mask/restoration; PC literals in ITCM; r2/r3 I/O-base4000100 only between GO/DONE; r4 timeout03fec3fc is numeric and never dereferenced; prologue/epilogue stack outside GO/DONE; no outside calls',
 paired_calls=calls,measure_SHA256=sha(body),measure_entry=base,veneer_SHA256=sha(veneer['body']),
 call_review='Warm/timed call r0=entry SP+20,r2=rs2 SP+12,arg5=rs6 SP+16 stored SP+0,r3=private-SP+48/+176; n=1 or loop4/16. Thumb-to-ARM veneer preserves SP/args/LR; wrapper push40 reads arg5 atSP+40 before snapshot. Timing uses I/O/private stack; shared result writes/checksums follow stop.',
 stack_frame_bytes=344,wrapper_exact_100B=True,actual_byte_faults_caught=faults,scope='Linked source/dataflow audit plus prior helper equality; actual new runtime completion still required; no DS timing law')
(D/'linked-audit.json').write_text(json.dumps(out,indent=2)+'\n');print('PASS linked helper, paired argument/call path, stack/ABI and actual-byte fault controls')
