#!/usr/bin/env python3
"""Reuse bounded prototype model for unchanged80-case suite; no new build."""
import pathlib,json,hashlib,subprocess,os,time,tarfile,importlib.util,resource,re
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-retimed';F=D/'full-suite';F.mkdir(exist_ok=True);I=W/'build/cpu232-service-cpu-gates/inputs';P=W/'docs/results/cpu232-service-cpu-gates-20261110';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
model=D/'obj/Vtb_arm';gate=json.loads((D/'result.json').read_text());assert H(model)==gate['model_sha256'];assert len(gate['cases'])==3 and all(r['functional']for r in gate['cases'].values())
fault=json.loads((W/'build/cpu232-retimed-fault/result.json').read_text());assert fault['status']=='ACTUAL_SHARED_EXEC_OWNER_FAULT_CAUGHT';assert {k:v for k,v in fault['sources'].items()if k!='tb_arm.sv'}=={k:v for k,v in gate['sources'].items()if k!='tb_arm.sv'}
assert (W/'build/cpu232-retimed-fault/source/tb_arm.sv').read_bytes().replace(b'.FAULT_OWNER(1)',b'.FAULT_OWNER(0)')==(D/'source/tb_arm.sv').read_bytes()
assert json.loads((D/'trace-comparison/result.json').read_text())['status']=='SIX_CASE_BOTH_CONTEXT_ARCHITECTURE_AND_CYCLE_TRACES_IDENTICAL'
with tarfile.open(P/'evidence.tar.gz')as t:old=json.load(t.extractfile('execution/result.json'))
r={'status':'RUNNING','model_sha256':H(model),'sources':gate['sources'],'cases':{},'inherited_failures':[],'new_failures':[],'cycle_changes':[],'input_sha256':{},'control_archive_sha256':H(P/'evidence.tar.gz')}
def save():(F/'result.json').write_text(json.dumps(r,indent=2)+'\n')
spec=importlib.util.spec_from_file_location('suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
cases=[]
for group in ['normal','DENSE']:
 for seed in range(1,26):cases.append((f'{group}-{seed:02d}',[f'+img0={I}/{group}-{seed:02d}.hex','+pc0=02000000','+run=1','+maxcycles=2000000'],old[group][str(seed)]))
for name,args,desc in suite.tests(str(I),'unused'):cases.append(('ARM-'+name,args,old['tb_arm'][name]))
for name,args,before in cases:
 for a in args:
  if a.startswith(('+img0=','+img1=')):
   p=pathlib.Path(a.split('=',1)[1]);hv=H(p);assert hv==old['inputs'][p.name];r['input_sha256'][p.name]=hv
 with(F/(name+'.log')).open('w')as log:
  p=subprocess.Popen([str(model),*args],cwd=W,stdout=log,stderr=subprocess.STDOUT)
  s=json.loads(STATUS.read_text());s.update(phase='RETIMED_FULL_'+name,receipt=str(F/'result.json'),workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'retimed80gate'},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':name}],updated_at=time.time());tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(tmp,STATUS)
  try:rc=p.wait(timeout=180)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);raise
 text=(F/(name+'.log')).read_text();row={'exit':rc,'functional':'TEST PASSED'in text,'cycles':re.findall(r'^cycles=(\d+)',text,re.M),'diagnostics':[x for x in text.splitlines()if any(t in x for t in ['FAIL','timeout','result=','Error','Fatal'])]};r['cases'][name]=row
 if not row['functional']:(r['new_failures']if before['functional']else r['inherited_failures']).append(name)
 if row['cycles']!=before['cycles']:r['cycle_changes'].append({'case':name,'before':before['cycles'],'after':row['cycles']})
 save();assert sum(p.stat().st_size for p in F.iterdir()if p.is_file())<512*(1<<20);print(name,row,flush=True)
 assert rc==0,(name,row)
r['status']='RETIMED80_COMPLETE_WITH_INHERITED_FAILURES';save();s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(tmp,STATUS)
