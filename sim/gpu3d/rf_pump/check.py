#!/usr/bin/env python3
"""Actual RF QIS helper with the shipped vendor RAM, old copies, and an oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--vendor',type=Path,default=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v'))
p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print('RF_PUMP_ACTUAL_PID',os.getpid(),'NI10/j1/t1',flush=True)
source=(ROOT/'rtl/gpu3d/gpu3d_gxeng.sv').read_text()
helper=source[source.index('module gpu3d_gxrf #('):].split('endmodule',1)[0]+'endmodule\n'
if a.mutant:
    needle='.outdata_reg_a("CLOCK1")';assert helper.count(needle)==1
    native=helper.replace(needle,'.outdata_reg_a("UNREGISTERED")')
else:native=helper
native='`define ALTERA_RESERVED_QIS\n'+native.replace('module gpu3d_gxrf #(','module rf_native #(',1)+'`undef ALTERA_RESERVED_QIS\n'
model=helper.replace('module gpu3d_gxrf #(','module rf_model #(',1)
(out/'actual.sv').write_text(native+model)
vendor=out/'vendor-altera_mf.v';shutil.copyfile(a.vendor.resolve(),vendor)
top='''`timescale 1ns/1ps
module tb_rf_pump;
reg clk=0,clk2=0,we=0;
reg[10:0]wa=0,ra=0,late_ra=0;
reg[9:0]rb=0,late_rb=0;
reg[31:0]wd=0;
wire[31:0]oa,ob,na,nb,ma,mb,fa,fb,la,lb;
reg[31:0]old_r=0,native_r=0,model_r=0;
reg[31:0]gold[0:2047];
reg[31:0]seed=32'h3bc74a91,ea,eb,prev_a=0,prev_b=0,prev_late_a=0,prev_late_b=0;
integer n,k,read_count=0,write_count=0,held_count=0,collision_count=0,late_write_count=0;
integer mutant=0;
function[31:0]random32;
begin seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);random32=seed;end
endfunction
gpu3d_ram #(.W(32),.AW(11)) old_a(.clk,.we,.waddr(wa),.wdata(wd),.raddr(ra),.rdata(oa));
gpu3d_ram #(.W(32),.AW(10)) old_b(.clk,.we(we&&!wa[10]),.waddr(wa[9:0]),.wdata(wd),.raddr(rb),.rdata(ob));
gpu3d_ram #(.W(32),.AW(11)) late_a(.clk,.we,.waddr(wa),.wdata(wd),.raddr(late_ra),.rdata(la));
gpu3d_ram #(.W(32),.AW(10)) late_b(.clk,.we(we&&!wa[10]),.waddr(wa[9:0]),.wdata(wd),.raddr(late_rb),.rdata(lb));
rf_native #(.PUMP(1)) dut(.clk,.clk2,.we,.waddr(wa),.wdata(wd),.raddr(ra),.raddr_b(rb),.rdata(na),.rdata_b(nb));
rf_model #(.PUMP(1)) mdl(.clk,.clk2,.we,.waddr(wa),.wdata(wd),.raddr(ra),.raddr_b(rb),.rdata(ma),.rdata_b(mb));
rf_model #(.PUMP(0)) fallback(.clk,.clk2,.we,.waddr(wa),.wdata(wd),.raddr(late_ra),.raddr_b(late_rb),.rdata(fa),.rdata_b(fb));
// The unchanged engine R<=res consumer, under legal QA PASSX / QB ADD0
// selections. Check this accepted SYS edge before any earlier native data
// reader in the negative case; the QIS output-clock fault must reach R.
always @(posedge clk)begin
 old_r<=n[0]?ob:oa;native_r<=n[0]?nb:na;model_r<=n[0]?mb:ma;
end
task edge_clock;
input integer sys;
begin #3;clk2=1;clk=sys;#2;clk2=0;clk=0;#3;end
endtask
initial begin
 mutant=$test$plusargs("accepted-only");
 for(k=0;k<2048;k=k+1)begin old_a.mem[k]=0;late_a.mem[k]=0;mdl.mem[k]=0;fallback.mem[k]=0;gold[k]=0;end
 for(k=0;k<1024;k=k+1)begin old_b.mem[k]=0;late_b.mem[k]=0;end
 #10;
 for(n=0;n<34816;n=n+1)begin
  ra=n<2048?11'(n):11'(random32());rb=10'(random32());
  late_ra=ra;late_rb=rb;
  edge_clock(0);
  if(n>2)begin
   if({oa,ob,ma,mb,nb}!=={prev_a,prev_b,prev_a,prev_b,prev_b})$fatal(1,"RF M model/B hold mismatch");
   if(!mutant&&na!==prev_a)$fatal(1,"RF M nativeA hold mismatch");
   if({fa,fb,la,lb}!=={prev_late_a,prev_late_b,prev_late_a,prev_late_b})$fatal(1,"RF default M hold mismatch");
   held_count=held_count+8;
  end
  // Write inputs and default-only read addresses can change after M.
  // The actual engine's two read addresses remain SYS-held.
  wa=n<2048?11'(n):((n%4==0)?ra:((n%4==1)?{1'b0,rb}:11'(random32())));
  wd=random32();we=(n<2048)||(n%7!=3);
  late_ra=11'(random32());late_rb=10'(random32());late_write_count=late_write_count+1;
  ea=gold[ra];eb=gold[{1'b0,rb}];
  edge_clock(1);
  if(n>2)begin
   if(native_r!==old_r)begin
    $display("ACCEPTED_RF_R_SYS_MISMATCH n=%0d old=%08x new=%08x ra=%03x rb=%03x",n,old_r,native_r,ra,rb);$fatal(1,"actual native RF publication reached R");
   end
   if(model_r!==old_r)$fatal(1,"architectural model R mismatch");
   if({oa,ob,na,nb,ma,mb}!=={ea,eb,ea,eb,ea,eb})$fatal(1,"RF SYS independent full32 OLD_DATA mismatch n=%0d",n);
   if({fa,fb,la,lb}!=={gold[late_ra],gold[{1'b0,late_rb}],gold[late_ra],gold[{1'b0,late_rb}]})$fatal(1,"RF default postM address mismatch");
   read_count=read_count+8;
  end
  prev_a=ea;prev_b=eb;prev_late_a=gold[late_ra];prev_late_b=gold[{1'b0,late_rb}];
  if(we)begin gold[wa]=wd;write_count=write_count+1;end
  collision_count=collision_count+integer'(we&&(wa==ra||wa=={1'b0,rb}));
  if(n>2&&we)begin
   if(mdl.mem[wa]!==gold[wa]||fallback.mem[wa]!==gold[wa]||old_a.mem[wa]!==gold[wa])$fatal(1,"logical memory/import image changed at SYS");
  end
 end
 for(k=0;k<2048;k=k+1)if(mdl.mem[k]!==gold[k]||fallback.mem[k]!==gold[k]||old_a.mem[k]!==gold[k])$fatal(1,"RF final2048cells mismatch");
 for(k=0;k<1024;k=k+1)if(old_b.mem[k]!==gold[k])$fatal(1,"original copy coherence mismatch");
 $display("PASS ACTUAL_RF_QIS SYS34816 reads%0d Mholds%0d writes%0d collisions%0d lateWriteInputs%0d final2048cells/defaultLateAddr; actualvendor notstub; acquisition3SYS",read_count,held_count,write_count,collision_count,late_write_count);$finish;
end
endmodule
'''
(out/'wrapper.sv').write_text(top)
files=[vendor,ROOT/'rtl/gpu3d/gpu3d_ram.sv',out/'actual.sv',out/'wrapper.sv']
cmd=['iverilog','-g2012','-s','tb_rf_pump','-o',str(out/'model.vvp')]+list(map(str,files))
(out/'load.txt').write_text(subprocess.check_output(['uptime'],text=True))
with(out/'build.log').open('w')as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'actual RF vendor build failed'
run=['vvp',str(out/'model.vvp')]+(['+accepted-only']if a.mutant else[])
with(out/'run.log').open('w')as f:r=subprocess.run(run,stdout=f,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
receipt=dict(PID=os.getpid(),nice=10,jobs=1,threads=1,mutant=a.mutant,exit=r.returncode,command=cmd,run=run,
    helper_sha256=hashlib.sha256(helper.encode()).hexdigest(),files_sha256={str(f):hashlib.sha256(f.read_bytes()).hexdigest()for f in files},output=log,
    scope='Actual QIS helper/phase/port/config with shipped Altera25.1 RAM model, independent old twoSYS copies, full32oracle/all2048cells, legal SYS-held PUMP readaddresses and arbitrary late writeinputs/defaultreadaddresses. ThreeSYS cold acquisition is actual Pocket reset contract. ArchitecturalSIMmodel uses original SYS interface for drainedimports.',
    negative='Only early nativeA M hold comparison omitted; actual QIS outdata_reg_a CLOCK1->UNREGISTERED mutation must reach the R<=res SYS consumer (QA PASSX/QB ADD0 legal selection). All other readers remain.'if a.mutant else None)
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
assert r.returncode!=0 and'ACCEPTED_RF_R_SYS_MISMATCH'in log if a.mutant else r.returncode==0
