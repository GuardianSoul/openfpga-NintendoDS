#!/usr/bin/env python3
"""First three unchanged CPU gates for defaultoff route-template controller."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,importlib.util,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
FAULT=os.environ.get('CTLROM_FAULT')=='1'
W=pathlib.Path(__file__).resolve().parents[3];D=W/('build/cpu232-ctlrom-fault'if FAULT else'build/cpu232-ctlrom');D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
I=W/'build/cpu232-service-cpu-gates/inputs';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda b:hashlib.sha256(b).hexdigest()
r={'status':'PREPARING','source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=W,text=True).strip(),'sources':{},'inputs':{},'cases':{},'workers':[],'not_production':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(tag,p=None):
 s=json.loads(STATUS.read_text());s.update(phase=tag,receipt=str(D/'result.json'),workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'original-CPU-gates'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
def call(cmd,tag,timeout=300):
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=W,stdout=f,stderr=subprocess.STDOUT);status(tag,p)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=10)
 return rc,(D/(tag+'.log')).read_text()
files=[]
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem','arm_core','arm9_core','arm7_ds']:
 p=S/(n+'.sv');p.write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W));files.append(p)
for n in ['arm9_core_ctlrom','arm_cpu_ctlrom','ctlrom_address','ctlrom_reconstruct','arm9_ctlrom_planes','arm9_ctlrom_packet']:
 p=S/(n+'.sv');p.write_bytes((W/'rtl/arm/study'/(n+'.sv')).read_bytes());files.append(p)
tb=subprocess.check_output(['git','show','232c26ac:sim/arm/tb_arm.sv'],cwd=W,text=True)
tb=tb.replace('  arm_cpu #(',"  arm_cpu_ctlrom #(.CTLROM(1),.FAULT_TEMPLATE("+str(int(FAULT))+"),.ARM9_BURST(1),",1)


p=S/'tb_arm.sv';p.write_text('`timescale 1ns/1ps\n'+tb);files.append(p)
for p in files:r['sources'][p.name]=H(p.read_bytes())
save();lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('CPU_GATES_WAIT_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
policy=json.loads(pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json').read_text());seen=set();other=0
for f in STATUS.parent.glob('*.json'):
 try:
  for q in json.loads(f.read_text()).get('workers',[]):
   if not isinstance(q,dict)or q.get('host')not in ['Desktop','desktop']:continue
   pid=q.get('PID',q.get('pid'))
   if not isinstance(pid,int)or pid in seen or pid==os.getpid()or not pathlib.Path('/proc',str(pid)).exists():continue
   seen.add(pid);other+=int(q.get('peak_new_bytes',q.get('disk_budget_bytes',0)))
 except (ValueError,TypeError,OSError):continue
mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());r['admission']={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'other_growth':other,'policy':policy};save();assert r['admission']['RAM']>=12*(1<<30)and r['admission']['disk']-policy['default_build_peak_new_bytes']-other>=policy['floor_bytes']
V=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator';rc,log=call([V,'--binary','--timing','--assert','--threads','1','-j','4','-Wno-fatal','--top-module','tb_arm','--Mdir',D/'obj','-GA9_CORE=1','-GA9_RF=\"MLAB\"','-GA7_DS=1','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=1711268835','-GA9_XD=2','-GA9_XI=1','-GARM9_WAYS=2','-GEVB=1','-GEARLYD=1',*files],'build');assert rc==0,log[-3000:];fcntl.flock(lock,fcntl.LOCK_UN)
model=D/'obj/Vtb_arm';r['model_sha256']=H(model.read_bytes());save()
spec=importlib.util.spec_from_file_location('suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
cases=[]
for group in ['normal','DENSE']:
 for seed in range(1,26):cases.append((f'{group}-{seed:02d}',[f'+img0={I}/{group}-{seed:02d}.hex','+pc0=02000000','+run=1','+maxcycles=2000000']))
for name,args,desc in suite.tests(str(I),'unused'):cases.append(('ARM-'+name,args))
cases=[(n,a)for n,a in cases if n in ['ARM-bpred9','normal-01','DENSE-01']]
cases.sort(key=lambda q:0 if q[0]=='ARM-bpred9'else 1)
if FAULT:cases=cases[:1]
for name,args in cases:
 for a in args:
  if a.startswith(('+img0=','+img1=')):
   p=pathlib.Path(a.split('=',1)[1]);r['inputs'][str(p)]=H(p.read_bytes())
 rc,log=call([model,*args],name);r['cases'][name]={'exit':rc,'functional':'TEST PASSED'in log,'cycles':re.findall(r'^cycles=(\d+)',log,re.M),'diagnostics':[x for x in log.splitlines()if any(t in x for t in ['FAIL','timeout','result=','Error','Fatal'])]};save();print(name,r['cases'][name],flush=True)
 if FAULT:
  assert 'TEST PASSED'not in log and ('TEST FAILED'in log or'shifter controls differ from E'in log),log[-1600:]
  r['status']='ACTUAL_WRONG_TEMPLATE_FAULT_CAUGHT';save();break
 if rc!=0:r['status']='MODEL_OR_ADAPTER_FAILURE';save();break
else:r['status']='CTLROM_FIRST_THREE_GATES_COMPLETE';save()
status(r['status']);s=json.loads(STATUS.read_text());s['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS)
