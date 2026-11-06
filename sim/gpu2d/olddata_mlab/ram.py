#!/usr/bin/env python3
"""Actual INIT0/OLD_DATA RAM contract, logical pending state and clock stops."""
import argparse,hashlib,json,os,resource,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1 mutant={a.mutant}',flush=True)
old=subprocess.check_output(['git','show','23cae397:rtl/gpu2d/gpu2d_ram.sv'],cwd=ROOT,text=True)
old=old[old.index('module gpu2d_ram #('):].split('endmodule',1)[0].replace('module gpu2d_ram #(','module ref_ram #(',1)+'endmodule\n'
s=(ROOT/'rtl/gpu2d/gpu2d_ram.sv').read_text()
if a.mutant:
 needle='forward_select <= pending_we && pending_address == raddr;';assert s.count(needle)==1;s=s.replace(needle,"forward_select <= 1'b0; // actual missing prior-write forward")
(out/'before.sv').write_text(old);(out/'after.sv').write_text(s)
(out/'driver.cpp').write_bytes((ROOT/'sim/gpu2d/olddata_mlab/ram.cpp').read_bytes())
(out/'wrapper.sv').write_text('''module tb_od_ram(input logic clk,we,input logic [5:0] wa,ra,input logic [24:0] wd,
output wire [21:0] q22,output wire [24:0] q25,output logic state_bad,
output wire pending22,pending25,output logic [31:0] current_collisions=0,prior_collisions=0);
wire [21:0] r22;wire [24:0] r25;
ref_ram #(.W(22),.AW(6)) a22(.clk,.we,.waddr(wa),.wdata(wd[21:0]),.raddr(ra),.rdata(r22));
ref_ram #(.W(25),.AW(6)) a25(.clk,.we,.waddr(wa),.wdata(wd),.raddr(ra),.rdata(r25));
gpu2d_mlab_od #(.W(22),.AW(6)) b22(.clk,.we,.waddr(wa),.wdata(wd[21:0]),.raddr(ra),.rdata(q22));
gpu2d_mlab_od #(.W(25),.AW(6)) b25(.clk,.we,.waddr(wa),.wdata(wd),.raddr(ra),.rdata(q25));
assign pending22=b22.pending_we;assign pending25=b25.pending_we;
always_comb begin
 state_bad=0;
 for(int i=0;i<64;i++) begin
  if(a22.mem[i] !== ((b22.pending_we&&b22.pending_address==6'(i))?b22.pending_data:b22.mem[i]))state_bad=1;
  if(a25.mem[i] !== ((b25.pending_we&&b25.pending_address==6'(i))?b25.pending_data:b25.mem[i]))state_bad=1;
 end
end
always @(negedge clk) begin
 if(r22!==q22||r25!==q25)$fatal(1,"RAM rdata mismatch");
 if(state_bad)$fatal(1,"RAM logical pending-merged state mismatch");
end
always @(posedge clk) begin
 current_collisions<=current_collisions+32'(we&&wa==ra);
 prior_collisions<=prior_collisions+32'(b22.pending_we&&b22.pending_address==ra);
end
endmodule
''')
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_od_ram','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1',str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'driver.cpp')]
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'BUILD_FAIL:{r.returncode}')
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_od_ram')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
text=(out/'run.log').read_text();print(text,flush=True)
rec={'before':'23cae397','candidate_sha256':hashlib.sha256(s.encode()).hexdigest(),'mutant':a.mutant,'exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'fixture_hashes':{n:hashlib.sha256((out/n).read_bytes()).hexdigest() for n in ['before.sv','after.sv','wrapper.sv','driver.cpp']}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
 for f in sorted(out.iterdir()):
  if f.is_file() and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
if (r.returncode==0)==a.mutant:raise SystemExit('unexpected result')
if a.mutant and 'RAM rdata mismatch' not in text:raise SystemExit('actual bypass fault not caught')
