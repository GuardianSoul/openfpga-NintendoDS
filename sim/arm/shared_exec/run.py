#!/usr/bin/env python3
"""Bounded whole shared-engine/response-bridge prototype; no fit or promotion."""
import pathlib,os,json,fcntl,subprocess,hashlib,shutil,resource,time
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-exec';S=D/'source';S.mkdir(exist_ok=True)
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
# The full original oracle and actual fault were established before this RTL.
receipt=json.loads((W/'docs/results/cpu232-service-cpu-gates-20261110/result.json').read_text());assert receipt['observed_cycles']==42657146 and '862'in receipt['actual_fault']
H=lambda b:hashlib.sha256(b).hexdigest();assert H((W/'docs/results/cpu232-service-cpu-gates-20261110/evidence.tar.gz').read_bytes())==receipt['archive_sha256']
r={'status':'PREPARING_SHARED_ENGINE_PROTOTYPE','PID':os.getpid(),'original_oracle_archive_sha256':receipt['archive_sha256'],'sources':{},'stages':[],'not_production':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(phase,p=None):
 s=json.loads(STATUS.read_text());s.update(phase=phase,source='232carm_corefullfixed-slot2xengine;new4nativeI/Dbridges;no microcontroller followup.',receipt=str(D/'result.json'),workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'sharedfullenginecontroller'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':phase}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
def call(cmd,tag,timeout=180):
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=W,stdout=f,stderr=subprocess.STDOUT);z={'tag':tag,'PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'cmd':list(map(str,cmd))};r['stages'].append(z);save();status(tag,p)
  try:z['exit']=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:p.terminate();z['exit']=p.wait(timeout=10);z['timeout']=True
  save()
 return z['exit'],(D/(tag+'.log')).read_text()
files=[]
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb']:
 b=subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W);p=S/(n+'.sv');p.write_bytes(b);files.append(p);r['sources'][str(p.relative_to(D))]=H(b)
for path in ['rtl/arm/study/arm_shared_core.sv','rtl/arm/study/arm_dual_shared.sv','sim/arm/shared_exec/tb.sv']:
 p=S/pathlib.Path(path).name;p.write_bytes((W/path).read_bytes());files.append(p);r['sources'][str(p.relative_to(D))]=H(p.read_bytes())
# Fixed expected values independently check reads, writes, flags and ARM/Thumb BX.
program='''.syntax unified
.arch armv5te
.arm
.global _start
_start:
 ldr r0,=0x02000800
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
 mov r0,#0
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
.word {value}
.word 0
'''
for c,v in [(0,17),(1,34)]:
 p=D/('context'+str(c));p.with_suffix('.s').write_text(program.format(value=v));subprocess.run(['clang','--target=armv5te-none-eabi','-c',p.with_suffix('.s'),'-o',p.with_suffix('.o')],check=True);subprocess.run(['ld.lld','-Ttext=0x02000000','--oformat=binary',p.with_suffix('.o'),'-o',p.with_suffix('.bin')],check=True);subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',p.with_suffix('.hex'),str(p.with_suffix('.bin'))+'@0x0'],check=True,stdout=subprocess.DEVNULL)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('SHARED_ENGINE_WAIT_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
def cleanup_finished():
 removed={}
 for name in ['candidate','owner-fault']:
  folder=D/('obj-'+name)
  if not folder.exists():continue
  for p in folder.iterdir():
   if p.is_file()and p.suffix in ['.o','.a','.gch']:
    removed[str(p.relative_to(D))]={'bytes':p.stat().st_size,'sha256':H(p.read_bytes())};p.unlink()
 if removed:
  (D/('compiler-cleanup-'+str(time.time_ns())+'.json')).write_text(json.dumps(removed,indent=2)+'\n')
def admission():
 policy_path=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json');policy=json.loads(policy_path.read_text())
 growth=policy['default_build_peak_new_bytes'];floor=policy['floor_bytes'];outstanding=0;seen=set()
 for p in STATUS.parent.glob('*.json'):
  try:
   unit=json.loads(p.read_text());workers=unit.get('workers',[])
   if not isinstance(workers,list):continue
   for worker in workers:
    if not isinstance(worker,dict)or worker.get('host')not in ['Desktop','desktop']:continue
    pid=worker.get('PID',worker.get('pid'))
    if not isinstance(pid,int)or pid==os.getpid()or pid in seen or not pathlib.Path('/proc',str(pid)).exists():continue
    seen.add(pid);outstanding+=int(worker.get('peak_new_bytes',worker.get('disk_budget_bytes',0)))
  except (ValueError,OSError,TypeError):continue
 mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());g={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'mutex':True,'growth':growth,'floor':floor,'outstanding_declared_growth':outstanding,'policy_sha256':H(policy_path.read_bytes())};r['guard']=g;r.setdefault('admissions',[]).append(g);save()
 assert g['NI']==10 and g['RAM']>=12*(1<<30) and g['disk']-growth-outstanding>=floor,g
admission()
V=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator'
for name,fault in [('candidate',0),('owner-fault',1)]:
 admission()
 rc,log=call([V,'--binary','--timing','--assert','--threads','1','-j','4','-Wno-fatal','--top-module','tb','-GFAULT_OWNER='+str(fault),'--Mdir',D/('obj-'+name),*files],'build-'+name);assert rc==0,log[-1400:]
 rc,log=call([D/('obj-'+name)/'Vtb','+img0='+str(D/'context0.hex'),'+img1='+str(D/'context1.hex')]+(['+debug']if os.environ.get('SHARED_EXEC_DEBUG')=='1'else[]),name)
 if not fault:
  r['candidate_outcome']={'exit':rc,'selfcheck':'SHARED_EXEC_PASS'in log,'tail':log[-1200:]};save()
  if rc!=0 or 'SHARED_EXEC_PASS'not in log:
   r['status']='PROTOTYPE_CONTRACT_FAILURE';save();status(r['status']);raise SystemExit(log[-1600:])
  for mode in [0,2]:
   z,out=call([D/('obj-'+name)/'Vtb','+img0='+str(D/'context0.hex'),'+img1='+str(D/'context1.hex'),'+waitmode='+str(mode)],'waitmode'+str(mode));assert z==0 and 'SHARED_EXEC_PASS'in out,out[-1500:]
 else:
  assert rc!=0 and 'SELF_CHECK_FAIL'in log,log[-1400:];r['actual_owner_fault_caught']=True;save()
fcntl.flock(lock,fcntl.LOCK_UN)
r['status']='BOUNDED_SHARED_ENGINE_PROGRESS_AND_OWNER_FAULT_PASS_UNQUALIFIED_TIMING';save();status(r['status']);q=json.loads(STATUS.read_text());q['workers']=[];tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(q,separators=(',',':'))+'\n');os.replace(tmp,STATUS);print(r['status'])
