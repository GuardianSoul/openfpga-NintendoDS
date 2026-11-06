#!/usr/bin/env python3
"""One paired before/current CPU model: default CPU/consumer state/order/cycle equivalence for passive metadata change."""
from pathlib import Path
import argparse,datetime,hashlib,io,json,os,re,resource,subprocess,tarfile,time

R=Path(__file__).resolve().parents[3]
P=argparse.ArgumentParser(description=__doc__)
P.add_argument('--output',type=Path,default=R/'build/stm4-meta/cpu')
P.add_argument('--verilator',default=os.environ.get('VERILATOR','verilator'))
P.add_argument('--status',type=Path)
a=P.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
I=D/'inputs';I.mkdir();S=D/'source';S.mkdir()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
(D/'tmp').mkdir();os.environ['TMPDIR']=str(D/'tmp')
sha=lambda b:hashlib.sha256(b).hexdigest()
base='362fea1dc1fcaee361977f06fd12826d45d03699'
packet='740c0c981d3daca32deee9efcb87b3b0aa99c834:docs/results/arm9-fetch-retry-20261101/'
git=lambda name:subprocess.check_output(['git','show',name],cwd=R)
qualification=json.loads(git(packet+'qualification.json'))
archive=git(packet+qualification['archive']['file']);assert sha(archive)==qualification['archive']['sha256']
with tarfile.open(fileobj=io.BytesIO(archive))as t:
 for n,expected in qualification['archive']['files'].items():
  if not(n.startswith('gates/inputs/')or n.startswith('gates/gold-suite/')or n in ['gates/input-receipt.json','gates/compare-cuts.json']):continue
  value=t.extractfile(n).read();assert len(value)==expected['bytes']and sha(value)==expected['sha256']
  target=D/n.removeprefix('gates/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(value)
inputs=json.loads((D/'input-receipt.json').read_text());cuts=json.loads((D/'compare-cuts.json').read_text())
tb=(I/'cpu-final/tb.sv').read_text();start=tb.index('  arm_cpu #(');stop=tb.index('\n  );',start)+len('\n  );')
instance=tb[start:stop].replace('arm_cpu #(','arm_cpu_before #(').replace(') dut (',') prior (')
outputs={'a7_i_req':1,'a7_i_addr':32,'a7_d_req':1,'a7_d_we':1,'a7_d_be':4,'a7_d_addr':32,'a7_d_wdata':32,
 'b9_req':1,'b9_we':1,'b9_addr':32,'b9_wdata':32,'b9_be':4,'dbg_wen':1,'dbg_wa':6,'dbg_wd':32,
 'dbg_retire':1,'dbg_tid':1,'dbg_pc':32,'dbg_cpsr':32}
for name in outputs:instance=instance.replace('('+name+')','(p_'+name+')')
declarations='\n'.join('wire '+(''if width==1 else'['+str(width-1)+':0] ')+'p_'+name+';'for name,width in outputs.items())
tb=tb.replace('  arm_cpu #(', '  arm_cpu #(.A7_EXEC_META(0),.A7_STM4_META(1),',1).replace(') dut (', ') dut (.a7_exec_meta(observed_meta),.a7_stm4_request(observed_stm),.a7_stm4_accept(observed_accept),',1)
declarations+='\narm_pkg::a7_exec_meta_t observed_meta;arm_pkg::a7_stm4_meta_t observed_stm;wire observed_accept;'
observer=(R/'sim/arm/stm4_meta/cpu_pair.svh').read_text()
assert tb.count('endmodule')==1
tb=tb.replace('endmodule',declarations+'\n'+instance+'\n'+observer+'\nendmodule')
(S/'tb.sv').write_text(tb)
files=[]
for name in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds'.split():
 p=S/(name+'.sv');p.write_bytes((R/'rtl/arm'/(name+'.sv')).read_bytes());files.append(p)
for name in ['arm_regfile','arm_core','arm_cpu','arm9_mem','arm9_ram','arm7_ds']:
 value=git(base+':rtl/arm/'+name+'.sv')
 if name=='arm_regfile':value=value.replace(b'module arm_regfile #(',b'module arm_regfile_before #(')
 elif name=='arm_core':value=value.replace(b'module arm_core ',b'module arm_core_before ').replace(b'arm_regfile #(',b'arm_regfile_before #(')
 elif name=='arm_cpu':value=value.replace(b'module arm_cpu ',b'module arm_cpu_before ').replace(b'arm_core #(',b'arm_core_before #(').replace(b'arm9_mem #(',b'arm9_mem_before #(').replace(b'arm7_ds #(',b'arm7_ds_before #(')
 elif name=='arm9_mem':value=value.replace(b'module arm9_mem ',b'module arm9_mem_before ').replace(b'arm9_ram #(',b'arm9_ram_before #(')
 elif name=='arm7_ds':value=value.replace(b'module arm7_ds import',b'module arm7_ds_before import')
 else:value=value.replace(b'module arm9_ram #(',b'module arm9_ram_before #(')
 assert b'module '+(name+'_before').encode()+b' 'in value
 p=S/(name+'_before.sv');p.write_bytes(value);files.append(p)
files.append(S/'tb.sv')
result=dict(base=base,source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),controller=os.getpid(),controller_starttime=Path('/proc/self/stat').read_text().split()[21],source_SHA256={p.name:sha(p.read_bytes())for p in files},input_packet=packet,input_archive_SHA256=qualification['archive']['sha256'],stages=[],DENSE={},ARM={})
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def status(phase,p=None):
 if not a.status:return
 s=json.loads(a.status.read_text());s['phase']=phase;s['worker']=dict(host='Desktop',controller=os.getpid()if p else None,PID=p.pid if p else None,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21]if p else None,jobs=1 if p else 0,threads=1 if p else 0,NI=10);s['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 temp=a.status.with_suffix('.tmp.'+str(os.getpid()));temp.write_text(json.dumps(s,indent=2)+'\n');temp.replace(a.status)
def call(cmd,tag,seconds=180):
 cmd=list(map(str,cmd));start=time.monotonic()
 with (D/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);s=dict(tag=tag,PID=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd);result['stages'].append(s);save();status(tag,p);print(json.dumps(dict(tag=tag,PID=p.pid)),flush=True)
  try:s['exit']=p.wait(timeout=seconds)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);s['exit']=p.returncode;s['timeout']=True
 s['reaped']=True;s['wall_seconds']=round(time.monotonic()-start,3);save();status(tag+' terminal');return s['exit']
cmd=list(inputs['build_recipe'][-1]['cmd']);cmd=cmd[:next(i for i,x in enumerate(cmd)if x.endswith('.sv'))]
assert cmd[cmd.index('-j')+1]=='1' and cmd[cmd.index('--threads')+1]=='1',cmd
cmd[0]=a.verilator;cmd[cmd.index('--Mdir')+1]=str(D/'obj');cmd+=list(map(str,files))
assert call(cmd,'build',300)==0,(D/'build.log').read_text()[-1800:]
model=D/'obj/Vtb_arm';result['model_SHA256']=sha(model.read_bytes());save()
recipes=[json.loads(x)for x in(I/'processes.jsonl').read_text().splitlines()]
oldbase='build/ldm-service'
for tag,recipe in [('seed'+str(seed),next(x['cmd']for x in recipes if Path(x['log']).name=='cpu-final-seed'+str(seed)+'.log'))for seed in range(1301,1326)]+[('ARM-'+Path(c['log']).stem.removeprefix('cpu-final-'),c['cmd'])for c in inputs['ARM_cases']]:
 argv=[str(model)]+[x.replace(oldbase,str(I))for x in recipe[1:]]
 argv=[('+trace0='+str(D/(tag+'.csv')))if x.startswith('+trace0=')else x for x in argv]
 rc=call(argv,tag);log=(D/(tag+'.log')).read_text();pair=re.findall(r'SWP_CPU_PAIR_PASS cycles(\d+) retired(\d+) writes(\d+) secondary(\d+)',log)
 assert rc==0 and len(pair)==1,(tag,rc,log[-1500:])
 row=dict(exit=rc,pair_cycles=int(pair[0][0]),retired=int(pair[0][1]),writes=int(pair[0][2]),secondary=int(pair[0][3]),functional='TEST PASSED'in log)
 cache=re.findall(r'SWP_DEFAULT_CACHE_CONSUMERS ihit(\d+) dhit(\d+) dtwrite(\d+) itwrite(\d+)',log);assert len(cache)==1
 row['cache']=dict(zip(['ihit','dhit','dtwrite','itwrite'],map(int,cache[0])))
 if tag.startswith('seed'):
  seed=tag.removeprefix('seed');cut=cuts[seed]
  def prefix(path):
   lines=path.read_text().splitlines();stop=next(i for i,x in enumerate(lines)if x.startswith(cut+','));return lines[:stop]
  current=prefix(D/(tag+'.csv'));gold=prefix(I/('cpu-final-'+tag+'.csv'))
  row.update(states=len(current),retained_gold_state_exact=current==gold);result['DENSE'][seed]=row;save()
  assert row['functional']and row['retained_gold_state_exact'],(tag,row)
 else:
  case=tag.removeprefix('ARM-');result['ARM'][case]=row;save()
  if not row['functional']:
   known='ctx1: timeout at pc=020000b8 retired=1490\nTEST FAILED (timeout)'
   assert case=='bpred7'and known in log and known in(D/'gold-suite'/('cpu-final-'+case+'.log')).read_text(),(case,row,log[-1200:])
 print(tag,json.dumps(row),flush=True)
assert len(result['DENSE'])==25 and len(result['ARM'])==26
result['status']='PASS25DENSE/26tb_arm exact before-state/cycle/read/retirement/write/bus order; inherited bpred7 only';save();status(result['status']);print(result['status'],flush=True)
