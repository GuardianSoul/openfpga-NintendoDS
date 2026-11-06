#!/usr/bin/env python3
"""One allocated worker: current-source captured write during owned2D returns."""
from pathlib import Path
import os,sys,json,hashlib,subprocess,resource,time,re,shutil
R=Path(__file__).resolve().parents[3];G=R/'build/dma-feed';os.chdir(R);assert'--allocated'in sys.argv
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(R/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
(G/'release').unlink(missing_ok=True);save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while'--await-release'in sys.argv and not(G/'release').exists():time.sleep(.2)
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd))
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(dict(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd,log=str(log)))+'\n')
  rc=wait_owned(p)
 if not allowed:assert rc==0,(str(log),rc,log.read_text()[-2500:])
 return rc
BASE='1363a89b'
FILES={'gpu2d_pkg.sv':'rtl/gpu2d/gpu2d_pkg.sv','gpu2d_ram.sv':'rtl/gpu2d/gpu2d_ram.sv','nds_ram.sv':'rtl/ds/nds_ram.sv','sys_ram.sv':'rtl/sys/sys_ram.sv','sys_dma.sv':'rtl/sys/sys_dma.sv','fabric.sv':'rtl/ds/nds_fabric.sv','nds_mr_arb.sv':'rtl/ds/nds_mr_arb.sv','nds_vram.sv':'rtl/ds/nds_vram.sv','nds_x2b.sv':'rtl/pocket/nds_x2b.sv','nds_sdram_bus.sv':'rtl/pocket/nds_sdram_bus.sv','nds_cdc.sv':'rtl/pocket/nds_cdc.sv','nds_psram.sv':'rtl/pocket/nds_psram.sv','psx_pq_psram.sv':'rtl/mem/psx_pq_psram.sv','sim_prims.sv':'sim/phase1/sim_prims.sv'}
def build(n):
 d=G/n;d.mkdir(exist_ok=True);inputs=[]
 for f,path in list(FILES.items())+[('cram_model.sv',None)]:
  b=(G/'qualified-source'/f).read_bytes()if path is None else subprocess.check_output(['git','show',BASE+':'+path])if n=='before'else(R/path).read_bytes()
  if n=='mutant'and f=='nds_vram.sv':
   a=b'assign vm_wdata = idle_cw ? c_wdata :';assert b.count(a)==1;b=b.replace(a,b"assign vm_wdata = idle_cw ? (tail_cw ? c_wdata ^ 32'd1 : c_wdata) :")
  if n=='early-mutant'and f=='nds_vram.sv':
   a=b'end else if (tail_cw) begin\n                    if (vm_write_capture)';assert b.count(a)==1;b=b.replace(a,b'end else if (tail_cw) begin\n                    if (1\'b1)')
  p=d/f
  if p.exists():assert p.read_bytes()==b
  else:p.write_bytes(b)
  inputs.append(p)
 p=d/'tb.sv';b=(R/'sim/ds/dma_feed_tail/tb.sv').read_bytes()
 if p.exists():assert p.read_bytes()==b
 else:p.write_bytes(b)
 inputs.append(p);m=d/'Vtb_dma_words'
 if not m.exists():
  cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_dma_words','-GOVERLAP=1','-GREISSUE=1','-GGROUP=1','-GARB_GROUP=1','-GSOURCE=1','-GSTART=1','-GPBW=1','-GPIPE=1','-GWCAP=1','--Mdir',d]
  if n!='before':cmd+=['+define+NEW_TAIL','-GTAIL='+str(int(n!='off'))]
  call(cmd+inputs,d/'build.log');save(d/'model.json',dict(sha256=sha(m),inputs={str(p):sha(p)for p in inputs}))
  for p in d.iterdir():
   if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_dma_words','model.json','build.log']:p.unlink()
 receipt=json.loads((d/'model.json').read_text());assert sha(m)==receipt['sha256']
 for p,h in receipt['inputs'].items():assert sha(p)==h
 return m
def actual(n,mode,words,stress,phase):
 tag=f'{n}-m{mode}-n{words}-pressure{stress}-phase{phase}';p=G/tag;m=build(n)
 if p.with_suffix('.log').exists() and not n.endswith('mutant'):
  rc=0
 else:
  rc=call([m,f'+mode={mode}',f'+ops={words}',f'+phase={phase}',*(['+stall']if stress else[])],p.with_suffix('.log'),n.endswith('mutant'))
 t=p.with_suffix('.log').read_text()
 if n.endswith('mutant'):return rc,t
 assert'PASS DMA words'in t and'GDATA_PASS'in t and'timeout'not in t.lower(),(tag,t[-2000:])
 c=re.findall(r'^CYCLES DMA(\d+) total(\d+)',t,re.M);assert len(c)==1
 row=dict(DMA_clocks=int(c[0][0]),total_clocks=int(c[0][1]),state=re.findall(r'^STATE .*$',t,re.M),physical=re.findall(r'^PHYS .*$',t,re.M),gdata=re.findall(r'^GDATA_PASS .*$',t,re.M),trace=re.findall(r'^TRACE .*$',t,re.M),tail=re.findall(r'^TAIL attempts(\d+) captures(\d+) unready(\d+)',t,re.M));assert row['state']and row['gdata']and row['physical']
 return row
results={}
if '--qualify' in sys.argv:
 cases=[(0,n,1,phase) for n in [32,96,256] for phase in [0,1,64,133,196]]+[(0,96,0,1)]+[(mode,96,1,1) for mode in [1,2,4,5,6,7,8,9,10,11,12,14,15,16]]+[(3,96,1,phase) for phase in [1,64]]
 for mode,n,stress,phase in cases:
  a=actual('before',mode,n,stress,phase);d=actual('off',mode,n,stress,phase);b=actual('on',mode,n,stress,phase)
  assert a==d,('default0 is not exact',mode,n,stress,phase)
  assert a['state']==b['state'] and a['physical']==b['physical'],('state/physical order',mode,n,stress,phase)
  if mode not in [0,3] or not stress:assert a==b,('fallback is not exact',mode,n,stress,phase)
  results[f'm{mode}-n{n}-p{stress}-phase{phase}']=dict(before=a,off=d,on=b)
  save(G/'qualification.json',dict(source=sha(R/'rtl/ds/nds_vram.sv'),cases=results))
  print('TAIL_CHECK',mode,n,stress,phase,'clocks',a['DMA_clocks'],b['DMA_clocks'],'tail',b['tail'],flush=True)
 faults={}
 for name in ['mutant','early-mutant']:
  rc,t=actual(name,0,96,1,1)
  assert rc!=0 and 'timeout' not in t.lower(),('fault escaped or timeout',name,rc)
  error=[x for x in t.splitlines() if 'Error' in x or 'failed' in x or 'readback' in x or 'ACK before' in x]
  assert error,('fault has no actual verdict',name,t[-1500:])
  faults[name]=dict(returncode=rc,actual_error=error,log_sha256=sha(G/f'{name}-m0-n96-pressure1-phase1.log'))
  save(G/'faults.json',faults);print('TAIL_FAULT_CAUGHT',name,error,flush=True)
 save(G/'qualification-complete.json',dict(source=sha(R/'rtl/ds/nds_vram.sv'),cases=len(results),faults=faults,log_hashes={p.name:sha(p)for p in G.glob('*-m*.log')}))
 print('TAIL_QUALIFICATION_COMPLETE',flush=True);sys.exit(0)
for mode,n,stress,phase in [(0,96,0,1),(0,96,1,1),(0,96,1,64)]:
 a=actual('before',mode,n,stress,phase);b=actual('on',mode,n,stress,phase);assert a['state']==b['state']and a['physical']==b['physical'],('state/physical order',mode,n,stress,phase)
 if not stress:assert a['DMA_clocks']==b['DMA_clocks']and a['trace']==b['trace']
 results[f'm{mode}-n{n}-p{stress}-phase{phase}']=dict(before=a,on=b);save(G/'pilot.json',dict(source=sha(R/'rtl/ds/nds_vram.sv'),cases=results));print('TAIL_PILOT',mode,n,stress,phase,'clocks',a['DMA_clocks'],b['DMA_clocks'],'tail',b['tail'],flush=True)
print('TAIL_PILOT_COMPLETE',flush=True)
