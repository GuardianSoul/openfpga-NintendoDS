#!/usr/bin/env python3
"""Exact-before CPU consumers: frozen inputs, paired state/order and cycle checks."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,resource,subprocess,sys,time
R=Path(__file__).resolve().parents[3];os.chdir(R);sys.dont_write_bytecode=True
p=argparse.ArgumentParser();p.add_argument('--allocated',action='store_true',required=True);p.add_argument('--await-release',action='store_true');p.add_argument('--out',type=Path,default=R/'build/wbd8-storage/cpu-v1');a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));sys.path.insert(0,str(R/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
save(G/'controller.json',dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,0)));print('GATED',(G/'controller.json').read_text(),flush=True)
while a.await_release and not(G/'release').exists():time.sleep(.2)
spec=importlib.util.spec_from_file_location('restore',R/'sim/arm/fetch_retry/prepare.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);m.restore(G/'gates',broad=True)
I=G/'gates/inputs';receipt=json.load(open(G/'gates/input-receipt.json'));V='build/tools/oss-cad-suite/bin/verilator';BASE='385039386d7d5d5a97f7c4ed4e6aaf96e6a553bf'
(G/'tmp').mkdir();os.environ['TMPDIR']=str(G/'tmp')
def call(argv,tag):
 guard();argv=list(map(str,argv));t=time.monotonic()
 with(G/(tag+'.log')).open('w')as f:
  q=subprocess.Popen(argv,stdout=f,stderr=subprocess.STDOUT);row=dict(pid=q.pid,starttime=Path('/proc',str(q.pid),'stat').read_text().split()[21],NI=os.getpriority(os.PRIO_PROCESS,q.pid),cmd=argv,log=str(G/(tag+'.log')))
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
  print('STAGE',tag,'PID',q.pid,flush=True);rc=wait_owned(q)
 row.update(exit=rc,reaped=True,wall_seconds=round(time.monotonic()-t,3));save(G/(tag+'.process.json'),row);assert rc==0,(tag,rc,(G/(tag+'.log')).read_text()[-2500:]);return G/(tag+'.log')
models={};CPU='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split();source_sha=sha(R/'rtl/arm/arm9_mem.sv')
hook='''\n integer qb_peak=0,qb_push=0,qb_pop=0,qb_full=0,qb_simul=0,qb_fd=0;string qb_name;
 initial if($value$plusargs("qcycle=%s",qb_name))qb_fd=$fopen(qb_name,"w");
 always @(posedge clk)if(!rst)begin
  if(dut.u_mem9.wb_n>qb_peak)qb_peak=dut.u_mem9.wb_n;
  if(dut.u_mem9.wd_push)qb_push++;
  if(dut.u_mem9.st==dut.u_mem9.S_WDRAIN&&b9_ack)begin qb_pop++;if(dut.u_mem9.wd_push)qb_simul++;end
  if(dut.u_mem9.wb_full&&dut.u_mem9.wq_e&&!dut.u_mem9.d_ok)qb_full++;
  if(qb_fd)$fdisplay(qb_fd,"%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%h",cycle,dut.u_mem9.wb_n,dut.u_mem9.wbuf_v?{dut.u_mem9.wbuf_a,dut.u_mem9.wbuf_d,dut.u_mem9.wbuf_be,dut.u_mem9.wbuf_tmr}:72'd0,dut.u_mem9.wd_push,dut.mem_hold,dut.u_mem9.d_wait,dut.u_mem9.nb_owned,dut.u_mem9.nb_ack,b9_req,b9_req?b9_addr:32'd0,b9_req&&b9_we?b9_wdata:32'd0,b9_req?b9_be:4'd0);
 end
 final begin $display("QUEUE_CPU peak%0d push%0d pop%0d full%0d simultaneous%0d",qb_peak,qb_push,qb_pop,qb_full,qb_simul);if(qb_fd)$fclose(qb_fd);end
'''
for name in ['before','on']:
 d=G/name;d.mkdir();files=[]
 for f in CPU:
  b=subprocess.check_output(['git','show',BASE+':rtl/arm/'+f+'.sv'])if name=='before'else(R/'rtl/arm'/(f+'.sv')).read_bytes();out=d/(f+'.sv');out.write_bytes(b);files.append(out)
 tb=(I/'cpu-final/tb.sv').read_text();needle=' .ARM9_READ_ACK_EARLY(1),';assert tb.count(needle)==1;tb=tb.replace(needle,' .ARM9_IO_REPLAY(1),'+needle);pos=tb.index('endmodule');tb=tb[:pos]+hook+tb[pos:];out=d/'tb.sv';out.write_text(tb);files.append(out)
 cmd=list(receipt['build_recipe'][-1]['cmd']);cmd[0]=V;cmd[cmd.index('--Mdir')+1]=str(d/'obj');cmd=[x for x in cmd if not x.endswith('.sv')]+files
 call(cmd,name+'-build');models[name]=d/'obj/Vtb_arm';save(d/'model.json',dict(sha256=sha(models[name]),inputs={str(f):sha(f)for f in files}));assert sha(R/'rtl/arm/arm9_mem.sv')==source_sha
recipes=[json.loads(l)for l in(I/'processes.jsonl').read_text().splitlines()];oldbase='build/ldm-service';packets=lambda s:re.findall(r'^PACKET.*$',s,re.M)
def run_pair(tag,args,cut=None,focused=False,known_failure=False):
 data={}
 for name,model in models.items():
  out=G/(tag+'-'+name);argv=[model,*args,'+trace0='+str(out)+'.csv','+trace1='+str(out)+'.a7.csv','+packets'];
  if focused:argv+=['+qcycle='+str(out)+'.cycles.csv']
  log=call(argv,tag+'-'+name);s=log.read_text();rows=out.with_suffix('.csv').read_text().splitlines()
  if cut:rows=rows[:next(i for i,x in enumerate(rows)if x.startswith(cut+','))]
  data[name]=dict(a7=(G/(tag+'-'+name+'.a7.csv')).read_text().splitlines(),rows=rows,packets=packets(s),cycles=re.findall(r'^cycles=(\d+)',s,re.M),PASS='TEST PASSED'in s,queue=re.findall(r'^QUEUE_CPU.*$',s,re.M),text=s)
  if known_failure:assert 'ctx1: timeout at pc=020000b8 retired=1490\nTEST FAILED (timeout)'in s
  else:assert data[name]['PASS'],(tag,name,s[-1700:])
 for key in ['rows','a7','packets','cycles','PASS','queue']:assert data['before'][key]==data['on'][key],(tag,key)
 if focused:assert(G/(tag+'-before.cycles.csv')).read_bytes()==(G/(tag+'-on.cycles.csv')).read_bytes(),(tag,'percycle')
 return dict(states=len(data['on']['rows']),packets=len(data['on']['packets']),cycles=data['on']['cycles'],queue=data['on']['queue'],state_packet_cycle_exact=True,retained_known_failure=known_failure)
# Fresh directed producer, both models consume the exact same image.
call(['llvm-mc','-triple=armv5te-none-eabi','-filetype=obj','-I',R/'sim/arm/tests',R/'sim/arm/wbd8_storage/directed.s','-o',G/'directed.o'],'asm')
call(['ld.lld','-Ttext=0x02000000','--entry=_start',G/'directed.o','-o',G/'directed.elf'],'link');call(['llvm-objcopy','-O','binary',G/'directed.elf',G/'directed.bin'],'objcopy');call(['python3','sim/arm/tools/mkhex.py',G/'directed.hex',str(G/'directed.bin')+'@0x02000000'],'mkhex')
nm=subprocess.check_output(['llvm-nm',G/'directed.elf'],text=True);cut=next(x.split()[0]for x in nm.splitlines()if x.endswith(' compare_end'));result=dict(source_sha256=source_sha,BASE=BASE,directed={},DENSE={},ARM={})
for latency in [0,2,9,31]:
 row=run_pair('directed'+str(latency),['+img0='+str(G/'directed.hex'),'+pc0=02000000','+run=1','+blat='+str(latency),'+maxcycles=3000000'],cut,True);result['directed'][str(latency)]=row;save(G/'results.json',result);print('DIRECTED',latency,row,flush=True)
for seed in range(1301,1326):
 tag='seed'+str(seed);cmd=next(x['cmd']for x in recipes if Path(x['log']).name=='cpu-final-'+tag+'.log');args=[x.replace(oldbase,str(I))for x in cmd[1:]if not x.startswith('+trace0=')];nm=subprocess.check_output(['llvm-nm',I/(tag+'.elf')],text=True);cut=next(x.split()[0]for x in nm.splitlines()if x.endswith(' compare_end'));result['DENSE'][str(seed)]=run_pair(tag,args,cut);save(G/'results.json',result);print('DENSE',seed,'PASS',flush=True)
for case in receipt['ARM_cases']:
 tag=Path(case['log']).stem.removeprefix('cpu-final-');args=[x.replace(oldbase,str(I))for x in case['cmd'][1:]if not x.startswith('+trace0=')];result['ARM'][tag]=run_pair('ARM-'+tag,args,known_failure=tag=='bpred7');save(G/'results.json',result);print('ARM',tag,'PASS'if tag!='bpred7'else'INHERITED_FAIL',flush=True)
print('WBD_CPU_COMPLETE',flush=True)
