#!/usr/bin/env python3
"""Actual queue source slice, independent head model and one RTL address fault."""
import argparse, hashlib, json, os, resource, subprocess, tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1 mutant={a.mutant}',flush=True)
old=subprocess.check_output(['git','show','0f191dcf:rtl/gpu3d/gpu3d_gxvfin.sv'],cwd=ROOT,text=True)
new=(ROOT/'rtl/gpu3d/gpu3d_gxvfin.sv').read_text();source_hash=hashlib.sha256(new.encode()).hexdigest()
if a.mutant:
    needle='.raddr(qr[4:0]), .rdata(q_head)';assert new.count(needle)==1
    new=new.replace(needle,".raddr(qr[4:0] ^ 5'd1), .rdata(q_head)")
(out/'candidate.sv').write_text(new)
for name,s in [('before',old),('after',new)]:
    body=s.split('    // ---- the write queue\n',1)[1].split('    assign busy =',1)[0]
    for line in ['    logic        pu;                     // push this clock (pa, pd)\n','    logic [10:0] pa;\n','    logic [31:0] pd;\n']:
        assert body.count(line)==1;body=body.replace(line,'')
    (out/(name+'.sv')).write_text(f'module queue_{name}(input logic clk,rst,pu,wfree,input logic [10:0] pa,input logic [31:0] pd,output wire cw,output wire [10:0] cwa,output wire [31:0] cwd);\n'+body+'endmodule\n')
(out/'driver.cpp').write_bytes((ROOT/'sim/gpu3d/clip_fifo/queue.cpp').read_bytes())
(out/'wrapper.sv').write_text('''module tb_clip_queue(input logic clk,rst,pu,wfree,input logic [10:0] pa,input logic [31:0] pd,
output wire cw,full,output wire [5:0] level,output wire [10:0] cwa,output wire [31:0] cwd,
output logic [31:0] occupancies=0,written=0,empty_arrivals=0,singleton=0,full_clocks=0,held=0,pushwrap=0,popwrap=0,resets=0);
wire cw_b;wire [10:0] cwa_b;wire [31:0] cwd_b;
queue_before a(.clk,.rst,.pu,.wfree,.pa,.pd,.cw,.cwa,.cwd);
queue_after b(.clk,.rst,.pu,.wfree,.pa,.pd,.cw(cw_b),.cwa(cwa_b),.cwd(cwd_b));
assign level=a.qn;assign full=a.qfull;
always @(posedge clk) begin
 if(rst)resets<=resets+1;
 else begin
  if(a.qn>31 || pu&&a.qfull)$fatal(1,"illegal queue source traffic");
  if(pu&&cw&&a.qw[4:0]==a.qr[4:0])$fatal(1,"observable head/tail collision");
  occupancies<=occupancies|(32'd1<<a.qn);
  if(pu)written[a.qw[4:0]]<=1;
  empty_arrivals<=empty_arrivals+32'(pu&&!cw);
  singleton<=singleton+32'(pu&&cw&&wfree&&a.qn==1);
  full_clocks<=full_clocks+32'(a.qfull);
  held<=held+32'(cw&&!wfree);
  pushwrap<=pushwrap+32'(pu&&a.qw[4:0]==31);
  popwrap<=popwrap+32'(cw&&wfree&&a.qr[4:0]==31);
 end
end
always @(negedge clk) begin
 if(a.qw!==b.qw||a.qr!==b.qr||a.qn!==b.qn||a.qfull!==b.qfull||cw!==cw_b)$fatal(1,"queue control mismatch");
 if(cw&&{cwa,cwd}!=={cwa_b,cwd_b})$fatal(1,"queue head/order mismatch");
 for(int k=0;k<32;k++)if(written[k]&&a.q[k]!==b.u_write_queue.mem[k])$fatal(1,"queue retained storage mismatch");
end
endmodule
''')
files=[ROOT/'rtl/gpu3d/gpu3d_ram.sv',out/'before.sv',out/'after.sv',out/'wrapper.sv',out/'driver.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_clip_queue','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1']+list(map(str,files))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'BUILD_FAIL:{r.returncode}')
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_clip_queue')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
rec={'before':'0f191dcf','source_sha256':source_hash,'staged_sha256':hashlib.sha256(new.encode()).hexdigest(),'mutant':a.mutant,'exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':10,'jobs':1,'threads':1,'command':cmd,'fixture_hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files[1:]+[out/'candidate.sv']}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
    for f in sorted(out.iterdir()):
        if f.is_file() and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
if (r.returncode==0)==a.mutant:raise SystemExit('unexpected result')
if a.mutant and 'queue head/order mismatch' not in log:raise SystemExit('actual address fault not caught')
