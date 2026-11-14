#!/usr/bin/env python3
"""Registered ARM7 port regression: corrected link versus previous actual RTL."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-native';D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
H=lambda b:hashlib.sha256(b).hexdigest()
previous=json.loads((D/'result.json').read_text()) if (D/'result.json').exists() else {}
r={'status':'PREPARING_FULL_NATIVE_SHARED_ENGINE','PID':os.getpid(),'sources':{},'stages':[],'not_production':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(tag,p=None):
 s=json.loads(STATUS.read_text());s.update(phase=tag,receipt=str(D/'result.json'),workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'native-shared-engine'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
def call(cmd,tag,timeout=180):
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=W,stdout=f,stderr=subprocess.STDOUT);z={'tag':tag,'PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'cmd':list(map(str,cmd))};r['stages'].append(z);save();status(tag,p)
  try:z['exit']=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:p.terminate();z['exit']=p.wait(timeout=10);z['timeout']=True
  save()
 return z['exit'],(D/(tag+'.log')).read_text()
# Require the unchanged original full-CPU oracle and actual caught fault first.
P=W/'docs/results/cpu232-service-cpu-gates-20261110';receipt=json.loads((P/'result.json').read_text());assert H((P/'evidence.tar.gz').read_bytes())==receipt['archive_sha256'];assert receipt['observed_cycles']==42657146 and '862'in receipt['actual_fault'];r['original_oracle_sha256']=receipt['archive_sha256']
files=[]
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem']:
 p=S/(n+'.sv');b=subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W);p.write_bytes(b);files.append(p);r['sources'][p.name]=H(b)
for rel in ['rtl/arm/study/arm_shared_elastic.sv','rtl/arm/study/arm_dual_elastic.sv','rtl/arm/study/arm_cpu_elastic.sv','sim/arm/shared_exec/registered_tb.sv']:
 p=S/pathlib.Path(rel).name;p.write_bytes((W/rel).read_bytes().replace(b'arm_cpu_shared #',b'arm_cpu_elastic #'));
 if p.name=='registered_tb.sv':
  t=p.read_text().replace('parameter bit FAULT_LAUNCH=0);','parameter bit FAULT_LAUNCH=0,parameter bit FAULT_DUP_STORE=0);').replace('.FAULT_LAUNCH(FAULT_LAUNCH)) dut(','.FAULT_LAUNCH(FAULT_LAUNCH),.FAULT_DUP_STORE(FAULT_DUP_STORE)) dut(').replace('$fatal(1,"native shared timeout");', '$display("ELASTIC_STATE pause%b idone%b ddone%b cancel%b f2%b/%b ib%b/%b wv%b/%b wm%0d we%b adv%b/%b halt%p",dut.shared.engine.paused,dut.shared.idone,dut.shared.ddone,dut.shared.icancel,dut.shared.engine.f2_v_ctx[0],dut.shared.engine.f2_v_ctx[1],dut.shared.engine.ib_v[0],dut.shared.engine.ib_v[1],dut.shared.engine.w_valid_ctx[0],dut.shared.engine.w_valid_ctx[1],dut.shared.engine.w_mem,dut.shared.engine.w_exec,dut.shared.engine.advance_e,dut.shared.engine.advance_o,dut.shared.engine.halted);$fatal(1,"native shared timeout");');p.write_text(t)
 files.append(p);r['sources'][p.name]=H(p.read_bytes())
(S/'cp15.inc').write_bytes(subprocess.check_output(['git','show','232c26ac:sim/arm/tests/cp15.inc'],cwd=W))
common=''' ldr r0,=0x02000800
 ldr r1,[r0]
 cmp r1,#{value}
 bne fail
 add r2,r1,#3
 str r2,[r0,#4]
 ldr r4,[r0,#4]
 cmp r2,r4
 bne fail
 ldr r5,=thumb_entry
 adr lr,arm_return
 bx r5
arm_return:
 cmp r6,#7
 bne fail
'''
cp=''' CP15_REGIONS
 CP15_ENABLE
 ldr r0,=0x0b000000
 ldr r1,=0x1234cafe
 str r1,[r0,#12]
 ldr r2,[r0,#12]
 cmp r1,r2
 bne fail
 mrc p15,0,r4,c6,c1,0
 ldr r5,=0x0200002b
 cmp r4,r5
 bne fail
 mov r0,#0x18
 ldr r1,=0xe3a08001
 str r1,[r0]
 ldr r1,=0xe25ef004
 str r1,[r0,#4]
'''
irq=''' mov r8,#0
 mrs r7,cpsr
 bic r7,r7,#0x80
 msr cpsr_c,r7
 ldr r2,=0x0f000004
 mov r3,#1
 str r3,[r2]
irq_wait:
 cmp r8,#1
 bne irq_wait
'''
halt=''' ldr r0,=0x04000301
 mov r1,#0x80
 strb r1,[r0]
 ldr r2,=0x0f000008
 mov r3,#2
 str r3,[r2]
'''
for c,val in [(0,17),(1,34)]:
 text='.syntax unified\n.arch armv5te\n.arm\n.global _start\n.include "cp15.inc"\n_start:\n'+(cp if c==0 else'')+common.format(value=val)+(irq if c==0 else halt)+''' mov r0,#0
 b end
fail:
 mov r0,#1
end:
 ldr r2,=0x0f000000
 str r0,[r2]
 b .
.ltorg
.thumb
.thumb_func
thumb_entry:
 movs r6,#7
 bx lr
.org 0x800
.word '''+str(val)+'\n.word 0\n'
 p=D/('context'+str(c));p.with_suffix('.s').write_text(text);subprocess.run(['clang','--target=armv5te-none-eabi','-c','-Wa,-I,'+str(S),p.with_suffix('.s'),'-o',p.with_suffix('.o')],check=True);subprocess.run(['ld.lld','-Ttext=0x02000000','--oformat=binary',p.with_suffix('.o'),'-o',p.with_suffix('.bin')],check=True);subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',p.with_suffix('.hex'),str(p.with_suffix('.bin'))+'@0x0'],check=True,stdout=subprocess.DEVNULL)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('NATIVE_SHARED_WAIT_BUILD_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
def admission():
 p=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json');policy=json.loads(p.read_text());seen=set();other=0
 for f in STATUS.parent.glob('*.json'):
  try:
   workers=json.loads(f.read_text()).get('workers',[])
   if not isinstance(workers,list):continue
   for q in workers:
    if not isinstance(q,dict)or q.get('host')not in ['Desktop','desktop']:continue
    pid=q.get('PID',q.get('pid'))
    if not isinstance(pid,int)or pid in seen or pid==os.getpid()or not pathlib.Path('/proc',str(pid)).exists():continue
    seen.add(pid);other+=int(q.get('peak_new_bytes',q.get('disk_budget_bytes',0)))
  except (ValueError,TypeError,OSError):continue
 mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());g={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'growth':policy['default_build_peak_new_bytes'],'floor':policy['floor_bytes'],'outstanding':other,'mutex':True,'policy_sha256':H(p.read_bytes())};r.setdefault('admissions',[]).append(g);save();assert g['NI']==10 and g['RAM']>=12*(1<<30)and g['disk']-g['growth']-other>=g['floor'],g
V=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator'
for name,fault,launchfault,dupfault in [('candidate',0,0,0),('wrong-owner',1,0,0),('duplicate-launch',0,1,0),('duplicate-store',0,0,1)]:
 top=S/'arm_cpu_elastic.sv'
 top.write_bytes((W/'rtl/arm/study/arm_cpu_elastic.sv').read_bytes())
 r.setdefault('variant_top_hashes',{})[name]=H(top.read_bytes());save()
 if os.environ.get('ELASTIC_REUSE_NATIVE')=='1':
  assert previous['sources']==r['sources']
  assert H((D/('obj-'+name)/'Vnative_tb').read_bytes())==previous['models'][name]
 else:
  admission();rc,log=call([V,'--binary','--timing','--assert','--threads','1','-j','4','-Wno-fatal','--top-module','native_tb','-GFAULT_OWNER='+str(fault),'-GFAULT_LAUNCH='+str(launchfault),'-GFAULT_DUP_STORE='+str(dupfault),'--Mdir',D/('obj-'+name),*files],'build-'+name);assert rc==0,log[-1600:]
 model=D/('obj-'+name)/'Vnative_tb';r.setdefault('models',{})[name]=H(model.read_bytes());save()
 cases=[('native-default',[]),('native-ready',['+waitmode=0']),('native-long',['+waitmode=2']),('native-reset',['+waitmode=1','+reset_pending=1'])]if name=='candidate'else[('native-'+name,[])]
 for tag,args in cases:
  rc,log=call([model,'+img0='+str(D/'context0.hex'),'+img1='+str(D/'context1.hex'),*args]+(['+debug']if os.environ.get('SHARED_EXEC_DEBUG')=='1'else[]),tag)
  if name=='previous-a7-link':
   assert rc!=0 and ('duplicate exit store'in log or'native CPU store count'in log or'native shared timeout'in log or'SELF_CHECK_FAIL'in log or'native feature/duplicate gate'in log),(name,log[-2400:])
   r['previous_a7_link_rejected']=True;save();continue
  if not(fault or launchfault or dupfault):
   if rc!=0 or'NATIVE_SHARED_PASS'not in log:r['status']='NATIVE_BINDING_FAILURE';save();status(r['status']);raise SystemExit(log[-2400:])
  else:
   expected='SELF_CHECK_FAIL'if fault else ('duplicate exit store' if dupfault else 'NATIVE_CP_OWNER_FAIL')
   assert rc!=0 and expected in log,(name,log[-1600:]);r['actual_wrong_owner_caught'if fault else ('actual_duplicate_store_caught' if dupfault else 'actual_launch_fault_caught')]=True;save()
fcntl.flock(lock,fcntl.LOCK_UN)
r['status']='ELASTIC_REGISTERED_A7_PASS_OWNER_LAUNCH_MUTANTS_CAUGHT';save();status(r['status']);q=json.loads(STATUS.read_text());q['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(q,separators=(',',':'))+'\n');os.replace(t,STATUS);print(r['status'])
