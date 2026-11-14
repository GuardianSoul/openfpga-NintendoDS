#!/usr/bin/env python3
"""Qualify only the #2192 import placement fix; never rerun baseline CPUs."""
import pathlib,subprocess,json,hashlib,os,tempfile,tarfile,shutil,time,fcntl,resource
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-compact-header-fix';D.mkdir(exist_ok=True)
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
H=lambda b:hashlib.sha256(b).hexdigest()
P=W/'docs/results/cpu232-compact-packets-20261110';old=json.loads((P/'result.json').read_text())
r={'status':'CHECKING_COMPILER_ONLY_IMPORT_MOVE','prior_249_receipt_sha256':H((P/'result.json').read_bytes()),'prior_249_archive_sha256':old['archive_sha256'],'native2192':'Quartus Standard10170 at second module-header import arm_shared_compact.sv9; beforearea, CPUpriceUNMEASURED','stages':[],'RTL_sha256':{},'no_baseline_cpu_or_game_rebuild_or_rerun':True}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def call(cmd,tag):
 with(D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=W,stdout=f,stderr=subprocess.STDOUT)
  s=json.loads(STATUS.read_text());s.update(phase='COMPACT_HEADER_'+tag,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'compiler-only-fix','peak_new_bytes':134217728},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');assert t.stat().st_size<2048;t.replace(STATUS)
  try:rc=p.wait(timeout=90)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);raise
 r['stages'].append({'tag':tag,'command':list(map(str,cmd)),'exit':rc,'log_sha256':H((D/(tag+'.log')).read_bytes())});save();return rc
assert H((P/'evidence.tar.gz').read_bytes())==old['archive_sha256']
with tarfile.open(P/'evidence.tar.gz')as t:
 for name,h in old['members'].items():assert H(t.extractfile(name).read())==h,name
 # Run the immutable verifier on its own pinned RTL, not on the compiler-fixed file.
 with tempfile.TemporaryDirectory(prefix='cpu-compact-prior-')as tmp:
  root=pathlib.Path(tmp);dst=root/'docs/results/cpu232-compact-packets-20261110';dst.mkdir(parents=True)
  for n in ['result.json','evidence.tar.gz','verify.py']:shutil.copyfile(P/n,dst/n)
  for n,h in old['RTL_sha256'].items():
   data=t.extractfile('rtl/'+pathlib.Path(n).name).read();assert H(data)==h
   p=root/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
  assert call(['python3',dst/'verify.py'],'prior249-verifier')==0
 names=[]
 for n,h in old['RTL_sha256'].items():
  p=W/n;current=p.read_bytes();before=t.extractfile('rtl/'+p.name).read()
  if p.name=='arm_shared_compact.sv':
   declaration=b'import arm_compact_pkg::*;'
   assert before.count(declaration)==current.count(declaration)==1
   assert b'module arm_shared_compact import arm_pkg::*; import arm_compact_pkg::*; #('in before
   assert b');\n  import arm_compact_pkg::*;\n'in current
   # Removing the one moved declaration and whitespace yields identical tokens.
   norm=lambda b:b''.join(b.replace(declaration,b'').split())
   assert norm(before)==norm(current)
   expected=before.replace(b'module arm_shared_compact import arm_pkg::*; import arm_compact_pkg::*; #(',b'module arm_shared_compact import arm_pkg::*; #(',1).replace(b');\n\n  // ---------------------------------------------------------------- state',b');\n  import arm_compact_pkg::*;\n\n  // ---------------------------------------------------------------- state',1)
   assert current==expected
   r['normalized_source_sha256']=H(norm(current))
  else:assert current==before,n
  r['RTL_sha256'][n]=H(current);names.append(p)
 r['only_RTL_change']='One arm_compact_pkg import moved from module header into module body before its first use; all other RTL bytes identical.'
# Re-generation must preserve the exact fixed modules.
assert call(['python3',W/'sim/arm/shared_exec/compact_generate.py'],'generator')==0
for n,h in r['RTL_sha256'].items():assert H((W/n).read_bytes())==h
assert call(['python3',W/'tools/ds/test_qlint_header_import.py'],'qlint-regression')==0
assert call(['python3',W/'tools/ds/qlint.py',*names],'qlint-new-modules')==0
before=D/'old-rejected-header.sv';before.write_bytes(subprocess.check_output(['git','show','3d680cd8:rtl/arm/study/arm_shared_compact.sv'],cwd=W))
assert call(['python3',W/'tools/ds/qlint.py',before],'qlint-old-header-caught')==1
assert 'second module-header import'in(D/'qlint-old-header-caught.log').read_text()
T=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin'
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());assert int(mi['MemAvailable'].split()[0])*1024>=12*(1<<30)
for tag,define in [('codec',[]),('codec-mask-fault',['-DCOMPACT_MUTATE_MASK'])]:
 model=D/(tag+'.vvp')
 assert call([T/'iverilog','-g2012',*define,'-s','tb','-o',model,W/'rtl/arm/arm_pkg.sv',W/'rtl/arm/study/arm_compact_pkg.sv',W/'sim/arm/shared_exec/compact_codec_tb.sv'],tag+'-compile')==0
 rc=call([T/'vvp',model],tag)
 assert (rc==0 and 'COMPACT_CODEC_PASS'in(D/(tag+'.log')).read_text())if tag=='codec'else(rc!=0 and 'COMPACT_MASK_FAIL'in(D/(tag+'.log')).read_text())
S=D/'source';S.mkdir(exist_ok=True);files=[]
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem']:
 p=S/(n+'.sv');p.write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W));files.append(p)
files.insert(1,W/'rtl/arm/study/arm_compact_pkg.sv')
files += [W/'rtl/arm/study'/(n+'.sv') for n in ['arm_context_bank','arm_shared_compact','arm_dual_compact','arm_cpu_compact']]
assert call([T/'verilator','--lint-only','--timing','--assert','-j','4','--threads','1','-Wno-fatal','--top-module','arm_cpu_compact',*files],'fullgraph-verilator-lint')==0
fcntl.flock(lock,fcntl.LOCK_UN)
r['status']='COMPILER_ONLY_IMPORT_MOVE_TOKEN_IDENTITY_CODEC_FAULT_LINT_PASS';save()
s=json.loads(STATUS.read_text());s.update(phase=r['status'],receipt=str(D/'result.json'),workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
print(r['status'])
