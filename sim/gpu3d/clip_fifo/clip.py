#!/usr/bin/env python3
"""Clip FIFO MLAB: complete actual clip output, service and retained state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import resource
import tarfile

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='0f191dcf')
p.add_argument('--red', type=int, choices=[0,1], default=1)
p.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1 red={a.red}',flush=True)
out = a.out.resolve(); out.mkdir(parents=True,exist_ok=True)
def guard():
    rows=[s.split(None,3) for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]]
    parent={int(p):int(pp) for p,pp,_,_ in rows}
    def ancestors(pid):
        seen=set()
        while pid in parent and pid not in seen:
            seen.add(pid);pid=parent[pid]
        return seen
    heavy={int(p) for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census')) or c in ['cc1plus','cc1','lto1']}
    leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other} for other in heavy)}
    foreign=[{'pid':int(p),'ppid':int(pp),'nice':int(n),'comm':c} for p,pp,n,c in rows if int(p) in leaves and os.getpid() not in ancestors(int(p))]
    with (out/'capacity.jsonl').open('a') as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'allowed':2})+'\n')
    return len(foreign)<=2
def run_guarded(cmd,log):
    while not guard():
        print('WAIT global worker capacity',flush=True);time.sleep(5)
    return subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
path='rtl/gpu3d/gpu3d_gxvfin.sv'
old=subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT).decode()
new=(ROOT/path).read_text()
primitive=(ROOT/'rtl/gpu3d/gpu3d_gxdiv.sv').read_text()
(out/'primitive.sv').write_text(primitive)
def unit(s,name):
    s=s[s.index('module gpu3d_gxclip #('):]
    return s.split('endmodule',1)[0].replace('module gpu3d_gxclip #(',f'module {name} #(',1)+'endmodule\n'
(out/'before.sv').write_text(unit(old,'clip_before'))
(out/'after.sv').write_text(unit(new,'clip_after'))
pkg=(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
constants={n:int(v,16) for n,v in re.findall(r'localparam logic \[10:0\] (\w+) = 11\'h([0-9A-Fa-f]+)',pkg)}
(out/'addresses.h').write_text('\n'.join(f'constexpr unsigned {n}=0x{v:x};' for n,v in constants.items())+'\n')
params='.A_LA(FU_A_LA),.A_LN(FU_A_LN),.A_CS(FU_A_CS),.A_OCM(PU_A_OCM),.A_CATTR(LU_A_CATTR),.A_POOL(PU_A_POOL),.DS_CLIPRED(RED)'
outputs={'cond':1,'cw':1,'cwa':11,'cwd':32,'busy':1,'nnew':4,'nside':1,'nnew_v':1}
ins='clk,rst,we,wa,wd,run,can,wfree'.split(',')
top=['''module tb_clip_wordbanks #(parameter bit RED=1)(
input logic clk,clk2,rst,we,run,can,wfree,input logic [10:0] wa,input logic [31:0] wd,
output wire cond,cw,busy,nnew_v,output wire [10:0] cwa,output wire [31:0] cwd,
output wire [3:0] nnew,output wire nside,
output wire [17:0] read_valid,output wire [8:0] read_addr[18],
output logic [31:0] old_data_collisions,neighbour_reads,head_reads,colour_reads,
output logic [31:0] full_clocks,held_clocks,rf_takes,outcomes);
import gpu3d_gxu_pkg::*;
''']
for suffix,mod in [('a','clip_before'),('b','clip_after')]:
    for n,w in outputs.items():top.append(f'wire [{w-1}:0] {n}_{suffix};')
    top.append(f'{mod} #({params}'+",.DIV_P2X(1'b1)"+f') {suffix}('+','.join([f'.{n}({n})' for n in ins]+['.clk2(clk2)']+[f'.{n}({n}_{suffix})' for n in outputs])+');')
for n in outputs:top.append(f'assign {n}={n}_a;')
top.append('''logic [31:0] written=0;
always @(posedge clk) if(!rst && a.pu) written[a.qw[4:0]]<=1'b1;
always @(posedge clk) if(!rst && a.pu && a.cw && a.qw[4:0]==a.qr[4:0])$fatal(1,"observable FIFO head/tail collision");
always_comb begin
read_valid='0;
if(a.st==a.S_HT && a.li<a.ln) read_valid=(18'd1<<3)|(18'd1<<a.comp);
if(a.st==a.S_NB && a.nk==9 && a.rk==0) read_valid=18'h3ffff;
if(a.st==a.S_CM && a.qe && !a.pu && a.k<a.ln) read_valid=18'h70;
end
genvar k; generate for(k=0;k<18;k++) begin:g_probe assign read_addr[k]={(k<9?a.rgroup_out:a.rgroup_in),4'(k%9<7?k%9:k%9+1)}; end endgenerate
always @(negedge clk) if(!rst) begin
''')
for n in outputs:
    gate='cw_a' if n in ['cwa','cwd'] else 'nnew_v_a' if n in ['nnew','nside'] else '1'
    top.append(f'if({gate} && {n}_a !== {n}_b) $fatal(1,"clip output {n} mismatch");')
for n in ['st','done','cur','ln','li','lcnt','cs','ocm','far12','newv','pool0','pool','hx','side','v','u','vw','vc','num','den','k','pts','rv','ru','dgo','dwait','qw','qr','nk','rk','nva','ck']:
    top.append(f'if(a.{n} !== b.{n}) $fatal(1,"clip state {n} mismatch");')
top.append('''for(int i=0;i<10;i++) if(a.sn_la[i]!==b.sn_la[i] || a.la[i]!==b.la[i] || a.lb[i]!==b.lb[i]) $fatal(1,"clip list state mismatch");
for(int i=0;i<9;i++) if(a.vin[i]!==b.vin[i] || a.pacc[i]!==b.pacc[i] || a.nv[i]!==b.nv[i]) $fatal(1,"clip arithmetic state mismatch");
for(int i=0;i<3;i++) if(a.cm[i]!==b.cm[i]) $fatal(1,"clip colour state mismatch");
for(int i=0;i<32;i++) if(written[i] && a.q[i]!==b.u_write_queue.mem[i]) $fatal(1,"clip retained queue word mismatch");
if(a.st==a.S_HT2 && (a.outside_word[3]!==b.outside_word[3] || a.outside_word[a.comp]!==b.outside_word[a.comp])) $fatal(1,"clip bank/address head mismatch");
if(a.st==a.S_NB2) for(int i=0;i<9;i++) if(a.outside_word[i]!==b.outside_word[i] || a.inside_word[i]!==b.inside_word[i]) $fatal(1,"clip bank/address neighbour mismatch");
if(a.st==a.S_CM2) for(int i=0;i<3;i++) if(a.outside_word[4+i]!==b.outside_word[4+i]) $fatal(1,"clip bank/address colour mismatch");
end
logic [17:0] collision;
always_comb for(int i=0;i<18;i++) collision[i]=we && wa[10:9]==2'b01 && read_valid[i] && wa[8:0]==read_addr[i];
always @(posedge clk) if(rst) begin old_data_collisions<=0;neighbour_reads<=0;head_reads<=0;colour_reads<=0;full_clocks<=0;held_clocks<=0;rf_takes<=0;outcomes<=0;end else begin
old_data_collisions<=old_data_collisions+32'(|collision);
neighbour_reads<=neighbour_reads+32'(a.st==a.S_NB2);
head_reads<=head_reads+32'(a.st==a.S_HT2);
colour_reads<=colour_reads+32'(a.st==a.S_CM2);
full_clocks<=full_clocks+32'(a.qfull);held_clocks<=held_clocks+32'(cw_a&&!wfree);
rf_takes<=rf_takes+32'(cw_a&&wfree);outcomes<=outcomes+32'(nnew_v_a);
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top))
driver=ROOT/'sim/gpu3d/divider_pump/clip.cpp'
(out/'main.cpp').write_bytes(driver.read_bytes())
cmd=[a.verilator,'--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_clip_wordbanks',f'-GRED={a.red}','--Mdir',str(out/'obj'),'-CFLAGS',f'-std=c++20 -O1 -I{out}',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'primitive.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]
with (out/'build.log').open('w') as log:
    r=run_guarded(cmd,log)
    if r.returncode:raise SystemExit(f'build failed:{r.returncode}')
print('BUILD_PASS',flush=True)
with (out/'run.log').open('w') as log:r=run_guarded([str(out/'obj/Vtb_clip_wordbanks')],log)
rec=dict(before=a.before,before_sha256=hashlib.sha256(old.encode()).hexdigest(),candidate_sha256=hashlib.sha256(new.encode()).hexdigest(),driver_sha256=hashlib.sha256(driver.read_bytes()).hexdigest(),command=cmd,red=a.red,exit=r.returncode,pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],nice=10,jobs=1,threads=1)
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
print((out/'run.log').read_text(),flush=True)
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
    for f in sorted(out.iterdir()):
        if f.is_file() and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
raise SystemExit(r.returncode)
