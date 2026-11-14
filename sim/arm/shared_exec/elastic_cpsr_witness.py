#!/usr/bin/env python3
"""Preserve raw traces; architectural MRS witnesses for every mismatch visit.
The probe replaces the following instruction by MRS r0 and its successor by
an unconditional trampoline. It restores only the overwritten r0 from the
pinned incoming retirement row, executes both original instructions, and
returns. All other scratch registers are saved/restored from actual state;
no probe instruction changes flags. Every incoming multiply RF row is checked
against the original, so restoring r0 cannot hide an incoming RF defect.
"""
import pathlib,json,hashlib,subprocess,os,resource,time,struct,re,tarfile
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-cpsr-all';D.mkdir(exist_ok=True);I=W/'build/cpu232-service-cpu-gates/inputs';G=W/'build/cpu232-retimed/trace-comparison';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
models={'original':W/'build/cpu232-service-cpu-gates/obj/Vtb_arm','elastic':W/'build/cpu232-shared-elastic-cpu/obj/Vtb_arm'}
with tarfile.open(W/'docs/results/cpu232-service-cpu-gates-20261110/evidence.tar.gz')as t:oracle=json.load(t.extractfile('execution/result.json'))
assert H(models['original'])==oracle['model_sha256'];assert H(models['elastic'])==json.loads((W/'build/cpu232-shared-elastic-cpu/result.json').read_text())['model_sha256']
sealed=json.loads((W/'docs/results/cpu232-shared-elastic-20261110/result.json').read_text());arch=W/'build/cpu232-shared-elastic-cpu/architectural/result.json';assert H(arch)==sealed['members']['cpu/architectural/result.json'];assert H(W/'build/cpu232-shared-elastic-cpu/result.json')==sealed['members']['cpu/result.json'];comparison=json.loads(arch.read_text())
gold=json.loads((G/'result.json').read_text());r={'status':'RUNNING','source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=W,text=True).strip(),'models':{k:H(p)for k,p in models.items()},'raw_traces':{},'all_51':[],'fixtures':{},'no_original_rebuild':True,'trampoline_changes_flags':False,'register_restore':'r0 from pinned actual incoming multiply retirement; other scratch registers saved/restored; every incoming multiply RF row verified','not_cycle_equivalence':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(phase,child=None):
 s=json.loads(STATUS.read_text());s.update(phase=phase,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'all51-CPSR-MRS-witness','peak_new_bytes':1073741824}]+([]if child is None else[{'host':'Desktop','PID':child.pid,'NI':os.getpriority(os.PRIO_PROCESS,child.pid),'job':phase}]),updated_at=time.time());tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');assert tmp.stat().st_size<=2048;tmp.replace(STATUS)
def idx(pc):return ((pc>>24)&15)*65536+((pc>>2)&65535)
def readhex(p):
 m={};i=0
 for t in p.read_text().split():
  if t.startswith('@'):i=int(t[1:],16)
  else:m[i]=int(t,16);i+=1
 return m
def writehex(p,m):
 out=[];last=-2
 for i,v in sorted(m.items()):
  if i!=last+1:out.append('@'+format(i,'x'))
  out.append(format(v,'08x'));last=i
 p.write_text('\n'.join(out)+'\n')
def branch(op,oldpc,newpc):
 if (op>>25)&7!=5:return op
 v=op&0xffffff;v=v-(1<<24)if v&(1<<23)else v;target=oldpc+8+4*v;disp=(target-(newpc+8))//4;assert -(1<<23)<=disp<(1<<23);return (op&0xff000000)|(disp&0xffffff)
for group in ['normal-01','DENSE-01']:
 original=G/(group+'-control.trace0');new=W/('build/cpu232-shared-elastic-cpu/architectural/'+group+'.trace0');assert H(original)==gold['cases'][group]['control']['trace0']==sealed['members']['retained-gold/'+group+'-control.trace0'];assert H(new)==comparison['cases'][group]['candidate_sha256'];a=[x.split(',')for x in original.read_text().splitlines()];b=[x.split(',')for x in new.read_text().splitlines()];assert len(a)==len(b)
 m0=readhex(I/(group+'.hex'));r['raw_traces'][group]={'original_sha256':H(original),'elastic_sha256':H(new)};targets={}
 for i,(x,y)in enumerate(zip(a,b)):
  assert [x[0],*x[2:]]==[y[0],*y[2:]],(group,i,'PC/RF mismatch')
  if x[1]==y[1]:continue
  pc=int(x[0],16);prev=int(a[i-1][0],16);op=m0[idx(prev)]
  assert op&(1<<20) and (op&0x0f0000f0)==0x00000090,(group,i,hex(op))
  assert int(x[1],16)^int(y[1],16) in [0x40000000,0x80000000,0xc0000000]
  assert x[1]==a[i-2][1] and y[1]==a[i-1][1],(group,i,'not exact before/after flags')
  visits=[row for row in a[:i+1]if row[0]==x[0]];visit=len(visits)-1
  event={'group':group,'row':i,'target_pc':x[0],'multiply_pc':a[i-1][0],'opcode':format(op,'08x'),'visit':visit,'original_raw':x[1],'elastic_raw':y[1],'before_multiply':a[i-2][1],'multiply_retire':a[i-1][1]};r['all_51'].append(event);targets[pc]=prev
 for pc,prev in sorted(targets.items()):
  name=group+'-'+format(pc,'08x');p=D/name;tramp=0x02030000;op1=m0[idx(pc)];op2=m0[idx(pc+4)];incoming=[row for row in a if int(row[0],16)==prev];assert len(incoming)==3,(name,len(incoming))
  # Original instructions do not read PC, except the relocated conditional B.
  # Instruction words are preserved; a B immediate keeps its original target.
  for op in [op1,op2]:
   if (op>>25)&7==5:continue
   if (op>>26)&3==1:assert (op>>16)&15!=15
   if (op>>25)&7==4:assert not op&0x8000 and (op>>16)&15!=15
  asm='''.syntax unified
.arch armv5te
.arm
.global _start,replay_first,replay_second
_start:
 str r1,save_r1
 str r2,save_r2
 ldr r1,counter
 ldr r2,=r0_table
 ldr r0,[r2,r1,lsl #2]
 add r1,r1,#1
 str r1,counter
 ldr r1,save_r1
 ldr r2,save_r2
replay_first:
 .word 0
replay_second:
 .word 0
 .word 0
save_r1: .word 0
save_r2: .word 0
counter: .word 0
r0_table:
'''+''.join(' .word 0x'+row[2]+'\n'for row in incoming)+'.ltorg\n'
  p.with_suffix('.s').write_text(asm)
  subprocess.run(['clang','--target=armv5te-none-eabi','-c',p.with_suffix('.s'),'-o',p.with_suffix('.o')],check=True)
  subprocess.run(['ld.lld','-Ttext='+hex(tramp),'--oformat=binary',p.with_suffix('.o'),'-o',p.with_suffix('.bin')],check=True)
  nm=subprocess.check_output(['llvm-nm',p.with_suffix('.o')],text=True);syms={line.split()[2]:int(line.split()[0],16)+tramp for line in nm.splitlines()if len(line.split())==3};data=bytearray(p.with_suffix('.bin').read_bytes());first=syms['replay_first'];second=syms['replay_second']
  struct.pack_into('<I',data,first-tramp,branch(op1,pc,first));struct.pack_into('<I',data,second-tramp,branch(op2,pc+4,second));struct.pack_into('<I',data,second+4-tramp,branch(0xea000000,pc,second+4)) # original pc+8
  m=m0.copy();m[idx(pc)]=0xe10f0000;m[idx(pc+4)]=branch(0xea000000,tramp-8,pc+4)
  for off in range(0,len(data),4):m[idx(tramp+off)]=int.from_bytes(data[off:off+4],'little')
  writehex(p.with_suffix('.hex'),m);row={'target_pc':format(pc,'08x'),'multiply_pc':format(prev,'08x'),'original_words':[format(op1,'08x'),format(op2,'08x')],'trampoline_PC':hex(tramp),'replay_PCs':[hex(first),hex(second)],'image_sha256':H(p.with_suffix('.hex')),'models':{}}
  for kind,model in models.items():
   csv=D/(name+'-'+kind+'.csv');log=D/(name+'-'+kind+'.log')
   with log.open('w')as f:
    child=subprocess.Popen([model,'+img0='+str(p.with_suffix('.hex')),'+pc0=02000000','+run=1','+maxcycles=2000000','+trace0='+str(csv)],stdout=f,stderr=subprocess.STDOUT,cwd=W);status('CPSR_'+name+'_'+kind,child)
    rc=child.wait(timeout=90)
   assert rc==0 and'TEST PASSED'in log.read_text(),(name,kind,log.read_text()[-1200:])
   trace=[x.split(',')for x in csv.read_text().splitlines()];pre=[x for x in trace if int(x[0],16)==prev];mrs=[x for x in trace if int(x[0],16)==pc]
   assert len(pre)==len(mrs)==3,(name,kind,len(pre),len(mrs))
   for n,(x,y)in enumerate(zip(pre,incoming)):assert [x[0],*x[2:]]==[y[0],*y[2:]],(name,kind,n,'incoming RF state changed',x,y)
   row['models'][kind]={'csv_sha256':H(csv),'incoming_RF_rows_verified':3,'MRS_full32':[x[2]for x in mrs],'MRS_retire_CPSR':[x[1]for x in mrs]}
  assert row['models']['original']['MRS_full32']==row['models']['elastic']['MRS_full32'],(name,'architectural MRS mismatch',row)
  r['fixtures'][name]=row;save();print(name,'3 full32 MRS and incoming RF witnesses agree',flush=True)
assert len(r['all_51'])==51 and len(r['fixtures'])==21
for e in r['all_51']:
 f=r['fixtures'][e['group']+'-'+e['target_pc']];e['MRS_original']=f['models']['original']['MRS_full32'][e['visit']];e['MRS_elastic']=f['models']['elastic']['MRS_full32'][e['visit']];assert e['MRS_original']==e['MRS_elastic']==e['multiply_retire'],e
r['status']='ALL51_EXACT_STALE_RETIRE_SNAPSHOTS_63_FULL32_ARCH_MRS_MATCH_INCOMING_RF_PINNED';save();status(r['status']);s=json.loads(STATUS.read_text());s['workers']=[];tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');tmp.replace(STATUS)
