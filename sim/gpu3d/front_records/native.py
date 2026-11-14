#!/usr/bin/env python3
"""Actual Quartus25.1 SDP OLD_DATA/byte-enable and fixed E/M records proof."""
from pathlib import Path
import argparse,importlib.util,json,time
R=Path(__file__).resolve().parents[3];ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);B=R/ap.parse_args().out;assert not B.exists();B.mkdir()
sp=importlib.util.spec_from_file_location('runner',R/'sim/gpu3d/edge_span_service/runner.py');run=importlib.util.module_from_spec(sp);sp.loader.exec_module(run)
V=Path('build/tools/oss-cad-suite/bin');vendor=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
s=(R/'rtl/gpu3d/gpu3d_front_records.sv').read_text();n='.byteena_a({we_late,we_late,we_early,we_early})';bad='.byteena_a({we_late,we_late,we_early ^ 1\'($test$plusargs("wrong_native_byte")),we_early})';assert s.count(n)==1;probe=s.replace(n,bad);assert probe.replace(bad,n)==s
native=probe.replace('gpu3d_front_record_slice','native_slice').replace('gpu3d_front_records','native_records')
(B/'actual.sv').write_text('`define ALTERA_RESERVED_QIS\n'+native+'\n`undef ALTERA_RESERVED_QIS\n'+s)
(B/'bench.sv').write_text(r'''`timescale 1ns/1ps
module tb_front_records_native;
reg clk=0,clk2=0,rst=1,early_we=0,late_we=0;reg[2:0]early_owner=0,late_owner=0;
reg[47:0]early_data=0;reg[58:0]late_data=0;reg[1:0]left_owner=0,right_owner=0;
wire[106:0]nl,nr,pl,pr;
native_records n(.clk,.clk2,.rst,.early_we,.late_we,.early_owner,.late_owner,.early_data,.late_data,.left_owner,.right_owner,.left_record(nl),.right_record(nr));
gpu3d_front_records p(.clk,.clk2,.rst,.early_we,.late_we,.early_owner,.late_owner,.early_data,.late_data,.left_owner,.right_owner,.left_record(pl),.right_record(pr));
reg swe=0,swl=0;reg[2:0]swa=0,sra=0;reg[19:0]sed=0,sld=0;wire[19:0]sne,snl,spe,spl;
native_slice ns(.clk(clk2),.we_early(swe),.we_late(swl),.waddr(swa),.raddr(sra),.early_data(sed),.late_data(sld),.early_q(sne),.late_q(snl));
gpu3d_front_record_slice ps(.clk(clk2),.we_early(swe),.we_late(swl),.waddr(swa),.raddr(sra),.early_data(sed),.late_data(sld),.early_q(spe),.late_q(spl));
reg[47:0]ge[0:7];reg[58:0]gl[0:7];reg ke[0:7],kl[0:7];
reg[19:0]se[0:7],sl[0:7];reg ske[0:7],skl[0:7];
reg[106:0]el,er,new_left,new_right;reg left_known=0,right_known=0,new_left_known,new_right_known;
reg lw;reg[2:0]lo;reg[58:0]ld;
reg[19:0]expect_se,expect_sl;reg expect_ske,expect_skl;
reg[31:0]rng=32'h63f4cd91;integer cycle,a,fast=0,data_checks=0,slice_checks=0,service_e_collisions=0,service_m_collisions=0,slice_collisions=0,partial=0,both=0,none=0,resets=0,mid_resets=0,cancelled=0,late_changes=0;
function[31:0]rand32;begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);rand32=rng;end endfunction
function[106:0]record_(input[47:0]e,input[58:0]l);
 record_={e[47:21],e[20],e[19],e[18:9],l[58:49],e[8:0],l[48:33],l[32:9],l[8:0]};
endfunction
task slice_before;begin
 swe=fast<8?1:fast%4==0||fast%4==1;swl=fast<8?1:fast%4==0||fast%4==2;
 swa=fast<8?3'(fast):3'(rand32());sra=fast%2==0?swa:3'(rand32());sed=20'(rand32());sld=20'(rand32());
 expect_se=se[sra];expect_sl=sl[sra];expect_ske=ske[sra];expect_skl=skl[sra];
 if((swe||swl)&&swa==sra)slice_collisions=slice_collisions+1;
 if(swe!=swl)partial=partial+1;else if(swe)both=both+1;else none=none+1;
end endtask
task slice_after;begin
 if(expect_ske)begin
  if(sne!==expect_se||spe!==expect_se)$fatal(1,"FR_NATIVE_FAIL slice_early_old_data cycle%0d fast%0d",cycle,fast);
  slice_checks=slice_checks+1;
 end
 if(expect_skl)begin
  if(snl!==expect_sl||spl!==expect_sl)$fatal(1,"FR_NATIVE_FAIL slice_late_old_data cycle%0d fast%0d",cycle,fast);
  slice_checks=slice_checks+1;
 end
 if(swe)begin se[swa]=sed;ske[swa]=1;end
 if(swl)begin sl[swa]=sld;skl[swa]=1;end
 fast=fast+1;
end endtask
initial begin
 for(a=0;a<8;a=a+1)begin ge[a]=0;gl[a]=0;ke[a]=0;kl[a]=0;se[a]=0;sl[a]=0;ske[a]=0;skl[a]=0;end
 #10;
 for(cycle=0;cycle<20000;cycle=cycle+1)begin
  if(left_known)begin if(nl!==el||pl!==el)$fatal(1,"FR_NATIVE_FAIL left_SYS_owner cycle%0d",cycle);data_checks=data_checks+1;end
  if(right_known)begin if(nr!==er||pr!==er)$fatal(1,"FR_NATIVE_FAIL right_SYS_owner cycle%0d",cycle);data_checks=data_checks+1;end
  rst=cycle%1021==1020;if(rst)resets=resets+1;
  early_we=cycle<8||cycle%7!=0;late_we=cycle<8||cycle%5!=0;
  left_owner=2'(rand32());right_owner=2'(rand32());
  early_owner=cycle<8?3'(cycle):cycle%3==0?{1'b0,left_owner}:3'(rand32());
  late_owner=cycle<8?3'(cycle):cycle%3==0?{1'b1,right_owner}:3'(rand32());
  early_data={rand32(),rand32()};late_data={rand32(),rand32()};
  lw=!rst&&late_we;lo=late_owner;ld=late_data;
  new_left=record_(ge[{1'b0,left_owner}],gl[{1'b0,left_owner}]);new_left_known=ke[{1'b0,left_owner}]&&kl[{1'b0,left_owner}];
  if(!rst&&early_we&&early_owner=={1'b0,left_owner})service_e_collisions=service_e_collisions+1;
  slice_before();#3;clk=1;clk2=1;#2;
  // At E, port B returns LEFT's old word even if A writes early bytes.
  if(new_left_known)begin if(nr!==new_left||pr!==new_left)$fatal(1,"FR_NATIVE_FAIL E_read_old_data cycle%0d",cycle);data_checks=data_checks+1;end
  if(!rst&&early_we)begin ge[early_owner]=early_data;ke[early_owner]=1;end
  slice_after();clk=0;clk2=0;#1;
  // SYS inputs may change after E. Only RIGHT's read owner is live at M;
  // late write owner, payload and valid must remain the captured transaction.
  late_owner=~late_owner;late_data={rand32(),rand32()};late_we=!late_we;
  early_data={rand32(),rand32()};early_owner=3'(rand32());early_we=!early_we;late_changes=late_changes+1;
  if(cycle%3!=0)right_owner=2'(rand32());
  if(cycle%997==500&&!rst)begin rst=1;resets=resets+1;mid_resets=mid_resets+1;if(lw)cancelled=cancelled+1;end
  new_right=record_(ge[{1'b1,right_owner}],gl[{1'b1,right_owner}]);new_right_known=ke[{1'b1,right_owner}]&&kl[{1'b1,right_owner}];
  if(!rst&&lw&&lo=={1'b1,right_owner})service_m_collisions=service_m_collisions+1;
  slice_before();#2;clk2=1;#2;
  if(!rst)begin el=new_left;left_known=new_left_known;end
  er=new_right;right_known=new_right_known;
  if(left_known)begin if(nl!==el||pl!==el)$fatal(1,"FR_NATIVE_FAIL M_left_hold cycle%0d",cycle);data_checks=data_checks+1;end
  if(right_known)begin if(nr!==er||pr!==er)$fatal(1,"FR_NATIVE_FAIL M_read_old_data cycle%0d",cycle);data_checks=data_checks+1;end
  if(!rst&&lw)begin gl[lo]=ld;kl[lo]=1;end
  slice_after();clk2=0;#1;
 end
 if(data_checks<90000||slice_checks<70000||service_e_collisions<5000||service_m_collisions<5000||slice_collisions<15000||partial<19000||both<9000||resets<15||mid_resets<15||cancelled<15)$fatal(1,"FR_NATIVE_FAIL coverage");
 $display("PASS_FRONT_RECORDS_NATIVE SYS%0d data%0d sliceFields%0d earlyCollisions%0d lateCollisions%0d sliceCollisions%0d partial%0d both%0d none%0d lateChanges%0d resets%0d midResets%0d cancelledLate%0d",cycle,data_checks,slice_checks,service_e_collisions,service_m_collisions,slice_collisions,partial,both,none,late_changes,resets,mid_resets,cancelled);$finish;
end
endmodule
''')
files=['actual.sv','bench.sv'];run.put(B/'snapshot.json',dict(at=time.time(),vendor=str(vendor),vendor_sha256=run.sha(vendor),production_sha256=run.sha(R/'rtl/gpu3d/gpu3d_front_records.sv'),inputs={n:run.sha(B/n)for n in files},inverse_native_byte_probe_exact=True,scope='Actual Quartus25.1 altsyncram40bit/10bitBE OLD_DATA, E/M ownership, partial same-address collisions and post-E input changes. No synthesis/area/STA/game proof.'))
for n in files:(B/n).chmod(0o444)
rc,log=run.worker(B,'build',[V/'iverilog','-g2012','-s','tb_front_records_native','-o',B/'model.vvp',vendor,B/'actual.sv',B/'bench.sv'],build=True);assert rc==0 and 'expects 4 bit(s), given'not in log,log[-5000:];run.put(B/'model.json',dict(sha256=run.sha(B/'model.vvp'),snapshot_sha256=run.sha(B/'snapshot.json')))
results={}
for name,args,marker in [('positive',[],'PASS_FRONT_RECORDS_NATIVE'),('native-byte-fault',['+wrong_native_byte'],'FR_NATIVE_FAIL')]:
 rc,log=run.worker(B,name,[V/'vvp',B/'model.vvp',*args]);good=(rc==0 and marker in log)if name=='positive'else(rc!=0 and marker in log);results[name]=dict(passed=good,exit=rc,tail=log.splitlines()[-8:]);run.put(B/'result.json',dict(result='IN_PROGRESS',cases=results));assert good,log[-5000:]
run.put(B/'result.json',dict(result='PASS_ACTUAL_QUARTUS_RECORD_RAM_AND_BYTE_FAULT',cases=results,remaining='No fit/legalusage/STA/game acceptance.'));print('PASS_ACTUAL_QUARTUS_RECORD_RAM_AND_BYTE_FAULT')
