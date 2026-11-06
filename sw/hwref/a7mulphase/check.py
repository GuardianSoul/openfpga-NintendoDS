#!/usr/bin/env python3
"""Qualify linked/live code and exact sample/state records, never emulator timing."""
from pathlib import Path
import argparse,csv,hashlib,importlib.util,json,re,struct
S=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fetch_sdk_helpers',S.parent/'arm7fetch/sdk-check.py')
elf=importlib.util.module_from_spec(spec);spec.loader.exec_module(elf)
sha=lambda b:hashlib.sha256(b).hexdigest()
RS=[0x7f,0x7fff,0x7fffff,0x7fffffff]
def require(ok,message):
 if not ok:raise ValueError(message)
def fnv(b):
 v=2166136261
 for x in b:v=((v^x)*16777619)&0xffffffff
 return v
def kernel(data):
 require(len(data)==272,'kernel must remain272 bytes')
 w=struct.unpack('<68I',data)
 require(w[0]==0xe3a01003,'multiplicand setup differs')
 require(w[1:65]==(0xe0030291,)*64,'exact64MUL r3,r1,r2 body differs')
 require(w[65:]==(0xe2500001,0x1affffbd,0xe12fff1e),'counter/backedge/return differs')
def sdk(a7,a9,build_header):
 k=elf.elf_symbol(a7,'mp_mul');body=elf.elf_symbol(a7,'mp_mul_body')['address'];end=elf.elf_symbol(a7,'mp_mul_end')['address']
 main=elf.elf_symbol(a7,'mp_main_copy');wrapper=elf.elf_symbol(a7,'mp_invoke');ret=elf.elf_symbol(a7,'mp_return')['address']
 kernel(k['body']);require(k['address']%32==0 and 0x03800000<=k['address']<end<=0x0380f000,'kernel not private WRAM')
 require(body-k['address']==4 and end-k['address']==272,'kernel symbols differ')
 require(main['address']%4096==0 and main['address']>>24==2 and main['size']==4096,'one aligned MAIN slot required')
 require(0x03800000<=wrapper['address']<ret<wrapper['address']+wrapper['size']<=0x0380f000,'wrapper is not private WRAM')
 # Exercise an actual linked opcode mutation, not an altered report flag.
 bad=bytearray(k['body']);struct.pack_into('<I',bad,4,0xe1a00000)
 try:kernel(bytes(bad))
 except ValueError:pass
 else:raise ValueError('actual firstMUL→NOP survived')
 quiet=elf.elf_symbol(a9,'mp_quiet');base=elf.elf_symbol(a9,'__itcm_start')['address'];top=elf.elf_symbol(a9,'__itcm_end')['address']
 ib,isz=elf.named_section(a9,'.itcm')
 require(0x01ff8000<=base<=quiet['address']<quiet['address']+quiet['size']<=top<=0x02000000,'quiet helper outside ITCM')
 match=re.fullmatch(r'#define MP_BUILD_ID "([0-9a-f]{64})"\n',build_header.read_text());require(match is not None,'build ID header malformed')
 return dict(build_id=match[1],result_bytes=4096,arm7_elf_SHA256=sha(a7.read_bytes()),arm9_elf_SHA256=sha(a9.read_bytes()),
  source_entry=k['address'],source_body=body,source_end=end,size=272,code_SHA256=sha(k['body']),code_fnv=fnv(k['body']),
  main_entry=main['address'],main_body=main['address']+4,wrapper=dict(entry=wrapper['address'],size=wrapper['size'],return_address=ret,SHA256=sha(wrapper['body'])),
  helper=dict(entry=quiet['address'],bytes=quiet['size'],SHA256=sha(quiet['body']),itcm_base=base,itcm_bytes=top-base,initialized_base=ib,initialized_bytes=isz,initialized_SHA256=sha(elf.allocated_image(a9,ib,isz))),
  kernel_mutation_caught=True,scope='SDK/layout/opcode qualification only; one fixed body/address per region, no DS timing law')
def invocation(b,n,rs,entry,return_pc):
 pre,post=struct.unpack('<16I',b[:64]),struct.unpack('<16I',b[64:])
 require(pre[:3]==(n,3,rs),'kernel input registers differ')
 require(post[:4]==(0,3,rs,(3*rs)&0xffffffff),'multiply/loop result registers differ')
 require(pre[4:15]==post[4:15],'preserved r4-r12/SP/LR differ')
 require(pre[4]==entry and pre[14]==return_pc,'actual call/return owner differs')
 require(0x03800000<=pre[5]<=0x03810000-128 and pre[5]%4==0,'register capture is not private WRAM')
 require(0x03800000<=pre[13]<0x03810000 and pre[13]%8==0,'wrapper stack/ABI differs')
 require(pre[15]&0xa0==0x80,'wrapper not IRQ-masked ARM')
 require(post[15]&0xf0000000==0x60000000 and post[15]&0x0fffffff==pre[15]&0x0fffffff,'final CPSR or preserved control differs')
 return fnv(b)
def analyze(directory,layout):
 d=Path(directory);prefix='a7mulphase_v1'
 completion=dict(x.split('=',1)for x in(d/(prefix+'_completion.txt')).read_text().splitlines())
 require(completion['status']=='SUCCESS'and int(completion['complete'])==8 and int(completion['new'])+int(completion['resumed'])==8 and int(completion['failed'])==int(completion['interrupted'])==0,'explicit successful completion required')
 require((d/(prefix+'_build.txt')).read_text()==layout['build_id']+'\n','producer source binding differs')
 require((d/(prefix+'_info.txt')).read_text().startswith('a7mulphase v1; build '+layout['build_id']+';'),'producer information differs')
 with(d/(prefix+'_setup.csv')).open()as f:setup={r['field']:int(r['value_hex'],16)for r in csv.DictReader(f)}
 h=layout['helper'];require([setup[k]for k in ['helper_entry','itcm_base','itcm_bytes']]==[h[k]for k in ['entry','itcm_base','itcm_bytes']],'runtime helper placement differs')
 require(setup['result_bytes']==4096 and setup['result_pointer']>>24==2 and setup['result_pointer']%32==0,'result size/address differs')
 require(setup['result_arm9_alias']==((setup['result_pointer']&0x3fffff)|0x02000000),'result alias differs')
 require(setup['dispcntA']==setup['dispcntB']==0x10080,'both screens must be forced blank')
 image=(d/(prefix+'_helper_itcm.bin')).read_bytes();require(len(image)==h['itcm_bytes'],'ITCM image size differs')
 lo=h['initialized_base']-h['itcm_base'];require(sha(image[lo:lo+h['initialized_bytes']])==h['initialized_SHA256'],'live initialized ITCM differs')
 lo=h['entry']-h['itcm_base'];require(sha(image[lo:lo+h['bytes']])==h['SHA256'],'live quiet helper differs')
 with(d/(prefix+'.csv')).open()as f:rows=list(csv.DictReader(f))
 order=[(i,r,p,n)for i in range(4)for r in range(2)for p in range(5)for n in[4,16]]
 require([(int(x['case_id']),int(x['region']),int(x['rep']),int(x['loops']))for x in rows]==order,'80 ordered complete raw samples required')
 expected=''.join(f'{verb} k{i:02d}_r{r}\n'for i in range(4)for r in range(2)for verb in['start','done'])
 require((d/(prefix+'_progress.txt')).read_text()==expected,'eight complete ordered START/DONE groups required')
 summaries=[];registers=0
 for i,rs in enumerate(RS):
  for region in range(2):
   raw=(d/f'{prefix}_k{i:02d}_r{region}.bin').read_bytes();require(len(raw)==4096,'binary sample record truncated')
   words=struct.unpack_from('<16I',raw);entry=layout['main_entry']if region else layout['source_entry'];body=entry+4
   require(words[:12]==(0x41504d31,1,i,region,0,272,layout['source_entry'],layout['source_body'],layout['source_end'],entry,body,entry+272),'binary identity/error/live layout differs')
   for at in[3072,3584]:
    code=raw[at:at+272];kernel(code);require(sha(code)==layout['code_SHA256'],'live kernel bytes differ from qualified ELF')
    require(raw[at+272:at+512]==bytes(240),'unused code snapshot bytes differ')
   require(words[12:]==(layout['code_fnv'],layout['code_fnv'],1,rs),'copy/FNV/Rs differs')
   for offset in[64,128]:
    c=struct.unpack_from('<16I',raw,offset)
    require(c[0]&0x80 and c[8]==0x80 and c[10]==0x84,'ARM7 IRQ/timer context differs')
    require(0x03800000<=c[1]<0x03810000 and 0<=c[11]<263,'ARM7 stack/line context differs')
    require(c[12]==0 and c[13]&15==1,'sound or GO context differs')
   short=[];long=[]
   for rep in range(5):
    for length,n in enumerate([4,16]):
     at=192+(rep*2+length)*288;meta=struct.unpack_from('<8I',raw,at)
     require(meta[0]==n and meta[1]>0 and meta[2]==meta[3]==(3*rs)&0xffffffff,'raw time/return result differs')
     require(meta[4]==invocation(raw[at+32:at+160],1,rs,entry,layout['wrapper']['return_address']),'warm register checksum differs')
     require(meta[5]==invocation(raw[at+160:at+288],n,rs,entry,layout['wrapper']['return_address']),'timed register checksum differs')
     registers+=64;require(0<=meta[6]<263 and 0<=meta[7]<263,'raw VCOUNT differs')
     row=rows[((i*2+region)*5+rep)*2+length]
     require([int(row[k])for k in ['loops','ticks','warm_value','value','start_line','end_line']]==[meta[k]for k in[0,1,2,3,6,7]],'CSV contradicts binary sample')
     require([int(row[k],16)for k in ['warm_checksum','checksum']]==list(meta[4:6]),'CSV register checksum differs')
     require([int(row[k],16)for k in ['rs_hex','entry','body','end']]==[rs,entry,body,entry+272]and int(row['error'])==0,'CSV identity/code differs')
     (long if length else short).append(meta[1])
   require(min(long)>min(short),'independent-minimum slope not positive')
   summaries.append(dict(case_id=i,rs=rs,m=i+1,region='MAIN'if region else'private_WRAM',ticks4=short,ticks16=long,slope=(min(long)-min(short))/768,entry=entry,body=body,code_SHA256=layout['code_SHA256']))
 return dict(status='PASS software protocol/state/body only; emulator timing is not DS truth',groups=8,raw_times=80,invocations=160,register_words=registers,live_body_snapshots=16,summary=summaries,
  files={p.name:sha(p.read_bytes())for p in sorted(d.glob(prefix+'*'))if p.is_file()})
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='action',required=True)
 s=sub.add_parser('sdk');s.add_argument('--arm7',type=Path,required=True);s.add_argument('--arm9',type=Path,required=True);s.add_argument('--build-id',type=Path,required=True);s.add_argument('--out',type=Path,required=True)
 o=sub.add_parser('outputs');o.add_argument('directory',type=Path);o.add_argument('--layout',type=Path,required=True);o.add_argument('--out',type=Path,required=True)
 a=p.parse_args();q=sdk(a.arm7,a.arm9,a.build_id)if a.action=='sdk'else analyze(a.directory,json.loads(a.layout.read_text()));a.out.write_text(json.dumps(q,indent=2)+'\n');print(q.get('status','PASS linked SDK/body/helper'))
