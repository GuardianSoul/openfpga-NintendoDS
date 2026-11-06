#!/usr/bin/env python3
"""Actual pumped primitive against its unpumped source and arithmetic result."""
import argparse,hashlib,json,os,resource,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} nice=10 jobs=1 threads=1 mutant={a.mutant}',flush=True)
s=(ROOT/'rtl/gpu3d/gpu3d_gxdiv.sv').read_text()
if a.mutant:
 needle="end else if (busy && !rsm) begin\n                    r <= r_n; q2 <= q_n; cnt <= c_n;"
 assert s.count(needle)==1
 s=s.replace(needle,needle.replace('q2 <= q_n;',"q2 <= q_n ^ 32'd1;"))
(out/'primitive.sv').write_text(s)
(out/'wrapper.sv').write_text('''module tb_private_divider(input logic clk,clk2,rst,start,input logic [1:0] qb,input logic [63:0] num,input logic [31:0] den,output logic busy,output logic [31:0] q);
wire busy_b;wire [31:0] q_b;
gpu3d_gxdivk #(.K(4)) a(.clk,.clk2(1'b0),.rst,.start,.qb,.num,.den,.busy,.q);
gpu3d_gxdivk #(.K(4),.P2X(1)) b(.clk,.clk2,.rst,.start,.qb,.num,.den,.busy(busy_b),.q(q_b));
logic started=0;
always @(posedge clk) if(rst) started<=0;else if(start) started<=1;
always @(negedge clk) if(!rst) begin
 if(busy!==busy_b) $fatal(1,"qualified busy mismatch");
 if(started && !busy && q!==q_b) $fatal(1,"qualified q mismatch");
end
endmodule
''')
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_private_divider','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1',str(out/'primitive.sv'),str(out/'wrapper.sv'),str(ROOT/'sim/gpu3d/divider_pump/primitive.cpp')]
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'build failed:{r.returncode}')
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_private_divider')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
text=(out/'run.log').read_text();print(text,flush=True)
rec={'mutant':a.mutant,'exit':r.returncode,'pid':os.getpid(),'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'primitive_sha256':hashlib.sha256(s.encode()).hexdigest()}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
if (r.returncode==0)==a.mutant:raise SystemExit('unexpected result')
if a.mutant and not any(t in text for t in ['qualified q mismatch','gpu3d_gxdivk P2X:']):raise SystemExit('actual step fault not caught')
