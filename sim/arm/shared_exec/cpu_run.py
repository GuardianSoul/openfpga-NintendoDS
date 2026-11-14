#!/usr/bin/env python3
"""Original CPU suite with clk2 retirement sampling for the shared engine."""
import pathlib,subprocess,os,json,hashlib,fcntl,resource,time,shutil,importlib.util,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
FAULT=os.environ.get('SHARED_CPU_FAULT')=='1'
W=pathlib.Path(__file__).resolve().parents[3];D=W/('build/cpu232-shared-cpu-fault'if FAULT else'build/cpu232-shared-cpu');D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
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
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem']:
 p=S/(n+'.sv');p.write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W));files.append(p)
for n in ['arm_shared_core','arm_dual_shared','arm_cpu_shared']:
 p=S/(n+'.sv');p.write_bytes((W/'rtl/arm/study'/(n+'.sv')).read_bytes());files.append(p)
if FAULT:
 p=S/'arm_dual_shared.sv';s=p.read_text();needle='dq[cd_tid]<=current_d;';assert s.count(needle)==1;p.write_text(s.replace(needle,"dq[cd_tid]<=current_d ^ (91'd1 << 50);"))
 r['actual_mutation']='queued native data address bit2 flipped; unchanged semantic replay checker'
tb=subprocess.check_output(['git','show','232c26ac:sim/arm/tb_arm.sv'],cwd=W,text=True)
a=tb.index('  arm_cpu #(');b=tb.index('\n  );',a)+len('\n  );');inst=tb[a:b];inst=inst[inst.index(' dut (')+1:];inst='  arm_cpu_shared '+inst
inst=inst.replace('.clk(clk)', '.clk_sys(clk), .clk2(clk2)').replace('.b9_req(b9_req)',".b9_n8(),.b9_tmr(),.b9_wnext(1'b0),.dg_fill(),.dbg_halt(),.b9_req(b9_req)");tb=tb[:a]+inst+tb[b:]
tb=tb.replace("logic clk = 1'b0;","logic clk = 1'b0;\n  logic clk2 = 1'b1; always #2.5 clk2=~clk2;")
tb=tb.replace("    rst = 1'b0;","    #0.1; rst = 1'b0;")
a=tb.index('  generate if (A7_DS) begin : g_lanes');b=tb.index('  end else begin : g_lanes1',a);tb=tb[:a]+'  generate if (1) begin : g_shared_lanes'+tb[b+len('  end else begin : g_lanes1'):]
a=tb.index('  // Trace, lockstep compare and test monitors');tb=tb[:a]+tb[a:].replace('always @(posedge clk)', 'always @(posedge clk2)',1)
tb=tb.replace('      cycle = cycle + 1;','      if(clk) begin\n      cycle = cycle + 1;').replace("      if (wake7) halted7 = 1'b0;","      if (wake7) halted7 = 1'b0;\n      end")
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
V=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator';rc,log=call([V,'--binary','--timing','--assert','--threads','1','-j','4','-Wno-fatal','--top-module','tb_arm','--Mdir',D/'obj',*files],'build');assert rc==0,log[-3000:];fcntl.flock(lock,fcntl.LOCK_UN)
model=D/'obj/Vtb_arm';r['model_sha256']=H(model.read_bytes());save()
spec=importlib.util.spec_from_file_location('suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
cases=[]
for group in ['normal','DENSE']:
 for seed in range(1,26):cases.append((f'{group}-{seed:02d}',[f'+img0={I}/{group}-{seed:02d}.hex','+pc0=02000000','+run=1','+maxcycles=2000000']))
for name,args,desc in suite.tests(str(I),'unused'):cases.append(('ARM-'+name,args))
if FAULT:cases=cases[:1]
for name,args in cases:
 for a in args:
  if a.startswith(('+img0=','+img1=')):
   p=pathlib.Path(a.split('=',1)[1]);r['inputs'][str(p)]=H(p.read_bytes())
 rc,log=call([model,*args],name);r['cases'][name]={'exit':rc,'functional':'TEST PASSED'in log,'cycles':re.findall(r'^cycles=(\d+)',log,re.M),'diagnostics':[x for x in log.splitlines()if any(t in x for t in ['FAIL','timeout','result=','Error','Fatal'])]};save();print(name,r['cases'][name],flush=True)
 if FAULT:
  assert rc!=0 and'live data request changed while unanswered'in log,log[-1600:]
  r['status']='ACTUAL_QUEUED_ADDRESS_MUTATION_CAUGHT';save();break
 if rc!=0:r['status']='MODEL_OR_ADAPTER_FAILURE';save();break
else:r['status']='ORIGINAL_CPU_SUITE_SCREEN_COMPLETE_NOT_EQUIVALENCE';save()
status(r['status']);s=json.loads(STATUS.read_text());s['workers']=[];t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS)
