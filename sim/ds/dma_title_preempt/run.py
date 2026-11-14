#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import argparse,fcntl,hashlib,json,pathlib,shutil,subprocess,time,resource
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];O=W/'build/dma-title-preempt';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');V='build/tools/oss-cad-suite/bin/verilator'
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def atomic(p,d):
 p.parent.mkdir(parents=True,exist_ok=True);t=p.with_suffix('.tmp.'+str(os.getpid()));t.write_text(json.dumps(d,separators=(',',':')));t.replace(p)
def status(phase,pid=None):
 s=json.loads(STATUS.read_text());s.update(phase=phase,updated_at=time.time(),workers=[] if pid is None else [{'host':'Desktop','pid':pid,'parent':os.getpid(),'ni':os.getpriority(os.PRIO_PROCESS,pid),'threads':1}]);atomic(STATUS,s)
def guard():
 assert shutil.disk_usage(W).free>=30*1024**3,'disk<30GiB';assert int(next(s.split()[1] for s in pathlib.Path('/proc/meminfo').read_text().splitlines() if s.startswith('MemAvailable:')))*1024>=12*1024**3,'memory<12GiB'
def call(cmd,log,phase):
 os.setpriority(os.PRIO_PROCESS,0,10)
 with log.open('w') as f:
  started=time.time();p=subprocess.Popen(cmd,cwd=W,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);assert os.getpriority(os.PRIO_PROCESS,p.pid)==10;status(phase,p.pid);rc=p.wait(timeout=120)
 atomic(log.with_suffix('.receipt.json'),{'cmd':cmd,'pid':p.pid,'ni':10,'rc':rc,'start_unix':started,'end_unix':time.time(),'sha256':h(log)});status('RHIT_UNIT_REAPED');return rc
ap=argparse.ArgumentParser();ap.add_argument('tag');ap.add_argument('--mutant',choices=['owner','address','capture','invalidation','lane','wb-address','dma-step','resume-owner','resume-source','resume-dest','resume-count','reload']);ap.add_argument('--off',action='store_true');a=ap.parse_args();d=O/a.tag;d.mkdir(parents=True,exist_ok=False)
frozen=d/'source';frozen.mkdir();REF='232c26ac'
paths=['rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_vram.sv','rtl/ds/nds_ram.sv','rtl/sys/sys_dma.sv','rtl/sys/sys_ram.sv']
for rel in paths:
 b=subprocess.check_output(['git','show',REF+':'+rel],cwd=W);assert b==(W/rel).read_bytes(),rel;(frozen/pathlib.Path(rel).name).write_bytes(b)
shutil.copyfile(W/'sim/ds/dma_title_preempt/tb.sv',frozen/'tb.sv')
if a.mutant:
 file,old,new={
  'owner':('nds_vram.sv','c_res_owned && c_req',"1'b1 && c_req"),
  'address':('nds_vram.sv','rb[rbi(lh, res_q[4:2])]','rb[rbi(lh, res_q[4:2] ^ {2\'b00,rhit})]'),
  'capture':('nds_vram.sv','!cap_v && !cap_p',"1'b1 && !cap_p"),
  'invalidation':('nds_vram.sv','assign any_w = (cw_valid && cw_ack) || (vm_req && vm_ack && vwe);',"assign any_w = 1'b0;"),
  'lane':('nds_fabric.sv',"addr[1] ? {16'd0, rdata[31:16]} : {16'd0, rdata[15:0]}","addr[1] ? {16'd0, rdata[15:0]} : {16'd0, rdata[31:16]}"),
  'wb-address':('nds_vram.sv','wb_off <= c_off[19:2]',"wb_off <= c_off[19:2] ^ 18'd1"),
  'dma-step':('sys_dma.sv',"(sz32 ? 28'd4 : 28'd2)","(sz32 ? 28'd4 : 28'd4)")
  ,'resume-owner':('sys_dma.sv','assign work_wa = lr_v ? lr_k : ek;',"assign work_wa = lr_v ? lr_k : ((save_go && e_why == 0) ? ek ^ 3'd2 : ek);"),
  'resume-source':('sys_dma.sv','lr_v ? reg_rd : {e_dst, e_src}',"lr_v ? reg_rd : {e_dst, (e_src + ((save_go && e_why == 0) ? 32'd4 : 32'd0))}"),
  'resume-dest':('sys_dma.sv','lr_v ? reg_rd : {e_dst, e_src}',"lr_v ? reg_rd : {(e_dst + ((save_go && e_why == 0) ? 32'd4 : 32'd0)), e_src}"),
  'resume-count':('sys_dma.sv','{4\'d0, e_chunk, e_rem, lr_v ? reg_rd',"{4'd0, e_chunk, (e_rem - ((save_go && e_why == 0) ? 21'd1 : 21'd0)), lr_v ? reg_rd"),
  'reload':('sys_dma.sv',"if (!e_res && e_cnt[22:21] == 2'd3) e_dst", "if (1'b0 && !e_res && e_cnt[22:21] == 2'd3) e_dst")
 }[a.mutant]
 p=frozen/file;s=p.read_text();assert s.count(old)==1,(file,old,s.count(old));p.write_text(s.replace(old,new))

files={p.name:h(p) for p in frozen.iterdir()}
for p in frozen.iterdir():p.chmod(0o444)
atomic(d/'snapshot.json',{'before_compilation_unix':time.time(),'files':files,'mutant':a.mutant,'off':a.off,'source_ref':REF})
with (pathlib.Path.home()/'.cache/nds-sim-build.lock').open('w') as lock:
 status('RHIT_UNIT_MUTEX_WAIT');fcntl.flock(lock,fcntl.LOCK_EX);guard()
 cmd=[V,'--binary','--timing','-O2','-j','4','--threads','1','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','--top-module','tb_dma_title','--Mdir',str(d/'obj'),f'-GEN={0 if a.off else 1}']+[str(frozen/pathlib.Path(p).name) for p in paths]+[str(frozen/'tb.sv')]
 rc=call(cmd,d/'build.log','RHIT_UNIT_BUILD')
if rc:raise SystemExit('build failed')
exe=d/'obj/Vtb_dma_title';rc=call([str(exe)],d/'run.log','DMA16_UNIT_SIM');assert all(h(frozen/n)==v for n,v in files.items())
text=(d/'run.log').read_text();result={'rc':rc,'model_sha256':h(exe),'source_sha256':files,'log_sha256':h(d/'run.log'),'mutant':a.mutant,'off':a.off,'source_ref':REF};atomic(d/'result.json',result)
if a.mutant:assert rc!=0 and any(s in text for s in ['PAYLOAD','ADDRESS','TITLE_DMA_COUNTS','DMA_TITLE_CLASS','PREEMPT_SNAPSHOT_STATE']),text[-2000:]
else:assert rc==0 and 'TITLE_DMA_PASS' in text,text[-2000:]
print(json.dumps(result))
