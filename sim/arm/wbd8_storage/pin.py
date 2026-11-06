#!/usr/bin/env python3
"""One leased paired CPU/fabric/SYS/pin-PSRAM worker with competing ARM7 traffic."""
from pathlib import Path
import sys,ast,tarfile
assert '--out'in sys.argv,'fresh explicit output required'
exec(compile(Path(__file__).with_name('cpu.py').read_text().split('models={}')[0],str(Path(__file__).with_name('cpu.py')),'exec'))
CPU='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split()
FILES=['rtl/arm/'+x+'.sv'for x in CPU]+['rtl/mem/psx_pq_psram.sv','sim/phase1/sim_prims.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_dsp_add.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/pocket/nds_psram.sv']+['rtl/sys/'+x+'.sv'for x in 'sys_ram sys_irq sys_timers sys_ipc sys_math sys_dma nds_sys'.split()]+['rtl/ds/nds_io.sv']
archive=R/'docs/results/io-replay-main40-20261101/evidence.tar.gz';q=json.load(open(archive.parent/'qualification.json'));assert sha(archive)==q['artifact']['sha256']
with tarfile.open(archive)as t:donor=t.extractfile('inputs/cram_model.sv').read()
assert hashlib.sha256(donor).hexdigest()=='f0c1d9c1f2f85350a6e2eced7d7defa3ec2907ece01a7ba0fecb4b507e4f6e1c'
hook=next(ast.literal_eval(x.value)for x in ast.parse((R/'sim/arm/wbd8_storage/cpu.py').read_text()).body if isinstance(x,ast.Assign)and any(isinstance(t,ast.Name)and t.id=='hook'for t in x.targets))
peer='''
 logic peer_req=0,peer_we=0;logic[31:0]peer_addr=0,peer_wdata=0;wire peer_ack;
 integer peer_mode=0,peer_id=0,peer_gap=0,peer_total=0,peer_start=0,peer_max=0;
 initial if($value$plusargs("qpeer=%d",peer_mode))begin end
 always @(posedge clk)begin
  if(rst)begin peer_req<=0;peer_id<=0;peer_gap<=peer_mode;end
  else if(peer_mode!=0&&g_stream.transport.initialized&&cycle>200)begin
   if(peer_req&&peer_ack)begin
    if(!peer_we&&g_stream.transport.a7_rdata!==(32'hc80a6e00^32'(peer_id>>1)))$fatal(1,"peer durable payload mismatch");
    $display("PEER c%0d id%0d we%0d a%h d%h wait%0d",cycle,peer_id,peer_we,peer_addr,peer_we?peer_wdata:g_stream.transport.a7_rdata,cycle-peer_start);
    if(cycle-peer_start>peer_max)peer_max=integer'(cycle)-peer_start;
    peer_total++;peer_req<=0;peer_id<=peer_id+1;peer_gap<=peer_mode;
   end else if(!peer_req)begin
    if(peer_gap>0)peer_gap<=peer_gap-1;
    else begin peer_req<=1;peer_we<=!peer_id[0];peer_addr<=32'h02418000+32'(((peer_id>>1)&255)*4);peer_wdata<=32'hc80a6e00^32'(peer_id>>1);peer_start=integer'(cycle);end
   end
  end
  if(!rst&&g_stream.transport.mr_req&&g_stream.transport.mr_ack)$display("PINWORD c%0d we%0d a%h be%h data%h",cycle,g_stream.transport.mr_we,g_stream.transport.mr_addr,g_stream.transport.mr_be,g_stream.transport.mr_we?g_stream.transport.mr_wdata:32'd0);
  if(!rst&&g_stream.transport.mr_rvalid)$display("PINRETURN c%0d data%h",cycle,g_stream.transport.mr_rdata);
 end
 final begin
  $display("PEER_SUMMARY requests%0d maxwait%0d",peer_total,peer_max);
  if(peer_mode!=0&&peer_total<16)$fatal(1,"inactive peer contention");
 end
'''
models={};source_sha=sha(R/'rtl/arm/arm9_mem.sv')
for name in ['before','on']:
 d=G/name;d.mkdir();files=[]
 for f in FILES:
  b=subprocess.check_output(['git','show',BASE+':'+f])if name=='before'else(R/f).read_bytes();out=d/f;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(b);files.append(out)
 out=d/'cram_model.sv';out.write_bytes(donor);files.append(out)
 tb=(R/'sim/arm/io_retry_window/compose_mixed.sv').read_text();old=".a7_req(1'b0),.a7_we(1'b0),.a7_addr(32'd0),.a7_wdata(32'd0),.a7_ack()";assert tb.count(old)==1;tb=tb.replace(old,'.a7_req(peer_req),.a7_we(peer_we),.a7_addr(peer_addr),.a7_wdata(peer_wdata),.a7_ack(peer_ack)');pos=tb.index('endmodule');tb=tb[:pos]+hook+peer+tb[pos:];out=d/'tb.sv';out.write_text(tb);files.append(out)
 out=d/'transport.sv';out.write_bytes((R/'sim/arm/io_retry_window/compose_transport.sv').read_bytes());files.append(out)
 cmd=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_arm','-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0','-GBF=1','-GSERVICE=3','+define+NEW_IO_REPLAY','-GREPLAY=1','--Mdir',d/'obj',*files]
 call(cmd,name+'-build');models[name]=d/'obj/Vtb_arm';save(d/'model.json',dict(sha256=sha(models[name]),inputs={str(f):sha(f)for f in files}));assert sha(R/'rtl/arm/arm9_mem.sv')==source_sha
# Two exact images, one previously qualified real SYS/timer leaf and one queue burst.
images={}
for tag in ['mixed','burst']:
 src=(R/'sim/arm/io_retry_window/compose_mixed.s').read_text()if tag=='mixed'else(R/'sim/arm/wbd8_storage/directed.s').read_text().replace('ldr r4,=0x04000108','ldr r4,=0x02410400')
 (G/(tag+'.s')).write_text(src);call(['llvm-mc','-triple=armv5te-none-eabi','-filetype=obj','-I',R/'sim/arm/tests',G/(tag+'.s'),'-o',G/(tag+'.o')],tag+'-asm');call(['ld.lld','-Ttext=0x02000000','--entry=_start',G/(tag+'.o'),'-o',G/(tag+'.elf')],tag+'-link');call(['llvm-objcopy','-O','binary',G/(tag+'.elf'),G/(tag+'.bin')],tag+'-objcopy');call(['python3','sim/arm/tools/mkhex.py',G/(tag+'.hex'),str(G/(tag+'.bin'))+'@0x02000000'],tag+'-mkhex');nm=subprocess.check_output(['llvm-nm',G/(tag+'.elf')],text=True);images[tag]=next(x.split()[0]for x in nm.splitlines()if x.endswith(' compare_end'))
result=dict(source_sha256=source_sha,base=BASE,cases={})
for tag,reset,pressure in [('mixed',0,0),('mixed',1,0),('mixed',2,0),('burst',0,1),('burst',0,7)]:
 case=tag+'-reset'+str(reset)+'-peer'+str(pressure);data={}
 for name,model in models.items():
  out=G/(case+'-'+name);log=call([model,'+img0='+str(G/(tag+'.hex')),'+pc0=02000000','+run=1','+blat=9','+ldm_desc','+maxcycles=300000','+trace0='+str(out)+'.csv','+trace1='+str(out)+'.a7.csv','+qcycle='+str(out)+'.cycles.csv','+reset_kind='+str(reset),'+qpeer='+str(pressure)],case+'-'+name);text=log.read_text();assert'TEST PASSED'in text and'chip_errors0'in text and'TEST FAILED'not in text,(case,name,text[-2200:]);rows=out.with_suffix('.csv').read_text().splitlines();rows=rows[:next(i for i,l in enumerate(rows)if l.startswith(images[tag]+','))]
  physical=re.findall(r'^(?:LDMDESC|PEER |PINWORD|PINRETURN).*$',text,re.M);summary=re.findall(r'^(?:QUEUE_CPU|PEER_SUMMARY|cycles=).*$',text,re.M)
  if reset:assert'RESET_POINT '+str(reset)in text
  data[name]=dict(state=rows,physical=physical,summary=summary)
 assert data['before']==data['on'],('paired pin state/descriptor/pressure/cycles',case)
 assert(G/(case+'-before.cycles.csv')).read_bytes()==(G/(case+'-on.cycles.csv')).read_bytes(),('paired pin percycle',case)
 result['cases'][case]=dict(states=len(data['on']['state']),physical_events=len(data['on']['physical']),summary=data['on']['summary'],PASS=True);save(G/'results.json',result);print('PIN_CASE_PASS',case,result['cases'][case],flush=True)
print('WBD_PIN_COMPLETE',flush=True)
