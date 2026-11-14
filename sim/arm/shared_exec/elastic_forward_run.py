#!/usr/bin/env python3
"""Registered ARM7 port regression: corrected link versus previous actual RTL."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-forward';D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
H=lambda b:hashlib.sha256(b).hexdigest()
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
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb']:
 p=S/(n+'.sv');p.write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W));files.append(p)
for rel in ['rtl/arm/study/arm_shared_elastic.sv','sim/arm/shared_exec/elastic_forward_tb.sv']:
 p=S/pathlib.Path(rel).name;p.write_bytes((W/rel).read_bytes());files.append(p)
for c,value in [(0,85),(1,102)]:
 text=f""".syntax unified
.arch armv5te
.arm
.global _start
_start:
 mov r0,#0x800
 mov r10,#{value}
 ldr r1,[r0]
 add r11,r10,#3
 cmp r11,#{value+3}
 bne fail
 mov r4,#7
 mov r5,#9
 muls r6,r4,r5
 mrs r7,cpsr
 and r7,r7,#0xc0000000
 cmp r7,#0
 bne fail
 cmp r6,#63
 bne fail
 mov r4,#0
 umulls r6,r8,r4,r5
 mrs r7,cpsr
 and r7,r7,#0xc0000000
 cmp r7,#0x40000000
 bne fail
 mov r4,#0x80000000
 mov r5,#1
 muls r6,r4,r5
 mrs r7,cpsr
 and r7,r7,#0xc0000000
 cmp r7,#0x80000000
 bne fail
 mov r0,#0
 b end
fail:
 mov r0,#1
end:
 mov r2,#0x0f000000
 str r0,[r2]
 b .
"""
 p=D/('context'+str(c));p.with_suffix('.s').write_text(text)
 subprocess.run(['clang','--target=armv5te-none-eabi','-c',p.with_suffix('.s'),'-o',p.with_suffix('.o')],check=True)
 subprocess.run(['ld.lld','-Ttext=0x02000000','--oformat=binary',p.with_suffix('.o'),'-o',p.with_suffix('.bin')],check=True)
 subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',p.with_suffix('.hex'),str(p.with_suffix('.bin'))+'@0x0'],check=True,stdout=subprocess.DEVNULL)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('FORWARD_WAIT_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)

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
for name,fault in [('candidate',0),('unsafe-late-bypass',1)]:
 admission();rc,log=call([V,'--binary','--timing','--assert','--threads','1','-j','4','-Wno-fatal','--top-module','elastic_forward_tb','-GFAULT_FORWARD='+str(fault),'--Mdir',D/('obj-'+name),*files],'build-'+name);assert rc==0,log[-2000:]
 model=D/('obj-'+name)/'Velastic_forward_tb'
 rc,log=call([model,'+img0='+str(D/'context0.hex'),'+img1='+str(D/'context1.hex')],name)
 if not fault:assert rc==0 and 'ELASTIC_FORWARD_PASS' in log,log[-2400:]
 else:assert rc!=0 and 'FORWARD_PROGRAM_FAIL' in log,log[-2400:]
 print(name,log[-500:],flush=True)
fcntl.flock(lock,fcntl.LOCK_UN)
r['status']='FULL_ENGINE_STALL_FORWARD_PASS_ACTUAL_UNSAFE_BYPASS_CAUGHT';save();status(r['status']);q=json.loads(STATUS.read_text());q['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(q,separators=(',',':'))+'\n');os.replace(t,STATUS)
