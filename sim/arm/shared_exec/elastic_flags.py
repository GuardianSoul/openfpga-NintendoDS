#!/usr/bin/env python3
"""MRS witnesses for MULS/UMULLS flags on retained original and new full CPU."""
import os,subprocess,json,hashlib,tarfile,pathlib,resource
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-forward';out=D/'native-multiply-flags.hex'
subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',out,str(D/'context0.bin')+'@0x02000000'],check=True,stdout=subprocess.DEVNULL)
with tarfile.open(W/'docs/results/cpu232-service-cpu-gates-20261110/evidence.tar.gz')as t:old=json.load(t.extractfile('execution/result.json'))
models={'retained-original':W/'build/cpu232-service-cpu-gates/obj/Vtb_arm','complete-elastic':W/'build/cpu232-shared-elastic-cpu/obj/Vtb_arm'}
r={}
for name,model in models.items():
 h=hashlib.sha256(model.read_bytes()).hexdigest();assert h==(old['model_sha256']if name=='retained-original'else json.loads((W/'build/cpu232-shared-elastic-cpu/result.json').read_text())['model_sha256'])
 with(D/(name+'-flags.log')).open('w')as f:p=subprocess.run([str(model),'+img0='+str(out),'+pc0=02000000','+run=1','+maxcycles=20000'],stdout=f,stderr=subprocess.STDOUT,timeout=30)
 text=(D/(name+'-flags.log')).read_text();assert p.returncode==0 and 'TEST PASSED'in text,text[-1200:]
 r[name]={'model_sha256':h,'PASS':True,'no_rebuild':True};print(name,text[-350:],flush=True)
(D/'native-flags-result.json').write_text(json.dumps(r,indent=2)+'\n')
