#!/usr/bin/env python3
"""Cycle/state miter against gpu3d_div4, including a real middle-result fault."""
from pathlib import Path
import hashlib, json, os, resource, subprocess, time
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/pump72/divider'
OUT.mkdir(parents=True,exist_ok=True)
OWNER=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json')
VER='build/tools/oss-cad-suite/bin/verilator'

def status(phase, child=None):
    v=json.loads(OWNER.read_text());v.update(phase=phase, updated_at=time.time(),worker=[])
    if child:v['worker']=[{'host':'D1','pid':child.pid,'start':Path(f'/proc/{child.pid}/stat').read_text().split()[21],'nice':10,'jobs':1,'threads':1}]
    p=OWNER.with_suffix('.tmp');p.write_text(json.dumps(v,separators=(',',':'))+'\n');assert p.stat().st_size<=2048;p.replace(OWNER)

def run(args, label, fail=False):
    with (OUT/(label+'.log')).open('w') as f:
        def limit():
            os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        p=subprocess.Popen(list(map(str,args)),cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,preexec_fn=limit)
        status('PUMP72_'+label,p);rc=p.wait();status('PUMP72_'+label+'_DONE')
    log=(OUT/(label+'.log')).read_text()
    if fail:assert rc and 'MUTANT_CAUGHT actual right quotient-bit capture fault' in log
    else:assert rc==0,log[-4000:]
    return dict(returncode=rc,log_sha256=hashlib.sha256(log.encode()).hexdigest())

source=(ROOT/'rtl/gpu3d/gpu3d_div4.sv').read_text()
mut=source[source.index('module gpu3d_div_step_pair2x'):source.index('// Same phase keeper')]
mut=mut.replace('module gpu3d_div_step_pair2x','module gpu3d_div_step_pair2x_mutant',1)
assert mut.count('right_bits <= step_bits;')==1
mut=mut.replace('right_bits <= step_bits;',"right_bits <= step_bits ^ SPC'(1);")
(OUT/'mutant.sv').write_text(mut)
case='''module pair_case #(parameter DW=25,QB=12,SPC=4)(
input logic clk,clk2,middle,rst,input logic start[0:1],
input logic [31:0] num[0:1],input logic [24:0] den_wide[0:1],
output logic mismatch,mutant_mismatch);
logic [DW-1:0] den[0:1],r[0:1],mr[0:1],br[0:1];
logic [QB-1:0] q[0:1],mq[0:1],bq[0:1];
logic busy[0:1],done[0:1],mb[0:1],md[0:1],bb[0:1],bd[0:1];
assign den[0]=DW'(den_wide[0]);assign den[1]=DW'(den_wide[1]);
gpu3d_div_step_pair2x #(.DW(DW),.QB(QB),.SPC(SPC)) candidate(.clk,.clk2,.middle,.rst,.start,.num,.den,.busy,.done,.q,.r);
gpu3d_div_step_pair2x_mutant #(.DW(DW),.QB(QB),.SPC(SPC)) mutant(.clk,.clk2,.middle,.rst,.start,.num,.den,.busy(mb),.done(md),.q(mq),.r(mr));
genvar k;
generate for(k=0;k<2;k=k+1) begin:g_ref
 gpu3d_div4 #(.DW(DW),.QB(QB),.SPC(SPC)) reference(.clk,.rst,.start(start[k]),.num(num[k]),.den(den[k]),.busy(bb[k]),.done(bd[k]),.q(bq[k]),.r(br[k]));
end endgenerate
always_comb begin
 mismatch=0;mutant_mismatch=0;
 for(int i=0;i<2;i++) begin
  if({busy[i],done[i],q[i],r[i]} !== {bb[i],bd[i],bq[i],br[i]}) mismatch=1;
  if({mb[i],md[i],mq[i],mr[i]} !== {bb[i],bd[i],bq[i],br[i]}) mutant_mismatch=1;
 end
 // Full retained private state, in addition to the externally visible ports.
 if(candidate.d[0] !== g_ref[0].reference.d || candidate.d[1] !== g_ref[1].reference.d ||
    candidate.n_lo[0] !== g_ref[0].reference.n_lo || candidate.n_lo[1] !== g_ref[1].reference.n_lo ||
    candidate.cnt[0] !== g_ref[0].reference.cnt || candidate.cnt[1] !== g_ref[1].reference.cnt) mismatch=1;
end
endmodule
module pair_tb(input logic clk,clk2,rst,
input logic start[0:1], input logic [31:0] num[0:1],input logic [24:0] den[0:1],
output logic [3:0] mismatch,mutant_mismatch);
logic middle;
gpu3d_div_pair_phase phase(.clk,.clk2,.middle);
// Numerators for the narrow quotient variants obey the original precondition.
logic [31:0] n12[0:1],n10[0:1];
assign n12[0]=num[0] % (32'(den[0])<<12);assign n12[1]=num[1] % (32'(den[1])<<12);
assign n10[0]=num[0] % (32'(den[0])<<10);assign n10[1]=num[1] % (32'(den[1])<<10);
pair_case #(.DW(25),.QB(12),.SPC(4)) a(.clk,.clk2,.middle,.rst,.start,.num(n12),.den_wide(den),.mismatch(mismatch[0]),.mutant_mismatch(mutant_mismatch[0]));
pair_case #(.DW(25),.QB(10),.SPC(2)) b(.clk,.clk2,.middle,.rst,.start,.num(n10),.den_wide(den),.mismatch(mismatch[1]),.mutant_mismatch(mutant_mismatch[1]));
pair_case #(.DW(10),.QB(32),.SPC(8)) c(.clk,.clk2,.middle,.rst,.start,.num,.den_wide(den),.mismatch(mismatch[2]),.mutant_mismatch(mutant_mismatch[2]));
pair_case #(.DW(10),.QB(32),.SPC(4)) d(.clk,.clk2,.middle,.rst,.start,.num,.den_wide(den),.mismatch(mismatch[3]),.mutant_mismatch(mutant_mismatch[3]));
endmodule
'''
(OUT/'tb.sv').write_text(case)
(OUT/'main.cpp').write_text('''#include "Vpair_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
int main(int argc,char **argv){
 Verilated::commandArgs(argc,argv);Vpair_tb m;uint64_t rng=0x7231cafe1234ULL;
 auto next=[&](){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return uint32_t(rng);};
 bool mutant=argc>1 && strcmp(argv[1],"mutant")==0;
 unsigned faults=0,starts[2]={0,0},late_reset=0,restarts=0;uint64_t checks=0;
 m.clk=0;m.clk2=0;m.rst=1;
 for(int k=0;k<2;k++){m.start[k]=0;m.num[k]=0;m.den[k]=1;}
 for(unsigned cycle=0;cycle<250000;cycle++){
  // Requests/reset may arrive after M: candidate does not consume them early.
  for(unsigned half=0;half<2;half++){
   m.clk=(half==0);m.clk2=1;m.eval();m.clk2=0;m.eval();
   if(cycle>3){checks++;if(m.mismatch){printf("MISMATCH cycle=%u half=%u mask=%x\\n",cycle,half,m.mismatch);return 2;}
    if(m.mutant_mismatch){faults|=m.mutant_mismatch;if(mutant){printf("MUTANT_CAUGHT actual right quotient-bit capture fault cycle=%u mask=%x\\n",cycle,m.mutant_mismatch);return 3;}}}
   if(cycle>=4){
    m.rst=(next()%101==0);if(m.rst&&half==1)late_reset++;
    for(int k=0;k<2;k++){
     m.start[k]=(next()%9==0);starts[k]+=m.start[k];
     m.den[k]=1+(next()%1023);m.num[k]=next();
     if(m.start[k]&&cycle%7==0)restarts++;
    }
   }
   m.eval();
  }
 }
 printf("PASS checks=%llu cycles=250000 starts=%u/%u late_reset=%u restart_samples=%u mutant_mask=%x\\n",(unsigned long long)checks,starts[0],starts[1],late_reset,restarts,faults);
 return faults==15?0:4;
}
''')
result={}
result['build']=run([VER,'--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','pair_tb','--Mdir',OUT/'obj',ROOT/'rtl/gpu3d/gpu3d_div4.sv',OUT/'mutant.sv',OUT/'tb.sv',OUT/'main.cpp'],'DIV_BUILD')
result['miter']=run([OUT/'obj/Vpair_tb'],'DIV_MITER')
result['actual_mutant']=run([OUT/'obj/Vpair_tb','mutant'],'DIV_MUTANT',True)
result.update(source_sha256=hashlib.sha256(source.encode()).hexdigest(),mutant_sha256=hashlib.sha256(mut.encode()).hexdigest(),status='PASS')
(OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
