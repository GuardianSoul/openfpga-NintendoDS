#!/usr/bin/env python3
"""Bounded explicit original-F local-merge prototype on the existing coupled fixture."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,re,resource,shutil,struct,subprocess,tarfile,time
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--DS',type=Path,default=Path('/home/user/Git/NDS_Pocket/build/coordinator/a7mulmix-dslite-20261102'))
p.add_argument('--quick',action='store_true')
p.add_argument('--verilator',default='build/tools/oss-cad-suite/bin/verilator');a=p.parse_args()
D=a.output.resolve();D.mkdir(parents=True,exist_ok=False);I=D/'inputs';I.mkdir();S=D/'source';S.mkdir();(D/'tmp').mkdir()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(240,240));resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024**2,512*1024**2));os.environ['TMPDIR']=str(D/'tmp')
sha=lambda b:hashlib.sha256(b).hexdigest();starttime=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
result=dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),controller=os.getpid(),controller_starttime=starttime(os.getpid()),
 stages=[],cases={},source_SHA256={},
 limits='Exact kernel/wrapper/addresses and warm1/4-16/min5; quiet component BL-retire brackets, no DS timer/helper/native equivalence claim. Test-only logical phase leaf; production CPU/P7/fabric frozen; no whole/native claim.',caps=dict(NI=10,jobs=1,threads=1,CPU_seconds_per_process=240,AS_bytes=4*1024**3,build_file_bytes=512*1024**2,model_file_bytes=64*1024**2,build_wall_seconds=180,model_wall_seconds=20))
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
status_path=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(phase,proc=None):
 q=json.loads(status_path.read_text());q['phase']=phase;q['current_action']='Owned logical MUL phase component on frozen production CPU/P7/fabric; explicit accepted-I spill; exact source/wrapper/operand checks. No physical retag or native claim.';q['worker']=dict(host='Desktop',active=bool(proc),controller=os.getpid(),PID=proc.pid if proc else None,starttime=starttime(proc.pid)if proc else None,NI=10,jobs=1 if proc else 0,threads=1 if proc else 0);q['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();temp=status_path.with_name('CPU.json.tmp.'+str(os.getpid()));temp.write_text(json.dumps(q,indent=2)+'\n');temp.replace(status_path)
def call(cmd,tag,limit,expected=0):
 cmd=list(map(str,cmd));begin=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  model_run=cmd[0].endswith('/Vtb')
  def model_cap():resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024**2,64*1024**2))
  proc=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT,preexec_fn=model_cap if model_run else None);row=dict(tag=tag,PID=proc.pid,starttime=starttime(proc.pid),NI=os.getpriority(os.PRIO_PROCESS,proc.pid),cmd=cmd);result['stages'].append(row);save();status(tag,proc);print(json.dumps({'tag':tag,'PID':proc.pid}),flush=True)
  try:row['exit']=proc.wait(timeout=limit)
  except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=10);row.update(exit=proc.returncode,timeout=True)
 row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save();status(tag+' terminal')
 if expected is not None:assert row['exit']==expected,(tag,(D/(tag+'.log')).read_text()[-2200:])
 return row['exit']
sp=importlib.util.spec_from_file_location('elf_inputs',R/'sw/hwref/arm7fetch/sdk-check.py');elf=importlib.util.module_from_spec(sp);sp.loader.exec_module(elf)
mix_layout=json.loads((a.DS/'layout.json').read_text());mix_data=json.loads((a.DS/'validation.json').read_text())
old_layout=json.loads((R/'build/a7-mulphase-compare/attempt1/inputs/mul-layout.json').read_text())
definitions=[(0,Path('/home/user/Git/NDS_Pocket-cpu-a7mulphase/build/a7mulphase-v1/a7mulphase7.elf'),old_layout,'mp_mul','mp_invoke'),
 (1,R/'build/a7mulmix-sdk/attempt1/sdk/a7mulmix7.elf',mix_layout,'mm_mul','mm_invoke')]
for kind,path,layout,ksym,wsym in definitions:
 assert sha(path.read_bytes())==layout['arm7_elf_SHA256']
 for name,value in [('kernel',elf.elf_symbol(path,ksym)['body']),('wrapper',elf.elf_symbol(path,wsym)['body'])]:
  assert sha(value)==(layout['code_SHA256']if name=='kernel'else layout['wrapper']['SHA256'])
  (I/f'{kind}-{name}.bin').write_bytes(value);(I/f'{kind}-{name}.hex').write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<'+'I'*(len(value)//4),value)))
boot='''.syntax unified
.arm
.text
.global _start,timed_call,timed_done,rs_literal,rs6_literal,loops_literal,entry_literal
.extern invoke
_start:
 ldr sp,stack_literal
 sub sp,sp,#8
 ldr r6,rs6_literal
 str r6,[sp]
 ldr r0,entry_literal
 mov r1,#1
 ldr r2,rs_literal
 ldr r3,warm_literal
 bl invoke
 ldr r6,rs6_literal
 str r6,[sp]
 ldr r0,entry_literal
 ldr r1,loops_literal
 ldr r2,rs_literal
 ldr r3,timed_literal
timed_call:
 bl invoke
timed_done:
 mov r8,#0x66
 b timed_done
.balign 4
stack_literal:.word 0x0380e000
warm_literal:.word 0x03802000
timed_literal:.word 0x03802080
entry_literal:.word 0
loops_literal:.word 0
rs_literal:.word 0
rs6_literal:.word 0
'''
(I/'boot.s').write_text(boot)
call([shutil.which('clang'),'--target=armv4t-none-eabi','-mcpu=arm7tdmi','-marm','-c',I/'boot.s','-o',I/'boot.o'],'assemble',30)
for kind,_,layout,_,_ in definitions:
 call([shutil.which('ld.lld'),'-Ttext=0x03808000','--entry=_start','--defsym=invoke='+hex(layout['wrapper']['entry']),I/'boot.o','-o',I/f'{kind}-boot.elf'],'link'+str(kind),30)
 call([shutil.which('llvm-objcopy'),'-O','binary',I/f'{kind}-boot.elf',I/f'{kind}-boot.bin'],'binary'+str(kind),30)
 b=(I/f'{kind}-boot.bin').read_bytes();(I/f'{kind}-boot.hex').write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<'+'I'*(len(b)//4),b)))
symbols={w[2]:int(w[0],16)for l in subprocess.check_output([shutil.which('llvm-nm'),'-n',I/'1-boot.elf'],text=True).splitlines()if len(w:=l.split())==3};result['symbols']=symbols
rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_thumb.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv','sim/arm/a7_mul_service/phase.sv']
sources=[]
for n in rels:
 p=S/Path(n).name;p.write_bytes((R/n).read_bytes());sources.append(p);result['source_SHA256'][n]=sha(p.read_bytes())
donor=R/'docs/results/arm7-data-ack-20261101/proof.tar.gz';assert sha(donor.read_bytes())=='0707d7ca3a716f90dbe0eea6ad968398cd806c22289c77c46a9cd7e794027734'
with tarfile.open(donor)as t:transport=t.extractfile('cpu36/tb.sv').read().decode().split('module cpu_before ')[0]
(S/'transport.sv').write_text(transport.replace('old_nds_psram #(','nds_psram #('));sources.append(S/'transport.sv')
s=(R/'sim/arm/a7_mulphase/tb.sv').read_text();s=s.replace('logic ir,io,dr,','logic raw_io,phase_ok,phase_pending,phase_spill;logic[4:0]phase_left;\n a7_mul_context_t request_meta;a7_mul_advance_t actual_advance;\n logic ir,io,dr,')
s=s.replace('wrapper[0:23]','wrapper[0:24]');s=s.replace('int loops,rs,m_ref,region,entry,caseid,','int kind,policy,rs6,private_entry,wrapper_entry,return_pc,wrap_words,expected_steps,sym_rs6;\n int loops,rs,m_ref,region,entry,caseid,')
s=s.replace('.WRAM_SWP_PIPE(1))cpu(','.WRAM_SWP_PIPE(1),.MUL_META(1))cpu(').replace('.exec_meta(),.stm4_request()', '.mul_request(request_meta),.mul_advance(actual_advance),.exec_meta(),.stm4_request()')
pos=s.index(' nds_arm7_port');s=s[:pos]+''' a7_mul_phase #(.ENABLE(1))phase_policy(.clk,.rst_cpu(rst),.i_req(ir),.i_arm(iarm),.i_addr(ia),.i_redirect(iredirect),.i_consume(iconsume),.request_meta,.actual_advance,.payload_ok(raw_io),.result_ok(phase_ok),.pending(phase_pending),.remaining(phase_left),.spill(phase_spill));
 assign io=policy!=0?phase_ok:raw_io;
'''+s[pos:];pos=s.index(' nds_arm7_port');s=s[:pos]+s[pos:].replace('.i_ok(io)','.i_ok(raw_io)',1)
s=s.replace('   assert(cpu.opa==3&&cpu.opb==32\'(rs)&&cpu.mterm==3\'(m_ref))',"   assert(cpu.opa==3&&cpu.opb==32'((cpu.ins[11:8]==6)?rs6:rs))")
s=s.replace("ram[b+2]==32'(rs))","ram[b+2]==32'(rs)&&ram[b+6]==32'(rs6))")
s=s.replace("ram[b+19]==32'(3*rs)","ram[b+19]==32'(3*rs6)")
s=s.replace("ram[b+14]==32'h03800788","ram[b+14]==32'(return_pc)")
s=s.replace('  m_ref=caseid+1;entry=region?', '''  if(!$value$plusargs("kind=%d",kind)||!$value$plusargs("policy=%d",policy)||!$value$plusargs("rs6=%h",rs6)||!$value$plusargs("private=%h",private_entry)||!$value$plusargs("wrapper_entry=%h",wrapper_entry)||!$value$plusargs("return_pc=%h",return_pc)||!$value$plusargs("sym_rs6=%h",sym_rs6))$fatal(1,"missing policy fixture inputs");
  wrap_words=kind?25:24;
  expected_steps=loops*(kind?32*(early(rs)+early(rs6)):64*early(rs));
  m_ref=caseid+1;entry=region?''')
s=s.replace("32'h03800640;","32'(private_entry);")
s=s.replace('  $readmemh(kernel_image,words);$readmemh(wrapper_image,wrapper);', '  $readmemh(kernel_image,words);$readmemh(wrapper_image,wrapper,0,wrap_words-1);')
s=s.replace("ram[32'h640/4+i]",'ram[(private_entry&65535)/4+i]').replace("for(int i=0;i<24;i++)ram[32'h750/4+i]=wrapper[i];",'for(int i=0;i<wrap_words;i++)ram[(wrapper_entry&65535)/4+i]=wrapper[i];')
s=s.replace("  ram[(sym_rs&65535)/4]", "  ram[(sym_rs6&65535)/4]=32'(rs6);\n  ram[(sym_rs&65535)/4]")
s=s.replace('m_ref*loops*64','expected_steps').replace("shadow[0]==32'(3*rs)","shadow[0]==32'(3*rs6)")
s=s.replace(' function automatic bit in_body', ''' function automatic int early(input logic[31:0]x);
  if(x[31:8]==0||x[31:8]==24'hffffff)return 1;
  if(x[31:16]==0||x[31:16]==16'hffff)return 2;
  if(x[31:24]==0||x[31:24]==8'hff)return 3;
  return 4;
 endfunction
 function automatic bit in_body''')
(S/'tb.sv').write_text(s);sources.append(S/'tb.sv');result['fixture_SHA256']={p.name:sha(p.read_bytes())for p in sources};save()
call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',*sources],'build',180)
model=D/'obj/Vtb';result['model_SHA256']=sha(model.read_bytes());save()
for kind,_,layout,_,_ in definitions:
 if a.quick and kind==0:continue
 pairs=[(127,127),(32767,32767),(8388607,8388607),(2147483647,2147483647)]if kind==0 else[(127,127),(2147483647,2147483647),(127,2147483647)]
 for case,(rs2,rs6)in enumerate(pairs):
  for region in ([1]if a.quick else[0,1]):
   rows={}
   for policy in [0,1]:
    samples={4:[],16:[]}
    for n in [4,16]:
     tag=f'k{kind}-c{case}-r{region}-p{policy}-n{n}';cmd=[model,'+kernel='+str(I/f'{kind}-kernel.hex'),'+wrapper='+str(I/f'{kind}-wrapper.hex'),'+boot='+str(I/f'{kind}-boot.hex'),'+out='+str(D/tag),'+kind='+str(kind),'+case='+str(case),'+policy='+str(policy),'+rs='+format(rs2,'x'),'+rs6='+format(rs6,'x'),'+region='+str(region),'+loops='+str(n),'+detail=1']
     for arg,v in [('call',symbols['timed_call']),('done',symbols['timed_done']),('sym_rs',symbols['rs_literal']),('sym_rs6',symbols['rs6_literal']),('sym_loops',symbols['loops_literal']),('sym_entry',symbols['entry_literal']),('private',layout['source_entry']),('wrapper_entry',layout['wrapper']['entry']),('return_pc',layout['wrapper']['return_address'])]:cmd.append('+'+arg+'='+format(v,'x'))
     call(cmd,tag,20);match=re.search(r'MUL_PHASE_PASS.*elapsed(\d+)',(D/(tag+'.log')).read_text());assert match;samples[n].append(int(match[1]))
    rows[str(policy)]=dict(elapsed_SYS=samples,slope=(min(samples[16])-min(samples[4]))/1536)
   for n in [4,16]:
    for suffix in ['state','data']:
     values=[(D/f'k{kind}-c{case}-r{region}-p{policy}-n{n}.{suffix}').read_text().splitlines()for policy in [0,1]]
     normalized=[[''.join(x.split(',',1)[1:])for x in v]for v in values];assert normalized[0]==normalized[1],(kind,case,region,n,suffix)
   target=(case+2.0625 if kind==0 and not region else[9.234375]*3+[10.234375]if kind==0 else None)
   if kind==0:ds=(case+2.0625)if not region else[9.234375,9.234375,9.234375,10.234375][case]
   else:ds=next(x['slope']for x in mix_data['summary']if x['case_id']==case and x['region']==('MAIN'if region else'private_WRAM'))
   result['cases'][f'{kind}-{case}-{region}']=dict(rs2=rs2,rs6=rs6,policies=rows,DS=ds,enabled_matches=rows['1']['slope']==ds);save();print('ROW',kind,case,region,rows,'DS',ds,flush=True)
result['state']='COMPONENT_MEASURED; reject any nonmatching cell; no native closure';save();status(result['state']);print(result['state'],flush=True)
