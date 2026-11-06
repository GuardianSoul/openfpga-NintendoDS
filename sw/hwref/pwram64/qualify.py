#!/usr/bin/env python3
"""Serial frozen-ROM Census qualification, one child at nice10/one thread.
Run in a small staging folder containing ROM, layout.json and check.py.
No SDK requirement, card operations or timing acceptance.
"""
import argparse,datetime,hashlib,json,os,resource,shutil,struct,subprocess,time
from pathlib import Path
import check
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=Path('qualification'));p.add_argument('--frames',type=int,default=1200);p.add_argument('--resume-run',action='store_true');a=p.parse_args();D=a.output.resolve();D.mkdir(exist_ok=a.resume_run)
resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
L=json.loads(Path('layout.json').read_text());rom=Path('pwram64.nds').resolve();assert check.SHA(rom.read_bytes())==L['rom_sha256']
census=Path('/home/user/Git/NDS_Pocket-census23-cli/bin/census23');assert check.SHA(census.read_bytes())=='2ff706841070a5a40ae401b7e92b25c72bb5ba2accae2469423f7d00cb23c86d'
q=dict(state='RUNNING',scope='Private64KiB external-placement software contract only; no DS timing or card staging',ROM_SHA256=L['rom_sha256'],Census_SHA256=check.SHA(census.read_bytes()),cases={},workers=[],external_SHA256={n:check.SHA(Path('/home/user/Git/NDS_Pocket/roms',n+'.bin').read_bytes())for n in ['bios7','bios9','firmware']})
if a.resume_run:
 q=json.loads((D/'receipt.json').read_text());assert q['ROM_SHA256']==L['rom_sha256'];q.setdefault('fixture_retries',[]).append('Interrupted seed progress legitimately gains the remaining12 groups; preserve qualified normal/resume/interrupted outputs, resume only missing gates.')
def save():
 t=D/'receipt.json.tmp';t.write_text(json.dumps(q,indent=2)+'\n');t.replace(D/'receipt.json')
def run(cmd,tag):
 assert os.getloadavg()[0]<24
 with (D/(tag+'.log')).open('w')as f:
  proc=subprocess.Popen(list(map(str,cmd)),stdout=f,stderr=subprocess.STDOUT,env=dict(os.environ,OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1'))
  row=dict(phase=tag,host='zero-laptop',PID=proc.pid,controller=os.getpid(),NI=os.getpriority(os.PRIO_PROCESS,proc.pid),jobs=1,threads=1,starttime=Path('/proc',str(proc.pid),'stat').read_text().rsplit(')',1)[1].split()[19]);q['workers'].append(row);save();print(json.dumps(row),flush=True);t=time.monotonic()
  try:row['exit']=proc.wait(timeout=55)
  except subprocess.TimeoutExpired:proc.terminate();row['exit']=proc.wait(timeout=5);row['timeout']=True
  row.update(reaped=True,seconds=time.monotonic()-t);save();assert row['exit']==0 and not row.get('timeout'),tag
info=json.loads(subprocess.check_output([census,'--build-info'],text=True));assert info['census_mode']=='ds-rules-23'and info['compiled_rule_count']==info['declared_rule_count']==23
assert set(info['frontend_capabilities'])>=set(['final-state','final-save','save-state-save']);q['build_info']=info;save()
relative=Path('hwref/pwram64-v1')
def execute(name,seed=None,prepare=None,changed=None):
 if name in q['cases']:
  target=D/name/'sd'/relative
  assert {f.name:check.SHA(f.read_bytes())for f in target.iterdir()if f.is_file()}==q['cases'][name]['outputs_SHA256']
  print('retained qualified case '+name,flush=True);return target
 d=D/name;d.mkdir();sd=d/'sd';sd.mkdir();target=sd/relative;target.mkdir(parents=True);script=d/'script.txt';script.write_text('')
 if seed:
  for f in seed.iterdir():
   if f.is_file():shutil.copyfile(f,target/f.name)
 if prepare:prepare(target)
 before={f.name:check.SHA(f.read_bytes())for f in target.iterdir()if f.is_file()}
 cmd=[census,'--expect-mode','ds-rules-23','--require-capabilities','final-state,final-save,save-state-save']
 for n in ['bios9','bios7','firmware']:cmd+=['--'+n,'/home/user/Git/NDS_Pocket/roms/'+n+'.bin']
 cmd+=['--rom',changed or rom,'--script',script,'--out',d/'run','--frames',str(a.frames),'--shot-every',str(a.frames),'--sd-dir',sd,'--sd-mb','64']
 run(cmd,name)
 summary=json.loads((d/'run/summary.json').read_text());assert summary['census_mode']=='ds-rules-23'and summary['compiled_rule_count']==summary['declared_rule_count']==23
 comp=target/'pwram64_v1_completion.txt';completion=dict(x.split('=',1)for x in comp.read_text().splitlines())if comp.exists()else None
 q['cases'][name]=dict(completion=completion,seed_SHA256=before,outputs_SHA256={f.name:check.SHA(f.read_bytes())for f in target.iterdir()if f.is_file()},summary_SHA256=check.SHA((d/'run/summary.json').read_bytes()));save();return target
normal=execute('normal');q['positive']=check.analyze(normal,L,D/'raw-windows.csv');assert q['cases']['normal']['completion']==dict(status='SUCCESS',complete='13',new='13',resumed='0',failed='0',interrupted='0');save()
resume=execute('resume',normal);check.analyze(resume,L);assert q['cases']['resume']['completion']==dict(status='SUCCESS',complete='13',new='0',resumed='13',failed='0',interrupted='0')
for n,h in q['cases']['resume']['seed_SHA256'].items():
 if n!='pwram64_v1_completion.txt':assert q['cases']['resume']['outputs_SHA256'][n]==h

def interrupted(d):(d/'pwram64_v1_build.txt').write_text(L['build_id']+'\n');(d/'pwram64_v1_progress.txt').write_text('start k00\n')
def wrongbuild(d):(d/'pwram64_v1_build.txt').write_text('0'*64+'\n')
def damaged(d):
 p=d/'pwram64_v1_k00.bin';b=bytearray(p.read_bytes());b[3392]^=1;p.write_bytes(b)
for name,seed,prepare,want in [('interrupted',None,interrupted,dict(status='INCOMPLETE',complete='12',new='12',resumed='0',failed='0',interrupted='1')),('damaged-DONE',normal,damaged,dict(status='INCOMPLETE',complete='12',new='0',resumed='12',failed='1',interrupted='0')),('wrong-build',None,wrongbuild,None)]:
 target=execute(name,seed,prepare);assert q['cases'][name]['completion']==want,(name,q['cases'][name]['completion'])
 try:check.analyze(target,L)
 except (ValueError,FileNotFoundError):pass
 else:raise AssertionError(name+' was accepted')
 for n,h in q['cases'][name]['seed_SHA256'].items():
  if n!='pwram64_v1_completion.txt'and not(name=='interrupted'and n=='pwram64_v1_progress.txt'):assert q['cases'][name]['outputs_SHA256'][n]==h
b=bytearray(rom.read_bytes());code=bytes.fromhex(L['kernel_hex']);assert b.count(code)==1;at=b.index(code)+L['actual_mutant_kernel_offset'];assert struct.unpack_from('<I',b,at)[0]==0xe5824000
struct.pack_into('<I',b,at,0xe1a00000);mutant=D/'first-distinct-STR-NOP.nds';mutant.write_bytes(b)
target=execute('actual-opcode-mutant',changed=mutant);want=dict(status='INCOMPLETE',complete='9',new='9',resumed='0',failed='4',interrupted='0');assert q['cases']['actual-opcode-mutant']['completion']==want,q['cases']['actual-opcode-mutant']['completion']
# N8/9 have a separate short tail; the four long distinct bursts must fail.
try:check.analyze(target,L)
except ValueError:pass
else:raise AssertionError('actual ROM mutation accepted')
q.update(state='PASS',actual_mutation=dict(offset=at,before='e5824000',after='e1a00000',ROM_SHA256=check.SHA(mutant.read_bytes()),device_refused=True));save();print('PASS',flush=True)
