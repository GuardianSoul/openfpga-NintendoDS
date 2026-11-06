#!/usr/bin/env python3
"""Sequential shared-CPU regression plus actual fabric/CDC metadata checks."""
from pathlib import Path
import os,sys,subprocess,json,hashlib,re,time,resource,importlib.util,shutil
ROOT=Path(__file__).resolve().parents[3];G=ROOT/'build/ldm-meta';os.chdir(ROOT);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));assert '--allocated'in sys.argv
sys.path.insert(0,str(ROOT/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest();V='build/tools/oss-cad-suite/bin/verilator'
(G/'LEASE_FINAL').unlink(missing_ok=True);(G/'final-supervisor.json').write_text(json.dumps({'pid':os.getpid(),'host':'Desktop','NI':10,'slots':1})+'\n');print((G/'final-supervisor.json').read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'LEASE_FINAL').exists():time.sleep(.2)
focused=json.loads((G/'focused.json').read_text());models={n:G/n/'obj/Vtb_arm'for n in ['before','candidate']}
assert focused['mutation']['caught']
for n,p in models.items():assert sha(p)==focused['models'][n]
for file,h in focused['source']['candidate'].items():assert sha(ROOT/'rtl/arm'/(file+'.sv'))==h
production={str(p.relative_to(ROOT)):sha(p)for p in [*(ROOT/'rtl/arm'/(f+'.sv')for f in focused['source']['candidate']),ROOT/'rtl/arm/cpu_domain.sv',ROOT/'rtl/ds/nds_top.sv',ROOT/'rtl/ds/nds_fabric.sv']}
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd));log.with_suffix('.command.json').write_text(json.dumps(cmd,indent=2)+'\n')
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT);print(p.pid,str(log),flush=True)
  with(G/'processes.jsonl').open('a')as q:q.write(json.dumps({'pid':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'argv':cmd,'log':str(log)})+'\n')
  rc=wait_owned(p)
 t=log.read_text()
 if not allowed:assert rc==0,(str(log),rc,t[-2000:])
 return rc,t
spec=importlib.util.spec_from_file_location('check',ROOT/'rnd/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);counter=0
def small(cmd,**kw):
 global counter;counter+=1;call(cmd,G/f'prepare-final-{counter}.log')
c.run=small
summary={'base':focused['base'],'production':production,'DENSE':{},'suite':{}}
if '--routes-only'in sys.argv:
 summary=json.loads((G/'cpu-final.json').read_text());assert summary['production']==production
else:
 for seed in range(1301,1326):
  src=subprocess.check_output(['python3','rnd/gen.py',str(seed),'800','3'],env=dict(os.environ,DENSE='1'),text=True);assert src.count('    ldr r2, =EXIT')==1;src=src.replace('    ldr r2, =EXIT','compare_end:\n    ldr r2, =EXIT')
  img=(G/f'seed{seed}.hex') if '--resume-cpu'in sys.argv else c.assemble(src,G/f'seed{seed}');end=next(l.split()[0]for l in subprocess.check_output(['llvm-nm',G/f'seed{seed}.elf'],text=True).splitlines()if l.endswith(' compare_end'));proof=[]
  for name,model in models.items():
   stem=G/f'{name}-dense{seed}';rc,t=(0,stem.with_suffix('.log').read_text()) if '--resume-cpu'in sys.argv else call([model,f'+img0={img}','+pc0=02000000','+run=1','+blat=2','+maxcycles=2000000',f'+trace0={stem}.csv','+packets'],stem.with_suffix('.log'));assert'TEST PASSED'in t
   rows=stem.with_suffix('.csv').read_text().splitlines();rows=rows[:next(i for i,l in enumerate(rows)if l.startswith(end+','))];proof.append((rows,re.findall(r'^PACKET.*',t,re.M),re.findall(r'cycles=(\d+)',t)))
  assert proof[0]==proof[1],('DENSE observable difference',seed)
  summary['DENSE'][str(seed)]={'states':len(proof[0][0]),'packets':len(proof[0][1]),'cycle_exact':True};print('DENSE',seed,'PASS',flush=True)
 images=G/'test-images';images.mkdir(exist_ok=True);original=Path('/home/user/Git/NDS_Pocket-cpu-read-ack/build/read-ack/test-images')
 for p in original.iterdir():
  if p.suffix=='.hex'or p.name=='armwrestler.hooks':shutil.copyfile(p,images/p.name)
 summary['suite_inputs']={p.name:sha(p)for p in images.iterdir()}
 spec=importlib.util.spec_from_file_location('suite',ROOT/'sim/arm/tools/run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
 for name,model in models.items():
  rows={}
  for test,args,desc in suite.tests(str(images),'unused'):
   rc,t=((1 if '%Error'in (G/f'suite-{name}-{test}.log').read_text() else 0),(G/f'suite-{name}-{test}.log').read_text()) if '--resume-cpu'in sys.argv else call([model,*args],G/f'suite-{name}-{test}.log',True);rows[test]={'verdict':'PASS'if'TEST PASSED'in t else'FAIL','exit':rc,'cycles':re.findall(r'cycles=(\d+)',t)}
  summary['suite'][name]=rows
 assert summary['suite']['before']==summary['suite']['candidate'] and len(summary['suite']['candidate'])==26
 assert [k for k,v in summary['suite']['candidate'].items()if v['verdict']=='FAIL']==['bpred7'],summary['suite']
 (G/'cpu-final.json').write_text(json.dumps(summary,indent=2)+'\n')
 print('SHARED CPU PASS25DENSE +unchanged25PASS/inheritedbpred7FAIL',flush=True)
 # Keep the ARM7 executing throughout the ARM9 program: the same compiled
 # shared CPU now exercises uncached pending/replay without solo LDM hold.
 barrel_models={}
 for name in ['before','candidate']:
  d=G/(name+'-barrel');d.mkdir(exist_ok=True);model=d/'obj/Vtb_arm'
  cc=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_arm','--Mdir',d/'obj','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=0','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0']
  if name=='candidate':cc+=['+define+NEW_META']
  if not model.exists():call(cc+[G/name/(f+'.sv')for f in focused['source'][name]]+[G/'tb.sv'],d/'build.log')
  barrel_models[name]=model
 summary['barrel_models']={n:sha(p)for n,p in barrel_models.items()}
 a7=c.assemble(".syntax unified\n.arm\n.global _start\n_start:\n ldr r0,=30000\n1: subs r0,r0,#1\n bne 1b\n ldr r0,=0x0f000000\n mov r1,#0\n str r1,[r0]\n b .\n",G/'a7-running')
 end=next(l.split()[0]for l in subprocess.check_output(['llvm-nm',G/'directed.elf'],text=True).splitlines()if l.endswith(' compare_end'))
 expected=[tuple(x)for x in json.loads((G/'expected.json').read_text())];proof=[]
 for name,model in barrel_models.items():
  stem=G/f'{name}-replay';rc,t=call([model,f'+img0={G/"directed.hex"}',f'+img1={a7}','+pc0=02000000','+pc1=02000000','+run=3','+blat=9','+maxcycles=2000000',f'+trace0={stem}.csv',f'+ops1={stem}.ops','+packets'],stem.with_suffix('.log'));assert 'TEST PASSED'in t
  rows=stem.with_suffix('.csv').read_text().splitlines();rows=rows[:next(i for i,l in enumerate(rows)if l.startswith(end+','))];proof.append((rows,re.findall(r'^PACKET.*',t,re.M),re.findall(r'cycles=(\d+)',t)))
  if name=='candidate':assert [(int(a,16),int(m,16))for a,m in re.findall(r'^META ([0-9a-f]+) ([0-9a-f]+)',t,re.M)]==expected
 assert proof[0]==proof[1]
 summary['barrel_replay']={'states':len(proof[0][0]),'packets':len(proof[0][1]),'descriptors':97,'cycle_state_packet_exact':True,'ARM7':'A9_SOLO=0 and ARM7 countdown alongside ARM9; always barrel, pending/replay uses captured metadata'}
 (G/'cpu-final.json').write_text(json.dumps(summary,indent=2)+'\n')
for name,top,deps,needle in [
 ('fabric','tb_meta_fabric',['rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_fabric.sv','sim/arm/ldm_meta/tb_fabric.sv'],'FAB_META_PASS'),
 ('cdc','tb_meta_cdc',['rtl/arm/cdc_req.sv','sim/arm/ldm_meta/tb_cdc.sv'],'CDC_META_PASS')]:
 d=G/name;d.mkdir(exist_ok=True)
 if '--routes-only'not in sys.argv:call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module',top,'--Mdir',d/'obj',*[ROOT/p for p in deps]],d/'build.log')
 model=d/'obj'/('V'+top)
 rc,t=(0,(d/'run.log').read_text()) if '--routes-only'in sys.argv else call([model],d/'run.log')
 assert needle in t,(name,t[-3000:]);summary[name]={'model_sha256':sha(model),'verdict':next(l for l in t.splitlines()if needle in l)}
arm=[ROOT/'rtl/arm'/(f+'.sv')for f in focused['source']['candidate']]+[ROOT/'rtl/arm/arm7_ds.sv',ROOT/'rtl/arm/cpu_domain.sv',ROOT/'rtl/arm/cdc_req.sv',ROOT/'rtl/arm/cdc_fifo.sv',ROOT/'rtl/arm/cdc_a7.sv',ROOT/'rtl/ds/nds_ram.sv',ROOT/'rtl/ds/nds_arm7_port.sv',ROOT/'rtl/ds/nds_lcache.sv',ROOT/'rtl/gpu3d/gpu3d_ram.sv',ROOT/'rtl/gpu2d/gpu2d_ram.sv']
summary['domain_routes']=[]
for fast in [0,1]:
 for solo in [1,3,5]:
  call([V,'--lint-only','--timing','--assert','-Wno-fatal','--top-module','cpu_domain',f'-GCPU_FAST={fast}',f'-GA9_SOLO={solo}',*arm],G/f'domain-fast{fast}-solo{solo}.log');summary['domain_routes'].append([fast,solo])
assert all(sha(ROOT/p)==h for p,h in production.items());summary['status']='FINAL LDM METADATA PASS';(G/'final.json').write_text(json.dumps(summary,indent=2)+'\n');print(summary['status'],flush=True)
