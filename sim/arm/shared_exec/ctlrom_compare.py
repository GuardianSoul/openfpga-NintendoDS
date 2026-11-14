#!/usr/bin/env python3
"""Reuse retained qualified control binary: architectural+cycle trace comparison."""
import pathlib,json,hashlib,subprocess,os,time,tarfile,importlib.util,resource,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';T=D/'trace-comparison';T.mkdir(exist_ok=True);I=W/'build/cpu232-service-cpu-gates/inputs';P=W/'docs/results/cpu232-service-cpu-gates-20261110';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
with tarfile.open(P/'evidence.tar.gz')as t:old=json.load(t.extractfile('execution/result.json'))
models={'control':W/'build/cpu232-service-cpu-gates/obj/Vtb_arm','retimed':D/'obj/Vtb_arm'}
assert H(models['control'])==old['model_sha256'];assert H(models['retimed'])==json.loads((D/'result.json').read_text())['model_sha256']
f=json.loads((W/'build/cpu232-ctlrom-fault/result.json').read_text());assert f['status']=='ACTUAL_WRONG_TEMPLATE_FAULT_CAUGHT'
r={'control_model_sha256':H(models['control']),'retimed_model_sha256':H(models['retimed']),'control_provenance':str(P/'result.json'),'no_control_rebuild':True,'cases':{}}
def save():(T/'result.json').write_text(json.dumps(r,indent=2)+'\n')
save()
spec=importlib.util.spec_from_file_location('suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
cases=[(n,a)for n,a,d in suite.tests(str(I),'unused')if n in ['bpred9','exc_dual','halt7','stress_dual_c']]
for group in ['normal','DENSE']:cases.append((group+'-01',[f'+img0={I}/{group}-01.hex','+pc0=02000000','+run=1','+maxcycles=2000000']))
for name,args in cases:
 row={}
 for kind,model in models.items():
  base=T/(name+'-'+kind);cmd=[str(model),*args,'+dbg=1',*[f'+{p}{c}={base}.{p}{c}'for p in ['trace','ops']for c in [0,1]]]
  with base.with_suffix('.log').open('w')as log:
   p=subprocess.Popen(cmd,cwd=W,stdout=log,stderr=subprocess.STDOUT)
   s=json.loads(STATUS.read_text());s.update(phase='RETIMED_ARCH_CYCLE_TRACE_'+name,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'retimed-trace-verifier'},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':kind+'-'+name}],updated_at=time.time());tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(tmp,STATUS)
   rc=p.wait(timeout=180)
  assert rc==0 and'TEST PASSED'in base.with_suffix('.log').read_text(),(name,kind)
  row[kind]={p+str(c):H(pathlib.Path(str(base)+'.'+p+str(c)))for p in ['trace','ops']for c in [0,1]}
  bus_debug='\n'.join(x for x in base.with_suffix('.log').read_text().splitlines()if re.match(r'^\d+ (BUS9|RET|RF) ',x))
  row[kind]['bus9_merged_retire_rf_debug_sha256']=hashlib.sha256(bus_debug.encode()).hexdigest()
  assert sum(p.stat().st_size for p in T.iterdir()if p.is_file())<512*(1<<20)
 r['cases'][name]=row;save()
 assert row['control']==row['retimed'],(name,row)
 r['cases'][name]=row;save();print(name,'architectural and cycle traces identical',flush=True)
r['status']='SIX_CASE_BOTH_CONTEXT_ARCHITECTURE_AND_CYCLE_TRACES_IDENTICAL';save();s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(tmp,STATUS)
