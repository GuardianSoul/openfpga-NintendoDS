#!/usr/bin/env python3
"""Independent input, linked-instruction, raw result and journal checks; no DS timing target."""
from pathlib import Path
import argparse,csv,hashlib,json,re,struct
NAMES=['alu','branch','ldr_sp','str_sp','ldr_pc','str_reg','ldrh','strh','stm1','timer_bank']
MAGIC=0x3754484d;INITIAL=0x6ac3f19d;VALUE=0x13579bdf
SOURCE=['protocol.h','arm7.c','kernels.S','timer.S','main.c','quiet.itcm.c','Makefile','../common/hwref.c','../common/hwref.h','../Makefile','../wramarb/linker.py']
def require(ok,why):
 if not ok:raise AssertionError(why)
def fnv(data):
 h=2166136261
 for b in data:h=((h^b)*16777619)&0xffffffff
 return h
def words(data):return struct.unpack('<'+'I'*(len(data)//4),data)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
class Elf:
 def __init__(self,path):
  self.path=Path(path);self.data=self.path.read_bytes();d=self.data
  require(d[:6]==b'\x7fELF\x01\x01','ELF32 LE required')
  h=struct.unpack_from('<16sHHIIIIIHHHHHH',d);require(h[2]==40,'ARM ELF required')
  self.segments=[struct.unpack_from('<8I',d,h[5]+i*h[9])for i in range(h[10])]
  self.sections=[struct.unpack_from('<10I',d,h[6]+i*h[11])for i in range(h[12])]
  self.symbols={}
  for s in self.sections:
   if s[1]!=2:continue
   strings=self.sections[s[6]];strings=d[strings[4]:strings[4]+strings[5]]
   for p in range(s[4],s[4]+s[5],s[9]):
    name,value,size,info,other,index=struct.unpack_from('<IIIBBH',d,p)
    name=strings[name:strings.find(b'\0',name)].decode()
    if name:self.symbols[name]=(value,size,info,index)
 def sym(self,name):require(name in self.symbols,'missing linked symbol '+name);return self.symbols[name][0]
 def read(self,address,size):
  for s in self.sections:
   if s[1]!=8 and s[2]&2 and s[3]<=address and address+size<=s[3]+s[5]:return self.data[s[4]+address-s[3]:s[4]+address-s[3]+size]
  for p in self.segments:
   if p[0]==1 and p[2]<=address and address+size<=p[2]+p[5]:
    load=self.data[p[1]:p[1]+p[4]]+bytes(p[5]-p[4]);return load[address-p[2]:address-p[2]+size]
  raise AssertionError(f'ELF address not backed by one load section: {address:08x}+{size:x}')
def static(elf7,elf9):
 e=Elf(elf7);report={};descriptors=[]
 opcodes={'alu':0x3001,'ldr_sp':0x9800,'str_sp':0x9200,'str_reg':0x50f2,'ldrh':0x5af0,'strh':0x52f2,'stm1':0xc604}
 for name in NAMES[:9]:
  entry=e.sym('at_'+name);start=entry&~1;body=e.sym('at_'+name+'_body');endbody=e.sym('at_'+name+'_body_end');end=e.sym('at_'+name+'_end');literal=e.sym('at_'+name+'_literal')
  require(entry&1 and not(start&31) and not(body&3),'Thumb entry/body alignment '+name)
  require(0x03800000<=start<body<endbody<end<=0x0380f000 and end-start<=512,'private WRAM bounds '+name)
  blob=e.read(start,end-start);bodybytes=e.read(body,endbody-body);half=struct.unpack('<'+'H'*(len(bodybytes)//2),bodybytes)
  if name=='branch':require(half==(0xe000,0x46c0)*64,'64 taken Thumb branches with skipped independent padding')
  elif name=='ldr_pc':
   require(len(half)==64,'64 Thumb literal loads')
   for i,h in enumerate(half):require(h&0xff00==0x4800 and ((body+2*i+4)&~3)+(h&255)*4==literal,'linked PC-relative load target')
  else:require(half==(opcodes[name],)*64,'actual linked 64 opcodes '+name)
  require(words(e.read(literal,4))==(VALUE,),'literal input identity '+name)
  require(blob[:2]==b'\xf0\xb5','20-byte callee-save prologue '+name)
  require(e.read(endbody,6)==b'\x01\x3d\x00\xd0'+e.read(endbody+4,2),'common SUBS/BEQ/B loop')
  h=struct.unpack('<H',e.read(endbody+4,2))[0];delta=(h&0x7ff)*2
  if delta&0x800:delta-=0x1000
  require(h&0xf800==0xe000 and endbody+8+delta==body,'actual backedge target '+name)
  descriptors.append((entry,body,end,fnv(blob)));report[name]=dict(entry=f'{entry:08x}',body=f'{body:08x}',end=f'{end:08x}',bytes=len(blob),fnv=f'{fnv(blob):08x}',sha256=hashlib.sha256(blob).hexdigest(),ops=64)
 entry=e.sym('at_timer');end=e.sym('at_timer_end');require(not(entry&31) and 0x03800000<=entry<end<=0x0380f000 and end-entry<=1024,'ARM7 timer leaf private WRAM')
 blob=e.read(entry,end-entry)
 for w in words(blob[:-12]):require(w&0x0f000000!=0x0b000000,'timer leaf must not call external code')
 require(words(blob[-12:])==(0x04000100,0x0000ffff,32768),'timer anchor/literal/timeout identity')
 descriptors.append((entry,entry,end,fnv(blob)));report['timer_bank']=dict(entry=f'{entry:08x}',end=f'{end:08x}',bytes=len(blob),fnv=f'{fnv(blob):08x}',sha256=hashlib.sha256(blob).hexdigest())
 e9=Elf(elf9);base=e9.sym('__itcm_start');end=e9.sym('__itcm_end')
 # Calico links the vector32 bytes at0, then the remainder at01ff8020.
 # They are aliases of the same physical32KiB ITCM captured from01ff8000.
 require(base==0x01ff8000,'SDK ITCM alias layout')
 helper=e9.read(0,32)+e9.read(base+32,end-base-32)
 require(0<len(helper)<=32768 and base<=e9.sym('at_quiet')<end,'ARM9 quiet helper ITCM placement')
 report['helper']=dict(entry=f'{e9.sym("at_quiet"):08x}',base=f'{base:08x}',bytes=len(helper),fnv=f'{fnv(helper):08x}')
 return e,e9,descriptors,helper,report
def states(root):
 state=[0]*10;p=root/'progress.txt'
 if not p.exists():return state
 data=p.read_bytes();require(not data or data.endswith(b'\n'),'journal truncated line')
 for line in data.decode().splitlines():
  m=re.fullmatch(r'(start|done) ([0-9]+)',line);require(m is not None,'journal malformed')
  verb,si=m.groups();i=int(si);require(i<10,'journal case range')
  require((verb=='start' and state[i]==0)or(verb=='done' and state[i]==1),'journal duplicate/order')
  state[i]=1 if verb=='start' else 2
 return state
def expected_return(i,n):return 0x12+64*n if i==0 else INITIAL if i==2 else VALUE if i==4 else INITIAL&65535 if i==6 else 0x12
def scratch(i,n):
 a=[INITIAL]*1024
 if i==8:a[:64*n]=[VALUE]*(64*n)
 elif i in (3,5):a[0]=VALUE
 elif i==7:a[0]=(INITIAL&0xffff0000)|(VALUE&65535)
 return struct.pack('<1024I',*a)
def check(root,elf7,elf9,source,defines='',complete=True):
 root=Path(root);e,e9,desc,helper,stat=static(elf7,elf9)
 build=hashlib.sha256(b''.join((Path(source)/p).read_bytes()for p in SOURCE)+defines.encode()).hexdigest()
 meta=(root/'metadata.bin').read_bytes();require(len(meta)==224,'metadata ABI size');m=words(meta)
 require(m[:4]==(MAGIC,1,9,0),'metadata identity/error')
 require(m[5]>=0x03800000 and m[6]==m[5]-32 and m[7]==m[5]+4096 and m[7]+32<=0x0380f000,'scratch/guard bounds')
 for i,d in enumerate(desc):require(tuple(m[8+i*4:12+i*4])==d,'metadata linked code identity '+str(i))
 require(m[49:52]==(320,31872,0) and not any(m[52:]),'timer metadata ABI')
 for p,n in [(m[4],5312),(m[48],31872)]:require(p>>24==2 and not(p&31) and (p&0x3fffff)+n<=0x400000,'result pointer bounds')
 require((root/'helper.bin').read_bytes()==helper,'actual ARM9 ITCM snapshot versus linked bytes')
 tag=f'arm7thumb-v1 source={build} cases=10 thumb_reps=5 timer_rows=320\nmeta bytes=224 fnv={fnv(meta):08x} helper entry={e9.sym("at_quiet"):08x} base={e9.sym("__itcm_start"):08x} bytes={len(helper)} fnv={fnv(helper):08x}\n'
 for i,d in enumerate(desc):tag+=f'case{i} {NAMES[i]} entry={d[0]:08x} body={d[1]:08x} end={d[2]:08x} fnv={d[3]:08x}\n'
 require((root/'manifest.txt').read_text()==tag,'source/code/helper manifest identity')
 ss=states(root);timings={};functional=0;timerrows=[]
 for i,s in enumerate(ss):
  if not s:
   require(not list(root.glob(f'case{i}.*')),'untracked case data');continue
  if s==1:continue # retained interrupted files remain unmeasured
  entry,body,end,h=desc[i];code=e.read(entry&~1,end-(entry&~1));require((root/f'case{i}.code.bin').read_bytes()==code,'actual live code bytes '+str(i))
  commit=f'arm7thumb-v1 source={build} case={i} code={h:08x}\n'
  for ext in ['bin','csv','code.bin','info.txt']:
   p=root/f'case{i}.{ext}';b=p.read_bytes();commit+=f'{p.name} {len(b)} {fnv(b):08x}\n'
  require((root/f'case{i}.commit').read_text()==commit,'completed case checksum/provenance '+str(i))
  raw=(root/f'case{i}.bin').read_bytes();a=words(raw);csvrows=list(csv.DictReader((root/f'case{i}.csv').open()))
  require(a[:3]==(MAGIC,1,i),'raw result identity')
  if i<9:
   require(len(raw)==5312 and len(csvrows)==10,'Thumb sample count')
   require(a[4:13]==(entry,body,end,len(code),h,h,m[5],m[6],m[7]) and a[13:16]==(0,0,0),'Thumb header/code '+str(i))
   require(raw[704:704+len(code)]==code and not any(raw[704+len(code):1216]),'raw active-code bytes/padding')
   vals=[]
   for row in range(10):
    v=a[16+16*row:32+16*row];n=16 if row%2 else 4;expected=expected_return(i,n)
    require(v[0]==n and v[2:4]==(expected_return(i,1),expected),'actual warm/timed output fault '+str(i))
    require(v[4]==fnv(scratch(i,n)),'actual scratch input/output fault '+str(i))
    require(v[5]==v[6] and v[5]&3==0 and 0x03800000<=v[5]<0x03810000 and v[7]&0x80,'SP/IRQ context '+str(i))
    require(v[8:15]==(expected,m[5],VALUE,0,v[5]-20,0,m[5]+(64*n*4 if i==8 else 0)),'actual register signature fault '+str(i))
    require(v[15]==0,'producer functional error '+str(i))
    r=csvrows[row];expectedcsv=[i,row//2,n,v[1],*v[2:15],v[15]]
    got=[int(r[k],16 if k in ['warm_return','returned','scratch_fnv','sp_before','sp_after','cpsr','r0','r1','r2','r3','r4','r5','r6']else 10)for k in r]
    require(got==expectedcsv,'CSV/raw mismatch '+str(i));vals.append(v[1]);functional+=7
   require(raw[1216:]==scratch(i,16),'full final scratch image '+str(i))
   require(a[3]==0,'Thumb producer error '+str(i))
   timings[NAMES[i]]=dict(raw_ticks=vals,paired_slopes=[(vals[2*r+1]-vals[2*r])/768 for r in range(5)],unit='ARM7 F/1 ticks per body op, includes common loop overhead; no DS target')
  else:
   require(len(raw)==31872 and len(csvrows)==320,'timer sample count')
   require(a[4:10]==(entry,end,len(code),h,h,320) and a[10:12]==a[14:16] and not any(a[18:32]),'timer header/code/context')
   require(raw[30848:30848+len(code)]==code and not any(raw[30848+len(code):]),'timer active code/padding')
   keys=[(mode,p,delay)for mode in range(3)for p in range(1 if mode else 0,4)for delay in range(32)]
   for row,key in enumerate(keys):
    v=a[32+24*row:56+24*row];mode,p,delay=key
    require(v[:3]==key and v[3]&0x80,'timer row/IRQ identity')
    require(v[17]==0xc0|p and v[18]==(0xc0|p if mode==2 else 0),'timer control identity')
    require(v[16]&0x20 and (mode!=2 or v[16]&0x40),'timer event observation incomplete')
    require(v[20]==v[21] and v[22]==v[23],'actual stopped-timer output fault')
    require(v[19]==0,'timer bounded timeout/function error')
    require([int(x)for x in csvrows[row].values()]==[i,*v],'timer CSV/raw mismatch')
    timerrows.append(dict(mode=mode,prescaler=p,delay=delay,start2=v[4],action=v[6],event2_last_miss=v[12],event2_first_hit=v[13],event3_last_miss=v[14],event3_first_hit=v[15]))
   require(a[3]==0,'timer producer error')
 if complete:require(ss==[2]*10,'incomplete measurement journal')
 return dict(status='PASS input/code/function/context/journal only',states=ss,complete=ss==[2]*10,source_build_id=build,elf7_sha256=sha(elf7),elf9_sha256=sha(elf9),linked=stat,register_values_checked=functional,thumb=timings,timer_rows=len(timerrows),timer_raw_bounds=timerrows,DS_timing_acceptance='NONE: hardware capture pending; ARM9 timer law not assumed on ARM7')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory');p.add_argument('--elf7',required=True);p.add_argument('--elf9',required=True);p.add_argument('--source',default=str(Path(__file__).resolve().parents[2]/'sw/hwref/arm7thumb'));p.add_argument('--defines',default='');p.add_argument('--allow-incomplete',action='store_true');p.add_argument('--out')
 a=p.parse_args();r=check(a.directory,a.elf7,a.elf9,a.source,a.defines,not a.allow_incomplete);s=json.dumps(r,indent=2)+'\n'
 if a.out:Path(a.out).write_text(s)
 else:print(s,end='')
