#!/usr/bin/env python3
"""Actual Quartus byte-enabled SDP payload and FAST tag service, no fit/STA."""
from pathlib import Path
import fcntl,hashlib,importlib.util,json,os,resource,subprocess
R=Path(__file__).resolve().parents[3];O=R/'build/raster-symptoms/cache-pool-native';T=Path('build/tools/oss-cad-suite/bin');vendor=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
spec=importlib.util.spec_from_file_location('pool_check',Path(__file__).with_name('check.py'));c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
os.setpriority(os.PRIO_PROCESS,0,max(10,os.getpriority(os.PRIO_PROCESS,0)));resource.setrlimit(resource.RLIMIT_CORE,(0,0));assert not O.exists();O.mkdir();c.B=O
ram=(R/'rtl/gpu3d/gpu3d_ram.sv').read_text();gpu=(R/'rtl/ds/nds_gpu3d.sv').read_text();tags=(R/'rtl/ds/nds_lcache.sv').read_text();old=subprocess.check_output(['git','show','2732d63da68d6050180ac95aa40ed550aaaf7e86:rtl/ds/nds_lcache.sv'],cwd=R,text=True)
helper=c.mod(gpu,'nds_g3d_data4');be=c.mod(ram,'gpu3d_ram_be4');tag=c.mod(tags,'nds_lcache_n')
native='`define ALTERA_RESERVED_QIS\n'+helper.replace('module nds_g3d_data4 #(','module payload_native #(',1)+be.replace('module gpu3d_ram_be4 #(','module tag_be_native #(',1)+tag.replace('module nds_lcache_n #(','module tags_native #(',1).replace('gpu3d_ram_be4 #','tag_be_native #')+'`undef ALTERA_RESERVED_QIS\n'
portable=helper.replace('module nds_g3d_data4 #(','module payload_model #(',1)+tag.replace('module nds_lcache_n #(','module tags_model #(',1)+c.mod(old,'nds_lcache_n').replace('module nds_lcache_n #(','module tags_old #(',1)
(O/'actual.sv').write_text(native+portable);(O/'gpu3d_ram.sv').write_text(ram)
bench=r'''`timescale 1ns/1ps
module tb_cache_native;
reg clk=0,clk2=0,we=0;reg[1:0]way=0;reg[8:0]wa=0,ra=0;reg[63:0]wd=0;
wire[3:0][63:0]nq,pq;reg[63:0]gold[4][512],expected[4];reg known[4][512],check_word[4];
payload_native nd(.clk,.we,.way,.waddr(wa),.wdata(wd),.raddr(ra),.rdata(nq));
payload_model pd(.clk,.we,.way,.waddr(wa),.wdata(wd),.raddr(ra),.rdata(pq));
reg rst=1,inv_all=0,l_en=0,f_end=0,f_ok=0;reg[6:0]li=0,ci=0,fi=0;reg[1:0]fw=0;reg[6:0]ft=0;
wire[3:0]nv,pv,ov,ncv,pcv,ocv;wire[6:0]nt[4],pt[4],ot[4],nct[4],pct[4],oct[4];wire nb,pb,ob;
tags_native #(.LB(7),.TW(7),.G(3),.WAYS(4),.PUMP(1),.POOL(1))ntags(.clk,.clk2,.rst,.inv_all,.l_en,.l_idx(li),.l_vn(nv),.l_tag(nt),.c_idx(ci),.c_v(ncv),.c_tag(nct),.f_idx(fi),.f_end,.f_way(fw),.f_ok,.f_tag(ft),.busy(nb));
tags_model #(.LB(7),.TW(7),.G(3),.WAYS(4),.PUMP(1),.POOL(1))ptags(.clk,.clk2,.rst,.inv_all,.l_en,.l_idx(li),.l_vn(pv),.l_tag(pt),.c_idx(ci),.c_v(pcv),.c_tag(pct),.f_idx(fi),.f_end,.f_way(fw),.f_ok,.f_tag(ft),.busy(pb));
tags_old #(.LB(7),.TW(7),.G(3),.WAYS(4),.PUMP(1))otags(.clk,.clk2,.rst,.inv_all,.l_en,.l_idx(li),.l_vn(ov),.l_tag(ot),.c_idx(ci),.c_v(ocv),.c_tag(oct),.f_idx(fi),.f_end,.f_way(fw),.f_ok,.f_tag(ft),.busy(ob));
reg[31:0]rng=32'h3da52c71;integer n,w,a,data_checks=0,tag_checks=0,collisions=0,late=0,flushes=0;
function[31:0]rand32;begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);rand32=rng;end endfunction
initial begin
 for(w=0;w<4;w=w+1)for(a=0;a<512;a=a+1)begin gold[w][a]=0;known[w][a]=0;end
 #10;
 for(n=0;n<16384;n=n+1)begin
  // Qualified tag/scan consumers are the next common SYS edge. Live
  // addresses change before M, as the original service allowed.
  if(n>4)begin
   if({nv,ncv,nb,pv,pcv,pb}!=={ov,ocv,ob,ov,ocv,ob})$fatal(1,"NATIVE_TAG_STATE n%0d",n);
   for(w=0;w<4;w=w+1)begin
    if({nt[w],pt[w],nct[w],pct[w]}!=={ot[w],ot[w],oct[w],oct[w]})$fatal(1,"NATIVE_TAG_CONSUMER n%0d way%0d",n,w);
    tag_checks=tag_checks+1;
   end
  end
  we=n<2048||n%7!=0;way=n<2048?2'(n/512):2'(rand32());wa=n<2048?9'(n):9'(rand32());
  ra=n%3==0?wa:9'(rand32());wd={rand32(),rand32()};
  for(w=0;w<4;w=w+1)begin expected[w]=gold[w][ra];check_word[w]=known[w][ra];end
  if(we&&ra==wa)collisions=collisions+1;
  rst=n<3||n%1021==0;inv_all=n%37==3;f_end=n%3!=2;f_ok=n%11!=0;
  l_en=n%5!=0;li=7'(rand32());ci=n%4==0?fi:7'(rand32());fi=7'(rand32());fw=2'(rand32());ft=7'(rand32());
  if(inv_all)flushes=flushes+1;
  #3;clk=1;clk2=1;#2;
  for(w=0;w<4;w=w+1)if(check_word[w])begin
   if(nq[w]!==expected[w]||pq[w]!==expected[w])$fatal(1,"NATIVE_PAYLOAD_OLD_DATA n%0d way%0d got%h want%h",n,w,nq[w],expected[w]);
   data_checks=data_checks+1;
  end
  if(we)begin gold[way][wa]=wd;known[way][wa]=1;end
  clk=0;clk2=0;#1;
  // Inputs are free to change after the common edge; M must use the
  // captured write and scanner ownership, not these new live values.
  ci=7'(rand32());li=7'(rand32());fi=7'(rand32());ft=7'(rand32());fw=2'(rand32());f_end=1'b0;late=late+1;
  #2;clk2=1;#2;clk2=0;#1;
 end
 if(data_checks<50000||tag_checks<60000||flushes<400||collisions<4000)$fatal(1,"NATIVE_COVERAGE");
 $display("PASS_CACHE_POOL_NATIVE SYS%0d payload%0d qualifiedTags%0d oldDataCollisions%0d lateMidInputs%0d flushes%0d",n,data_checks,tag_checks,collisions,late,flushes);$finish;
end
endmodule
'''
(O/'bench.sv').write_text(bench)
manifest=dict(vendor=str(vendor),vendor_sha256=c.H(vendor),production_hashes={p:c.H(R/p)for p in ['rtl/ds/nds_gpu3d.sv','rtl/ds/nds_lcache.sv']},inputs={n:c.H(O/n)for n in ['actual.sv','gpu3d_ram.sv','bench.sv']},scope='Actual Quartus25.1 altsyncram parameter branches, full64bit payloads, native byte enables/mixedOLD_DATA and FAST tag consumers versus original PUMP controller. No synthesis/packing/STA claim.')
c.put(O/'snapshot.json',manifest)
for n in manifest['inputs']:(O/n).chmod(0o444)
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as f:
 c.status(phase='CACHE_POOL_NATIVE_BUILD_MUTEX_WAIT',workers=[]);fcntl.flock(f,fcntl.LOCK_EX);c.guard();rc,t=c.worker('native-build',[T/'iverilog','-g2012','-s','tb_cache_native','-o',O/'model.vvp',vendor,O/'gpu3d_ram.sv',O/'actual.sv',O/'bench.sv']);assert rc==0,t[-4000:]
rc,t=c.worker('native-run',[T/'vvp',O/'model.vvp']);c.put(O/'result.json',dict(result='PASS'if rc==0 and'PASS_CACHE_POOL_NATIVE'in t else'FAIL',returncode=rc,tail=t.splitlines()[-8:],model_sha256=c.H(O/'model.vvp')));assert rc==0 and'PASS_CACHE_POOL_NATIVE'in t,t[-4000:];print(t[-800:])
