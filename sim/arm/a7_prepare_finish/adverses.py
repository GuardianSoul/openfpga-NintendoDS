#!/usr/bin/env python3
"""One bounded paired CPU/payload/old-tail/pressure component continuation."""
from pathlib import Path
import argparse, hashlib, json, os, re, resource, shutil, subprocess, time

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--trial',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--resume',action='store_true');p.add_argument('--scenarios',default='1,2,3,4');a=p.parse_args()
D=a.output.resolve();D.mkdir(parents=True,exist_ok=a.resume);S=D/'source';I=D/'inputs'
if not a.resume:
 shutil.copytree(a.trial/'source',S);shutil.copytree(a.trial/'inputs',I)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(240,240));resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest()
if not a.resume:
 s=(S/'tb.sv').read_text();s=s.replace(' logic initialized,idle;', (R/'sim/arm/a7_prepare_finish/adverse.svh').read_text()+'\n logic initialized,idle;')
 s=s.replace('.clk,.rst,.run,.reset_pc', '.clk,.rst(cpu_rst),.run,.reset_pc',1).replace('.irq(1\'b0)', '.irq(irq)',1)
 s=s.replace('if(!rst&&iconsume)', 'if(!cpu_rst&&iconsume)').replace('if(!rst&&cpu.pipe_fire', 'if(!cpu_rst&&cpu.pipe_fire')
 s=s.replace('always @(negedge clk)if(!rst)', 'always @(negedge clk)if(!cpu_rst)')
 s=s.replace('always @(posedge clk)if(!rst&&active)', 'always @(posedge clk)if(!cpu_rst&&active)')
 s=s.replace('if(in_body(pc))mul_retired++;', 'if(in_body(pc)&&psr[4:0]!=M_IRQ)mul_retired++;')
 s=s.replace('.x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1\'b0),.x_rdata(32\'d0)', '.x_req(xr),.x_we(xwe),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xq)')
 s=s.replace('  return 0;\n endfunction', "  if(a==32'h18)return 32'he25ef004;\n  return 0;\n endfunction",1)
 s=s.replace(".a9_req(1'b0),.a9_we(1'b0),.a9_n8(1'b0),.a9_ldm(1'b0),.a9_addr(32'd0),.a9_wdata(32'd0),.a9_be(4'hF),.a9_ack(),.a9_rvalid(),.a9_rdata()", ".a9_req(a9_req),.a9_we(1'b0),.a9_n8(1'b0),.a9_ldm(1'b0),.a9_addr(a9_addr),.a9_wdata(32'd0),.a9_be(4'hF),.a9_ack(a9_ack),.a9_rvalid(a9_rvalid),.a9_rdata(a9_rdata)")
 s=s.replace('  wrap_words=kind?25:24;', '''  void'($value$plusargs("scenario=%d",scenario));
   wrap_words=kind?25:24;''')
 s=s.replace('  for(int j=0;j<1024;j++)begin', '''
   for(int i=0;i<16;i++)begin
    transport.chips.m0.mem[32'h10000/4+i]=16'(i);
    transport.chips.m1.mem[32'h10000/4+i]=16'hc900;
   end
   for(int j=0;j<1024;j++)begin''')
 s=s.replace('  $fclose(phasefd);', '''  if(scenario>=1&&scenario<=3)assert(intervention)else $fatal(1,"intervention not reached");
   if(scenario==4)assert(a9_returns==32)else $fatal(1,"pressure coverage %0d",a9_returns);
   $display("ADVERSE_PASS scenario%0d policy%0d A9returns%0d",scenario,policy,a9_returns);
   $fclose(phasefd);''')
 s=s.replace('integer phasefd=0,phase_errors=0,phase_prepares=0,phase_commits=0,phase_finishes=0;', 'integer phasefd=0,phase_errors=0,phase_prepares=0,phase_commits=0,phase_finishes=0,phase_discards=0;')
 s=s.replace('if(iconsume||iredirect)begin finish_cycle=-1;', 'if(iredirect&&cpu.phase_prepared)phase_discards++;\n  if(iconsume||iredirect)begin finish_cycle=-1;')
 s=s.replace('phase_commits==loops*64', 'phase_commits+phase_discards==loops*64')
 s=s.replace('  $fclose(phasefd);', '  if(policy!=0)assert(phase_discards==(scenario==3?1:0))else $fatal(1,"unexpected prepared cancellation");\n  $fclose(phasefd);')
 (S/'tb.sv').write_text(s)
 result=dict(trial_RTL_SHA256=sha((S/'arm7_ds.sv').read_bytes()),source_SHA256={f.name:sha(f.read_bytes())for f in S.glob('*.sv')},stages=[],rows=[])
else:
 result=json.loads((D/'results.json').read_text());(D/'first-controller.json').write_text(json.dumps(result,indent=2)+'\n')
 for name,digest in result['source_SHA256'].items():assert sha((S/name).read_bytes())==digest
 result['rows']=[];result['fixture_correction']='Ignore RESET marker clock column only, as for ordinary retirement clocks; no CPU/tb/model change or rerun of completed scenarios.'

def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def call(cmd,tag,timeout):
 begin=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  proc=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT);row=dict(tag=tag,PID=proc.pid,starttime=Path('/proc',str(proc.pid),'stat').read_text().rsplit(')',1)[1].split()[19]);result['stages'].append(row);save();print(tag,proc.pid,flush=True)
  q=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(q.read_text());j['phase']='phase adverse '+tag;j['worker']=dict(host='Desktop',active=True,PID=proc.pid,NI=10,jobs=1,threads=1);tmp=q.with_suffix('.tmp');tmp.write_text(json.dumps(j,indent=2)+'\n');tmp.replace(q)
  try:row['exit']=proc.wait(timeout=timeout)
  except subprocess.TimeoutExpired:proc.terminate();row['exit']=proc.wait(timeout=10);row['timeout']=True
 row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save();j['worker']=dict(host='Desktop',active=False,PID=None,NI=10,jobs=0,threads=0);tmp.write_text(json.dumps(j,indent=2)+'\n');tmp.replace(q)
 assert row['exit']==0,(tag,(D/(tag+'.log')).read_text()[-2500:]);return(D/(tag+'.log')).read_text()
if not a.resume:
 boot=(I/'boot.s').read_text().replace('_start:\n','_start:\n msr cpsr_c,#0x53\n')
 (I/'irq-boot.s').write_text(boot)
 call(['clang','--target=armv4t-none-eabi','-mcpu=arm7tdmi','-marm','-c',I/'irq-boot.s','-o',I/'irq-boot.o'],'IRQ-assemble',30)
 call(['ld.lld','-Ttext=0x03808000','--entry=_start','--defsym=invoke=0x03800850',I/'irq-boot.o','-o',I/'irq-boot.elf'],'IRQ-link',30)
 call(['llvm-objcopy','-O','binary',I/'irq-boot.elf',I/'irq-boot.bin'],'IRQ-binary',30)
 b=(I/'irq-boot.bin').read_bytes();(I/'irq-boot.hex').write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n'for i in range(0,len(b),4)))
 irq_symbols={w[2]:int(w[0],16)for line in subprocess.check_output(['llvm-nm',I/'irq-boot.elf'],text=True).splitlines()if len(w:=line.split())==3}
 result['IRQ_symbols']=irq_symbols;save()
 files=sorted(S.glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv')
 call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',*files],'build',180)
else:
 irq_symbols=result['IRQ_symbols']
result['model_SHA256']=sha((D/'obj/Vtb').read_bytes());save()

template=next(x['command']for x in json.loads((a.trial/'results.json').read_text())['stages']if x['tag']=='c1-r1-p1-n4')
for scenario in map(int,a.scenarios.split(',')):
 for policy in [0,1]:
  tag=f's{scenario}-p{policy}';args={v.split('=',1)[0]:v.split('=',1)[1]for v in template[1:]};args.update({'+out':str(D/tag),'+policy':str(policy),'+scenario':str(scenario)})
  for name in ['kernel','wrapper','boot']:args['+'+name]=str(I/Path(args['+'+name]).name)
  if scenario==3:
   args['+boot']=str(I/'irq-boot.hex')
   for name,symbol in [('call','timed_call'),('done','timed_done'),('sym_rs','rs_literal'),('sym_rs6','rs6_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:args['+'+name]=format(irq_symbols[symbol],'x')
  log=(D/(tag+'.log')).read_text() if a.resume and (D/(tag+'.log')).exists() else call([D/'obj/Vtb',*[k+'='+v for k,v in args.items()]],tag,30)
  assert'ADVERSE_PASS'in log
 for suffix in ['state','data']:
  b=[(D/f's{scenario}-p{policy}.{suffix}').read_text().splitlines()for policy in[0,1]]
  normalized=[['RESET'if x.startswith('RESET,')else x.split(',',1)[1]for x in lane]for lane in b]
  assert normalized[0]==normalized[1],(scenario,suffix)
 result['rows'].append(dict(scenario=scenario,function_state_data_equal=True));save()
result['status']='PASS pause/CPU-only reset with old physical owner/IRQ/32 competing A9 reads; state/data preserved';save();print(result['status'])
