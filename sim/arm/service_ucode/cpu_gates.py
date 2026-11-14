#!/usr/bin/env python3
"""Exact priced-controller CPU25normal/25DENSE/tb_arm paired qualification.

One serial NI10 worker, one locked -j4 build; no native fit or game sweep.
"""
import pathlib,os,json,hashlib,subprocess,fcntl,shutil,re,resource,time,importlib.util,sys,argparse
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=pathlib.Path,default=W/'build/cpu232-service-cpu-gates');args=ap.parse_args();D=args.output.resolve();D.mkdir(parents=True,exist_ok=False)
S=D/'source';S.mkdir();I=D/'inputs';I.mkdir();L=D/'logs';L.mkdir()
STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
PRICE='d49f54bc8af803924de402b96d62914b8ff62058';BASE='232c26ac0ee2a23abffa6397c69802badee0e999'
H=lambda b:hashlib.sha256(b).hexdigest();git=lambda rev,p:subprocess.check_output(['git','show',rev+':'+p],cwd=W)
r={'status':'PREPARING','price_source':PRICE,'control':BASE,'controller_PID':os.getpid(),'NI':10,'sources':{},'inputs':{},'stages':[],'normal':{},'DENSE':{},'tb_arm':{},'inherited_failures':[]}
def save():(D/'result.json').write_text(json.dumps(r,indent=2)+'\n')
def status(phase,child=None):
 d=json.loads(STATUS.read_text());d.update(phase=phase,source='Exactd49f54bcpricecontroller+232ccontrolinoneisolatedCPUharness;noRootworktreeedits.',receipt=str(D/'result.json'),next_action='Finish25normal+25DENSE+tb_armwithcycle/publicbus/architecturalwrite/retirementoracle;retaininheritedfailures.StoponRootnativegainrejection;noextra fit/gamesweep.',workers=[{'host':'Desktop','pid':os.getpid(),'NI':10,'job':'CPUgatecontroller'}]+([]if child is None else[{'host':'Desktop','pid':child.pid,'NI':os.getpriority(os.PRIO_PROCESS,child.pid),'job':phase}]),updated_at=time.time());v=json.dumps(d,separators=(',',':'));assert len(v)<2048,len(v);t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
def stop_check():
 p=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/rc053-controller-native-preflight.json')
 q=json.loads(p.read_text())if p.exists()else{}
 if(D/'STOP').exists()or 'REJECT' in q.get('status','').upper():
  r['status']='STOPPED_NATIVE_PRICE_REJECTED';save();status(r['status']);raise SystemExit(0)
def call(argv,tag,timeout=180,expect_fault=False):
 stop_check();argv=list(map(str,argv));start=time.monotonic()
 with(L/(tag+'.log')).open('w')as f:
  p=subprocess.Popen(argv,cwd=W,stdout=f,stderr=subprocess.STDOUT);z={'tag':tag,'pid':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'argv':argv};r['stages'].append(z);save();status(tag,p)
  try:
   while p.poll()is None:
    if time.monotonic()-start>timeout:p.terminate();p.wait(timeout=10);raise RuntimeError('timeout '+tag)
    # Poll only this run's documented native disposition; stop only our child.
    q=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/rc053-controller-native-preflight.json')
    native=json.loads(q.read_text())if q.exists()else{}
    if(D/'STOP').exists()or 'REJECT'in native.get('status','').upper():
     p.terminate();p.wait(timeout=10);r['status']='STOPPED_NATIVE_PRICE_REJECTED';save();status(r['status']);raise SystemExit(0)
    time.sleep(.1)
  finally:
   z['returncode']=p.poll();z['wall_seconds']=round(time.monotonic()-start,3);save()
 text=(L/(tag+'.log')).read_text()
 if expect_fault:assert p.returncode!=0 and 'CPU_UCODE_PAIR_FAIL'in text,(tag,text[-1200:])
 else:assert p.returncode==0 and 'CPU_UCODE_PAIR_FAIL'not in text and '%Error'not in text,(tag,p.returncode,text[-1500:])
 return text
# Pin all shared CPU logic to the exact price source. Only arm9_mem differs.
files=[]
for n in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_core arm7_ds arm9_ram arm9_mem arm_cpu'.split():
 b=git(PRICE,'rtl/arm/'+n+'.sv');p=S/(n+'.sv');p.write_bytes(b);files.append(p);r['sources'][n]=H(b)
 if n!='arm9_mem':assert b==git(BASE,'rtl/arm/'+n+'.sv'),n
candidate=(S/'arm9_mem.sv').read_bytes();proto=git('f352e113','rtl/arm/study/arm9_mem_ucode.sv').replace(b'arm9_mem_ucode',b'arm9_mem').replace(b'ucode_packed_update',b'packed_update');assert candidate==proto
before=git(BASE,'rtl/arm/arm9_mem.sv').decode().replace('module arm9_mem import','module arm9_mem_before import',1).replace('packed_update','before_packed_update')
# Actual reference address-path mutant is dormant unless explicitly requested.
needle="{dp_a[31:5], 3'(k + fsd), 2'b00}";assert before.count(needle)==1
before=before.replace(needle,"("+needle+" ^ (gate_fault ? 32'd4 : 32'd0))")
mark='  // ---------------------------------------------------------------- CP15';assert mark in before
before=before.replace(mark,"  bit gate_fault; initial gate_fault = $test$plusargs(\"oracle_fault\");\n"+mark,1)
(S/'arm9_mem_before.sv').write_text(before);files.append(S/'arm9_mem_before.sv')
b=git(PRICE,'rtl/arm/arm_cpu.sv').decode().replace('module arm_cpu import','module arm_cpu_before import',1).replace('arm9_mem #(','arm9_mem_before #(')
(S/'arm_cpu_before.sv').write_text(b);files.append(S/'arm_cpu_before.sv')
# The same CPU program, memory responses and IRQ/wake signals feed both copies.
tb=git(PRICE,'sim/arm/tb_arm.sv').decode();start=tb.index('  arm_cpu #(');end=tb.index('\n  );',start)+len('\n  );')
inst=tb[start:end];inst=inst.replace('arm_cpu #(','arm_cpu #(.ARM9_BURST(1),',1).replace('.b9_req(b9_req)', '.b9_n8(b9_n8),.b9_wnext(1\'b0),.b9_tmr(b9_tmr),.b9_req(b9_req)')
outputs={'a7_i_req':1,'a7_i_addr':32,'a7_d_req':1,'a7_d_we':1,'a7_d_be':4,'a7_d_addr':32,'a7_d_wdata':32,'b9_n8':1,'b9_tmr':4,'b9_req':1,'b9_we':1,'b9_addr':32,'b9_wdata':32,'b9_be':4,'dbg_wen':1,'dbg_wa':6,'dbg_wd':32,'dbg_retire':1,'dbg_tid':1,'dbg_pc':32,'dbg_cpsr':32}
old=inst.replace('arm_cpu #(','arm_cpu_before #(',1).replace(') dut (',') prior (')
for name in outputs:old=old.replace('('+name+')','(p_'+name+')')
decl='wire b9_n8;wire[3:0]b9_tmr;\n'+'\n'.join('wire '+(''if w==1 else f'[{w-1}:0] ')+f'p_{n};'for n,w in outputs.items())
observer='''integer pair_observations=0;bit pair_failed=0;
task pair_fail(input string what);begin pair_failed=1;$display("CPU_UCODE_PAIR_FAIL cycle=%0d signal=%s",cycle,what);$fatal(1,"controller CPU observable mismatch");end endtask
always @(negedge clk)if(!rst)begin
 pair_observations=pair_observations+1;
'''
for n in ['a7_i_req','a7_d_req','b9_req','dbg_wen','dbg_retire']:observer+=f' if({n} !== p_{n})pair_fail("{n}");\n'
for gate,names in [('a7_i_req',['a7_i_addr']),('a7_d_req',['a7_d_we','a7_d_be','a7_d_addr']),('b9_req',['b9_we','b9_n8','b9_addr','b9_be','b9_tmr']),('dbg_wen',['dbg_wa','dbg_wd']),('dbg_retire',['dbg_tid','dbg_pc','dbg_cpsr'])]:
 for n in names:observer+=f' if({gate} && {n} !== p_{n})pair_fail("{n}");\n'
for g,data,be in [('a7_d_req&&a7_d_we','a7_d_wdata','a7_d_be'),('b9_req&&b9_we','b9_wdata','b9_be')]:observer+=f' if({g})for(integer b=0;b<4;b=b+1)if({be}[b] && {data}[b*8+:8] !== p_{data}[b*8+:8])pair_fail("{data} byte");\n'
for n in ['i_ok','i_abort','d_ok','d_abort','d_wait','hivecs']:observer+=f' if(dut.u_mem9.{n} !== prior.u_mem9.{n})pair_fail("memory {n}");\n'
observer+=''' if(dut.u_mem9.f_req&&dut.u_mem9.i_ok&&{dut.u_mem9.i_rdata,dut.u_mem9.i_half} !== {prior.u_mem9.i_rdata,prior.u_mem9.i_half})pair_fail("memory I data");
 if((dut.u_mem9.w_req||dut.u_mem9.w_cp)&&dut.u_mem9.d_ok&&dut.u_mem9.d_rdata_f !== prior.u_mem9.d_rdata_f)pair_fail("memory D data");
end
final if(!pair_failed)$display("CPU_UCODE_PAIR_PASS observations=%0d",pair_observations);
'''
tb=tb[:start]+inst+tb[end:];tb=tb.replace('endmodule',decl+'\n'+old+'\n'+observer+'\nendmodule');(S/'tb.sv').write_text(tb);files.append(S/'tb.sv')
for p in files:r['sources'][p.name]=H(p.read_bytes())
# Copy canonical suite images without changing their donor tree.
assets=pathlib.Path.home()/'Git/NDS_Pocket-wt/a9-stall/build/arm'
for p in assets.iterdir():
 if p.suffix=='.hex'or p.name=='armwrestler.hooks':(I/p.name).write_bytes(p.read_bytes());r['inputs'][p.name]=H(p.read_bytes())
(I/'gen.py').write_bytes(git(PRICE,'sim/arm/rc6_checks/gen.py'));(I/'cp15.inc').write_bytes(git(PRICE,'sim/arm/tests/cp15.inc'))
# Keep the suite definition itself pinned and sealed.
(I/'run_tests.py').write_bytes(git(PRICE,'sim/arm/tools/run_tests.py'))
spec=importlib.util.spec_from_file_location('cpu_suite',I/'run_tests.py');suite=importlib.util.module_from_spec(spec);spec.loader.exec_module(suite)
# The canonical image set predates the hum recipe. Generate that missing
# fixture from the exact price source before any CPU run; never alter donor files.
for name,args,desc in suite.tests(str(I),'unused'):
 for arg in args:
  if not arg.startswith(('+img0=','+img1=')):continue
  image=pathlib.Path(arg.split('=',1)[1])
  if not image.exists():
   assert image.name=='hum.hex',('missing fixture',image)
   stem=image.with_suffix('');stem.with_suffix('.s').write_bytes(git(PRICE,'sim/arm/tests/hum.s'))
   subprocess.run(['clang','--target=armv5te-none-eabi','-c','-Wa,-I,'+str(I),stem.with_suffix('.s'),'-o',stem.with_suffix('.o')],check=True)
   subprocess.run(['ld.lld','-Ttext=0x02000000','--oformat=binary',stem.with_suffix('.o'),'-o',stem.with_suffix('.bin')],check=True)
   subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',image,str(stem.with_suffix('.bin'))+'@0x02000000'],check=True,stdout=subprocess.DEVNULL)
  r['inputs'][image.name]=H(image.read_bytes())
for name in ['gen.py','cp15.inc','run_tests.py']:r['inputs'][name]=H((I/name).read_bytes())

# One global build mutex; guards checked after acquiring it, not before waiting.
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');status('WAIT_GLOBAL_BUILD_MUTEX');fcntl.flock(lock,fcntl.LOCK_EX)
mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());guard={'NI':os.getpriority(os.PRIO_PROCESS,0),'memory_available':int(mi['MemAvailable'].split()[0])*1024,'disk_free':shutil.disk_usage(W).free,'mutex_held':True};r['build_guard']=guard;save();assert guard['NI']==10 and guard['memory_available']>=12*(1<<30) and guard['disk_free']>=30*(1<<30),guard
V=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/verilator'
params=['-GA9_CORE=1','-GA9_RF="MLAB"','-GA7_DS=1','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=1711268835','-GA9_XD=2','-GA9_XI=1','-GARM9_WAYS=2','-GEVB=1','-GEARLYD=1']
r['parameters']=params;call([V,'--binary','--timing','--assert','--threads','1','-j','4','-O2','-Wno-fatal','--top-module','tb_arm','--Mdir',D/'obj',*params,*files],'build',300)
fcntl.flock(lock,fcntl.LOCK_UN);lock.close();model=D/'obj/Vtb_arm';r['model_sha256']=H(model.read_bytes());save()
# Generate 25 ordinary and25 DENSE programs using the existing fixed generator.
for dense,group in [(False,'normal'),(True,'DENSE')]:
 for seed in range(1,26):
  stop_check();stem=I/f'{group}-{seed:02d}'
  env=dict(os.environ,DENSE='1'if dense else'0',NOCP='0',UNAL='0')
  src=subprocess.check_output(['python3',I/'gen.py',str(seed),'1500','3'],cwd=W,env=env);stem.with_suffix('.s').write_bytes(src)
  subprocess.run(['clang','--target=armv5te-none-eabi','-c','-Wa,-I,'+str(I),stem.with_suffix('.s'),'-o',stem.with_suffix('.o')],check=True)
  subprocess.run(['ld.lld','-Ttext=0x02000000','--oformat=binary',stem.with_suffix('.o'),'-o',stem.with_suffix('.bin')],check=True)
  subprocess.run(['python3',W/'sim/arm/tools/mkhex.py',stem.with_suffix('.hex'),str(stem.with_suffix('.bin'))+'@0x02000000'],check=True,stdout=subprocess.DEVNULL)
  for ext in ['.s','.bin','.hex']:r['inputs'][stem.name+ext]=H(stem.with_suffix(ext).read_bytes())
  args=[f'+img0={stem}.hex','+pc0=02000000','+run=1','+maxcycles=2000000']
  if not dense and seed==1:call([model,*args,'+oracle_fault'],'actual-controller-address-fault',expect_fault=True)
  text=call([model,*args],f'{group}-{seed:02d}');pair=re.search(r'CPU_UCODE_PAIR_PASS observations=(\d+)',text);assert pair
  row={'functional':'TEST PASSED'in text,'pair_observations':int(pair[1]),'cycles':re.findall(r'^cycles=(\d+)',text,re.M),'image_sha256':H(stem.with_suffix('.hex').read_bytes())};r[group][str(seed)]=row;save();print(group,seed,row,flush=True)
  assert row['functional'],(group,seed,text[-1600:])
for name,args,desc in suite.tests(str(I),'unused'):
 text=call([model,*args],f'ARM-{name}');pair=re.search(r'CPU_UCODE_PAIR_PASS observations=(\d+)',text);assert pair
 ok='TEST PASSED'in text;row={'functional':ok,'pair_observations':int(pair[1]),'cycles':re.findall(r'^cycles=(\d+)',text,re.M),'diagnostics':[x for x in text.splitlines()if 'FAIL'in x or 'timeout'in x or 'result='in x]};r['tb_arm'][name]=row
 if not ok:r['inherited_failures'].append(name)
 save();print('ARM',name,row,flush=True)
r['status']='PASS_PAIRED_CPU25NORMAL_25DENSE_TB_ARM_WITH_INHERITED_FAILURES';save();status(r['status']);done=json.loads(STATUS.read_text());done['workers']=[];tmp=STATUS.with_suffix('.tmp');tmp.write_text(json.dumps(done,separators=(',',':'))+'\n');os.replace(tmp,STATUS);print(r['status'],r['inherited_failures'],flush=True)
