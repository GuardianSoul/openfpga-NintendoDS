#!/usr/bin/env python3
"""Source/object and synthetic protocol tests; never build/run a DS ROM."""
from pathlib import Path
import argparse,csv,hashlib,importlib.util,json,os,resource,shutil,struct,subprocess,time
S=Path(__file__).resolve().parent;R=S.parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(60,60));resource.setrlimit(resource.RLIMIT_AS,(1024**3,1024**3))
spec=importlib.util.spec_from_file_location('mix_independent_checker',S/'check.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
sha=lambda b:hashlib.sha256(b).hexdigest();result=dict(scope='SOURCE/OBJECT + SYNTHETIC ONLY; no SDK link/ROM/emulator/native/DS/hardware/staging',stages=[],mutations=[],ISA=[])
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def run(cmd,tag,expected=0):
 cmd=list(map(str,cmd));start=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  proc=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);tick=Path('/proc',str(proc.pid),'stat').read_text().rsplit(')',1)[1].split()[19]
  row=dict(tag=tag,cmd=cmd,PID=proc.pid,starttime=tick,NI=os.getpriority(os.PRIO_PROCESS,proc.pid));row['exit']=proc.wait(timeout=30)
 row.update(reaped=True,seconds=round(time.monotonic()-start,3));result['stages'].append(row);save();assert row['exit']==expected,(tag,(D/(tag+'.log')).read_text())
inputs='protocol.h arm7.c kernel.S main.c quiet.itcm.c Makefile ../common/hwref.c ../common/hwref.h ../Makefile ../wramarb/linker.py'.split()
build=sha(b''.join((S/n).read_bytes()for n in inputs));(D/'build-id.h').write_text('#define MM_BUILD_ID "'+build+'"\n')
gcc=Path('/opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc');inc=Path('/opt/devkitpro/calico/include')
for name in ['arm7.c','main.c','quiet.itcm.c']:
 arm7=name=='arm7.c';cmd=[gcc,'-fsyntax-only','-Wall','-Werror','-O2','-mcpu='+('arm7tdmi'if arm7 else'arm946e-s'),'-mthumb','-D__NDS__','-DARM'+('7'if arm7 else'9'),'-I'+str(inc),'-I/opt/devkitpro/libnds/include','-include',D/'build-id.h',S/name]
 run(cmd,'syntax-'+name)
run([gcc,'-mcpu=arm7tdmi','-marm','-c',S/'kernel.S','-o',D/'kernel.o'],'assemble')
run(['/opt/devkitpro/devkitARM/bin/arm-none-eabi-ld','-Ttext=0x03800640','--entry=mm_mul',D/'kernel.o','-o',D/'kernel-only.elf'],'link-kernel-only')
k=c.elf.elf_symbol(D/'kernel-only.elf','mm_mul');w=c.elf.elf_symbol(D/'kernel-only.elf','mm_invoke');ret=c.elf.elf_symbol(D/'kernel-only.elf','mm_return')['address'];c.kernel(k['body']);c.wrapper_code(w['body'])
result['kernel']=dict(entry=k['address'],SHA256=sha(k['body']),bytes=len(k['body']),wrapper_SHA256=sha(w['body']),wrapper_bytes=len(w['body']),return_pc=ret)
# Independent tiny ARM interpreter executes only the inspected four ISA forms.
# Count actual decoded Rs sources, final arithmetic/flags and all untouched regs.
def execute(entry,n,rs2,rs6):
 regs=[0x12340000+i for i in range(16)];regs[0]=n;regs[2]=rs2;regs[6]=rs6;regs[14]=0x01000000
 original=regs.copy();pc=entry;nzcv=0;seen={2:0,6:0};steps=0
 while pc!=regs[14]:
  assert entry<=pc<entry+272 and steps<2048;steps+=1;ins=struct.unpack_from('<I',k['body'],pc-entry)[0];nxt=pc+4
  if ins==0xe3a01003:regs[1]=3
  elif ins&0x0fc000f0==0x90:
   assert ins>>28==14 and(ins>>20)&3==0;rd=(ins>>16)&15;rs=(ins>>8)&15;rm=ins&15;assert rd==3 and rm==1 and rs in seen
   regs[rd]=(regs[rm]*regs[rs])&0xffffffff;seen[rs]+=1
  elif ins==0xe2500001:
   old=regs[0];regs[0]=(old-1)&0xffffffff;nzcv=(int(bool(regs[0]&0x80000000))<<3)|(int(regs[0]==0)<<2)|(int(old>=1)<<1)|int(old==0x80000000)
  elif ins>>24==0x1a:
   if not nzcv&4:
    off=ins&0xffffff;off=off-(1<<24)if off&(1<<23)else off;nxt=pc+8+4*off
  elif ins==0xe12fff1e:nxt=regs[14]
  else:raise AssertionError(hex(ins))
  pc=nxt
 assert regs[:4]==[0,3,rs2,(3*rs6)&0xffffffff]and regs[4:]==original[4:]and nzcv==6 and seen=={2:32*n,6:32*n}
 return dict(entry=entry,loops=n,rs2=rs2,rs6=rs6,executed_MULs=sum(seen.values()),steps=steps)
for entry in [k['address'],0x02fcd000]:
 for rs2,rs6 in [(127,127),(0x7fffffff,0x7fffffff),(127,0x7fffffff)]:
  for n in [1,4,16]:result['ISA'].append(execute(entry,n,rs2,rs6))
def reject(name,fn):
 try:fn()
 except (ValueError,AssertionError,KeyError,FileNotFoundError):result['mutations'].append(name)
 else:raise AssertionError('mutation survived: '+name)
for name,index,value in [('kernel-NOP',1,0xe1a00000),('wrong-Rs',2,0xe0030291),('wrong-backedge',66,0x1affffbe)]:
 bad=bytearray(k['body']);struct.pack_into('<I',bad,index*4,value);reject(name,lambda b=bytes(bad):c.kernel(b))
bad=bytearray(w['body']);struct.pack_into('<I',bad,20,0xe59d6024);reject('wrapper-fifth-argument-offset',lambda:c.wrapper_code(bytes(bad)))
# Synthetic fixtures are generated independently from the C record writer.
F=D/'synthetic';F.mkdir();prefix='a7mulmix_v1';helper=bytes(range(32));base=0x01ff8000
layout=dict(build_id=build,source_entry=k['address'],source_body=k['address']+4,source_end=k['address']+272,main_entry=0x02fcd000,
 code_SHA256=sha(k['body']),code_fnv=c.fnv(k['body']),wrapper=dict(return_address=ret),helper=dict(entry=base,bytes=32,SHA256=sha(helper),itcm_base=base,itcm_bytes=32,initialized_base=base,initialized_bytes=32,initialized_SHA256=sha(helper)))
(D/'synthetic-layout.json').write_text(json.dumps(layout,indent=2)+'\n');(F/(prefix+'_helper_itcm.bin')).write_bytes(helper)
(F/(prefix+'_build.txt')).write_text(build+'\n');(F/(prefix+'_info.txt')).write_text('a7mulmix v1; build '+build+'; SYNTHETIC NOT DS\n')
setup=dict(helper_entry=base,itcm_base=base,itcm_bytes=32,result_pointer=0x02ff0000,result_bytes=4128,result_arm9_alias=0x023f0000,dispcntA=0x10080,dispcntB=0x10080)
(F/(prefix+'_setup.csv')).write_text('field,value_hex\n'+''.join(f'{n},{v:08x}\n'for n,v in setup.items()))
progress=''.join(f'{v} k{i:02d}_r{r}\n'for i in range(3)for r in range(2)for v in ['start','done']);(F/(prefix+'_progress.txt')).write_text(progress)
completion='status=SUCCESS\ncomplete=6\nnew=6\nresumed=0\nfailed=0\ninterrupted=0\n';(F/(prefix+'_completion.txt')).write_text(completion)
def invocation(n,rs2,rs6,entry):
 pre=list(range(16));pre[:3]=[n,3,rs2];pre[4]=entry;pre[5]=0x03802000;pre[6]=rs6;pre[13]=0x0380dfd8;pre[14]=ret;pre[15]=0xd3
 post=pre.copy();post[:4]=[0,3,rs2,(3*rs6)&0xffffffff];post[15]=0x600000d3
 return struct.pack('<32I',*(pre+post))
columns='case_id,rs2_hex,rs6_hex,region,rep,loops,ticks,warm_value,value,warm_checksum,checksum,start_line,end_line,entry,body,end,error'.split(',');rows=[]
for i,(rs2,rs6)in enumerate([(127,127),(0x7fffffff,0x7fffffff),(127,0x7fffffff)]):
 for region in range(2):
  entry=layout['main_entry']if region else layout['source_entry'];raw=bytearray(4128);header=[0x414d5831,1,i,region,0,272,k['address'],k['address']+4,k['address']+272,entry,entry+4,entry+272,c.fnv(k['body']),c.fnv(k['body']),1,rs2,rs6,ret]+[0]*6;struct.pack_into('<24I',raw,0,*header)
  ctx=[0xd3,0x0380d000,0,0,0,0,0,0,0x80,0,0x84,192,0,1,0,1]
  for off in [96,160]:struct.pack_into('<16I',raw,off,*ctx)
  for rep in range(5):
   for length,n in enumerate([4,16]):
    # This fixture deliberately uses the local witness, never labeled DS.
    L=([591,655,623][i]if region else[132,324,228][i]);ticks=(136 if region else 137)+n*L
    warm=invocation(1,rs2,rs6,entry);timed=invocation(n,rs2,rs6,entry);meta=[n,ticks,(3*rs6)&0xffffffff,(3*rs6)&0xffffffff,c.fnv(warm),c.fnv(timed),192,192]
    at=224+(rep*2+length)*288;raw[at:at+288]=struct.pack('<8I',*meta)+warm+timed
    values=[i,rs2,rs6,region,rep,n,ticks,*meta[2:8],entry,entry+4,entry+272,0];row=dict(zip(columns,values))
    for key in ['rs2_hex','rs6_hex','warm_checksum','checksum','entry','body','end']:row[key]=f'{row[key]:08x}'
    rows.append(row)
  for off in [3104,3616]:raw[off:off+272]=k['body']
  (F/f'{prefix}_k{i:02d}_r{region}.bin').write_bytes(raw)
csvpath=F/(prefix+'.csv')
with csvpath.open('w')as f:writer=csv.DictWriter(f,fieldnames=columns,lineterminator="\n");writer.writeheader();writer.writerows(rows)
positive=c.analyze(F,layout);assert positive['register_words']==3840;assert positive['predictions']['MAIN']['local']=='623/64'and positive['predictions']['MAIN']['shared']=='591/64';result['synthetic']=positive
# Exercise exact pure C resume/readback functions extracted without rewriting.
source=(S/'main.c').read_text()
def function(name):
 start=source.index('static ',source.index(name)-30);start=source.rfind('static ',0,source.index(name));opening=source.index('{',source.index(name));depth=1;end=opening+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
host='''#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;typedef uint32_t u32;
#include "protocol.h"
static MmResult result;static u8 journal[6];
'''
host+='#define HWREF_DIR "'+str(F)+'"\n'+next(l for l in source.splitlines()if l.startswith('#define CSV_HEADER'))+'\n'
host+='\n'.join(function(name)for name in ['fnv(','read_journal(','csv_saved(','saved_group('])
host+='''
int main(int argc,char**argv){
 if(!read_journal())return 1;
 for(int i=0;i<6;i++)if(journal[i]!=2)return 1;
 for(int i=0;i<3;i++)for(int r=0;r<2;r++)if(!saved_group(i,r))return 1;
 if(!mm_complete(6,6,0,0,0)||!mm_complete(6,0,6,0,0)||mm_complete(5,5,0,0,0)||mm_complete(6,6,0,0,1)||mm_complete(6,6,0,1,0)||mm_complete(6,5,0,0,0))return 1;
 // An actual weakened producer predicate must be rejected by this test.
 MmInvocation bad=result.samples[0][0].warm;bad.pre[6]=bad.post[6]=127;
 if(mm_valid_invocation(&bad,1,result.rs2,result.rs6,result.entry,result.wrapper_return)){puts("WEAK_R6_PREDICATE_CAUGHT");return 1;}
 return 0;
}
'''
(D/'protocol.h').write_bytes((S/'protocol.h').read_bytes());(D/'resume.c').write_text(host)
run([shutil.which('cc'),'-O2','-Wall','-Werror','-Wno-unused-parameter',D/'resume.c','-o',D/'resume'],'host-resume-build');run([D/'resume'],'host-resume-pass')
# Mutate actual binary/text payloads, recomputing FNV where needed, rather
# than merely changing expected report flags. Both checkers must reject.
binary=F/(prefix+'_k02_r1.bin')
def mutation(name,change,path=binary):
 old=path.read_bytes();bad=bytearray(old);change(bad);path.write_bytes(bad)
 try:reject(name,lambda:c.analyze(F,layout));run([D/'resume'],'host-'+name,1)
 finally:path.write_bytes(old)
mutation('live-opcode',lambda b:struct.pack_into('<I',b,3108,0xe1a00000))
mutation('wrong-r6-header',lambda b:struct.pack_into('<I',b,64,127))
def bad_r6(b):
 at=224;struct.pack_into('<I',b,at+32+24,127);struct.pack_into('<I',b,at+32+64+24,127);struct.pack_into('<I',b,at+16,c.fnv(b[at+32:at+160]))
mutation('wrong-r6-snapshot-rehashed',bad_r6)
mutation('wrong-return-owner',lambda b:struct.pack_into('<I',b,68,ret+4))
mutation('bad-timer-context',lambda b:struct.pack_into('<I',b,96+32,0))
mutation('last-raw-time-zero',lambda b:struct.pack_into('<I',b,224+9*288+4,0))
mutation('CSV-checksum',lambda b:b.__setitem__(slice(None),bytes(b).replace(rows[-1]['checksum'].encode(),b'00000000')),csvpath)
mutation('incomplete-journal',lambda b:b.__setitem__(slice(None),bytes(b).removesuffix(b'done k02_r1\n')),F/(prefix+'_progress.txt'))
for name,text in [('failure-completion','status=INCOMPLETE\ncomplete=5\nnew=5\nresumed=0\nfailed=1\ninterrupted=0\n'),('interrupted-completion',completion.replace('interrupted=0','interrupted=1'))]:
 path=F/(prefix+'_completion.txt');old=path.read_text();path.write_text(text)
 try:reject(name,lambda:c.analyze(F,layout))
 finally:path.write_text(old)
# A valid but timing-contradictory return must remain accepted as evidence.
original_binary=binary.read_bytes();original_csv=csvpath.read_bytes();raw=bytearray(original_binary)
for rep in range(5):
 at=224+(rep*2+1)*288;old_tick=struct.unpack_from('<I',raw,at+4)[0];struct.pack_into('<I',raw,at+4,old_tick+768)
binary.write_bytes(raw)
altered=[dict(row)for row in rows]
for row in altered:
 if row['case_id']==2 and row['region']==1 and row['loops']==16:row['ticks']+=768
with csvpath.open('w')as f:writer=csv.DictWriter(f,fieldnames=columns,lineterminator='\n');writer.writeheader();writer.writerows(altered)
other=c.analyze(F,layout);assert other['predictions']['MAIN']['mixed']=='687/64';run([D/'resume'],'host-valid-contradictory-timing');result['valid_contradictory_timing_accepted']=True
binary.write_bytes(original_binary);csvpath.write_bytes(original_csv)
path=F/(prefix+'_completion.txt');path.write_text(completion.replace('new=6','new=0').replace('resumed=0','resumed=6'));c.analyze(F,layout);path.write_text(completion);result['completed_resume_accepted']=True
original=(D/'protocol.h').read_text();target='||v->pre[6]!=rs6';assert target in original;(D/'protocol.h').write_text(original.replace(target,''));run([shutil.which('cc'),'-O2','-Wall','-Werror','-Wno-unused-parameter',D/'resume.c','-o',D/'resume-weak'],'host-real-predicate-mutant-build');run([D/'resume-weak'],'host-real-predicate-mutant-caught',1);assert'WEAK_R6_PREDICATE_CAUGHT'in(D/'host-real-predicate-mutant-caught.log').read_text();(D/'protocol.h').write_text(original)
result['source_SHA256']={f.name:sha(f.read_bytes())for f in S.iterdir()if f.is_file()and(f.suffix in ['.c','.h','.S','.py']or f.name=='Makefile')};result['status']='PASS source/object18 ISA runs; synthetic60raw/3840registers; actual C resume gates;10 payload mutations+4 opcode/ABI faults; actual weakened R6 predicate caught. SDK/host-ROM/DS timing NOT qualified.';save();print(result['status'])
