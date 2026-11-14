#!/usr/bin/env python3
"""Packed texture service: exact original dates, then critical-fill forwarding.
Uses the sealed RC8 original consumer/oracle and production shared owner cone.
One frozen build, sequential NI10/t1 workers, global C++ mutex and j1.
"""
from pathlib import Path
import argparse,fcntl,hashlib,json,os,resource,shutil,subprocess,time
R=Path(__file__).resolve().parents[3];B=R/'build/raster-symptoms/cache-pool';O=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');V=Path('build/tools/oss-cad-suite/bin/verilator')
H=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
def put(p,v):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(v,indent=2)+'\n');t.replace(p)
def status(**v):
 d=json.loads(O.read_text());d.update(updated_at=time.time(),**v);s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t=O.with_suffix('.Raster.tmp');t.write_text(s);t.replace(O)
def guard():
 disk=shutil.disk_usage(R).free;mem=int(next(x.split()[1]for x in Path('/proc/meminfo').read_text().splitlines()if x.startswith('MemAvailable:')))*1024
 if disk<30*1024**3 or mem<12*1024**3:
  msg=f'disk{disk/1024**3:.2f}/30GiB;RAM{mem/1024**3:.2f}/12GiB';status(phase='CACHE_POOL_RESOURCE_BLOCKED',workers=[],resource_blocker=msg);raise RuntimeError(msg)
def mod(s,n):
 a=s.index('module '+n+' #(');return s[a:s.index('endmodule',a)+9]+'\n'
def prepare():
 assert not B.exists(),'refuse to replace source snapshot';B.mkdir()
 src=(R/'rtl/ds/nds_gpu3d.sv').read_text();before=subprocess.check_output(['git','show','2732d63da68d6050180ac95aa40ed550aaaf7e86:rtl/ds/nds_gpu3d.sv'],cwd=R,text=True);original=mod(before,'nds_g3d_cache2');candidate=mod(src,'nds_g3d_cache2')
 seal=json.loads((R/'docs/results/texture-pool-20261110/original-oracle-seal.json').read_text());assert hashlib.sha256(original.encode()).hexdigest()==seal['current_cache_sha256']
 (B/'before.sv').write_text(original.replace('module nds_g3d_cache2 #(','module cache_before #(',1))
 old='.way(f_w[0][1:0])';bad='.way($test$plusargs("pool_wrong_way") ? (f_w[0][1:0]^2\'d1) : f_w[0][1:0])';assert candidate.count(old)==1
 cand=candidate.replace('module nds_g3d_cache2 #(','module cache_probe #(',1).replace(old,bad)
 old2='data <= b_rdata[h[2:1]*16 +: 16]';bad2='data <= b_rdata[(h[2:1]^2\'($test$plusargs("pool_wrong_word")))*16 +: 16]';assert cand.count(old2)==1;cand=cand.replace(old2,bad2)
 assert cand.replace('module cache_probe #(','module nds_g3d_cache2 #(',1).replace(bad,old).replace(bad2,old2)==candidate
 (B/'candidate.sv').write_text(cand+mod(src,'nds_g3d_data4'))
 tag=(R/'rtl/ds/nds_lcache.sv').read_text();oldt='bca<=c_idx;';badt='bca<=$test$plusargs("pool_wrong_scan") ? l_idx : c_idx;';assert tag.count(oldt)==1;probe=tag.replace(oldt,badt);assert probe.replace(badt,oldt)==tag;(B/'nds_lcache.sv').write_text(probe)
 for rel in ['rtl/gpu2d/gpu2d_pkg.sv','rtl/gpu3d/gpu3d_ram.sv']:
  shutil.copyfile(R/rel,B/Path(rel).name)
 tb=Path(__file__).with_name('original_tb.sv').read_text();header=tb[:tb.index(' if(k==2)')]
 header=header.replace('output logic[31:0]tex_epoch','output logic[31:0]critical_count[0:2],output logic[31:0]tex_epoch')
 body=''
 for label,condition,module,extra in [('g_small','k==2','cache_probe',',.POOL(1),.CWF(1)'),('g_four','k==1','cache_probe',',.POOL(1),.CWF(0)'),('g_off',None,'cache_before','')]:
  body+=(' if'if condition=='k==2'else' else if'if condition else' else')+(f'({condition})'if condition else'')+f' begin:{label}\n'
  body+=f''' {module} #(.AW(19),.LW(9),.QL(4),.NF(2),.WAYS(4),.PUMP(1),.PF(1),.PF_SINGLE(1){extra})u_tc(.clk,.clk2,.rst,.flush,.req(tex_req),.addr(tex_addr),.valid(tc_v),.data(td),.b_req(tc_req),.b_blk(tc_blk),.b_ack(tc_ack),.b_rvalid(tc_rv),.b_rdata(t_rdata[k]),.pf_v,.pf_a);
 assign tl=u_tc.l_en;assign th=(u_tc.st==u_tc.C_LOOK&&u_tc.hit){'||u_tc.cwf_take'if module=='cache_probe'else''};assign pg=u_tc.p_go;assign pn=u_tc.pq_n;
 assign fl=u_tc.f_last;assign fs=u_tc.f_st[0];
 assign ci=u_tc.n==0&&u_tc.f_v==0&&!u_tc.r_v&&u_tc.pq_n==0&&u_tc.st==u_tc.C_IDLE;
 assign critical_now={'u_tc.cwf_take'if module=='cache_probe'else"1'b0"};
 end
'''
 tail=tb[tb.index(' rc8_receiver_before #(.AW(17)'):];tail=tail.replace('rc8_receiver_before','cache_before')
 header=header.replace(' logic tl,pl,th,ph,pg,fl,fs;',' logic critical_now;\n logic tl,pl,th,ph,pg,fl,fs;')
 tail=tail.replace('if(th)tex_epoch[k]<=te;','if(th)tex_epoch[k]<=critical_now?mem_epoch:te;')
 tail=tail.replace('initial begin hint_look[k]=0;','initial begin critical_count[k]=0;hint_look[k]=0;')
 tail=tail.replace('if(!rst)begin','if(!rst)begin if(critical_now)critical_count[k]++;')
 tail=tail.replace("if(k!=0&&pf_v&&pn-3'(pg)>=(k==2?1:4))","if(pf_v&&pn-3'(pg)>=1)")
 (B/'tb.sv').write_text(header+body+tail)
 cpp=(R/'sim/gpu3d/tpf_receiver/main.cpp').read_text();cpp=cpp.replace('struct Request { uint32_t addr; };','struct Request { uint32_t addr; uint64_t at; };');cpp=cpp.replace('uint64_t blocks=0, simultaneous=0, stalled=0, maxflight=0;','uint64_t blocks=0, simultaneous=0, stalled=0, maxflight=0, latency[2]={0,0}, maxlat[2]={0,0};')
 cpp=cpp.replace('push_back({ta})','push_back({ta,cycle})').replace('push_back({pa})','push_back({pa,cycle})')
 needle='            // Contention/backpressure, no first beat before ACK+2.';assert cpp.count(needle)==1
 cpp=cpp.replace(needle,'''            if(k==1) {
                if(((m->t_req>>1)&1)!=(m->t_req&1)||((m->t_req&1)&&m->t_blk[1]!=m->t_blk[0]))throw std::runtime_error("CACHE_POOL_CYCLE_EQ block offer");
                m->t_ack|=(m->t_ack&1)<<1;m->t_rvalid|=(m->t_rvalid&1)<<1;m->t_rdata[1]=m->t_rdata[0];
                q.flights=p[0].flights;q.blocks=p[0].blocks;q.simultaneous=p[0].simultaneous;q.stalled=p[0].stalled;q.maxflight=p[0].maxflight;
                continue;
            }
'''+needle)
 needle='        for(int k=0;k<3;k++)for(int space=0;space<2;space++) {';assert cpp.count(needle)==1
 cpp=cpp.replace(needle,'''        if(!reset) {
            if((m->tex_valid&1)!=((m->tex_valid>>1)&1)||(m->pal_valid&1)!=((m->pal_valid>>1)&1))throw std::runtime_error("CACHE_POOL_CYCLE_EQ valid date");
            if((m->tex_valid&1)&&m->tex_data[0]!=m->tex_data[1])throw std::runtime_error("CACHE_POOL_CYCLE_EQ texture data");
            if((m->pal_valid&1)&&m->pal_data[0]!=m->pal_data[1])throw std::runtime_error("CACHE_POOL_CYCLE_EQ palette data");
        }
'''+needle)
 cpp=cpp.replace('uint32_t a=q.demands[space].front().addr;q.demands[space].pop_front();','auto demand=q.demands[space].front();uint32_t a=demand.addr;q.demands[space].pop_front();q.latency[space]+=cycle-demand.at;q.maxlat[space]=std::max(q.maxlat[space],cycle-demand.at);')
 cpp=cpp.replace('if(p[0].blocks||!p[1].blocks||!p[2].blocks)','if(!p[0].blocks||!p[1].blocks||!p[2].blocks)')
 needle='            printf("RC8_RECEIVER_PROFILE %d';assert cpp.count(needle)==1
 cpp=cpp.replace(needle,'''            printf("CACHE_POOL_CRITICAL profile=%d count=%u\\n",k,m->critical_count[k]);
            printf("CACHE_POOL_LATENCY profile=%d texture_sum=%llu palette_sum=%llu texture_max=%llu palette_max=%llu\\n",k,(unsigned long long)p[k].latency[0],(unsigned long long)p[k].latency[1],(unsigned long long)p[k].maxlat[0],(unsigned long long)p[k].maxlat[1]);
'''+needle)
 cpp=cpp.replace('if(!m->hint_drop[1]', 'if(!m->critical_count[2])throw std::runtime_error("missing critical-fill retirement coverage");\n        if(!m->hint_drop[1]')
 (B/'main.cpp').write_text(cpp)
 files=['gpu2d_pkg.sv','gpu3d_ram.sv','nds_lcache.sv','before.sv','candidate.sv','tb.sv','main.cpp'];manifest=dict(frozen_unix=time.time(),source_before='2732d63d',original_oracle_seal=H(R/'docs/results/texture-pool-20261110/original-oracle-seal.json'),candidate_production_sources={p:H(R/p)for p in ['rtl/ds/nds_gpu3d.sv','rtl/ds/nds_lcache.sv']},inputs={n:H(B/n)for n in files},probe_inverse_exact=True,profile='allPFsingle; 0original,1packed,2packed+CWF; 0/1 identical actual backend and cycleEQ; 2 independent contention/freshness model',workers=[]);put(B/'snapshot.json',manifest)
 for n in files:(B/n).chmod(0o444)
 print('CACHE_POOL_PREPARED')
def worker(tag,cmd):
 guard();pfile=B/(tag+'.log');assert not pfile.exists()
 with pfile.open('x')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);ni=os.getpriority(os.PRIO_PROCESS,p.pid);assert ni>=10;start=time.time();record=dict(pid=p.pid,parent=os.getpid(),host='Desktop',ni=ni,threads=1,command=list(map(str,cmd)),start=start);put(B/(tag+'.process.json'),record);status(phase='CACHE_POOL_'+tag.upper(),workers=[{k:record[k]for k in ['pid','parent','host','ni','threads']}],resource_blocker=None)
  while p.poll() is None:
   if time.time()-start>600 or pfile.stat().st_size>16*1024**2:
    os.killpg(p.pid,15);p.wait(timeout=10);raise RuntimeError('fixture timeout/output bound')
   time.sleep(.1)
  rc=p.returncode
 record.update(returncode=rc,seconds=time.time()-start,log_sha256=H(pfile));put(B/(tag+'.receipt.json'),record);status(phase='CACHE_POOL_WORKER_REAPED',workers=[]);return rc,pfile.read_text()
def run(action):
 os.setpriority(os.PRIO_PROCESS,0,max(10,os.getpriority(os.PRIO_PROCESS,0)));resource.setrlimit(resource.RLIMIT_CORE,(0,0));s=json.loads((B/'snapshot.json').read_text())
 for n,h in s['inputs'].items():assert H(B/n)==h
 files=[B/n for n in s['inputs']if n.endswith('.sv')]
 if action=='lint':
  rc,t=worker('lint',[V,'--lint-only','--no-timing','--assert','--threads','1','-Wno-fatal','--top-module','tb_tpf_receiver',*files]);assert rc==0,t[-4000:];return
 lock=Path.home()/'.cache/nds-sim-build.lock'
 if action=='build':
  with lock.open('a')as f:
   status(phase='CACHE_POOL_BUILD_MUTEX_WAIT',workers=[]);fcntl.flock(f,fcntl.LOCK_EX);guard();rc,t=worker('build',[V,'--cc','--exe','--build','--no-timing','--assert','-j','1','--threads','1','-Wno-fatal','--compiler','clang','-CFLAGS','-std=c++20 -O1','-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','tb_tpf_receiver','--Mdir',B/'obj',*files,B/'main.cpp']);assert rc==0,t[-4000:]
  put(B/'model.json',dict(sha256=H(B/'obj/Vtb_tpf_receiver'),snapshot_sha256=H(B/'snapshot.json')));return
 assert H(B/'obj/Vtb_tpf_receiver')==json.loads((B/'model.json').read_text())['sha256']
 results={}
 for tag,args,negative in [('seed1',['--seed=1'],None),('wrong-data-way',['--seed=1','+pool_wrong_way'],'CACHE_POOL_CYCLE_EQ texture data'),('wrong-scan-address',['--seed=1','+pool_wrong_scan'],'CACHE_POOL_CYCLE_EQ'),('wrong-critical-word',['--seed=1','+pool_wrong_word'],'RC8_RECEIVER_DATA_FAIL profile=2 space=0')]:
  rc,t=worker(tag,[B/'obj/Vtb_tpf_receiver',*args]);ok=(rc!=0 and negative in t)if negative else(rc==0 and 'RC8_RECEIVER_PASS'in t);results[tag]=dict(passed=ok,exit=rc,tail=t.splitlines()[-8:]);put(B/'result.json',dict(result='IN_PROGRESS',cases=results));assert ok,t[-4000:]
 put(B/'result.json',dict(result='PASS_PACKED_EXACT_DATES_CWF_VALUES_AND_ACTUAL_FAULTS',cases=results,limits='Portable unit profile only; no native mapping/STA or fullscene performance/acceptance.'))
if __name__=='__main__':
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('action',choices=['prepare','lint','build','run']);ap.add_argument('--out',type=Path);a=ap.parse_args();B=a.out or B;prepare()if a.action=='prepare'else run(a.action)
