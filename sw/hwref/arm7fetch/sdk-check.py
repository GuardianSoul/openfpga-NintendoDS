#!/usr/bin/env python3
"""Qualify the SDK-linked kernels/helper, using CPU's unchanged ISA checker."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
def elf_symbol(path,name):
 b=path.read_bytes();h=struct.unpack_from('<16sHHIIIIIHHHHHH',b)
 assert h[0][:6]==b'\x7fELF\x01\x01' and h[2]==40
 sections=[struct.unpack_from('<10I',b,h[6]+i*h[11]) for i in range(h[12])]
 for section in sections:
  if section[1]!=2:continue
  strings=sections[section[6]];names=b[strings[4]:strings[4]+strings[5]]
  for at in range(section[4],section[4]+section[5],section[9]):
   n,address,size,_,_,idx=struct.unpack_from('<IIIBBH',b,at)
   if names[n:].split(b'\0',1)[0].decode()!=name:continue
   data=b''
   if size and idx<len(sections):
    sh=sections[idx];start=sh[4]+(address&~1)-sh[3];data=b[start:start+size]
   return dict(address=address,size=size,body=data)
 raise ValueError('missing symbol '+name)
s=importlib.util.spec_from_file_location('cpu_kernel_checks',Path(__file__).with_name('check.py'))
cpu=importlib.util.module_from_spec(s);s.loader.exec_module(cpu)
sha=lambda b:hashlib.sha256(b).hexdigest()

def named_section(path,name):
 b=path.read_bytes();h=struct.unpack_from('<16sHHIIIIIHHHHHH',b)
 sections=[struct.unpack_from('<10I',b,h[6]+i*h[11]) for i in range(h[12])]
 sh=sections[h[13]];names=b[sh[4]:sh[4]+sh[5]]
 for sh in sections:
  if names[sh[0]:].split(b'\0',1)[0].decode()==name:return sh[3],sh[5]
 raise ValueError('missing section '+name)


def allocated_image(path,base,size):
 b=path.read_bytes();h=struct.unpack_from('<16sHHIIIIIHHHHHH',b)
 image=bytearray(size);covered=bytearray(size)
 for i in range(h[12]):
  sh=struct.unpack_from('<10I',b,h[6]+i*h[11])
  if sh[1]!=1 or not sh[2]&2:continue
  lo,hi=max(base,sh[3]),min(base+size,sh[3]+sh[5])
  if lo<hi:
   at=sh[4]+lo-sh[3];image[lo-base:hi-base]=b[at:at+hi-lo];covered[lo-base:hi-base]=b'\1'*(hi-lo)
 assert all(covered),'unmapped ITCM initialization byte'
 return bytes(image)


def check(a7,a9):
 cases=json.loads(Path(__file__).with_name('cases.json').read_text())
 main=elf_symbol(a7,'af_main_copy');assert main['address']%4096==0 and main['size']==18*4096 and main['address']>>24==2
 report=[]
 for c in cases:
  k=elf_symbol(a7,c['symbol']);body=elf_symbol(a7,c['body_symbol'])['address'];end=elf_symbol(a7,c['end_symbol'])['address']
  start=k['address'];assert start%32==0 and 0x03800000<=start<end<=0x0380f000
  data=k['body'];assert len(data)==end-start<=4096 and len(data)%4==0
  words=list(struct.unpack('<'+'I'*(len(data)//4),data));offset=body-start;dst=main['address']+c['id']*4096
  cpu.validate(c,words,start,offset);cpu.validate(c,words,dst,offset)
  if c['kind'] in ['alu','branch']:
   bad=words.copy();bad[offset//4]=0xe1a00000
   try:cpu.validate(c,bad,start,offset)
   except AssertionError:pass
   else:raise AssertionError('actual kernel NOP mutation survived')
  fnv=2166136261
  for b in data:fnv=((fnv^b)*16777619)&0xffffffff
  report.append(dict(case=c['name'],id=c['id'],source_entry=start,source_body=body,source_end=end,size=len(data),main_entry=dst,
                     main_body=dst+offset,code_sha256=sha(data),code_fnv=fnv,checks='CPU ISA/layout loops1/4/16 at linkedWRAM and actual MAIN slot'))
 quiet=elf_symbol(a9,'af_quiet');base=elf_symbol(a9,'__itcm_start')['address'];end=elf_symbol(a9,'__itcm_end')['address']
 init_base,init_bytes=named_section(a9,'.itcm')
 assert 0x01ff8000<=base<=quiet['address']<quiet['address']+quiet['size']<=end<=0x02000000
 return dict(arm7_elf_sha256=sha(a7.read_bytes()),arm9_elf_sha256=sha(a9.read_bytes()),cases=report,
             helper=dict(entry=quiet['address'],bytes=quiet['size'],sha256=sha(quiet['body']),itcm_base=base,itcm_bytes=end-base,
                         initialized_base=init_base,initialized_bytes=init_bytes,initialized_sha256=sha(allocated_image(a9,init_base,init_bytes)),
                         vectors_scope='Runtime-initialized NOBITS vectors retained as observation, not compared to nonexistent ELF bytes',
                         disassembly_review='required: no MAIN access between GO and DONE; IRQ-masked ITCM code with I/O polls'),
             checksum_count_executions=108,actual_kernel_mutations_caught=16,scope='Software/layout qualification only; no DS timing or N/S model')

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--arm7',type=Path,required=True);p.add_argument('--arm9',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 a.out.write_text(json.dumps(check(a.arm7,a.arm9),indent=2)+'\n');print('PASS18 SDK-linked/relocated PIC kernels;108 semantics executions;16 actual NOP mutations')
