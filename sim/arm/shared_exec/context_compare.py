#!/usr/bin/env python3
"""Complete fixed-store vs retained15c: exact cycles, both RF/CPSR/PC and bus.
No control rebuild. Both async and sync service models are checked.
"""
import pathlib,json,os,subprocess,hashlib,re,time,resource,importlib.util
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-context-equivalence';D.mkdir(exist_ok=True);I=W/'build/cpu232-service-cpu-gates/inputs';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
models={'retained15c':W/'build/cpu232-shared-elastic-cpu/obj/Vtb_arm','mlab-async':W/'build/cpu232-context-mlab-async/obj/Vtb_arm','m10k-sync':W/'build/cpu232-context-m10k-sync/obj/Vtb_arm'}
old=W/'build/cpu232-shared-elastic-cpu/result.json';seal=json.loads((W/'docs/results/cpu232-shared-elastic-20261110/result.json').read_text());assert H(old)==seal['members']['cpu/result.json']
for k,p in models.items():
 receipt=old if k=='retained15c'else W/('build/cpu232-context-'+k+'/result.json');assert H(p)==json.loads(receipt.read_text())['model_sha256']
r={'status':'RUNNING','no_control_rebuild':True,'models':{k:H(p)for k,p in models.items()},'cases':{}}
spec=importlib.util.spec_from_file_location('suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
cases=[(n,a)for n,a,d in suite.tests(str(I),'unused')if n in ['bpred9','exc_dual','halt7','stress_dual_c']]
for g in ['normal','DENSE']:cases.append((g+'-01',[f'+img0={I}/{g}-01.hex','+pc0=02000000','+run=1','+maxcycles=2000000']))
for name,args in cases:
 row={}
 for kind,model in models.items():
  base=D/(name+'-'+kind);cmd=[str(model),*args,'+dbg=1',*[f'+{p}{c}={base}.{p}{c}'for p in ['trace','ops']for c in [0,1]]]
  with base.with_suffix('.log').open('w')as f:
   child=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,cwd=W)
   s=json.loads(STATUS.read_text());s.update(phase='CONTEXT_EQ_'+name+'_'+kind,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'full-context-equivalence','peak_new_bytes':1073741824},{'host':'Desktop','PID':child.pid,'NI':os.getpriority(os.PRIO_PROCESS,child.pid),'job':kind}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');assert t.stat().st_size<=2048;t.replace(STATUS)
   rc=child.wait(timeout=90)
  text=base.with_suffix('.log').read_text();assert rc==0 and'TEST PASSED'in text,(name,kind,text[-1500:])
  row[kind]={p+str(c):H(pathlib.Path(str(base)+'.'+p+str(c)))for p in ['trace','ops']for c in [0,1]};row[kind]['cycle']=re.findall(r'^cycles=(\d+)',text,re.M);row[kind]['BUS_RET_RF']=hashlib.sha256('\n'.join(x for x in text.splitlines()if re.match(r'^\d+ (BUS9|RET|RF) ',x)).encode()).hexdigest()
  if kind!='retained15c':assert row[kind]==row['retained15c'],(name,kind,row)
  assert sum(p.stat().st_size for p in D.iterdir()if p.is_file())<512*(1<<20)
 r['cases'][name]=row;(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(name,'both profiles exactbothcontext arch/cycle/bus',flush=True)
r['status']='SIX_CASE_BOTH_PROFILES_BOTH_CONTEXT_PC_CPSR_RF_CYCLE_BUS_BYTE_EQUIVALENT';(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
