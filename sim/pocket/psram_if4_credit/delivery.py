#!/usr/bin/env python3
"""Reuse the retained IF8 transport/owner/reset fixture on exact b4df control."""
from pathlib import Path
import datetime,hashlib,json,os,resource,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[3]
OUT=Path('/tmp/nds-if4-credit-delivery');OUT.mkdir()
os.chdir(ROOT);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def pinned(path):
 return subprocess.check_output(['git','show','c74a3620:'+path])
H=OUT/'helpers';H.mkdir()
for n in['worker_guard.py','sim_ownership.py']:(H/n).write_bytes(pinned('sim/arm/read_ack/'+n))
sys.path.insert(0,str(H));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
base=subprocess.check_output(['git','show','e704c35b:rtl/pocket/nds_psram.sv'],text=True)
assert hashlib.sha256(base.encode()).hexdigest()=='b4dfdff78ba20175f273925b8a5878dd114d06b458bf7b1e59cb6968076a619e'
candidate=(ROOT/'rtl/pocket/nds_psram.sv').read_text();source_hash=hashlib.sha256(candidate.encode()).hexdigest()
fixtures={n:subprocess.check_output(['git','show','2c620703:sim/ds/a7_delivery/'+n],text=True)for n in['tb.sv','chips.sv']}
def status(phase,pid=None):
 p=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(p.read_text())
 def start(n):
  try:return int(Path(f'/proc/{n}/stat').read_text().rsplit(')',1)[1].split()[19])
  except FileNotFoundError:return None
 j.update(phase=phase,profile='actual fabric/MR/PSRAM IF4/PREFILL8, three phases/skew/row gaps, immediate/deferred requests',updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),evidence=str(OUT))
 j['worker'].update(controller=os.getpid(),PID=pid,starttime={'controller':start(os.getpid()),'PID':start(pid)if pid else None})
 t=json.dumps(j,indent=2)+'\n';assert len(t.encode())<=2048;q=p.with_name('CPU.json.tmp.'+str(os.getpid()));q.write_text(t);os.replace(q,p)
def call(cmd,d,name,expected=None):
 guard();cmd=list(map(str,cmd))
 with(d/(name+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT)
  with(OUT/'processes.jsonl').open('a')as q:q.write(json.dumps({'controller':os.getpid(),'PID':p.pid,'NI':10,'argv':cmd,'log':str(d/(name+'.log'))})+'\n')
  status(d.name+'/'+name,p.pid);print(d.name,name,p.pid,flush=True);rc=wait_owned(p)
 text=(d/(name+'.log')).read_text()
 if expected:assert rc!=0 and any(s in text for s in expected)and 'timeout'not in text.lower(),(d.name,text[-2000:])
 else:assert rc==0 and(name=='build'or'PASS delivery'in text),(d.name,text[-2000:])
 return text
variants=[('before',0,0),('candidate',0,0),('slow-half0',2,1),('slow-half1',1,1),('fault-generation',0,0),('fault-stale-write',0,0),('fault-owner',1,1)]
summary={'before_PHY':hashlib.sha256(base.encode()).hexdigest(),'candidate_PHY':source_hash,'fixture_donor':'2c620703 retained a7_delivery','cases':{}};reference={}
for name,skew,gaps in variants:
 d=OUT/name;d.mkdir();new=base if name=='before'else candidate;changes=[];expected=None
 if name=='fault-generation':
  changes=[('&& s_addr[20:0] == if8_base && s_ifgen == if8_gen','&& s_addr[20:0] == if8_base')];expected=['delivery physical count']
 if name=='fault-stale-write':
  changes=[('if (reset_sys || (s_req && s_we)) if8_valid <= 0;','if (reset_sys) if8_valid <= 0;'),('if8_valid <= if8_start;','if8_valid <= if8_start || (s_we && if8_valid);')];expected=['delivery ordered payload']
 if name=='fault-owner':
  changes=[('else if ((!busy || dma_reissue) && !bw_c && direct_req','else if (1\'b1 && !bw_c && direct_req')];expected=['delivery physical owner retagged']
 for old,replacement in changes:assert new.count(old)==1,(name,old);new=new.replace(old,replacement)
 (d/'nds_psram.sv').write_text(new)
 for n,text in fixtures.items():(d/n).write_text(text)
 for rel in['rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv']:shutil.copyfile(ROOT/rel,d/Path(rel).name)
 (d/'cram_model.sv').write_bytes(pinned('sim/pocket/psram_if4/cram_model.sv'))
 (d/'inputs.json').write_text(json.dumps({p.name:sha(p)for p in d.glob('*.sv')},indent=2)+'\n')
 model=d/'obj/Vtb_a7_delivery';cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_a7_delivery','-GIFS=1','-GPREFILL=1',f'-GSKEW={skew}',f'-GGAPS={gaps}','--Mdir',model.parent,*sorted(d.glob('*.sv'))]
 call(cmd,d,'build')
 for p in model.parent.iterdir():
  if p.is_file()and(p.suffix in['.gch','.o','.a','.d']or(p.name.startswith('Vtb')and p.suffix in['.cpp','.h','.mk','.dat'])):p.unlink()
 runs=[]
 for phase,immediate in([(0,True)]if expected else[(0,True),(3000,True),(7000,True),(0,False)]):
  text=call([model,f'+phase={phase}',*(['+immediate']if immediate else[])],d,f'run-{phase}-{int(immediate)}',expected)
  if expected:runs.append({'caught':True,'expected':expected})
  else:
   state=next(l for l in text.splitlines()if l.startswith('STATE delivery'));key=f'{phase}-{int(immediate)}'
   if name=='before':reference[key]=state
   else:assert state==reference[key],(name,state,reference[key])
   runs.append({'phase':phase,'immediate':immediate,'state':state,'verdict':next(l for l in text.splitlines()if l.startswith('PASS delivery'))})
 summary['cases'][name]={'model_SHA256':sha(model),'runs':runs};(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
assert sha(ROOT/'rtl/pocket/nds_psram.sv')==source_hash
status('delivery owner/generation/write/reset gates PASS')
print('IF4_DELIVERY_PASS',flush=True)
