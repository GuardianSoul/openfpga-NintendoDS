#!/usr/bin/env python3
"""One NI10/j1/t1 Laptop worker; immutable inputs and compact receipts."""
from pathlib import Path
import datetime,hashlib,json,os,resource,shutil,subprocess,sys,tarfile,time
ROOT=Path(__file__).resolve().parents[3];os.chdir(ROOT)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
P7=sha(ROOT/'rtl/ds/nds_arm7_port.sv')
OUT=Path('/tmp/nds-a7-data-handoff')/P7[:12];OUT.mkdir(parents=True,exist_ok=True)
H=OUT/'helpers';H.mkdir(exist_ok=True)
for n in ['worker_guard.py','sim_ownership.py']:
 (H/n).write_bytes(subprocess.check_output(['git','show','c74a3620:sim/arm/read_ack/'+n]))
sys.path.insert(0,str(H));from worker_guard import guard,wait_owned
V='build/tools/oss-cad-suite/bin/verilator'
def status(phase,pid=None):
 def start(p):
  try:return int(Path(f'/proc/{p}/stat').read_text().rsplit(')',1)[1].split()[19])
  except FileNotFoundError:return None
 j=dict(host='Laptop',phase=phase,P7=P7,controller=os.getpid(),PID=pid,starttime={'controller':start(os.getpid()),'PID':start(pid)if pid else None},NI=10,jobs=1,threads=1,updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
 (OUT/'status.json').write_text(json.dumps(j,indent=2)+'\n');print(json.dumps(j),flush=True)
def call(cmd,d,name,expected=None):
 guard();cmd=list(map(str,cmd));log=d/(name+'.log')
 with log.open('w')as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT)
  with(OUT/'processes.jsonl').open('a')as q:q.write(json.dumps(dict(controller=os.getpid(),pid=p.pid,argv=cmd,log=str(log),NI=10,time=time.time()))+'\n')
  status(d.name+'/'+name,p.pid);rc=wait_owned(p)
 text=log.read_text()
 if expected:assert rc!=0 and expected in text and 'timeout'not in text.lower(),(d.name,text[-2000:])
 else:assert rc==0,(d.name,text[-2000:])
 return text
def prune(d):
 for p in d.iterdir():
  if p.is_file()and(p.suffix in['.gch','.o','.a','.d']or(p.name.startswith('Vtb')and p.suffix in['.cpp','.h','.mk','.dat'])):p.unlink()
def pinned(path):return subprocess.check_output(['git','show','27340ba4:'+path])
def freeze(d,rels):
 d.mkdir(exist_ok=True)
 for rel in rels:
  data=(ROOT/rel).read_bytes();p=d/Path(rel).name
  if p.exists():assert p.read_bytes()==data,p
  else:p.write_bytes(data)
def leaf():
 variants=[('leaf',None),('fault-ack',('&& !busy_w && !rp_i && f_ack;','&& !busy_w && !rp_i;','premature/unowned data completion')),('fault-payload',('data_return ? f_rdata : rb_d','data_return ? (f_rdata ^ 32\'d1) : rb_d','owned data payload')),('fault-match',('rp_a == d_addr && rp_be == d_be','1\'b1','mismatched/orphaned lookup consumed owner')),('fault-consumed',("if (data_held) rb_v <= 1'b0;","if (data_held) rb_v <= 1'b1;",'consumed response replayed'))]
 result={}
 for name,fault in variants:
  d=OUT/name;freeze(d,['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv'])
  p=d/'nds_arm7_port.sv'
  if fault:
   old,new,expected=fault;s=p.read_text();assert s.count(old)==1;(d/'mutant.sv').write_text(s.replace(old,new));p=d/'mutant.sv'
  tb=d/'tb.sv';tb.write_bytes((ROOT/'sim/arm/a7_data_handoff/tb.sv').read_bytes())
  files=[q for q in sorted(d.glob('*.sv'))if q.name not in['nds_arm7_port.sv','mutant.sv']]+[p]
  (d/'inputs.json').write_text(json.dumps({q.name:sha(q)for q in files},indent=2)+'\n')
  model=d/'obj/Vtb_data'
  call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_data','--Mdir',model.parent,*files],d,'build');prune(model.parent)
  text=call([model],d,'run',fault[2]if fault else None)
  if not fault:assert'DATA_OWNER_PASS'in text
  result[name]=dict(model_SHA256=sha(model),expected=fault[2]if fault else'PASS12 owned read/write/replay/reset',caught=bool(fault))
 (OUT/'leaf-summary.json').write_text(json.dumps(result,indent=2)+'\n')
def cpu36():
 d=OUT/'cpu36';d.mkdir(exist_ok=True);(d/'source').mkdir(exist_ok=True)
 archive=ROOT/'docs/results/arm7-if4-pair-credit-20261101/cpu.tar.gz'
 assert sha(archive)=='306a116d63a5fb2ebcad02be6ac413d359866d0c636c0f1fc79ed3880ed91bd7'
 with tarfile.open(archive)as t:donor={m.name:t.extractfile(m).read()for m in t if m.isfile()}
 for name,data in donor.items():
  if name.startswith('source/')and name.endswith('.sv'):(d/name).write_bytes(data)
 rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_thumb.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv']
 for rel in rels:shutil.copyfile(ROOT/rel,d/'source'/Path(rel).name)
 old=pinned('rtl/ds/nds_arm7_port.sv');(d/'source/old_nds_arm7_port.sv').write_bytes(old.replace(b'module nds_arm7_port #',b'module old_nds_arm7_port #',1))
 (d/'source/old_nds_psram.sv').write_bytes(pinned('rtl/pocket/nds_psram.sv').replace(b'module nds_psram #',b'module old_nds_psram #',1))
 tb=donor['tb.sv'].decode();needle=' nds_arm7_port #(.WRAM_M10K(1),';assert tb.count(needle)==1;tb=tb.replace(needle,' nds_arm7_port #(.DATA_ACK_HANDOFF(1),.WRAM_M10K(1),');(d/'tb.sv').write_text(tb)
 record={'before':'27340ba4/9c405d1a P7; PHY6e98 both lanes','P7':P7,'only_change':'owned P7 data ACK/held completion, no CPU or device price change','sources':{p.name:sha(p)for p in sorted((d/'source').glob('*.sv'))},'TB':sha(d/'tb.sv')}
 (d/'sources.json').write_text(json.dumps(record,indent=2)+'\n')
 runner=donor['run.py'].decode().replace("ROOT=Path('/home/user/Git/NDS_Pocket-cpu-if4-credit')",f'ROOT=Path({str(ROOT)!r})').replace("OUT=Path('/tmp/nds-if4-credit-cpu')",f'OUT=Path({str(d)!r})')
 runner=runner.replace("Path('/home/user/Git/NDS_Pocket-cpu-a7critical/sw/tests/a7fetch39/build.py')","ROOT/'sw/tests/a7fetch39/build.py'")
 runner=runner.replace('SEQ2_DONE36+18private+actualbadthresholdfault','DATA_ACK_CPU_PASS36+18private; actual RTL negatives separate')
 runner=runner.replace('physical pair/order/owner/reset faults run separately; CPU/P7 unchanged','four actual P7 ACK/payload/match/consumption faults qualified separately; CPU unchanged, P7 changed')
 (d/'run.py').write_text(runner);(d/'prepare.py').write_text('# Frozen by a7_data_handoff/run.py cpu36\n');shutil.copytree(H,d/'helpers',dirs_exist_ok=True)
 call(['python3','-u',d/'run.py'],d,'controller')
 summary=json.loads((d/'receipt/summary.json').read_text());assert summary['PASS']and len(summary['rows'])==36
 assert all(v['after']<=v['before']for v in summary['component_MAIN_slopes'].values())
def extra():
 d=OUT/'extra';d.mkdir(exist_ok=True)
 rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']
 freeze(d,rels)
 (d/'old_nds_arm7_port.sv').write_bytes(pinned('rtl/ds/nds_arm7_port.sv').replace(b'module nds_arm7_port #',b'module old_nds_arm7_port #',1))
 assert sha(ROOT/'docs/results/arm7-ack-handoff-20261101/extra.tar.gz')=='0fe8fb0386eb6d49295cfe690f83c5faf237552e8819cdcc1c2f8d8aeceb4bd0'
 with tarfile.open(ROOT/'docs/results/arm7-ack-handoff-20261101/extra.tar.gz')as t:
  owner=t.extractfile('receipt/tb_owner.sv').read().decode();mixed=t.extractfile('receipt/tb_mixed.sv').read().decode()
 owner=owner.replace('nds_arm7_port #(', 'nds_arm7_port #(.DATA_ACK_HANDOFF(1),')
 (d/'tb_owner.sv').write_text(owner)
 # Keep both logical F profiles identical. Compare actual pre-change P7
 # against the opt-in candidate on the same CPU and physical service model.
 mixed=mixed.replace('.MAIN_IF_FLOW(T==1)', '.MAIN_IF_FLOW(1)')
 old=' nds_arm7_port #(.MAIN_IF_FLOW(1),.MAIN_IF_QUAD(1),.MAIN_IF_EARLY(1)) port7(`PORT_PINS);'
 new=''' wire read_owner;
 if(T==0)begin:before_port
 old_nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_FLOW(1),.MAIN_IF_QUAD(1),.MAIN_IF_EARLY(1)) port7(`PORT_PINS);
 assign read_owner=port7.rp_i;
 end else begin:after_port
 nds_arm7_port #(.DATA_ACK_HANDOFF(1),.WRAM_M10K(1),.MAIN_IF_FLOW(1),.MAIN_IF_QUAD(1),.MAIN_IF_EARLY(1)) port7(`PORT_PINS);
 assign read_owner=port7.rp_i;
 end'''
 assert mixed.count(old)==1;mixed=mixed.replace(old,new)
 mixed=mixed.replace('.w_req(),.w_we(),.w_addr(),.w_be(),.w_wdata(),.w_ok(1\'b0),.w_rdata(32\'b0)', '.w_req(wreq[T]),.w_we(wwe[T]),.w_addr(wa_mem[T]),.w_be(wbe[T]),.w_wdata(wwd[T]),.w_ok(wok[T]),.w_rdata(wrd[T])')
 mixed=mixed.replace('logic[1087:0] states[2][100]', 'logic[1087:0] states[2][512]').replace('retires[T]>=100','retires[T]>=512')
 mixed=mixed.replace(' int mirror=0,patch_index,target_pc,end_pc;string image;', ''' logic[1:0]wreq,wwe,wok=0;logic[17:2]wa_mem[2];logic[3:0]wbe[2],hb[2];logic[31:0]wwd[2],wrd[2],wram[2][256];
 logic data_packet[2];logic[68:0]data_events[2][128];int data_count[2];integer statefd[2];string trace;
 int latency=2;int mirror=0,patch_index,target_pc,end_pc;string image;''')
 mixed=mixed.replace(' always @(posedge clk)begin\n  ack[T]<=0;', ''' always @(posedge clk)begin
  wok[T]<=!rst&&wreq[T];
  if(wreq[T])begin
   wrd[T]<=wram[T][wa_mem[T][9:2]];
   if(wwe[T])for(int b=0;b<4;b++)if(wbe[T][b])wram[T][wa_mem[T][9:2]][b*8+:8]<=wwd[T][b*8+:8];
  end
  ack[T]<=0;''')
 mixed=mixed.replace('k[T]<=0;delay_n[T]<=2;', 'k[T]<=0;delay_n[T]<=latency;hb[T]<=fbe[T];data_packet[T]<=fw[T]||!read_owner;')
 mixed=mixed.replace('if(!fw[T])for(int j=0;j<4;j++)packet[T][j]<=rom[T][word_index(fa[T])+j];', "if(!fw[T]&&fa[T][31:24]==8'h02)for(int j=0;j<4;j++)packet[T][j]<=rom[T][word_index(fa[T])+j];")
 mixed=mixed.replace("else $fatal(1,\"unexpected store%h\",ha[T]);", "else if(ha[T][31:24]!=8'h04)$fatal(1,\"unexpected store%h\",ha[T]);")
 mixed=mixed.replace('active[T]<=0;\n    if(hw[T])begin', '''active[T]<=0;
    if(data_packet[T])begin
     if(data_count[T]>=128)$fatal(1,"too many data packets");
     data_events[T][data_count[T]]={hw[T],ha[T],hb[T],hw[T]?hd[T]:fq[T]};data_count[T]++;
    end
    if(hw[T])begin''')
 mixed=mixed.replace('rom[T][word_index(ha[T])];end', "(ha[T][31:24]==8'h02 ? rom[T][word_index(ha[T])] : 32'hf381a567);end")
 mixed=mixed.replace('retires[T]++;', '$fdisplay(statefd[T],"%h",states[T][retires[T]]);retires[T]++;')
 mixed=mixed.replace('  for(int t=0;t<2;t++)begin\n   retires[t]=0;', '''  void'($value$plusargs("lat=%d",latency));
  if(!$value$plusargs("trace=%s",trace))$fatal(1,"missing trace");
  for(int t=0;t<2;t++)begin
   statefd[t]=$fopen($sformatf("%s-m%0d.states",trace,t),"w");data_count[t]=0;for(int j=0;j<256;j++)wram[t][j]=0;
   retires[t]=0;''')
 mixed=mixed.replace('  $display("PASS actual ARM7 flow mixed', '''  if(data_count[0]!=data_count[1])$fatal(1,"data packet cardinality changed");
  for(int j=0;j<data_count[0];j++)if(data_events[0][j]!==data_events[1][j])$fatal(1,"data packet order/payload changed");
  for(int t=0;t<2;t++)$fclose(statefd[t]);
  $display("DATA_PACKETS %0d exact",data_count[0]);
  $display("PASS actual ARM7 flow mixed''')
 (d/'tb_mixed.sv').write_text(mixed)
 libs=[d/Path(p).name for p in rels if not p.endswith('arm7_ds.sv')]
 models={}
 for top in ['tb_owner','tb_mixed']:
  obj=d/top;model=obj/('V'+top)
  if not model.exists():call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module',top,'--Mdir',obj,*libs,*([d/'arm7_ds.sv',d/'old_nds_arm7_port.sv']if top=='tb_mixed'else[]),d/(top+'.sv')],d,top+'-build')
  prune(obj);models[top]=dict(path=str(model),sha256=sha(model))
 if not(d/'owner.log').exists():call([models['tb_owner']['path']],d,'owner')
 assert'OWNER_PASS29'in(d/'owner.log').read_text()
 results=[]
 programs=[('smc',subprocess.check_output(['git','show','c74a3620:docs/results/arm7-main-quad-20261101/modified.s']),2,range(4),[2]),('thumb',subprocess.check_output(['git','show','c74a3620:sim/arm/a7fetch/mixed.s']),1,range(1),[2]),('data',(ROOT/'sim/arm/a7_data_handoff/data.s').read_bytes(),3,range(1),[0,1,2,3,7,8])]
 for name,assembly,writes,mirrors,latencies in programs:
  asm=d/(name+'.s');asm.write_bytes(assembly);elf=d/(name+'.elf');binary=d/(name+'.bin');image=d/(name+'.hex')
  call(['clang','--target=armv4t-none-eabi','-mcpu=arm7tdmi','-fuse-ld=lld','-nostdlib','-Wl,-Ttext=0x02080000',asm,'-o',elf],d,name+'-assemble')
  call(['llvm-objcopy','-O','binary',elf,binary],d,name+'-binary');raw=binary.read_bytes();raw+=bytes((-len(raw))%4);image.write_text(''.join(f'{int.from_bytes(raw[i:i+4],"little"):08x}\n'for i in range(0,len(raw),4)))
  syms={n:int(a,16)for a,t,n in(line.split()for line in subprocess.check_output(['llvm-nm',elf],text=True).splitlines()if len(line.split())==3)}
  for mirror in mirrors:
   for lat in latencies:
    stem=d/f'{name}-m{mirror}-lat{lat}';text=call([models['tb_mixed']['path'],f'+img={image}',f'+patch={(syms["patch_ptr"]-0x02080000)//4}',f'+target={syms["target"]}',f'+endpc={syms["compare_end"]}',f'+mirror={mirror}',f'+writes={writes}',f'+lat={lat}',f'+trace={stem}'],d,stem.name)
    assert'PASS actual ARM7 flow mixed'in text
    assert Path(str(stem)+'-m0.states').read_bytes()==Path(str(stem)+'-m1.states').read_bytes()
    results.append(dict(program=name,mirror=mirror,latency=lat))
 arm=[ROOT/'rtl/arm/arm_pkg.sv']+sorted(p for p in(ROOT/'rtl/arm').glob('*.sv')if p.name!='arm_pkg.sv')
 domain=arm+[ROOT/p for p in['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_arm7_port_min.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/gpu2d/gpu2d_ram.sv']]
 routes=[]
 for fast,solo,cache,quad in[(0,5,1,1),(1,5,1,1),(0,3,1,1),(1,3,1,1),(0,5,0,1),(1,5,0,1),(0,5,1,0)]:
  name=f'route-{fast}-{solo}-{cache}-{quad}';call([V,'--lint-only','--timing','-Wno-fatal','--top-module','cpu_domain',f'-GCPU_FAST={fast}',f'-GA9_SOLO={solo}',f'-GARM7_CACHE={cache}',f'-GA7_IF_QUAD={quad}','-GA7_DATA_ACK=1','-GA7_IF_FLOW=1','-GARM9_WAYS=4','-GA9_OPT=461366243',*domain],d,name);routes.append([fast,solo,cache,quad])
 (OUT/'extra-summary.json').write_text(json.dumps(dict(PASS=True,owner=29,models=models,mixed=results,routes=routes),indent=2)+'\n')
def export():
 dst=ROOT/'build/a7-data-handoff';dst.mkdir(parents=True,exist_ok=True)
 with tarfile.open(dst/'results.tar.gz','w:gz',compresslevel=6)as t:
  for p in sorted(OUT.rglob('*')):
   if p.is_file()and'__pycache__'not in p.parts:t.add(p,arcname=str(p.relative_to(OUT)),recursive=False)
 (dst/'archive.json').write_text(json.dumps(dict(P7=P7,out=str(OUT),sha256=sha(dst/'results.tar.gz')),indent=2)+'\n')
def witness():
 d=OUT/'witness';d.mkdir(exist_ok=True);e=OUT/'extra'
 assert json.loads((OUT/'extra-summary.json').read_text())['PASS']
 for p in e.glob('*.sv'):shutil.copyfile(p,d/p.name)
 shutil.copyfile(ROOT/'sim/arm/a7_data_handoff/observe.sv',d/'observe.sv')
 tb=(d/'tb_mixed.sv').read_text().replace('module tb_mixed;','module tb_mixed;\n int test_cycles=0;always @(posedge clk)if(!rst)test_cycles++;')
 tb=tb.replace('  $display("DATA_PACKETS', '  $display("FIXTURE_CYCLES %0d",test_cycles);\n  $display("DATA_PACKETS');(d/'tb_mixed.sv').write_text(tb)
 files=[p for p in sorted(d.glob('*.sv'))if p.name!='tb_owner.sv']
 model=d/'obj/Vtb_mixed';call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_mixed','--Mdir',model.parent,*files],d,'build');prune(model.parent)
 syms={n:int(a,16)for a,t,n in(line.split()for line in subprocess.check_output(['llvm-nm',e/'data.elf'],text=True).splitlines()if len(line.split())==3)}
 results={}
 for enabled in[0,1]:
  stem=d/('on'if enabled else'off');cmd=[model,f'+img={e/"data.hex"}',f'+patch={(syms["patch_ptr"]-0x02080000)//4}',f'+target={syms["target"]}',f'+endpc={syms["compare_end"]}','+mirror=0','+writes=3','+lat=2',f'+trace={stem}']
  if enabled:cmd+=[f'+a7data_witness={d/"owner"}']
  text=call(cmd,d,stem.name);assert'PASS actual ARM7 flow mixed'in text
  results[str(enabled)]={'cycles':next(l for l in text.splitlines()if l.startswith('FIXTURE_CYCLES')),'states':{str(t):sha(Path(str(stem)+f'-m{t}.states'))for t in[0,1]}}
 assert results['0']==results['1']
 (OUT/'witness-summary.json').write_text(json.dumps(dict(PASS=True,model_SHA256=sha(model),passivity=results),indent=2)+'\n')
status('preparing '+sys.argv[1]);shutil.copyfile(Path(__file__),OUT/(sys.argv[1]+'-controller.py'))
try:
 if sys.argv[1]=='leaf':leaf()
 elif sys.argv[1]=='cpu36':cpu36()
 elif sys.argv[1]=='extra':extra()
 elif sys.argv[1]=='witness':witness()
 else:raise ValueError(sys.argv[1])
 status(sys.argv[1]+' PASS')
finally:export()
