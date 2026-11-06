#!/usr/bin/env python3
"""Joined dedicated ARM7 before/native/fallback public proof, sequential D1."""
from pathlib import Path
import subprocess,os,json,hashlib,resource,sys,re,shutil,random
R=Path(__file__).resolve().parents[3];os.chdir(R);D=R/'build/cpu-a7-mul-pair';D.mkdir(exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
V='build/tools/oss-cad-suite/bin/verilator';BASE='a7e1c5a9';H=lambda b:hashlib.sha256(b).hexdigest()
P=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
r={'joined_before':BASE,'branch_before':'169264df','stages':[],'cases':[],'hashes':{},'controller':os.getpid()}
def save():
 (D/'result.tmp').write_text(json.dumps(r,indent=2)+'\n');(D/'result.tmp').replace(D/'result.json')
def call(cmd,tag,fail=None):
 with(D/(tag+'.log')).open('w')as log:
  p=subprocess.Popen(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT)
  row={'tag':tag,'PID':p.pid,'command':list(map(str,cmd))};r['stages'].append(row);save()
  d=json.loads(P.read_text());d.update(phase='A7MUL_'+tag,worker={'active':True,'host':'DesktopD1','PID':p.pid,'controller':os.getpid(),'NI':10,'jobs':1,'threads':1});q=P.with_suffix('.json.tmp-cpu-compression');q.write_text(json.dumps(d,separators=(',',':'))+'\n');os.replace(q,P)
  try:rc=p.wait(timeout=240)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);raise
  row.update(exit=rc,reaped=True);save()
 text=(D/(tag+'.log')).read_text();assert (rc!=0 and fail in text)if fail else rc==0,text[-3000:]
 return text
oldexpr=(R/'sim/arm/a7_mul_pair/evidence/old-expression.sv.txt').read_text();newexpr=(R/'sim/arm/a7_mul_pair/evidence/new-expression.sv.txt').read_text()
branch=(R/'rtl/arm/arm7_ds.sv').read_text();prior=subprocess.check_output(['git','show','169264df:rtl/arm/arm7_ds.sv'],text=True);assert branch.replace(newexpr,oldexpr)==prior
mul=(R/'rtl/arm/arm_mul.sv').read_text();previous_mul=subprocess.check_output(['git','show','169264df:rtl/arm/arm_mul.sv'],text=True);assert mul.startswith(previous_mul)
leaves='module arm_mul_pair18 ('+mul.split('module arm_mul_pair18 (',1)[1]
r['prior_ARM9_literal_unchanged']=True;r['prior_ARM9_receipt_SHA256']=H((R/'sim/arm/mul_pair/evidence/summary.json').read_bytes())
unit=''
for kind,native,bad in [('native',True,False),('fallback',False,False),('bad',True,True)]:
 t=leaves.replace('arm_mul_pair18','arm_mul_pair18_'+kind).replace('arm_mul_full33','arm_mul_full33_'+kind)
 if bad:t=t.replace('.by(b1)','.by(a1)')
 unit+=('`define ALTERA_RESERVED_QIS\n'if native else'')+t+('`undef ALTERA_RESERVED_QIS\n'if native else'')
(D/'unit-leaves.sv').write_text(unit)
call([V,'--binary','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--top-module','a7_fullmul_tb','--Mdir',D/'unitobj',R/'sim/arm/mul_pair/contract.sv',D/'unit-leaves.sv',R/'sim/arm/a7_mul_pair/unit.sv'],'unit-build')
log=call([D/'unitobj/Va7_fullmul_tb'],'unit');assert 'A7_FULL66_PASS'in log
call([D/'unitobj/Va7_fullmul_tb','+mutant'],'unit-fault','A7_NATIVE_BY_FULL66_FAULT')
r['unit']='202178 exact full66/native/fallback/accumulator; actual BY partial fault caught'
# Dedicated A7 fixture preserves existing RAM/bus/hook/architectural observer.
tb=(R/'sim/arm/compact_profile/tb.sv').read_text();needle='      if (dbg_wen) shadow'
if 'if (dut.u_core.rf_we2) shadow'not in tb:
 assert tb.count(needle)==1;tb=tb.replace(needle,'      if (dut.u_core.rf_we2) shadow[dut.u_core.rf_wa2[5]][dut.u_core.rf_wa2[4:0]] = dut.u_core.rf_wd2;\n'+needle)
(D/'tb_arm.sv').write_text(tb);r['testbench_SHA256']=H(tb.encode())
names='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm7_ds arm7_stm4_owner arm_cpu'.split()
flags=['-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0'];r['options']=flags
for kind in ['before','native','fallback']:
 src=D/kind;src.mkdir(exist_ok=True);files=[]
 for name in names:
  data=subprocess.check_output(['git','show',BASE+':rtl/arm/'+name+'.sv'],text=True)
  if name=='arm7_ds'and kind!='before':
   assert data.count(oldexpr)==1;data=data.replace(oldexpr,newexpr)
  if name=='arm_mul'and kind!='before':data+='\n'+('`define ALTERA_RESERVED_QIS\n'if kind=='native'else'')+leaves+('`undef ALTERA_RESERVED_QIS\n'if kind=='native'else'')
  p=src/(name+'.sv');p.write_text(data);files.append(p);r['hashes'][kind+'/'+name]=H(data.encode())
 if kind=='native':files.append(R/'sim/arm/mul_pair/contract.sv')
 call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','--x-assign','fast','--x-initial','fast','-Wno-fatal','--top-module','tb_arm',*flags,'--Mdir',src/'obj',*files,D/'tb_arm.sv'],kind+'-build')
# Directed actual ARMv4 instruction oracle. All six multiply forms plus NZ.
asm=['.syntax unified','.arch armv4t','.arm','.global _start','_start:']
mask=(1<<64)-1;rr=random.Random(0xa733)
values=[(0,0,0),(1,0xffffffff,mask),(0xffffffff,0xffffffff,1),(0x80000000,0x80000000,mask),(0x7fffffff,0x80000000,0x8000000000000001),(0x10000,0x10000,0xffffffff),(0xffff,0xffff,mask),(0xffff0001,0xffff0000,0x7fffffffffffffff)]+[(rr.getrandbits(32),rr.getrandbits(32),rr.getrandbits(64))for _ in range(32)]
def signed(v):return v-(1<<32)if v&(1<<31)else v
for i,(a,b,acc)in enumerate(values):
 for op in ['mul','mla','umull','umlal','smull','smlal']:
  asm += [f'ldr r0, =0x{a:08x}',f'ldr r1, =0x{b:08x}',f'ldr r2, =0x{acc&0xffffffff:08x}',f'ldr r3, =0x{acc>>32:08x}']
  long=op not in ['mul','mla'];v=(signed(a)*signed(b)if op.startswith('sm')else a*b)+(acc if op.endswith('lal')else (acc&0xffffffff if op=='mla'else 0));v&=mask if long else 0xffffffff
  if long:
   asm+=['mov r4,r2','mov r5,r3',f'{op}s r4,r5,r0,r1']
  else:asm+=[f'{op}s r4,r0,r1'+(',r2'if op=='mla'else'')]
  asm+=['mrs r6,cpsr',f'ldr r7, =0x{v&0xffffffff:08x}','cmp r4,r7','bne fail']
  if long:asm += [f'ldr r7, =0x{v>>32:08x}','cmp r5,r7','bne fail']
  nz=(0x80000000 if v&(1<<(63 if long else 31))else 0)|(0x40000000 if v==0 else 0)
  asm+=['and r6,r6,#0xc0000000',f'ldr r7, =0x{nz:08x}','cmp r6,r7','bne fail']
 asm += [f'b next{i}','.ltorg',f'next{i}:']
asm += ['mov r0,#0','ldr r1,=0x0f000000','str r0,[r1]','b .','fail:','ldr r0,=0xdead0033','ldr r1,=0x0f000000','str r0,[r1]','b .','.ltorg']
(D/'directed.s').write_text('\n'.join(asm)+'\n')
for tag,cmd in [('as',['clang','--target=armv4t-none-eabi','-c',D/'directed.s','-o',D/'directed.o']),('ld',['ld.lld','--image-base=0','-Ttext=0x02000000','--entry=_start',D/'directed.o','-o',D/'directed.elf']),('bin',['llvm-objcopy','-O','binary',D/'directed.elf',D/'directed.bin']),('hex',['python3',R/'sim/arm/tools/mkhex.py',D/'directed.hex',str(D/'directed.bin')+'@0x02000000'])]:call(cmd,'guest-'+tag)
# Freeze accepted broad fixtures; only affected dedicated ARM7/dual cases.
images=D/'images';images.mkdir(exist_ok=True);assets=Path('/home/user/Git/NDS_Pocket-codex-cpu/build/arm')
for p in list(assets.glob('*.hex'))+[assets/'armwrestler.hooks']:shutil.copyfile(p,images/p.name)
sys.path.insert(0,str(R/'sim/arm/tools'));import run_tests
cases=[('mul-directed',[f'+img1={D}/directed.hex','+pc1=02000000','+run=2','+maxcycles=3000000'])]
selected={'exc_dual','hazard_dual','jsmolka_arm','jsmolka_thumb','armwrestler','dual','bpred7','halt7','stress_dual_c','dual_c','exc_dual_wait','hazard_dual_wait','dual_wait'}
cases +=[(name,args)for name,args,_ in run_tests.tests(str(images),'unused')if name in selected]
# Re-run only directed workload at stalled memory latency; every observed edge compared.
cases.append(('mul-directed-lat9',[f'+img1={D}/directed.hex','+pc1=02000000','+run=2','+rwait=30','+blat=9','+maxcycles=3000000']))
for name,args in cases:
 outputs=[]
 for kind in ['before','native','fallback']:
  stem=D/(kind+'-'+name);log=call([D/kind/'obj/Vtb_arm',*args,'+dbg=1',f'+trace0={stem}.0.csv',f'+trace1={stem}.1.csv',f'+ops0={stem}.0.ops',f'+ops1={stem}.1.ops'],kind+'-'+name)
  public=[x for x in log.splitlines()if re.match(r'^\d+ (BUS9|RET|RF) ',x)or x.startswith(('cycles=','TEST ','ctx'))]
  traces=[Path(str(stem)+s).read_bytes()for s in ['.0.csv','.1.csv','.0.ops','.1.ops']];outputs.append((public,traces))
 assert outputs[0]==outputs[1]==outputs[2],('public/state/order/cycle difference',name)
 verdict='PASS'if 'TEST PASSED'in outputs[0][0]else'INHERITED_FAIL'
 if name.startswith('mul-directed'):assert verdict=='PASS',name
 r['cases'].append({'name':name,'verdict':verdict,'retirements':sum(v.count(b'\n')for v in outputs[0][1][:2]),'public_rows':len(outputs[0][0]),'SHA256':H(repr(outputs[0]).encode())});save()
r['state']='PASS joined dedicated ARM7 before/native/fallback exact public bus/writeback/retirement/cycles/state; inherited failures retained';save();print(r['state'],flush=True)
