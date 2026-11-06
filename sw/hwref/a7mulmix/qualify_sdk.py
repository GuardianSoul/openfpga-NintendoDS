#!/usr/bin/env python3
"""Serial SDK/Census23 functional gate, with no physical-card operations."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,resource,shutil,struct,subprocess,time
S=Path(__file__).resolve().parent;R=S.parents[2]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--build-only',action='store_true');p.add_argument('--complete',action='store_true');a=p.parse_args();D=a.output.resolve()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(120,120));resource.setrlimit(resource.RLIMIT_AS,(2*1024**3,2*1024**3));resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest();tick=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
spec=importlib.util.spec_from_file_location('mm_checker',S/'check.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
status_path=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(phase,proc=None):
 s=json.loads(status_path.read_text());s['phase']=phase;s['worker']=dict(host='Desktop',active=bool(proc),controller=os.getpid()if proc else None,PID=proc.pid if proc else None,starttime=tick(proc.pid)if proc else None,NI=10,jobs=int(bool(proc)),threads=int(bool(proc)));s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=status_path.with_name('CPU.json.tmp.'+str(os.getpid()));t.write_text(json.dumps(s,indent=2)+'\n');assert t.stat().st_size<=2048;t.replace(status_path)
if a.complete:
 q=json.loads((D/'results.json').read_text());assert q['state']=='SDK_BUILT_AUDIT_PENDING';assert (D/'linked-audit.json').exists()
else:
 D.mkdir(parents=True,exist_ok=False);q=dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),controllers=[],stages=[],cases={},limits='Software qualification only, no DS timing or staging',caps=dict(NI=10,jobs=1,threads=1,CPU_seconds=120,AS_bytes=2*1024**3,file_bytes=128*1024**2,wall_per_child_seconds=60))
q['controllers'].append(dict(PID=os.getpid(),starttime=tick(os.getpid()),NI=10))
def save():(D/'results.json').write_text(json.dumps(q,indent=2)+'\n')
def run(cmd,tag,cwd=R):
 assert os.getloadavg()[0]<24
 start=time.monotonic();cmd=list(map(str,cmd));log=D/(tag+'.log')
 with log.open('w')as f:
  proc=subprocess.Popen(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT);row=dict(tag=tag,cmd=cmd,cwd=str(cwd),PID=proc.pid,starttime=tick(proc.pid),NI=os.getpriority(os.PRIO_PROCESS,proc.pid));q['stages'].append(row);save();status(tag,proc);print(tag,proc.pid,flush=True)
  try:row['exit']=proc.wait(timeout=60)
  except subprocess.TimeoutExpired:proc.terminate();row['exit']=proc.wait(timeout=5);row['timeout']=True
 row.update(reaped=True,seconds=round(time.monotonic()-start,3));save();status(tag+' terminal');assert row['exit']==0 and not row.get('timeout'),(tag,log.read_text()[-2400:]);return log
sdk=D/'sdk'
if not a.complete:
 sdk.mkdir();run(['make','-j1','-C',S,'OUT='+str(sdk)],'SDK-build')
 layout=c.sdk(sdk/'a7mulmix7.elf',sdk/'a7mulmix.elf',sdk/'build-id.h');(D/'layout.json').write_text(json.dumps(layout,indent=2)+'\n');q.update(layout=layout,ROM_SHA256=sha((sdk/'a7mulmix.nds').read_bytes()),state='SDK_BUILT_AUDIT_PENDING')
 q['producer_SHA256']={n:sha((S/n).read_bytes())for n in ['protocol.h','arm7.c','kernel.S','main.c','quiet.itcm.c','Makefile']}
 for name in ['a7mulmix7','a7mulmix']:
  log=run(['/opt/devkitpro/devkitARM/bin/arm-none-eabi-objdump','-d',sdk/(name+'.elf')],name+'-disassembly');(D/(name+'.dis')).write_bytes(log.read_bytes())
 save();print('SDK pair built; linked layout/call/helper audit required',flush=True)
 if a.build_only:raise SystemExit(0)
else:
 layout=json.loads((D/'layout.json').read_text());assert layout==c.sdk(sdk/'a7mulmix7.elf',sdk/'a7mulmix.elf',sdk/'build-id.h')
 for n,digest in q['producer_SHA256'].items():assert sha((S/n).read_bytes())==digest,n
 audit=json.loads((D/'linked-audit.json').read_text());assert audit['PASS']and audit['arm7_ELF_SHA256']==layout['arm7_elf_SHA256']and audit['arm9_ELF_SHA256']==layout['arm9_elf_SHA256']
 assert sha((sdk/'a7mulmix.nds').read_bytes())==q['ROM_SHA256']
assert (D/'linked-audit.json').exists()
census=Path('/home/user/Git/NDS_Pocket-census23-cli/bin/census23');assert sha(census.read_bytes())=='2ff706841070a5a40ae401b7e92b25c72bb5ba2accae2469423f7d00cb23c86d'
info=json.loads(run([census,'--build-info'],'Census23-build-info').read_text());assert info['census_mode']=='ds-rules-23'and info['compiled_rule_count']==info['declared_rule_count']==23
assert set(info['frontend_capabilities'])>=set(['final-state','final-save','save-state-save']);q['Census_SHA256']=sha(census.read_bytes());q['runtime_external_SHA256']={n:sha(Path('/home/user/Git/NDS_Pocket/roms',n).read_bytes())for n in ['bios7.bin','bios9.bin','firmware.bin']};save()
prefix='a7mulmix_v1';relative=Path('hwref/a7mulmix-v1');rom=sdk/'a7mulmix.nds'
def execute(name,seed=None,changed_rom=None,prepare=None):
 folder=D/name;folder.mkdir();sd=folder/'sd';sd.mkdir();target=sd/relative;target.mkdir(parents=True);script=folder/'script.txt';script.write_text('');seed_hash={}
 if seed:
  for f in seed.iterdir():
   if f.is_file():shutil.copyfile(f,target/f.name)
 if prepare:prepare(target)
 seed_hash={f.name:sha(f.read_bytes())for f in target.iterdir()if f.is_file()}
 actual_rom=changed_rom or rom
 argv=[census,'--expect-mode','ds-rules-23','--require-capabilities','final-state,final-save,save-state-save']
 for n in ['bios9','bios7','firmware']:argv+=['--'+n,'/home/user/Git/NDS_Pocket/roms/'+n+'.bin']
 argv+=['--rom',actual_rom,'--script',script,'--out',folder/'run','--frames','600','--shot-every','600','--sd-dir',sd,'--sd-mb','64']
 run(argv,name+'-Census23');summary=json.loads((folder/'run/summary.json').read_text());assert summary['census_mode']=='ds-rules-23'and summary['compiled_rule_count']==summary['declared_rule_count']==23
 comp=target/(prefix+'_completion.txt');completion=dict(x.split('=',1)for x in comp.read_text().splitlines())if comp.exists()else None
 q['cases'][name]=dict(seed_SHA256=seed_hash,completion=completion,output_SHA256={f.name:sha(f.read_bytes())for f in target.iterdir()if f.is_file()},ROM_SHA256=sha(actual_rom.read_bytes()),summary_SHA256=sha((folder/'run/summary.json').read_bytes()))
 save();return target
normal=execute('normal');checked=c.analyze(normal,layout);assert checked['groups']==6 and checked['raw_times']==60 and checked['register_words']==3840
assert q['cases']['normal']['completion']==dict(status='SUCCESS',complete='6',new='6',resumed='0',failed='0',interrupted='0');(D/'normal-check.json').write_text(json.dumps(checked,indent=2)+'\n')
resume=execute('resume',normal);c.analyze(resume,layout);assert q['cases']['resume']['completion']==dict(status='SUCCESS',complete='6',new='0',resumed='6',failed='0',interrupted='0')
for n,h in q['cases']['resume']['seed_SHA256'].items():
 if n!=prefix+'_completion.txt':assert q['cases']['resume']['output_SHA256'][n]==h,n
def interrupted(d):
 (d/(prefix+'_build.txt')).write_text(layout['build_id']+'\n');(d/(prefix+'_progress.txt')).write_text('start k00_r0\n')
def damaged(d):
 path=d/(prefix+'_k00_r0.bin');b=bytearray(path.read_bytes());struct.pack_into('<I',b,16,16);path.write_bytes(b)
def refusal(d):(d/(prefix+'_build.txt')).write_text('0'*64+'\n')
for name,seed,prep,want in [
 ('interrupted',None,interrupted,dict(status='INCOMPLETE',complete='5',new='5',resumed='0',failed='0',interrupted='1')),
 ('damaged-DONE',normal,damaged,dict(status='INCOMPLETE',complete='5',new='0',resumed='5',failed='1',interrupted='0')),
 ('refusal',None,refusal,None)]:
 target=execute(name,seed,prepare=prep);assert q['cases'][name]['completion']==want,(name,q['cases'][name]['completion'])
 try:c.analyze(target,layout)
 except (ValueError,FileNotFoundError):pass
 else:raise AssertionError(name+' accepted')
 if name=='damaged-DONE':
  for n,h in q['cases'][name]['seed_SHA256'].items():
   if n!=prefix+'_completion.txt':assert q['cases'][name]['output_SHA256'][n]==h
 if name=='refusal':assert q['cases'][name]['seed_SHA256']==q['cases'][name]['output_SHA256']
# Real NDS payload fault: replace the first r2 MUL, after freezing positive
# files. Embedded C completion must fail even though final results overwrite it.
b=bytearray(rom.read_bytes());needle=c.elf.elf_symbol(sdk/'a7mulmix7.elf','mm_mul')['body'];assert bytes(b).count(needle)==1
# Calico stores private-WRAM code in its load image; VMA is not the NDS
# header's initial ARM7 RAM address. Bind the complete unique kernel bytes.
at=bytes(b).index(needle)+4;arm7_offset=struct.unpack_from('<I',b,0x30)[0];arm7_size=struct.unpack_from('<I',b,0x3c)[0];assert arm7_offset<=at<arm7_offset+arm7_size
assert struct.unpack_from('<I',b,at)[0]==0xe0030291
struct.pack_into('<I',b,at,0xe1a00000);mutant=D/'first-MUL-NOP.nds';mutant.write_bytes(b)
target=execute('real-ROM-opcode-mutant',changed_rom=mutant);want=dict(status='INCOMPLETE',complete='0',new='0',resumed='0',failed='6',interrupted='0');assert q['cases']['real-ROM-opcode-mutant']['completion']==want
for path in target.glob(prefix+'_k*.bin'):
 raw=path.read_bytes();i,region=struct.unpack_from('<II',raw,8);rs2,rs6=c.PAIRS[i];entry=layout['main_entry']if region else layout['source_entry']
 for rep in range(5):
  for length,n in enumerate([4,16]):
   off=224+(rep*2+length)*288;c.invocation(raw[off+32:off+160],1,rs2,rs6,entry,layout['wrapper']['return_address']);c.invocation(raw[off+160:off+288],n,rs2,rs6,entry,layout['wrapper']['return_address'])
 try:c.kernel(raw[3104:3376])
 except ValueError:pass
 else:raise AssertionError('real-ROM opcode fault survived')
q['real_ROM_opcode_fault']=dict(offset=at,normal_word='e0030291',mutant_word='e1a00000',arithmetic_state_preserved=True,device_completion_refused_all6=True)
q['state']='PASS_SDK_LINKED_BODY_CALL_HELPER_AND_SOFTWARE_COMPLETION; DS_TIMING_UNMEASURED';save();status('SDK/Census23 qualified; DS timing unmeasured; no staging');print(q['state'],flush=True)
