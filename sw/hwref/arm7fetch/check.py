#!/usr/bin/env python3
"""Check linked ARMv4T layout and untimed instruction semantics, not DS timing."""
from pathlib import Path
import argparse,hashlib,json,struct

def elf_text_symbols(path):
 b=path.read_bytes();h=struct.unpack_from('<16sHHIIIIIHHHHHH',b)
 assert h[0][:6]==b'\x7fELF\x01\x01' and h[2]==40,'ELF32 little-endian ARM required'
 s=[struct.unpack_from('<10I',b,h[6]+i*h[11]) for i in range(h[12])]
 def blob(sh):return b[sh[4]:sh[4]+sh[5]]
 def string(data,n):return data[n:data.index(b'\0',n)].decode()
 names=blob(s[h[13]]);text=next(sh for sh in s if string(names,sh[0])=='.text')
 syms={}
 for sh in s:
  if sh[1]!=2:continue
  strings=blob(s[sh[6]])
  for off in range(sh[4],sh[4]+sh[5],sh[9]):
   n,v,size,info,other,idx=struct.unpack_from('<IIIBBH',b,off)
   if n:syms[string(strings,n)]=v
 return text[3],blob(text),syms

def execute(words,base,loops):
 reg=[0x18273645+i for i in range(16)];saved=reg[4:12];reg[0]=loops;reg[14]=0x01010101
 pc=base;z=False;count={'ADD':0,'SUBS':0,'B':0,'BNE':0}
 for step in range(100000):
  assert pc%4==0 and base<=pc<base+len(words)*4,'branch left kernel'
  ins=words[(pc-base)//4];cond=ins>>28;assert cond in (14,1),'unexpected condition'
  if ins&0x0e000000==0x0a000000:
   count['B' if cond==14 else 'BNE']+=1
   taken=cond==14 or not z;v=ins&0xffffff;v=v if v<0x800000 else v-0x1000000
   pc=pc+8+v*4 if taken else pc+4;continue
  assert cond==14,'conditional non-branch'
  if ins&0x0ffffff0==0x012fff10:
   assert ins&15==14 and reg[14]==0x01010101
   assert reg[4:12]==saved,'callee-saved register changed'
   return reg[0],reg[3],count
  assert ins&0x0c000000==0,'unexpected opcode'
  op=(ins>>21)&15;rn=(ins>>16)&15;rd=(ins>>12)&15;assert rd<15
  if ins&(1<<25):
   v=ins&255;rot=((ins>>8)&15)*2;v=((v>>rot)|(v<<(32-rot)))&0xffffffff if rot else v
  else:
   assert ins&0x70==0,'unexpected register shifter';v=(reg[ins&15]<<((ins>>7)&31))&0xffffffff
  if op==13:value=v
  elif op==4:value=(reg[rn]+v)&0xffffffff;count['ADD']+=1
  elif op==2:value=(reg[rn]-v)&0xffffffff;count['SUBS']+=1
  else:raise AssertionError('unexpected data opcode')
  reg[rd]=value
  if ins&(1<<20):z=value==0
  pc+=4
 raise AssertionError('kernel failed to return')

def validate(case,words,base,body_offset):
 assert (base+body_offset)%16==case['offset'],'wrong first-op offset'
 if case['kind']=='alu':assert words[body_offset//4:body_offset//4+64]==[0xe0800001]*64,'64ADD body'
 if case['kind']=='branch':
  for j in range(64):
   i=body_offset//4+j*case['stride']//4;w=words[i];assert w>>24==0xea,'64B body'
   d=w&0xffffff;d=d if d<0x800000 else d-0x1000000
   assert i*4+8+4*d==body_offset+(j+1)*case['stride'],'wrong stride target'
 for n in [1,4,16]:
  value,counter,c=execute(words,base,n);assert value==case['checksum']*n and counter==0,'checksum/loop count'
  trips=64*n if case['kind']=='ring' else n
  assert c['SUBS']==trips and c['BNE']==trips,'bookkeeping count'
  assert c['ADD']==(64*n if case['kind'] in ['alu','ring'] else 0),'ADD count'
  assert c['B']==(64*n if case['kind']=='branch' else (case['nodes']-1)*64*n if case['kind']=='ring' else 0),'branch count'

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('elf',type=Path);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
 r=Path(__file__).resolve().parent;cases=json.loads((r/'cases.json').read_text());addr,data,syms=elf_text_symbols(a.elf);report=[];faults=[]
 for c in cases:
  start,body,end=(syms[c[k]] for k in ['symbol','body_symbol','end_symbol']);assert start%32==0 and 0<end-start<=4096
  b=data[start-addr:end-addr];w=list(struct.unpack('<'+'I'*(len(b)//4),b));offset=body-start
  validate(c,w,start,offset);validate(c,w,0x02340000+c['id']*4096,offset)
  if c['kind'] in ['alu','branch']:
   bad=w.copy();bad[offset//4]=0xe1a00000
   try:validate(c,bad,start,offset)
   except AssertionError:pass
   else:raise AssertionError('NOP mutation survived')
   faults.append(c['name'])
  report.append(dict(case=c['name'],id=c['id'],WRAM_entry=hex(start),body=hex(body),end=hex(end),body_offset=offset,size=end-start,bytes_sha256=hashlib.sha256(b).hexdigest(),checks='loops1/4/16 checksum, branch graph/count and callee-saved exact at linkedWRAM and relocatedMAIN'))
 a.out.write_text(json.dumps(dict(ELF_sha256=hashlib.sha256(a.elf.read_bytes()).hexdigest(),cases=report,mutations_caught=faults,scope='compiled ISA/layout only; no measured DS timings, cache/prefetch model or NDS envelope'),indent=2)+'\n')
 print('PASS18 linked/relocated kernels,108 checksum/count executions,16 actual-code NOP mutations; no DS timing claim')
