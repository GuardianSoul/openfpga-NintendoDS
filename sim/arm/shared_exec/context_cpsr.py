#!/usr/bin/env python3
"""Retain all51 classifications/63MRS probes on both fixed context profiles.
Reuse original pinned images and elastic CSVs; no control rebuild or rerun.
"""
import pathlib,json,os,subprocess,hashlib,time,resource
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];P=W/'build/cpu232-shared-elastic-cpsr-all';D=W/'build/cpu232-context-cpsr';D.mkdir(exist_ok=True);STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();seal=json.loads((W/'docs/results/cpu232-elastic-cpsr-witness-20261110/result.json').read_text());assert H(P/'result.json')==seal['members']['positive/result.json'];old=json.loads((P/'result.json').read_text());r={'status':'RUNNING','prior51_seal':seal['archive_sha256'],'cases':{},'no_control_rebuild_or_run':True}
for profile in ['mlab-async','m10k-sync']:
 model=W/('build/cpu232-context-'+profile+'/obj/Vtb_arm');assert H(model)==json.loads((W/('build/cpu232-context-'+profile+'/result.json')).read_text())['model_sha256'];rows={}
 for name,fixture in old['fixtures'].items():
  image=P/(name+'.hex');assert H(image)==fixture['image_sha256'];gold=P/(name+'-elastic.csv');assert H(gold)==seal['members']['positive/'+gold.name];csv=D/(profile+'-'+name+'.csv');log=D/(profile+'-'+name+'.log')
  with log.open('w')as f:
   p=subprocess.Popen([model,'+img0='+str(image),'+pc0=02000000','+run=1','+maxcycles=2000000','+trace0='+str(csv)],stdout=f,stderr=subprocess.STDOUT,cwd=W)
   s=json.loads(STATUS.read_text());s.update(phase='CONTEXT_MRS_'+profile,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'63-MRS-regression','peak_new_bytes':1073741824},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':name}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');assert t.stat().st_size<=2048;t.replace(STATUS)
   rc=p.wait(timeout=90)
  assert rc==0 and'TEST PASSED'in log.read_text(),(profile,name)
  assert H(csv)==H(gold),(profile,name,'raw CSV differs')
  rows[name]={'all_arch_rows_byte_identical':True,'sha256':H(csv),'full32_MRS':fixture['models']['elastic']['MRS_full32']}
 r['cases'][profile]=rows;(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(profile,'all21fixtures/63full32MRS/all51dispositions preserved; allCSVbytes identical',flush=True)
r['status']='BOTH_FIXED_PROFILES_ALL51_AND63_FULL32_MRS_UNCHANGED_FULL_CSV_BYTE_MATCH';(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
