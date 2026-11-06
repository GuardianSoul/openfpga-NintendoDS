#!/usr/bin/env python3
"""Prepare only by default. Execute only after Root assigns a new lease."""
from pathlib import Path
import argparse,hashlib,json,os,resource,shutil,subprocess
R=Path(__file__).resolve().parents[3]
MODES={'healthy':0,'wrong-field':1,'bad-phase':2,'phase-guard-mutant':3,'partial-witness':4,'pending':5,'active':6,'missing-reads':7,'missing-profile':8,'capture-conflict':9,'poison-held':10}
p=argparse.ArgumentParser();p.add_argument('--mode',choices=MODES,default='healthy');p.add_argument('--execute',action='store_true');p.add_argument('--lease');a=p.parse_args()
if a.execute and not a.lease:p.error('--execute requires the explicit Root-assigned --lease name')
D=R/'build/clip16-import-v1'/a.mode;D.mkdir(parents=True,exist_ok=True)
files=['rtl/gpu3d/gpu3d_gxu_pkg.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/gpu3d/gpu3d_gxdiv.sv','rtl/gpu3d/gpu3d_gxvfin.sv','sim/gpu3d/clip_import/tb.sv','sim/pocket_ds/runtime_import_clip_store.svh']
for f in files:shutil.copyfile(R/f,D/Path(f).name)
f=D/'runtime_import_clip_store.svh';s=f.read_text()
if a.mode=='wrong-field':
 needle='g_field[0].u_mem.mem[g]=words[0][g]';assert s.count(needle)==1;s=s.replace(needle,'g_field[0].u_mem.mem[g]=words[1][g]',1)
elif a.mode=='phase-guard-mutant':
 needle='assert(held && post_m &&';assert s.count(needle)==1;s=s.replace(needle,"assert(held && 1'b1 &&",1)
f.write_text(s)
if a.mode=='missing-profile':
 f=D/'tb.sv';s=f.read_text();needle=' `define RUNTIME_CLIP_STORE_ENABLED\n';assert s.count(needle)==1;f.write_text(s.replace(needle,' // Deliberately missing enabled-profile macro\n',1))
T=Path('build/tools/oss-cad-suite/bin')
cmd=[T/'verilator','--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--top-module','tb_clip_import','-GMODE='+str(MODES[a.mode]),'--Mdir',D/'obj','-I'+str(D),*[D/Path(f).name for f in files[:-1]]]
r={'source':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),'mode':a.mode,'source_only':not a.execute,'lease':a.lease,'NI':10,'jobs':1,'threads':1,'command':list(map(str,cmd)),'sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest()for f in D.iterdir()if f.is_file()and f.suffix in ['.sv','.svh']},'stages':[],'status':'PREPARED_NOT_EXECUTED'}
def save():
 p=D/'receipt.tmp';p.write_text(json.dumps(r,indent=2)+'\n');p.replace(D/'receipt.json')
save()
if not a.execute:print('PREPARED_NOT_EXECUTED',a.mode,str(D/'receipt.json'));raise SystemExit(0)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));r['PID']=os.getpid();r['status']='RUNNING';save()
def stage(name,cmd):
 with (D/(name+'.log')).open('w')as log:
  child=subprocess.Popen(list(map(str,cmd)),cwd=D,stdout=log,stderr=subprocess.STDOUT);row={'name':name,'PID':child.pid};r['stages'].append(row);save()
  try:rc=child.wait(timeout=180)
  except subprocess.TimeoutExpired:child.terminate();rc=child.wait(timeout=5);row['timeout']=True
  row.update(exit=rc,reaped=True);save()
 return rc,(D/(name+'.log')).read_text()
rc,log=stage('build',cmd);assert rc==0,log[-3000:]
rc,log=stage('run',[D/'obj/Vtb_clip_import'])
if a.mode in ['healthy','poison-held']:assert rc==0 and 'PASS_IMPORT_FIRST_USE' in log and '%Fatal' not in log and '%Error' not in log,log[-3000:]
else:
 markers={'wrong-field':'IMPORT_PUBLIC_','bad-phase':'CLIP_IMPORT_PHASE_BARRIER','phase-guard-mutant':'IMPORT_PHASE_GUARD_MUTANT_ESCAPED_REJECTION','partial-witness':'CLIP_IMPORT_INCOMPLETE_WITNESS','pending':'CLIP_IMPORT_PENDING_WRITE','active':'CLIP_IMPORT_ACTIVE_SNAPSHOT','missing-reads':'CLIP_IMPORT_INCOMPLETE_WITNESS','missing-profile':'CLIP_IMPORT_PROFILE_MISMATCH','capture-conflict':'CLIP_CAPTURE_REPLICA_CONFLICT'}
 assert rc!=0 and markers[a.mode] in log,log[-3000:]
if a.mode=='poison-held':assert 'PASS_HELD_LIVENESS' in log,log[-3000:]
r['status']='PASS_HELD_LIVENESS_WITNESS' if a.mode=='poison-held' else 'PASS_FIRST_USE' if a.mode=='healthy' else 'CAUGHT_ACTUAL_MUTANT' if a.mode in ['wrong-field','phase-guard-mutant'] else 'PASS_REJECTION';save();print(r['status'],a.mode,log[-700:])
