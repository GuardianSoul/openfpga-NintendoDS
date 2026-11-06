#!/usr/bin/env python3
"""One leased worker: paired architectural/packet checks and actual replay fault."""
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split('models={}')[0],str(Path(__file__).with_name('run.py')),'exec'))
import importlib.util,struct
CPU='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split()
BASE='27340ba41414cba3e53c8eab962b733b8a0b2df2'
V='build/tools/oss-cad-suite/bin/verilator'
def build(n):
 d=G/('flat-'+n);d.mkdir(exist_ok=True);inputs=[]
 for f in CPU:
  b=subprocess.check_output(['git','show',BASE+':rtl/arm/'+f+'.sv'])if n=='before'else(R/'rtl/arm'/(f+'.sv')).read_bytes()
  if n=='mutant'and f=='arm_core':
   a=b'e1 <= io_retry_go ? io_retry_uop : u;';assert b.count(a)==1;b=b.replace(a,a+b"\n      if(io_retry_go)e1.wa <= 5'd0;")
  p=d/(f+'.sv')
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 p=d/'tb.sv';b=(R/'sim/arm/io_retry_window/flat.sv').read_bytes()
 if p.exists():assert p.read_bytes()==b
 else:p.write_bytes(b)
 inputs.append(p);model=d/'Vtb_arm'
 if not model.exists():
  cmd=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_arm','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_IO_REPLAY','-GIO_REPLAY='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(model),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_arm','model.json','build.log']:p.unlink()
 receipt=json.loads((d/'model.json').read_text());assert sha(model)==receipt['sha256']
 for p,h in receipt['inputs'].items():assert sha(p)==h
 return model
I=G/'inputs'
def module(n):
 spec=importlib.util.spec_from_file_location(n,I/(n+'.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
c=module('check_cpu');prep=0
def small(cmd,**kw):
 global prep;prep+=1;assert not kw;call(cmd,G/('qual-prepare-'+str(prep)+'.log'))
c.run=small
models={n:build(n)for n in ['before','off','on','mutant']}
def run(n,img,tag,cut,lat=2,allowed=False):
 out=G/tag;rc=call([models[n],'+img0='+str(img),'+pc0=02000000','+run=1','+blat='+str(lat),'+maxcycles=2000000','+trace0='+str(out)+'.csv','+packets'],out.with_suffix('.log'),allowed);t=out.with_suffix('.log').read_text()
 if not allowed:assert'TEST PASSED'in t and'timeout'not in t.lower(),(tag,t[-1600:])
 rows=out.with_suffix('.csv').read_text().splitlines()
 if cut:rows=rows[:next(i for i,x in enumerate(rows)if x.startswith(cut+','))]
 return rows,re.findall(r'^PACKET .*$',t,re.M),t,rc
def symbol(p,n):return next(x.split()[0]for x in subprocess.check_output(['llvm-nm',p],text=True).splitlines()if x.endswith(' '+n))
stem=G/'directed';img=c.assemble((R/'sim/arm/io_retry_window/directed.s').read_text(),stem);seed=G/'seed.bin';seed.write_bytes(struct.pack('<8192I',*[0x13240000+i for i in range(8192)]));small(['python3','sim/arm/tools/mkhex.py',img,str(stem.with_suffix('.bin'))+'@0x02000000',str(seed)+'@0x02410000']);cut=symbol(stem.with_suffix('.elf'),'compare_end');focused={}
for lat in [0,1,2,9]:
 rows={n:run(n,img,n+'-directed-b'+str(lat),cut,lat)for n in ['before','off','on']}
 assert rows['before'][:2]==rows['off'][:2]==rows['on'][:2],('state/packet',lat)
 assert re.findall(r'cycles=\d+',rows['before'][2])==re.findall(r'cycles=\d+',rows['off'][2])
 focused[str(lat)]=dict(states=len(rows['on'][0]),packets=len(rows['on'][1]),cycles={n:re.findall(r'cycles=(\d+)',r[2])for n,r in rows.items()},replays=re.findall(r'REPLAY_COUNT (\d+)',rows['on'][2]));save(G/'focused.json',focused);print('FOCUSED',lat,focused[str(lat)],flush=True)
rows,packets,t,rc=run('mutant',img,'mutant-replay-destination',None,2,True)
assert 'TEST FAILED'in t and'timeout'not in t.lower() and int(re.findall(r'REPLAY_COUNT (\d+)',t)[0])>0
assert rows!=(G/'on-directed-b2.csv').read_text().splitlines()
save(G/'replay-mutation.json',dict(actual_source='flat-mutant/arm_core.sv',fault='only reissued scalar uop destination forced R0',caught='CPU TEST FAILED and retired state mismatch',exit=rc));print('REPLAY_MUTANT_CAUGHT',flush=True)
dense={}
for seed in range(1501,1526):
 src=subprocess.check_output(['python3',I/'gen.py',str(seed),'800','3'],env=dict(os.environ,DENSE='1'),text=True);assert src.count('    ldr r2, =EXIT')==1;src=src.replace('    ldr r2, =EXIT','compare_end:\n    ldr r2, =EXIT');stem=G/('dense'+str(seed));img=c.assemble(src,stem);cut=symbol(stem.with_suffix('.elf'),'compare_end');a=run('before',img,'dense-before-'+str(seed),cut);b=run('on',img,'dense-on-'+str(seed),cut);assert a[:2]==b[:2],('DENSE state/packets',seed);dense[str(seed)]=dict(states=len(a[0]),packets=len(a[1]));save(G/'DENSE.json',dense);print('DENSE',seed,'PASS',flush=True)
suite=module('run_tests');suites={}
for n in ['before','on']:
 verdicts={}
 for test,args,desc in suite.tests(str(I/'test-images'),'unused'):
  out=G/('suite-'+n+'-'+test+'.log');rc=call([models[n],*args],out,True);t=out.read_text();verdicts[test]=dict(verdict='PASS'if'TEST PASSED'in t else'FAIL',exit=rc,cycles=re.findall(r'cycles=(\d+)',t));print('ARM',n,test,verdicts[test]['verdict'],flush=True)
 suites[n]=verdicts;save(G/'ARM.json',suites)
assert len(suites['on'])==26
assert {k:v['verdict']for k,v in suites['before'].items()}=={k:v['verdict']for k,v in suites['on'].items()}
assert [k for k,v in suites['on'].items()if v['verdict']=='FAIL']==['bpred7']
save(G/'qualified.json',dict(source={str(R/'rtl/arm'/(f+'.sv')):sha(R/'rtl/arm'/(f+'.sv'))for f in ['arm9_mem','arm_core','arm_cpu']},focused=focused,DENSE=dense,ARM=suites,scope='component correctness only; DS41 timing residual, native/combined/fit remain open'))
print('IO_REPLAY_COMPONENT_GATES_PASS',flush=True)
