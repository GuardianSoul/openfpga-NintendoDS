#!/usr/bin/env python3
from pathlib import Path
import os,json,time,signal,subprocess,resource,hashlib,shutil
D=Path(__file__).resolve().parent;O=D/'out';O.mkdir(exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
s=json.loads((D/'input.json').read_text());
for stale in [O/'run.log',O/'captured-sidecar.hex',D/'captured-sidecar.hex']:
 if stale.exists():stale.unlink()
r={'source':s['source'],'parent_atomic_sha256':s['parent_atomic_sha256'],'PID':os.getpid(),'host':os.uname().nodename,'NI':10,'jobs':1,'threads':1,'stages':[],'status':'RUNNING','peak_scratch':0}
for f,h in s['sha256'].items():assert hashlib.sha256((D/f).read_bytes()).hexdigest()==h,f
def size():return sum(p.stat().st_size for p in D.rglob('*')if p.is_file())
def save():
 p=O/'receipt.tmp';p.write_text(json.dumps(r,indent=2)+'\n');p.replace(O/'receipt.json')
def run(name,cmd,expected_failure=False):
 with(O/(name+'.log')).open('w')as log:
  p=subprocess.Popen(list(map(str,cmd)),cwd=D,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);row={'name':name,'PID':p.pid,'own_process_group':p.pid,'command':list(map(str,cmd))};r['stages'].append(row);save();start=time.monotonic()
  while p.poll()is None:
   used=size();r['peak_scratch']=max(r['peak_scratch'],used)
   if used>s['disk_cap_bytes']or shutil.disk_usage(D).free<s['minimum_free_bytes']or time.monotonic()-start>240:
    row['abort']='own scratch cap' if used>s['disk_cap_bytes'] else 'own free-space floor' if shutil.disk_usage(D).free<s['minimum_free_bytes'] else 'own240s stage time cap';os.killpg(p.pid,signal.SIGTERM);break
   time.sleep(1)
  try:row['exit']=p.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);row['exit']=p.wait()
  row['reaped']=True;save()
 text=(O/(name+'.log')).read_text();assert (row['exit']!=0 if expected_failure else row['exit']==0) and 'abort'not in row,(name,text[-3500:]);return text
V=Path('build/tools/oss-cad-suite/bin/verilator')
cmd=[V,'--cc','--exe','--main','--timing','--assert','--threads','1','-j','1','-O1','-CFLAGS','-O0','-Wno-fatal','--output-split','10000','--top-module','tb_context','--Mdir',O/'obj','-I'+str(D),*[D/Path(f).name for f in s['source_files']],D/'tb_context.sv']
try:
 run('elaborate',cmd)
 # Task-local make rules remove PCH dependencies; installed SDK stays intact.
 # O0 changes only simulation host compilation, not event/RTL semantics.
 (O/'obj/no-pch.mk').write_text('include Vtb_context.mk\n%.o: %.cpp\n\t$(CXX) $(CXXFLAGS) $(CPPFLAGS) -O0 -c -o $@ $<\n')
 run('build',['make','-C',O/'obj','-f','no-pch.mk','-j1','VM_DEFAULT_RULES=0','OPT_FAST=-O0','OPT_SLOW=-O0','OPT_GLOBAL=-O0','Vtb_context'])
 text=run('run',[O/'obj/Vtb_context'],bool(s.get('expected_failure')));assert (s['expected_failure'] in text if s.get('expected_failure') else 'PASS_FULL_CONTEXT_CAPTURE_IMPORT_FIRST_USE'in text and '%Fatal'not in text and '%Error'not in text),text[-4000:]
 r['status']='CAUGHT_ACTUAL_FINALIZE_IMPORT_MUTANT' if s.get('expected_failure') else 'PASS_FULL_RF_CONTEXT_WRAPPER_CAPTURE_FIRST_USE'
except BaseException:r['status']='FAIL';raise
finally:
 if(D/'captured-sidecar.hex').exists():shutil.copyfile(D/'captured-sidecar.hex',O/'captured-sidecar.hex')
 r['peak_scratch']=max(r['peak_scratch'],size());save()
 # All actual sources remain in the thin input bundle, logs/receipts fetch.
 if(O/'obj').exists():shutil.rmtree(O/'obj')
