#!/usr/bin/env python3
"""Current-main mixed CPU/real PSRAM/SYS timer, owned resets and replay fault."""
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split('models={}')[0].replace("G=R/'build/io-retry-window'","G=R/'build/io-replay-main40'"),str(Path(__file__).with_name('run.py')),'exec'))
import importlib.util
BASE='6c9a40e25c7d96f708041dc25f6a21a5f3a99eed'
CPU=['rtl/arm/'+x+'.sv'for x in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split()]
FILES=CPU+['rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv','sim/pocket/psram_if4/cram_model.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_dsp_add.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/pocket/nds_psram.sv']+['rtl/sys/'+x+'.sv'for x in 'sys_ram sys_irq sys_timers sys_ipc sys_math sys_dma nds_sys'.split()]+['rtl/ds/nds_io.sv']
def build(n):
 d=G/('mixed-'+n);d.mkdir(exist_ok=True);inputs=[]
 for f in FILES:
  b=(G/'inputs/cram_model.sv').read_bytes()if f=='sim/pocket/psram_if4/cram_model.sv'else subprocess.check_output(['git','show',BASE+':'+f])if n=='before'else(R/f).read_bytes()
  if n=='mutant'and f=='rtl/arm/arm_core.sv':
   a=b'e1 <= io_retry_go ? io_retry_uop : u;';assert b.count(a)==1;b=b.replace(a,a+b"\n      if(io_retry_go)e1.wa <= 5'd1;")
  p=d/f;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 for f in ['compose_mixed.sv','compose_transport.sv']:
  p=d/f;b=(R/'sim/arm/io_retry_window'/f).read_bytes()
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 m=d/'Vtb_arm'
 if not m.exists():
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_arm','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','-GBF=1','-GSERVICE=3','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_IO_REPLAY','-GREPLAY='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(m),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_arm','model.json','build.log']:p.unlink()
 receipt=json.loads((d/'model.json').read_text());assert sha(m)==receipt['sha256']
 for p,h in receipt['inputs'].items():assert sha(G/p.split('/build/io-replay-main40/',1)[1])==h
 return m
spec=importlib.util.spec_from_file_location('cpucheck',G/'inputs/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c);prep=0
def small(cmd,**kw):
 global prep;prep+=1;assert not kw;call(cmd,G/('mixed-prepare-'+str(prep)+'.log'))
c.run=small
stem=G/'mixed';img=c.assemble((R/'sim/arm/io_retry_window/compose_mixed.s').read_text(),stem);cut=next(x.split()[0]for x in subprocess.check_output(['llvm-nm',stem.with_suffix('.elf')],text=True).splitlines()if x.endswith(' compare_end'))
models={n:build(n)for n in ['before','off','on','mutant']}
results={}
for reset in [0,1,2]:
 rows={};packets={};times={}
 for n in ['before','off','on']:
  out=G/f'mixed-{n}-reset{reset}';call([models[n],'+img0='+str(img),'+pc0=02000000','+run=1','+blat=9','+ldm_desc','+maxcycles=300000','+trace0='+str(out)+'.csv','+reset_kind='+str(reset)],out.with_suffix('.log'));t=out.with_suffix('.log').read_text();assert'TEST PASSED'in t and'chip_errors0'in t and'timeout'not in t.lower(),(n,reset,t[-1500:]);a=out.with_suffix('.csv').read_text().splitlines();rows[n]=a[:next(i for i,l in enumerate(a)if l.startswith(cut+','))];packets[n]=re.findall(r'^LDMDESC c=\d+ (.*)$',t,re.M);times[n]=re.findall(r'^cycles=(\d+)',t,re.M);assert packets[n] and any('04000108'in x for x in packets[n]) and any('tag=1'in x for x in packets[n])
  if reset:assert'RESET_POINT '+str(reset)in t
  if n=='on':assert int(re.findall(r'MIXED_REPLAYS (\d+)',t)[0])>0
 assert rows['before']==rows['off']==rows['on']and packets['before']==packets['off']==packets['on'],('mixed state/order',reset)
 assert times['before']==times['off'],('mixed default cycles',reset)
 results[str(reset)]=dict(states=len(rows['on']),packets=len(packets['on']),cycles=times);save(G/'mixed.json',results);print('MIXED',reset,results[str(reset)],flush=True)
out=G/'mixed-mutant';rc=call([models['mutant'],'+img0='+str(img),'+pc0=02000000','+run=1','+blat=9','+ldm_desc','+maxcycles=300000','+trace0='+str(out)+'.csv'],out.with_suffix('.log'),True);t=out.with_suffix('.log').read_text();assert'TEST FAILED'in t and'timeout'not in t.lower() and int(re.findall(r'MIXED_REPLAYS (\d+)',t)[0])>0
save(G/'mixed-mutation.json',dict(source='mixed-mutant/rtl/arm/arm_core.sv',actual_fault='reissued uop destination R1',caught='CPU fail, no timeout',exit=rc));print('MIXED_MUTANT_CAUGHT',flush=True)
