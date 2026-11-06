#!/usr/bin/env python3
"""One allocated NI10/j1/t1 actual-DMA/CAP_CHAIN1 pin-memory chain."""
from pathlib import Path
import hashlib,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];G=R/'build/dma-cut-turn-v3';G.mkdir(parents=True,exist_ok=True);os.chdir(R)
assert '--allocated'in sys.argv;os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-2500:])
 return rc
BASE='f6850d09'
FILES=['rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/sys/sys_ram.sv','rtl/sys/sys_dma.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_vram.sv','rtl/pocket/nds_x2b.sv','rtl/pocket/nds_sdram_bus.sv','rtl/pocket/nds_sdram_mc.sv','rtl/pocket/nds_cdc.sv','rtl/pocket/nds_psram.sv','rtl/mem/psx_pq_psram.sv','sim/phase1/sdram_chip_model.sv','sim/phase1/sim_prims.sv']
def build(n):
 d=G/n;d.mkdir(exist_ok=True);inputs=[]
 for rel in FILES+['sim/ds/dma_cut_turn/cram_model.sv','sim/ds/dma_cut_turn/tb.sv']:
  b=subprocess.check_output(['git','show',BASE+':'+rel])if n=='before'and rel in FILES else(R/rel).read_bytes()
  if n=='payload-mutant'and rel=='rtl/pocket/nds_sdram_bus.sv':
   a=b'b_we <= s_we; b_quad <= s_quad; b_addr <= s_addr; b_wdata <= s_wdata; b_be <= s_be;';assert b.count(a)==1;b=b.replace(a,b"b_we <= s_we; b_quad <= s_quad; b_addr <= s_addr; b_wdata <= cut_turn ? (s_wdata ^ 32'd1) : s_wdata; b_be <= s_be;")
  if n=='early-mutant'and rel=='rtl/pocket/nds_sdram_bus.sv':
   a=b'wire cut_turn = CUT_WRITE_TURN && CUT_TAG && !reset && busy && take_t != take_seen';assert b.count(a)==1;b=b.replace(a,b'wire cut_turn = CUT_WRITE_TURN && CUT_TAG && !reset && busy')
  p=d/rel;p.parent.mkdir(parents=True,exist_ok=True)
  if p.exists():assert p.read_bytes()==b,p
  else:p.write_bytes(b)
  inputs.append(p)
 m=d/'Vtb_dma_words'
 if not m.exists():
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_dma_words','-GOVERLAP=1','-GREISSUE=1','-GGROUP=1','-GARB_GROUP=1','-GSOURCE=1','-GSTART=1','-GPBW=1','-GPIPE=1','-GWCAP=1','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_TURN','-GTURN='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(m),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_dma_words','model.json','build.log']:p.unlink()
 return m
def actual(n,words,stress,phase,mode=0,reset=False):
 m=build(n);p=G/(f'{n}-m{mode}-n{words}-p{stress}-phase{phase}'+('-reset'if reset else''))
 if not p.with_suffix('.log').exists():
  rc=call([m,f'+mode={mode}',f'+ops={words}',f'+phase={phase}',*(['+stall']if stress else[]),*(['+reset_turn']if reset else[])],p.with_suffix('.log'),n.endswith('mutant'))
 else:rc=1 if '%Fatal:'in p.with_suffix('.log').read_text()else 0
 t=p.with_suffix('.log').read_text()
 if n.endswith('mutant'):return rc,t,p
 if reset:
  assert'TURN_RESET_PASS'in t and'timeout'not in t.lower();return dict(reset=re.findall(r'^TURN_RESET_PASS .*$',t,re.M))
 assert'PASS DMA words'in t and'GDATA_PASS'in t and'timeout'not in t.lower(),(p,t[-2000:])
 times=re.findall(r'^CYCLES DMA(\d+) total(\d+)',t,re.M);assert len(times)==1
 turns=re.findall(r'^TURN pending(\d+) captures(\d+) capPairs(\d+) capPops(\d+) chipR(\d+) chipW(\d+) chipErrors(\d+)',t,re.M);assert len(turns)==1
 return dict(performed=int(re.search(r'PERFORMED turns(\d+)',t)[1]),DMA_clocks=int(times[0][0]),total_clocks=int(times[0][1]),turn=dict(zip('pending captures capPairs capPops chipR chipW chipErrors'.split(),map(int,turns[0]))),state=re.findall(r'^STATE .*$',t,re.M),physical=re.findall(r'^PHYS .*$',t,re.M),DMAEND=re.findall(r'^DMAEND .*$',t,re.M),gdata=re.findall(r'^GDATA_PASS .*$',t,re.M),trace=re.findall(r'^TRACE .*$',t,re.M))
results={}
# Measure this actual path before introducing the only production candidate.
if '--baseline-only'in sys.argv:
 for words,stress,phase in [(96,0,1),(96,1,1),(96,1,64)]:
  a=actual('before',words,stress,phase);results[f'n{words}-p{stress}-phase{phase}']=a;save(G/'baseline.json',dict(source=BASE,cases=results));print('PHYSICAL_BASELINE',words,stress,phase,{k:a[k]for k in ['DMA_clocks','total_clocks','turn']},flush=True)
 print('PHYSICAL_BASELINE_COMPLETE',flush=True);sys.exit(0)
# A fresh qualification defaults to all27. The sealed execution reused the
# immutable26 v2 cases and ran v3 only for reset/faults; both drivers are frozen.
cases=[(n,p,phase,0,False)for n in [32,96,256,1024]for p,phase in [(0,1),(1,1),(1,64),(1,133),(1,196)]]
cases +=[(96,1,1,m,False)for m in [1,2,3,4,5,8]]+[(96,0,1,0,True)]
if '--reset-faults'in sys.argv:cases=[(96,0,1,0,True)]
for words,stress,phase,mode,reset in cases:
 a=actual('before',words,stress,phase,mode,reset);d=actual('off',words,stress,phase,mode,reset);b=actual('on',words,stress,phase,mode,reset)
 assert a==d,('default exact',words,stress,phase,mode,reset)
 if not reset:
  for k in ['state','physical','DMAEND']:assert a[k]==b[k],('state/order',k,words,stress,phase,mode)
  for x in [a,b]:
   assert x['turn']['chipErrors']==0 and x['turn']['capPairs']==x['turn']['capPops']==(8 if stress else 0)
   g=re.fullmatch(r'GDATA_PASS pairs(\d+) max(\d+) period197 digest([0-9a-f]+)',x['gdata'][0]);assert g and int(g[1])==(32 if stress else 0)and int(g[2])<=197
  if mode in [1,2,4,5,8]:assert b['DMA_clocks']==a['DMA_clocks'] and b['turn']['pending']==0,('DMA fallback',mode)
 key=f'm{mode}-n{words}-p{stress}-phase{phase}'+('-reset'if reset else'')
 results[key]=dict(input=dict(words=words,stress=stress,phase=phase,mode=mode,reset=reset),before=a,off=d,on=b)
 save(G/'qualification.json',dict(source=sha(R/'rtl/pocket/nds_sdram_bus.sv'),cases=results))
 print('TURN_CHECK',key,(a.get('DMA_clocks'),b.get('DMA_clocks')),flush=True)
faults={}
for n,reason in [('payload-mutant','readback'),('early-mutant','turnover preceded actual physical take')]:
 rc,t,p=actual(n,96,1,64);assert rc!=0 and'timeout'not in t.lower()and reason in t,(n,t[-2000:])
 faults[n]=dict(returncode=rc,errors=[l for l in t.splitlines()if'%Fatal:'in l],log_sha256=sha(p.with_suffix('.log')));save(G/'faults.json',faults);print('TURN_FAULT_CAUGHT',n,faults[n],flush=True)
save(G/'complete.json',dict(source=sha(R/'rtl/pocket/nds_sdram_bus.sv'),cases=len(results),faults=faults));print('TURN_COMPLETE',flush=True)
