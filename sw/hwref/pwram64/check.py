#!/usr/bin/env python3
"""Portable exact-output checker. Census timing is never a DS measurement."""
import argparse,csv,hashlib,json,struct
from pathlib import Path
BASE=0x03800000;COUNTS=[1,8,64,256,1024,2048,16384,8,9,16,256,2048,16384]
SEED=0x6d2b79f5
SIZE=68928;CODE=1024;IMAGE=3392;MASK=0xffffffff
SHA=lambda b:hashlib.sha256(b).hexdigest()
def need(ok,msg):
 if not ok:raise ValueError(msg)
def fnv(data):
 h=2166136261
 for x in data:h=((h^x)*16777619)&MASK
 return h
def ror(x):return (x>>1)|((x&1)<<31)
def graph(n):
 order=list(range(n));seed=SEED
 for i in range(n,1,-1):
  seed=(seed*1664525+1013904223)&MASK;j=seed%i;order[i-1],order[j]=order[j],order[i-1]
 out=[0]*n
 for i in range(n):out[order[i]]=order[(i+1)%n]
 return out
def expected_image(k,before=False):
 words=[0x5a5a0000^i for i in range(16384)]
 if k<6:
  n=COUNTS[k];next=graph(n)
  for i in range(n):words[i*8+7]=BASE+next[i]*32+28
 elif not before:
  if k==6:words[0]=0x12341234
  else:
   for j in range(COUNTS[k]):words[(j%2048)*8+j//2048]=0x12341234
 return struct.pack('<16384I',*words)
def group(data,k,layout):
 need(len(data)==SIZE,f'k{k}: result size')
 h=struct.unpack_from('<32I',data);nodes=COUNTS[k]if k<6 else 0;stores=0 if k<6 else COUNTS[k]
 need(h[:8]==(0x50575231,1,k,0,nodes,stores,int(k==6),SEED if nodes else 0),f'k{k}: identity/error')
 need(h[8:18]==tuple(layout['header_addresses']),f'k{k}: linked stack/code addresses')
 need(h[18]==h[19]and h[28]==1 and h[29]==SIZE,f'k{k}: full private restore')
 need(h[21:24]==(BASE,layout['image'],16384),f'k{k}: DMA span')
 need(h[24]==0 and h[30]==len(bytes.fromhex(layout['kernel_hex']))and h[31]==0,f'k{k}: header fields')
 pre,post=expected_image(k,True),expected_image(k)
 prehash,posthash=fnv(pre),fnv(post)
 need(h[20]==prehash,f'k{k}: preimage scan')
 need(data[IMAGE:]==post,f'k{k}: full DMA image')
 need(data[1216:1216+CODE]==bytes.fromhex(layout['kernel_hex']).ljust(CODE,b'\0')and data[2240:2240+CODE]==data[1216:2240],f'k{k}: frozen live kernel')
 for off in [128,192]:
  c=struct.unpack_from('<16I',data,off)
  need(c[0]&0xc0==0xc0 and h[8]<=c[1]<h[9]and c[1]%8==0 and c[6]==3 and c[8]==0x80 and c[10]==0x84 and c[11]<263 and c[12]==0 and c[13]&15==1,f'k{k}: IRQ/shared-stack/timer/context')
 rows=[]
 for rep in range(5):
  for phase in range(3):
   s=struct.unpack_from('<16I',data,256+(rep*3+phase)*64);n=(1 if phase==0 else nodes*(4 if phase==2 else 1))if nodes else (16384 if phase==2 else stores)
   need(s[0]==n and s[3]==(s[2]-s[1])&MASK and 0<s[3]<=67027964 and s[5]==prehash and s[6]==posthash and s[7]<263 and s[8]<263 and s[10]==(phase if nodes else 3+phase)and not any(s[11:]),f'k{k}: sample{rep}/{phase} endpoints/history')
   value=terminal=0
   if nodes:
    next=graph(nodes)
    terminal=BASE+28
    for _ in range(n):terminal=BASE+next[(terminal-BASE-28)//32]*32+28;value=terminal^ror(value)
   elif phase==0:value=0 if k==6 else (n*32+(n//2048)*4)&65535
   elif phase==1:
    for _ in range(n):value=0x12341234^ror(value)
   need(s[4]==value and s[9]==terminal,f'k{k}: sample{rep}/{phase} exact result')
   rows.append(dict(case_id=k,rep=rep,phase=phase,operations=n,start=s[1],end=s[2],ticks=s[3],value=value,terminal=terminal,start_line=s[7],end_line=s[8]))
 cap=struct.unpack_from('<64h',data,3264)
 if k==12:need(h[25:28]==(BASE,128,0x86)and cap[8:]==(0x1234,)*56,'sound private-source suffix')
 else:need(h[25:28]==(0,0,0)and not any(cap),f'k{k}: unexpected sound')
 return rows
def analyze(directory,layout,write_csv=None):
 d=Path(directory);need((d/'pwram64_v1_build.txt').read_text()==layout['build_id']+'\n','producer binding')
 comp=dict(x.split('=',1)for x in(d/'pwram64_v1_completion.txt').read_text().splitlines())
 need(comp['status']=='SUCCESS'and comp['complete']=='13'and int(comp['new'])+int(comp['resumed'])==13 and all(comp[x]=='0'for x in ['failed','interrupted']),'completion')
 need((d/'pwram64_v1_progress.txt').read_text()==''.join(f'start k{k:02}\ndone k{k:02}\n'for k in range(13)),'complete ordered journal')
 need(SHA((d/'pwram64_v1_helper_itcm.bin').read_bytes()[32:])==layout['itcm_sha256'],'quiet ITCM bytes')
 setup=dict(csv.reader((d/'pwram64_v1_setup.csv').read_text().splitlines()[1:]));need(int(setup['helper_entry'],16)==layout['helper']and int(setup['wramcnt'],16)==3 and int(setup['result_pointer'],16)==layout['out'],'ARM9 setup')
 rows=[]
 for k in range(13):rows+=group((d/f'pwram64_v1_k{k:02}.bin').read_bytes(),k,layout)
 if write_csv:
  with Path(write_csv).open('w')as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
 return dict(PASS=True,groups=13,raw_windows=len(rows),private_bytes_checked=13*65536,restore_pairs=13,sound_suffix_samples=56,limits='Functional/layout qualification only; no DS timing or backing-drain claim',sha256={p.name:SHA(p.read_bytes())for p in sorted(d.iterdir())if p.is_file()})
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('layout',type=Path);p.add_argument('--csv',type=Path);a=p.parse_args();print(json.dumps(analyze(a.directory,json.loads(a.layout.read_text()),a.csv),indent=2))
