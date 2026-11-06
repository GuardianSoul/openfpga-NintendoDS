#!/usr/bin/env python3
"""Verify exact DS42 code/context/function and report unadjusted native timings."""
from pathlib import Path
import argparse,hashlib,json,re,struct
MAGIC=0x3754484d;INITIAL=0x6ac3f19d;VALUE=0x13579bdf
NAMES=['alu','branch','ldr_sp','str_sp','ldr_pc','str_reg','ldrh','strh','stm1']
def fnv(b):
 h=2166136261
 for x in b:h=((h^x)*16777619)&0xffffffff
 return h
def scratch(i,n):
 a=[INITIAL]*1024
 if i==8:a[:64*n]=[VALUE]*(64*n)
 if i in[3,5]:a[0]=VALUE
 if i==7:a[0]=(INITIAL&0xffff0000)|(VALUE&65535)
 return struct.pack('<1024I',*a)
def expected(i,n):return 18+64*n if i==0 else INITIAL if i==2 else VALUE if i==4 else INITIAL&65535 if i==6 else 18
def check(base,dump):
 ram=dump.read_bytes();assert len(ram)==4*1024*1024
 status=struct.unpack_from('<13I',ram,0x230000);assert status[:3]==(MAGIC,9,0)and not any(status[4:])
 cp15=[0x5507d,0x02ff000a,0x20,0x42,0x42,2,0x06330033,0x66600060,0x04000033,0x0200002b,0,0,0x02ff001f,0x01ff801d,0xffff001d,0x17]
 for i in range(9):assert struct.unpack_from('<32I',ram,0x231000+i*128)==tuple(cp15*2),('ARM9 context',i)
 helper=(base/'inputs/helper.bin').read_bytes();assert ram[0x220000:0x220000+2128]==ram[0x221000:0x221000+2128]==helper
 rows=[]
 for i,name in enumerate(NAMES):
  raw=ram[i*0x1800+0x200000:i*0x1800+0x200000+5312];a=struct.unpack('<1328I',raw);ds=struct.unpack('<1328I',(base/'inputs'/f'DS-case{i}.bin').read_bytes());code=(base/'inputs'/f'k{i}.bin').read_bytes()
  assert a[:4]==(MAGIC,1,i,0)and a[4:16]==ds[4:16],('header/code/context',i)
  assert raw[704:704+len(code)]==code and not any(raw[704+len(code):1216])
  assert a[8]==a[9]==fnv(code)
  ticks=[];dticks=[];cpsr=[]
  for j in range(10):
   v=a[16+j*16:32+j*16];d=ds[16+j*16:32+j*16];n=4 if j%2==0 else 16
   assert v[0]==n and v[2:4]==(expected(i,1),expected(i,n))and v[15]==0,('output',i,j)
   assert v[4]==fnv(scratch(i,n))and v[5:7]==(0x0380fd88,0x0380fd88)and v[7]&0x80,('scratch/SP/IRQ',i,j)
   assert v[8:15]==d[8:15],('register signature',i,j)
   ticks.append(v[1]);dticks.append(d[1]);cpsr.append(dict(native=hex(v[7]),DS=hex(d[7])))
  assert raw[1216:]==scratch(i,16),('full scratch',i)
  slopes=[(ticks[2*r+1]-ticks[2*r])/768 for r in range(5)];ds_slopes=[(dticks[2*r+1]-dticks[2*r])/768 for r in range(5)]
  rows.append(dict(case=name,native_ticks=ticks,DS_ticks=dticks,native_paired_slopes=slopes,DS_paired_slopes=ds_slopes,slope_exact=slopes==ds_slopes,CPSR=cpsr))
 return dict(source=json.loads((base/'build.json').read_text())['source'],functional_PASS=True,groups=9,samples=90,register_signatures=630,full_scratch_images=9,ARM9_context_snapshots=18,helper_before_after_exact=True,rows=rows,all_paired_slopes_exact=all(r['slope_exact']for r in rows),timing_scope='Raw original loops/bookkeeping preserved. Minimal SDK replacement/time/invoke wrapper explicit; no alignment, offset or generic charge fit.')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('base',type=Path);p.add_argument('dump',type=Path);p.add_argument('--out',type=Path,required=True);a=p.parse_args();r=check(a.base,a.dump);a.out.write_text(json.dumps(r,indent=2)+'\n');print('DS42 NATIVE',r['groups'],r['samples'],r['register_signatures'],'function/context PASS; paired slopes exact',r['all_paired_slopes_exact'])
