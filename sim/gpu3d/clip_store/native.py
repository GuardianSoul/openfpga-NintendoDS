#!/usr/bin/env python3
"""New five-field adapter with actual Quartus RAM, old copies and two oracles."""
import argparse
import datetime
import hashlib
import json
import os
import re
import resource
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-clip-pump16'
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
T=Path('build/tools/oss-cad-suite/bin')
V=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
p=argparse.ArgumentParser();p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=B/('native-mutant'if a.mutant else'native');out.mkdir(parents=True,exist_ok=True)
print('CLIP_STORE_NATIVE_PID',os.getpid(),'D3 NI10/j1/t1',flush=True)
def phase(stage,child=None,active=True):
 d=json.loads(S.read_text());d['phase']=stage;d['worker']={'active':active,'host':'Desktop','lease':'D3 clipstore','PID':os.getpid(),'child_PID':child,'nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t=S.with_suffix('.tmp');t.write_text(s);t.replace(S)
def run(cmd,log,stage):
 with log.open('w')as f:
  child=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);phase(stage,child.pid);rc=child.wait()
 phase(stage+' reaped',child.pid,False);return rc,child.pid

full=(R/'rtl/gpu3d/gpu3d_gxvfin.sv').read_text()
helper=re.search(r'(?ms)^module gpu3d_gxclip_store\b.*?^endmodule\b[^\n]*',full)[0]+'\n'
actual=helper
if a.mutant:
 needle='forward_data <= pending_data;';assert actual.count(needle)==1
 actual=actual.replace(needle,'forward_data <= wd;')
native='`define ALTERA_RESERVED_QIS\n'+actual.replace('module gpu3d_gxclip_store (','module store_native (',1)+'`undef ALTERA_RESERVED_QIS\n'
model=helper.replace('module gpu3d_gxclip_store (','module store_model (',1)
(out/'actual.sv').write_text(native+model)
top='''`timescale 1ns/1ps
module tb_clip_store_native;
reg clk=0,clk2=0,we=0,rst=0;
reg [10:0] wa=0;reg[31:0]wd=0;reg[4:0]ro=0,ri=0;
wire[31:0]no[5],ni[5],mo[5],mi[5],oo[5],oi[5];
reg[31:0]gold[0:159],phys[0:159],raw_expected[0:4];
reg[31:0]ea[0:4],eb[0:4],prev_a[0:4],prev_b[0:4];
reg[31:0]old_delta=0,native_delta=0,model_delta=0;
reg[31:0]seed=32'h516bc384,pd=0;reg[4:0]pg=0;integer pf=-1;
integer n,k,i,field,word,raw_checks=0,prefix_checks=0,consumed=0,collisions=0,writes=0,reset_writes=0,late=0,negative=0;
function[31:0]rand32;begin seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);rand32=seed;end endfunction
function integer fi(input integer w);begin case(w)4:fi=0;5:fi=1;6:fi=2;8:fi=3;9:fi=4;default:fi=-1;endcase end endfunction
store_native dut(.clk,.clk2,.we,.wa,.wd,.rgroup_out(ro),.rgroup_in(ri),.outside_word(no),.inside_word(ni));
store_model mdl(.clk,.clk2,.we,.wa,.wd,.rgroup_out(ro),.rgroup_in(ri),.outside_word(mo),.inside_word(mi));
genvar g;generate for(g=0;g<5;g=g+1)begin:refs
 localparam integer W=g<3?g+4:g+5;
 wire w=we&&wa[10:9]==2'b01&&wa[3:0]==W;
 gpu3d_ram #(.W(32),.AW(5),.STYLE("M10K")) a(.clk,.we(w),.waddr(wa[8:4]),.wdata(wd),.raddr(ro),.rdata(oo[g]));
 gpu3d_ram #(.W(32),.AW(5),.STYLE("M10K")) b(.clk,.we(w),.waddr(wa[8:4]),.wdata(wd),.raddr(ri),.rdata(oi[g]));
 initial for(integer c=0;c<32;c=c+1)begin a.mem[c]=0;b.mem[c]=0;mdl.g_field[g].u_mem.mem[c]=0;end
end endgenerate
// An actual segment delta is captured at the original SYS edge. A stale
// forwarding mutation must reach this consumer before raw read comparisons.
always @(posedge clk)begin
 old_delta<=oi[n%5]-oo[n%5];native_delta<=ni[n%5]-no[n%5];model_delta<=mi[n%5]-mo[n%5];
end
task edge_clock(input integer sys);begin #3;clk2=1;clk=sys;#2;clk2=0;clk=0;#3;end endtask
initial begin
 negative=$test$plusargs("consumed-only");
 for(k=0;k<160;k=k+1)begin gold[k]=0;phys[k]=0;end
 for(i=0;i<5;i=i+1)begin prev_a[i]=0;prev_b[i]=0;end
 #10;
 for(n=0;n<8192;n=n+1)begin
  // New live read addresses before M must not replace held prior-E inside.
  ro=5'(rand32());ri=5'(rand32());
  edge_clock(0);
  if(n>3&&!negative)for(i=0;i<5;i=i+1)begin
   if({no[i],ni[i],mo[i],mi[i],oo[i],oi[i]}!=={prev_a[i],prev_b[i],prev_a[i],prev_b[i],prev_a[i],prev_b[i]})$fatal(1,"actual native prefix/M snapshot mismatch n%0d field%0d",n,i);
   prefix_checks=prefix_checks+6;
  end
  // All SYS inputs may change after M; write ownership remains SYS.
  ro=n%4==0?pg:5'(rand32());ri=n%4==1?pg:5'(rand32());
  field=n<160?n%5:integer'(rand32()%5);word=field<3?field+4:field+5;
  wa={2'b01,5'(n<160?n/5:rand32()),4'(word)};
  if(n>=160&&n%19==0)wa[10:9]=2'b10;
  if(n>=160&&n%23==0)wa[3:0]=4'd7;
  wd=rand32();we=n<160||n%7!=3;rst=n%127==0;late=late+1;
  for(i=0;i<5;i=i+1)begin ea[i]=gold[i*32+ro];eb[i]=gold[i*32+ri];raw_expected[i]=phys[i*32+ro];end
  edge_clock(1);
  if(n>3)begin
   if(native_delta!==old_delta)begin
    $display("ACTUAL_STORE_STALE_FORWARD_REACHED_SEGMENT n%0d old%08x native%08x",n,old_delta,native_delta);$fatal(1,"actual native field delta publication mismatch");
   end
   if(model_delta!==old_delta)$fatal(1,"portable field delta mismatch");
   consumed=consumed+1;
   if(!negative)for(i=0;i<5;i=i+1)begin
    if(ni[i]!==raw_expected[i])$fatal(1,"native mixed-port OLD_DATA mismatch n%0d field%0d",n,i);
    if({oo[i],oi[i]}!=={ea[i],eb[i]})$fatal(1,"old copy oracle mismatch");
    raw_checks=raw_checks+3;
   end
  end
  if(pf>=0)begin phys[pf*32+pg]=pd;collisions=collisions+integer'(pg==ro||pg==ri);end
  pf=we&&wa[10:9]==2'b01 ? fi(wa[3:0]):-1;pg=wa[8:4];pd=wd;
  if(pf>=0)begin gold[pf*32+pg]=pd;writes=writes+1;if(rst)reset_writes=reset_writes+1;end
  for(i=0;i<5;i=i+1)begin prev_a[i]=ea[i];prev_b[i]=eb[i];end
 end
 if(reset_writes==0||collisions<100||consumed<8000)$fatal(1,"native coverage");
 $display("PASS CLIP_STORE_NATIVE actualQuartusOLD_DATA SYS8192 raw%0d prefix%0d consumed%0d writes%0d resetWrites%0d collisions%0d lateInputs%0d full160cells/32bit",raw_checks,prefix_checks,consumed,writes,reset_writes,collisions,late);$finish;
end
endmodule
'''
(out/'wrapper.sv').write_text(top)
cmd=[str(T/'iverilog'),'-g2012','-s','tb_clip_store_native','-o',str(out/'model.vvp'),str(V),str(R/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'actual.sv'),str(out/'wrapper.sv')]
(out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
rc,child=run(cmd,out/'build.log','native prefix compile');assert rc==0,(out/'build.log').read_text()[-1800:]
run_cmd=[str(T/'vvp'),str(out/'model.vvp')]+(['+consumed-only']if a.mutant else[])
rc,child=run(run_cmd,out/'run.log','native prefix execution')
log=(out/'run.log').read_text();print(log[-2200:],flush=True)
rec={'before':'97698ee421304616961056481a9353b9a9a10538','mutant':a.mutant,'PID':os.getpid(),'child_PID':child,'exit':rc,'command':cmd,'run':run_cmd,'helper_sha256':hashlib.sha256(helper.encode()).hexdigest(),'actual_sha256':hashlib.sha256(actual.encode()).hexdigest(),'vendor_sha256':hashlib.sha256(V.read_bytes()).hexdigest(),'output':log,'scope':'New five-field adapter actual QIS/profile with shipped Quartus25.1 altsyncram, portable branch, two old SYS copies, independent physical and logical prefix oracles; no accepted math baseline run.'}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
if a.mutant:assert rc!=0 and 'ACTUAL_STORE_STALE_FORWARD_REACHED_SEGMENT'in log
else:assert rc==0
phase('Native '+('actual stale fault CAUGHT'if a.mutant else'OLD_DATA/prefix PASS'),child,False)
