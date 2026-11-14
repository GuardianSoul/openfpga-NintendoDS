#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import argparse,fcntl,hashlib,json,pathlib,shutil,subprocess,time,resource
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];O=W/'build/vram-rhit';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');V='build/tools/oss-cad-suite/bin/verilator'
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
  p=subprocess.Popen(cmd,cwd=W,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);assert os.getpriority(os.PRIO_PROCESS,p.pid)==10;status(phase,p.pid);rc=p.wait(timeout=120)
 atomic(log.with_suffix('.receipt.json'),{'cmd':cmd,'pid':p.pid,'ni':10,'rc':rc,'sha256':h(log)});status('RHIT_UNIT_REAPED');return rc
ap=argparse.ArgumentParser();ap.add_argument('tag');ap.add_argument('--mutant',choices=['owner','address','capture','tag','valid','post','cap-pending','lane','wb-address']);ap.add_argument('--off',action='store_true');ap.add_argument('--map-bus',action='store_true');ap.add_argument('--held-remap',action='store_true');ap.add_argument('--wrap',action='store_true');ap.add_argument('--pf',action='store_true');ap.add_argument('--live-hit',action='store_true');ap.add_argument('--equiv',action='store_true');ap.add_argument('--quiet',action='store_true');a=ap.parse_args();d=O/a.tag;d.mkdir(parents=True,exist_ok=False)
s=(W/'rtl/ds/nds_vram.sv').read_text()
if a.mutant and a.mutant!='lane':
 old,new={'owner':('c_res_owned && c_req','1\'b1 && c_req'),'address':('rb[rbi(lh, res_q[4:2])]','rb[rbi(lh, res_q[4:2] ^ {2\'b00,rhit})]'),'capture':('!cap_v && !cap_p','1\'b1 && !cap_p'),'tag':('res_q[20] && lhit[0]','res_q[20] && lv[0]'),'valid':('res_q[20] && lhit[0]','1\'b1 && lhit[0]'),'post':('!post_p &&','1\'b1 &&'),'cap-pending':('!cap_v && !cap_p &&','!cap_v && 1\'b1 &&'),'wb-address':('wb_off <= c_off[19:2]','wb_off <= c_off[19:2] ^ 18\'d1')}[a.mutant];assert s.count(old)==1;s=s.replace(old,new)
frozen=d/'source';frozen.mkdir();(frozen/'nds_vram.sv').write_text(s)
for source in [W/'rtl/gpu2d/gpu2d_pkg.sv',W/'sim/ds/vram_rhit/tb.sv',W/'rtl/ds/nds_fabric.sv',W/'rtl/ds/nds_ram.sv',W/'rtl/gpu2d/gpu2d_ram.sv']:shutil.copyfile(source,frozen/source.name)
if a.mutant=='lane':
 p=frozen/'nds_fabric.sv';b=p.read_text();old="addr[1] ? {16'd0, rdata[31:16]} : {16'd0, rdata[15:0]}";assert b.count(old)==1;p.write_text(b.replace(old,"addr[1] ? {16'd0, rdata[15:0]} : {16'd0, rdata[31:16]}"))
if a.equiv:
 old=subprocess.check_output(['git','show','1d90f68a:rtl/ds/nds_vram.sv'],cwd=W,text=True).replace('module nds_vram\n','module nds_vram_old\n',1);(frozen/'old.sv').write_text(old)
 tb=(W/'sim/ds/tb_vram_eq.sv').read_text().replace('.clk, .rst, .vramcnt, .c_req, .c_cpu, .c_we,','.clk, .rst, .vramcnt, .c_req, .c_cpu, .c_dma, .c_we,').replace('u_new (`VRAM_PORTS(n_), .c_dma);','u_new (`VRAM_PORTS(n_));')
 tb=tb.replace('.VR_PF(0))',f'.VR_PF(0), .VR_RHIT({1 if a.quiet else 0}))')
 if a.quiet:tb=tb.replace('else if (!g_req && $urandom % 20 == 0)','else if (1\'b0)').replace(' && n_g > 0','')
 (frozen/'eq.sv').write_text(tb)

files={p.name:h(p) for p in frozen.iterdir()}
for p in frozen.iterdir():p.chmod(0o444)
atomic(d/'snapshot.json',{'before_compilation_unix':time.time(),'files':files,'mutant':a.mutant,'off':a.off,'pf':a.pf,'live_hit':a.live_hit,'wrap':a.wrap,'held_remap':a.held_remap,'map_bus':a.map_bus})
with (pathlib.Path.home()/'.cache/nds-sim-build.lock').open('w') as lock:
 status('RHIT_UNIT_MUTEX_WAIT');fcntl.flock(lock,fcntl.LOCK_EX);guard()
 cmd=[V,'--binary','--timing','-O2','-j','4','--threads','1','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','--top-module','tb_rhit','--Mdir',str(d/'obj'),f'-GEN={0 if a.off else 1}',f'-GPF={int(a.pf)}',f'-GLIVE={int(a.live_hit)}',f'-GWRAP={int(a.wrap)}',f'-GHELD_MAP={int(a.held_remap)}',f'-GMAP_BUS={int(a.map_bus)}',str(frozen/'nds_fabric.sv'),str(frozen/'nds_ram.sv'),str(frozen/'gpu2d_ram.sv'),str(frozen/'gpu2d_pkg.sv'),str(frozen/'nds_vram.sv'),str(frozen/'tb.sv')]
 if a.equiv:
  cmd=[V,'--binary','--timing','-O2','-j','4','--threads','1','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','--top-module','tb_vram_eq','--Mdir',str(d/'obj'),str(frozen/'gpu2d_pkg.sv'),str(frozen/'old.sv'),str(frozen/'nds_vram.sv'),str(frozen/'eq.sv')]
 rc=call(cmd,d/'build.log','RHIT_UNIT_BUILD')
if rc:raise SystemExit('build failed')
exe=d/('obj/Vtb_vram_eq' if a.equiv else 'obj/Vtb_rhit');rc=call([str(exe)]+(['+seed=7','+cycles=100000'] if a.equiv else []),d/'run.log','RHIT_UNIT_SIM');assert all(h(frozen/n)==v for n,v in files.items())
text=(d/'run.log').read_text();result={'rc':rc,'model_sha256':h(exe),'source_sha256':files,'log_sha256':h(d/'run.log'),'mutant':a.mutant,'off':a.off,'pf':a.pf,'live_hit':a.live_hit,'wrap':a.wrap,'held_remap':a.held_remap,'map_bus':a.map_bus};atomic(d/'result.json',result)
if a.mutant:assert rc!=0 and ('READ_PAYLOAD' in text or 'BLOCK_DATA_ORDER' in text),text[-2000:]
else:assert rc==0 and ('0 mismatches' in text and '\nPASS' in text if a.equiv else ('MAP_BUS_PASS' if a.map_bus else 'HELD_MAP_PASS' if a.held_remap else 'RHIT_UNIT_PASS') in text),text[-2000:]
print(json.dumps(result))
