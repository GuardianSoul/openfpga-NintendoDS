#!/usr/bin/env python3
"""One leased worker: exact defaults, actual faults, pin negatives, fresh CPU gates."""
# Reuse the source-bound driver without executing its main sweep.
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split("names=")[0],str(Path(__file__).with_name('run.py')),'exec'))
import importlib.util,struct
positive=json.loads((G/'results-final.json').read_text());assert len(positive['forms'])==53
assert positive['source_sha256']==sha(R/'rtl/ds/nds_fabric.sv')
proof={};off=build('off')
for tag,v in positive['forms'].items():
 row,packets,state=actual('off',off,tag);ref=G/('before-'+tag)
 assert state==ref.with_suffix('.csv').read_bytes() and row==v['before'],('default changed',tag,row,v['before'])
 assert (G/('off-'+tag+'.ops')).read_bytes()==ref.with_suffix('.ops').read_bytes()
 t=ref.with_suffix('.log').read_text();assert packets==re.findall(r'^LDMWORD c\d+ a([0-9a-f]+) meta([0-9a-f]+) d([0-9a-f]+)$',t,re.M)
 proof[tag]=dict(cycle_state_DATA_exact=True,states=state.count(b'\n'),words=len(packets))
 record(G/'default-proof.json',proof)
print('DEFAULT53_PASS',flush=True)
# Corrupt the actual final DATA capture, with its real hold/return active.
m=build('mutant');log=G/'mutant-final-data.log';rc=call([m,'+img0='+str(G/'fixed2-0.hex'),'+pc0=02000000','+run=1','+blat=9','+maxcycles=3000000'],log,True)
assert rc!=0 and 'physical DATA mismatch'in log.read_text() and 'timeout'not in log.read_text().lower()
# Corrupt only the forwarded ALU base value; architectural base commit remains real.
m=build('cbad');row,p,state=actual('cbad',m,'ldm2-0');assert state!=(G/'before-ldm2-0.csv').read_bytes()
record(G/'mutations.json',dict(final_capture=dict(caught=True,exit=rc),forwarded_base=dict(caught=True,architectural_test_passes=True,retirement_state_mismatch=True)))
print('TWO_ACTUAL_MUTANTS_CAUGHT',flush=True)
# Existing semantic suite on actual pin transport; include accepted writes.
end=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',G/'directed.elf'],text=True).splitlines()if x.endswith(' compare_end'))
pin={};states={};packets={};writes={}
for n in ['before','bf3']:
 out=G/(n+'-directed');call([build(n),'+img0='+str(G/'directed.hex'),'+pc0=02000000','+run=1','+blat=9','+maxcycles=3000000','+trace0='+str(out)+'.csv','+dbg=1'],out.with_suffix('.log'))
 t=out.with_suffix('.log').read_text();assert'TEST PASSED'in t and'chip_errors0'in t,(n,t[-2000:]);rows=out.with_suffix('.csv').read_text().splitlines();states[n]=rows[:next(i for i,x in enumerate(rows)if x.startswith(end+','))]
 packets[n]=re.findall(r'^LDMWORD c\d+ a([0-9a-f]+) meta([0-9a-f]+) d([0-9a-f]+)$',t,re.M);writes[n]=re.findall(r'BUS9 WR (a=\w+ d=\w+)',t);assert len(packets[n])==97
 pin[n]=dict(states=len(states[n]),DATA=len(packets[n]),writes=len(writes[n]))
assert states['before']==states['bf3'] and packets['before']==packets['bf3'] and writes['before']==writes['bf3'];record(G/'pin-directed.json',pin);print('PIN_SEMANTIC97_PASS',flush=True)
# The actual CPU/RF change receives fresh regression, not a reused metadata receipt.
CPU=FILES[:8];V='build/tools/oss-cad-suite/bin/verilator'
def flat_build(n):
 d=G/('cpu-'+n);d.mkdir(exist_ok=True);inputs=[]
 for f in CPU:
  b=subprocess.check_output(['git','show',BASE+':'+f])if n=='before'else(R/f).read_bytes();p=d/Path(f).name
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 tb=d/'tb.sv';tb.write_bytes((R/'sim/arm/ldm_service/flat.sv').read_bytes());inputs.append(tb);model=d/'Vtb_arm'
 if not model.exists():
  cmd=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','--top-module','tb_arm','--Mdir',d]
  if n=='before':cmd+=['+define+NO_BASE_FORWARD']
  call(cmd+inputs,d/'build.log');record(d/'model.json',dict(sha256=sha(model),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_arm','model.json','build.log']:p.unlink()
 return model
models={n:flat_build(n)for n in ['before','on']}
spec=importlib.util.spec_from_file_location('cpucheck',R/'rnd/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);prep=0
def small(cmd,**kw):
 global prep;prep+=1;assert not kw;call(cmd,G/('prepare-qual-'+str(prep)+'.log'))
c.run=small
DENSE={}
def flat(n,img,stem,cut):
 call([models[n],'+img0='+str(img),'+pc0=02000000','+run=1','+blat=2','+maxcycles=2000000','+trace0='+str(stem)+'.csv','+packets'],stem.with_suffix('.log'))
 t=stem.with_suffix('.log').read_text();assert'TEST PASSED'in t,(n,stem,t[-2000:]);rows=stem.with_suffix('.csv').read_text().splitlines();return rows[:next(i for i,x in enumerate(rows)if x.startswith(cut+','))],re.findall(r'^PACKET.*$',t,re.M)
for seed in range(1301,1326):
 src=subprocess.check_output(['python3','rnd/gen.py',str(seed),'800','3'],env=dict(os.environ,DENSE='1'),text=True);assert src.count('    ldr r2, =EXIT')==1;src=src.replace('    ldr r2, =EXIT','compare_end:\n    ldr r2, =EXIT');img=c.assemble(src,G/('seed'+str(seed)));cut=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',G/('seed'+str(seed)+'.elf')],text=True).splitlines()if x.endswith(' compare_end'))
 a=flat('before',img,G/('cpu-before-seed'+str(seed)),cut);b=flat('on',img,G/('cpu-on-seed'+str(seed)),cut);assert a==b,('DENSE state/order',seed)
 DENSE[str(seed)]=dict(states=len(a[0]),packets=len(a[1]),RR=1);record(G/'DENSE.json',DENSE);print('DENSE',seed,'PASS',flush=True)
spec=importlib.util.spec_from_file_location('suite',R/'sim/arm/tools/run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite);suites={}
for n,m in models.items():
 verdicts={}
 for test,args,desc in suite.tests(str(G/'test-images'),'unused'):
  log=G/('cpu-'+n+'-'+test+'.log');rc=call([m,*args],log,True);t=log.read_text();verdicts[test]=dict(verdict='PASS'if'TEST PASSED'in t else'FAIL',exit=rc,cycles=re.findall(r'cycles=(\d+)',t));print('ARM',n,test,verdicts[test]['verdict'],flush=True)
 suites[n]=verdicts;record(G/'ARM.json',suites)
assert {k:v['verdict']for k,v in suites['before'].items()}=={k:v['verdict']for k,v in suites['on'].items()}
assert[k for k,v in suites['on'].items()if v['verdict']=='FAIL']==['bpred7'] and len(suites['on'])==26
record(G/'qualified.json',dict(source={str(R/f):sha(R/f)for f in ['rtl/arm/arm_core.sv','rtl/arm/arm_cpu.sv','rtl/ds/nds_fabric.sv']},default53=True,pin_semantic=pin,mutations=json.loads((G/'mutations.json').read_text()),DENSE=DENSE,ARM=suites,scope='bounded candidate; native53 live-code, combined contention, games, fit/STA still separate gates'))
print('QUALIFIED_SERVICE_CANDIDATE_PASS',flush=True)
