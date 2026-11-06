#!/usr/bin/env python3
"""One D1 worker, current production RTL; adapter first-use/fault regression."""
import datetime,hashlib,json,os,resource,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[3];D=R/'build/cull-import26';O=D/'out';O.mkdir(exist_ok=True)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
V=Path('build/tools/oss-cad-suite/bin/verilator')
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
s=json.loads((D/'input.json').read_text())
for f,h in s['sha256'].items():assert hashlib.sha256((D/f).read_bytes()).hexdigest()==h,f
rec={'source':s['source'],'controller_PID':os.getpid(),'NI':10,'jobs':1,'threads':1,'stages':[],'status':'RUNNING'}
def save():
 (O/'execution.json').write_text(json.dumps(rec,indent=2)+'\n')
def run(label,cmd,marker=None,fail=False):
 with(O/(label+'.log')).open('w')as log:
  p=subprocess.Popen(list(map(str,cmd)),cwd=D,stdout=log,stderr=subprocess.STDOUT)
  row={'label':label,'PID':p.pid,'command':list(map(str,cmd))};rec['stages'].append(row);save()
  d=json.loads(S.read_text());d['phase']='D1 cull import26 '+label;d['worker']={'active':True,'host':'Desktop','PID':os.getpid(),'child_PID':p.pid,'lease':'D1','nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=S.with_suffix('.import26.tmp');t.write_text(json.dumps(d,separators=(',',':'))+'\n');t.replace(S)
  row['exit']=p.wait();save()
 text=(O/(label+'.log')).read_text()
 assert (row['exit']!=0 if fail else row['exit']==0),(label,text[-3000:])
 if marker:assert marker in text,(label,text[-3000:])
 return text
try:
 run('elaborate',[V,'--cc','--exe','--main','--timing','--assert','--threads','1','-j','1','-O1','-CFLAGS','-O0','-Wno-fatal','--output-split','10000','--top-module','tb_cull_import','--Mdir',O/'obj','-I'+str(D),*[D/Path(f).name for f in s['source_files']],D/'tb_cull_import.sv'])
 (O/'obj/no-pch.mk').write_text('include Vtb_cull_import.mk\n%.o: %.cpp\n\t$(CXX) $(CXXFLAGS) $(CPPFLAGS) -O0 -c -o $@ $<\n')
 run('build',['make','-C',O/'obj','-f','no-pch.mk','-j1','VM_DEFAULT_RULES=0','OPT_FAST=-O0','OPT_SLOW=-O0','OPT_GLOBAL=-O0','Vtb_cull_import'])
 for mode in range(5):
  text=run('mode'+str(mode),[O/'obj/Vtb_cull_import','+mode='+str(mode)],'CULL_IMPORT_PENDING_CONFLICT'if mode==4 else 'CAUGHT_ACTUAL_CULL_IMPORT_FAULT'if mode>1 else 'PASS_CULL_IMPORT_FIRST_USE',mode==4)
  if mode==4:assert 'REPAIRED'not in text
 rec['status']='PASS_CHANGED_CULL_IMPORT_ONLY'
except BaseException:
 rec['status']='FAIL';raise
finally:
 save();d=json.loads(S.read_text());d['worker']['active']=False;d['phase']='cull import26 '+rec['status'];t=S.with_suffix('.import26.tmp');t.write_text(json.dumps(d,separators=(',',':'))+'\n');t.replace(S)
print(rec['status'],flush=True)
