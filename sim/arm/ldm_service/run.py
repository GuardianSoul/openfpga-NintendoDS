#!/usr/bin/env python3
"""Actual CPU, paired pins and descriptor-bound LDM service, one leased slot."""
from pathlib import Path
import hashlib,json,os,re,resource,shutil,subprocess,sys,time
R=Path(__file__).resolve().parents[3];G=R/'build/ldm-service';os.chdir(R)
assert '--allocated'in sys.argv;os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def record(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);record(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED', (G/'controller.json').read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as q:q.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-2000:])
 return rc
BASE='2c3229b7bcbac40f779ed62086209f54a5006f98'
FILES=['rtl/arm/'+x+'.sv'for x in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split()]+['rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv','sim/pocket/psram_if4/cram_model.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/pocket/nds_psram.sv']
def build(name):
 d=G/name;d.mkdir(exist_ok=True);inputs=[]
 for f in FILES:
  b=subprocess.check_output(['git','show',BASE+':'+f])if name=='before'else(R/f).read_bytes()
  if name in ['cbad','cf3'] and f=='rtl/arm/arm_core.sv':
   old=b'w_wd       <= (e3.wsrc';assert b.count(old)==1;b=b.replace(old,b"w_wd       <= ldm_bf(e3) ? 32'd0 : (e3.wsrc")
  if name=='tf3' and f=='rtl/ds/nds_fabric.sv':
   start=b'ls_work <= ls_form(a9_ldm_meta) ?';end=b": 7'd0;";a=b.index(start);z=b.index(end,a)+len(end);b=b[:a]+b"ls_work <= 7'd0;"+b[z:]
  if name in ['mutant','mf3'] and f=='rtl/ds/nds_fabric.sv':
   a=b'ls_end_data<=a9_raw_data;';assert b.count(a)==1;b=b.replace(a,b"ls_end_data<=a9_raw_data ^ 32'd1;")
  p=d/f;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b,('source changed',p)
  else:p.write_bytes(b)
  inputs.append(p)
 for f in ['tb.sv','transport.sv']:
  p=d/f;b=(R/'sim/arm/ldm_service'/f).read_bytes()
  if not p.exists():p.write_bytes(b)
  inputs.append(p)
 model=d/'Vtb_arm'
 if not model.exists():
  service=0 if name in ['before','off','off3']else 1 if name=='reuse'else 3
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--timescale','1ns/1ps','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','-GBF='+str(int(name in ['bf2','bf3','mutant','cbad','mf3','cf3','tf3'])),'-GSERVICE='+str(service),'--top-module','tb_arm','--Mdir',d]
  if name=='before':cmd+=['+define+NO_SERVICE','+define+NO_BASE_FORWARD']
  call(cmd+inputs,d/'build.log');record(d/'model.json',dict(sha256=sha(model),inputs={str(p):sha(p)for p in inputs},SERVICE=service,base=BASE))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_arm','model.json','build.log']:p.unlink()
 receipt=json.loads((d/'model.json').read_text());assert sha(model)==receipt['sha256']
 for p,h in receipt['inputs'].items():assert sha(p)==h
 return model
forms=json.loads((G/'forms.json').read_text())
def actual(name,model,tag):
 stem=G/(name+'-'+tag);form=tag.rsplit('-',1)[0]
 call([model,'+img0='+str(G/(tag+'.hex')),'+pc0=02000000','+run=1','+blat=9','+maxcycles=3000000','+trace0='+str(stem)+'.csv','+ops0='+str(stem)+'.ops'],stem.with_suffix('.log'))
 t=stem.with_suffix('.log').read_text();assert'TEST PASSED'in t and'chip_errors0'in t,(tag,t[-2000:])
 ops=[x.split()for x in stem.with_suffix('.ops').read_text().splitlines()];a=[int(x[3])for x in ops if int(x[0],16)==0x1000];b=[int(x[3])for x in ops if int(x[0],16)==0x1000+forms[form]['bytes']-4];assert len(a)==len(b)==3
 intervals=[y-x for x,y in zip(a,b)];packets=re.findall(r'^LDMWORD c\d+ a([0-9a-f]+) meta([0-9a-f]+) d([0-9a-f]+)$',t,re.M)
 return dict(intervals=intervals,SYS=(intervals[2]-intervals[1])/1536,words=len(packets),physical=len(re.findall('^PHYSICAL lane2',t,re.M))),packets,stem.with_suffix('.csv').read_bytes()
names=['audit2'] if '--audit'in sys.argv else ['before','bf3'];models={n:build(n)for n in names}
cached_before={}
for file in ['results-v1.json','results-final.json']:
 if (G/file).exists():cached_before=json.loads((G/file).read_text())['forms'];break
if '--audit'in sys.argv:
 for tag in ['fixed2-0','ldm2-0','fixed8-0','ldm8_anchor-0']:
  call([models['audit2'],'+img0='+str(G/(tag+'.hex')),'+pc0=02000000','+run=1','+blat=9','+maxcycles=3000000','+handover'],G/('audit-'+tag+'.log'))
 print('AUDIT_DONE',flush=True);sys.exit(0)
tags=['fixed2-0','fixed2-12','fixed8-4','ldm8_anchor-0','ldm8_anchor-4','ldm2-4','nop16-0']
if '--all'in sys.argv:tags += [n+'-'+str(o)for n in forms for o in ([0]if n=='nop16'else[0,4,8,12])if n+'-'+str(o)not in tags]
results={}
for tag in tags:
 rows={};packets={};states={}
 for n,m in models.items():
  if n=='before' and tag in cached_before and (G/('before-'+tag+'.csv')).exists():
   rows[n]=cached_before[tag][n]
   t=(G/('before-'+tag+'.log')).read_text();packets[n]=re.findall(r'^LDMWORD c\d+ a([0-9a-f]+) meta([0-9a-f]+) d([0-9a-f]+)$',t,re.M);states[n]=(G/('before-'+tag+'.csv')).read_bytes()
  else:rows[n],packets[n],states[n]=actual(n,m,tag)
 assert packets['before']==packets['bf3']and states['before']==states['bf3'],('data/state mismatch',tag)
 results[tag]=rows;record(G/'results-final.json',dict(forms=results,models={n:sha(p)for n,p in models.items()},source_sha256=sha(R/'rtl/ds/nds_fabric.sv')));print('SERVICE',tag,json.dumps(rows),flush=True)
print('SERVICE_COMPLETE',len(results),flush=True)
