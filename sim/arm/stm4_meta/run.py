#!/usr/bin/env python3
"""One serial NI10/j1/t1 worker: real P7 old/default/off/on and actual faults."""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,resource,shutil,struct,subprocess,time
R=Path(__file__).resolve().parents[3]
BASE="362fea1dc1fcaee361977f06fd12826d45d03699"
ap=argparse.ArgumentParser(__doc__);ap.add_argument("--output",type=Path,required=True)
ap.add_argument("--status",type=Path);ap.add_argument("--verilator",default="build/tools/oss-cad-suite/bin/verilator")
a=ap.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
(D/"tmp").mkdir();os.environ["TMPDIR"]=str(D/"tmp")
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
receipt=dict(base=BASE,source=subprocess.check_output(["git","rev-parse","HEAD"],cwd=R,text=True).strip(),
 controller=os.getpid(),controller_starttime=Path("/proc/self/stat").read_text().split()[21],stages=[],cases={},models={})
def save():(D/"results.json").write_text(json.dumps(receipt,indent=2)+"\n")
def status(phase,p=None):
 if not a.status:return
 d=json.loads(a.status.read_text());d["phase"]=phase;d["worker"]=dict(host="Desktop",controller=os.getpid()if p else None,
  PID=p.pid if p else None,starttime=Path("/proc",str(p.pid),"stat").read_text().split()[21]if p else None,
  jobs=1 if p else 0,threads=1 if p else 0,NI=10);d["updated_at"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
 q=a.status.with_suffix(".tmp."+str(os.getpid()));q.write_text(json.dumps(d,indent=2)+"\n");q.replace(a.status)
def call(cmd,tag,limit=300,expected=0):
 cmd=list(map(str,cmd));start=time.monotonic()
 with(D/(tag+".log")).open("w")as f:
  p=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
  row=dict(tag=tag,PID=p.pid,starttime=Path("/proc",str(p.pid),"stat").read_text().split()[21],
   NI=os.getpriority(os.PRIO_PROCESS,p.pid),cmd=cmd);receipt["stages"].append(row);save();status(tag,p)
  print(json.dumps(dict(tag=tag,PID=p.pid)),flush=True)
  try:row["exit"]=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=10);row.update(exit=p.returncode,timeout=True)
 row.update(reaped=True,wall_seconds=round(time.monotonic()-start,3));save();status(tag+" terminal")
 if expected is not None:assert row["exit"]==expected,(tag,(D/(tag+".log")).read_text()[-2200:])
 return row["exit"]
asm=[".syntax unified",".arm",".text",".global _start,finished,irq_handler","_start:"]
asm +=[f"mov r{i},#0"for i in range(13)]
asm +=["ldr sp,stack","mrs r0,cpsr","bic r0,r0,#0x80","msr cpsr_c,r0",
 "mov r0,#17","mov r2,#34","mov r3,#51","mov r5,#85","mov r6,#102","mov r7,#119",
 "mov r10,#2","repeat_body:","ldr r1,mainptr","eligible_a:","stmia r1,{r2-r5}",
 "ldr r4,mainptr","eligible_b:","stmia r4,{r0-r3}","ldr r12,mainptr","eligible_c:",
 "stmia r12,{r0,r2,r6,r10}","subs r10,r10,#1","bne repeat_body"]
eligible=["eligible_a","eligible_b","eligible_c"]
# Semantic negatives: no benchmark PC/mask special case in production.
for name,op in [("w1","stmia r4!,{r0-r3}"),("ib","stmib r4,{r0-r3}"),
 ("da","stmda r4,{r0-r3}"),("db","stmdb r4,{r0-r3}"),
 ("base","stmia r4,{r2,r3,r4,r5}"),("pc","stmia r4,{r0,r1,r2,pc}"),
 ("user","stmia r4,{r0-r3}^"),("one","stmia r4,{r0}"),
 ("two","stmia r4,{r0,r1}"),("three","stmia r4,{r0-r2}"),
 ("five","stmia r4,{r0-r3,r5}"),("eight","stmia r4,{r0-r3,r5-r8}")]:
 asm +=["ldr r4,mainptr",name+":",op]
asm +=["ldr r4,unaligned","stmia r4,{r0-r3}","cmp r0,#0","stmne r4,{r0-r3}",
 "cmp r0,r0","stmne r4,{r0-r3}","ldr r4,mainptr","str r0,[r4]","str r2,[r4,#4]",
 "ldr r3,[r4]","strb r0,[r4,#1]","strh r2,[r4,#2]","swp r3,r0,[r4]",
 "ldr r4,wptr","stmia r4,{r0-r3}","ldmia r4,{r0-r3}","swp r3,r0,[r4]",
 "adr r7,thumb_entry+1","bx r7",".thumb",".balign 2","thumb_entry:",
 "movs r0,#3","stmia r4!,{r0-r3}","ldmia r4!,{r0-r3}","ldr r7,back","bx r7",
 ".balign 4","back:.word arm_return",".arm","arm_return:",
 "finished:","mov r8,#0x66","b finished",".balign 4",
 "mainptr:.word 0x02010080","unaligned:.word 0x02010081","wptr:.word 0x037ff040","stack:.word 0x0380f000",
 "irq_handler:","add r11,r11,#1","subs pc,lr,#4"]
(D/"program.s").write_text("\n".join(asm)+"\n")
for cmd,tag in [
 ([shutil.which("clang"),"--target=armv4t-none-eabi","-mcpu=arm7tdmi","-marm","-nostdlib","-c",D/"program.s","-o",D/"program.o"],"assemble"),
 ([shutil.which("ld.lld"),"-Ttext=0x03808000","--entry=_start",D/"program.o","-o",D/"program.elf"],"link"),
 ([shutil.which("llvm-objcopy"),"-O","binary",D/"program.elf",D/"program.bin"],"binary")]:call(cmd,tag)
symbols={w[2]:int(w[0],16)for l in subprocess.check_output([shutil.which("llvm-nm"),"-n",D/"program.elf"],text=True).splitlines()if len(w:=l.split())==3}
b=(D/"program.bin").read_bytes();b+=b"\0"*((-len(b))%4)
(D/"program.hex").write_text("".join(f"{w:08x}\n"for w in struct.unpack("<"+"I"*(len(b)//4),b)))
(D/"eligible.hex").write_text("".join(f"{symbols[n]:08x}\n"for n in eligible))
receipt["program"]=dict(symbols=symbols,eligible=eligible,source_sha256=sha(D/"program.s"),binary_sha256=sha(D/"program.bin"));save()
files=['rtl/arm/'+n+'.sv'for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core','arm9_ram','arm9_mem','arm_cpu','arm7_ds','arm7_stm4_owner']]
files+=['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']
for variant in ["candidate","wrongbeat","wrongowner"]:
 S=D/variant/"source";S.mkdir(parents=True);inputs=[]
 for f in files:
  value=(R/f).read_bytes()
  if variant=="wrongbeat"and f.endswith("arm7_ds.sv"):
   needle=b"stm4_request.beat = 2'(5'd4 - left);";assert value.count(needle)==1
   value=value.replace(needle,b"stm4_request.beat = 2'(5'd4 - left) ^ 2'b01;")
  if variant=="wrongowner"and f.endswith("arm7_stm4_owner.sv"):
   needle=b"physical_ack ? posted_owner : '0;";assert value.count(needle)==1
   value=value.replace(needle,b"physical_ack ? answer_owner : '0;")
  p=S/Path(f).name;p.write_bytes(value);inputs.append(p)
 for name in ["arm7_ds","arm_cpu"]:
  value=subprocess.check_output(["git","show",BASE+":rtl/arm/"+name+".sv"],cwd=R)
  value=value.replace(("module "+name+" ").encode(),("module "+name+"_before ").encode())
  if name=="arm_cpu":value=value.replace(b"arm7_ds #(",b"arm7_ds_before #(")
  p=S/(name+"_before.sv");p.write_bytes(value);inputs.append(p)
 for n in ["tb.sv","probe.svh"]:(S/n).write_bytes((R/"sim/arm/stm4_meta"/n).read_bytes())
 parts=[]
 for mode in range(4):
  module="arm_cpu_before"if mode==0 else"arm_cpu"
  params=".A7_DS(1),.A7_WRAM_SWP_PIPE(FAST)"
  if mode in [2,3]:params+=", .A7_STM4_META("+str(int(mode==3))+")"
  tail=""if mode==0 else".a7_stm4_request(request_meta),.a7_stm4_accept(list_accept),"
  inst=f"{module} #({params})wrapper({tail}"+chr(96)+"PINS);"
  if mode==0:inst+="assign request_meta='0;assign list_accept=0;"
  parts +=[("generate "if mode==0 else"")+"if(MODE=="+str(mode)+")begin:g_cpu"+str(mode),
   inst,chr(96)+"PROBE(wrapper.g_a7ds.u_a7)","end "+("else"if mode<3 else"endgenerate")]
 (S/"instances.svh").write_text("\n".join(parts)+"\n");inputs.append(S/"tb.sv")
 receipt["models"][variant]=dict(source_SHA256={str(p.relative_to(S)):sha(p)for p in S.iterdir()if p.is_file()});save()
 obj=D/variant/"obj"
 call([a.verilator,"--binary","--timing","--assert","--threads","1","-j","1","-O2","-Wno-fatal",
  "-I"+str(S),"--top-module","tb","--Mdir",obj,*inputs],"build-"+variant)
 model=obj/"Vtb";receipt["models"][variant]["model_SHA256"]=sha(model);save()
 scenarios=range(6)if variant=="candidate"else[0]
 for scenario in scenarios:
  tag=variant+"-s"+str(scenario);prefix=D/tag
  rc=call([model,"+scenario="+str(scenario),"+img="+str(D/"program.hex"),"+eligible="+str(D/"eligible.hex"),
   "+eligible_n="+str(len(eligible)),"+out="+str(prefix),"+done="+format(symbols["finished"],"x"),
   "+handler="+format(symbols["irq_handler"],"x")],tag,expected=None)
  log=(D/(tag+".log")).read_text()
  assert "STM_BEHAVIOR_ALL_PASS"in log,(tag,rc,log[-2200:])
  for fast in [0,4]:
   for suffix in ["state","data","edge","mem","take"]:
    values=[Path(str(prefix)+"-m"+str(m)+"."+suffix).read_bytes()for m in range(fast,fast+4)]
    assert all(values),(tag,fast,suffix,"empty evidence")
    if suffix=="mem":assert all(len(v)==(65536+256)*9 for v in values),(tag,"truncated backing dump")
    assert all(v==values[0]for v in values),(tag,fast,suffix)
  if variant=="candidate":assert rc==0 and"STM_METADATA_ALL_PASS"in log,(tag,log[-1800:])
  else:assert rc!=0 and"STM_METADATA_MUTATION_CAUGHT"in log and"STM_METADATA_FAULT"in log,(tag,rc,log[-1800:])
  rows=re.findall(r"STM_LANE_PASS mode(\d+) scenario(\d+) cycles(\d+) states(\d+) accepts(\d+) requests(\d+) admits(\d+) drains(\d+) turns(\d+) retries(\d+) faults(\d+)",log)
  assert len(rows)==8,(tag,rows)
  receipt["cases"][tag]=dict(exit=rc,full_behavior_exact=True,lanes=[list(map(int,r))for r in rows],log_sha256=sha(D/(tag+".log")));save()
  print("QUALIFIED",tag,flush=True)
receipt["status"]="PASS previous/default/off/on exact state/data/order/cycles; actual wrongbeat and wrongowner faults caught after full behavior comparison"
save();status(receipt["status"]);print(receipt["status"],flush=True)
