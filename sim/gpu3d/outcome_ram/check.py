#!/usr/bin/env python3
"""Cycle equivalence of the actual outcome RTL and complete fronts.

The queue-only modules are literal source slices, with only oq_take exposed
as an input. This permits all legal occupancies independently of geometry
throughput. The full-front pairs retain the real command-driven oq_take.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='15655ceb')
p.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
p.add_argument('--mutant', action='store_true')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
print(f'worker_pid={os.getpid()} nice={os.getpriority(os.PRIO_PROCESS, 0)} jobs=1 threads=1', flush=True)
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
before = subprocess.check_output(['git', 'show', f'{a.before}:rtl/gpu3d/gpu3d_gxfront.sv'], cwd=ROOT).decode()
after = (ROOT / 'rtl/gpu3d/gpu3d_gxfront.sv').read_text()
if a.mutant:
    needle = 'forward_head <= !rst && oc_valid && oq_w == next_r;'
    assert after.count(needle) == 1
    after = after.replace(needle, 'forward_head <= 1\'b0; // deliberate actual RTL fault')

def queue(src, name, head):
    block = src[src.index('    // Engine outcomes are independent'):src.index('    // the entries decoded as they are written')]
    return f'''module {name}(
input logic clk,rst,oc_valid,take,engine_ovf,oc_side,oc_quad,oc_rej,
input logic [3:0] oc_nv,oc_ncl,
input logic vblank,geom_en,flush,e_pop,do_exec,
output logic [11:0] model_npoly, output logic [12:0] model_nvert,
output logic model_ovf,e_ordered,
output wire [11:0] head, output wire [9:0] count,
output wire [8:0] rp,wp, output wire pending);
localparam bit DSX=1; localparam int SP_AW=18;
wire [11:0] engine_npoly='0; wire [12:0] engine_nvert='0;
{block}
assign oq_take=take;
assign head={head}; assign count=oq_count; assign rp=oq_r; assign wp=oq_w; assign pending=ovf_pending;
endmodule
'''

ports = []
hdr = before[before.index('    input  logic        clk,'):before.index('    // CmdNumParams')]
for m in re.finditer(r'(input|output)\s+logic\s*(\[[^]]+\])?\s*(\w+)', hdr):
    direction, width, name = m.groups()
    ports.append((direction, width or '', name))
assert len(ports) == 54, len(ports)
top_ports = ['input logic clk,rst,qpush,qtake,qovf,qblank,qflush,qen,qepop,qexec', 'input logic [10:0] qbits', 'output wire [9:0] qcount', 'output wire [11:0] qhead', 'output wire [4:0] front_wait,front_pending', 'output logic [31:0] front_takes,front_late,front_load44', 'input logic [4:0] f_wr_enable']
for d,w,n in ports:
    if d == 'input' and n not in ('clk','rst'):
        top_ports.append(f'input logic {w} f_{n}')
top = ['module tb_outcome_ram(\n'+',\n'.join(top_ports)+'\n);']
for suffix,mod in [('a','oq_before'),('b','oq_after')]:
    top.append(f'wire [11:0] np_{suffix},head_{suffix}; wire [12:0] nv_{suffix}; wire [9:0] count_{suffix}; wire [8:0] rp_{suffix},wp_{suffix}; wire ov_{suffix},order_{suffix},pending_{suffix};')
    top.append(f'''{mod} q_{suffix}(.clk,.rst,.oc_valid(qpush),.take(qtake),.engine_ovf(qovf),.oc_side(qbits[10]),.oc_nv(qbits[9:6]),.oc_ncl(qbits[5:2]),.oc_quad(qbits[1]),.oc_rej(qbits[0]),
    .vblank(qblank),.geom_en(qen),.flush(qflush),.e_pop(qepop),.do_exec(qexec),.model_npoly(np_{suffix}),.model_nvert(nv_{suffix}),.model_ovf(ov_{suffix}),.e_ordered(order_{suffix}),.head(head_{suffix}),.count(count_{suffix}),.rp(rp_{suffix}),.wp(wp_{suffix}),.pending(pending_{suffix}));''')
top.append('assign qcount=count_b; assign qhead=head_b;')
top.append('''always @(negedge clk) if (!rst) begin
  if ({np_a,nv_a,count_a,rp_a,wp_a,ov_a,order_a,pending_a} !== {np_b,nv_b,count_b,rp_b,wp_b,ov_b,order_b,pending_b}) $fatal(1,"queue control/state mismatch");
  if (count_a != 0 && head_a !== head_b) $fatal(1,"queue valid head mismatch count=%0d old=%03x new=%03x",count_a,head_a,head_b);
end''')
configs = ['.DSX(1),.CHEAP(0),.READ_LOAD44(1)', '.DSX(1),.CHEAP(0),.READ_LOAD44(0)', '.DSX(0),.CHEAP(0)', '.DSX(0),.CHEAP(1)', '.DSX(1),.CHEAP(0),.READ_LOAD44(1),.SPILL(1),.SP_ON(4096),.SP_AW(18)']
for i, cfg in enumerate(configs):
    for suffix,mod in [('a','front_before'),('b','front_after')]:
        con = []
        top.append(f'logic [8:0] dp_{i}{suffix}; wire pop_{i}{suffix}=f_e_pop && e_avail_{i}{suffix};')
        top.append(f'always @(posedge clk) if(rst) dp_{i}{suffix}<=0; else if(pop_{i}{suffix}) dp_{i}{suffix}<=dp_{i}{suffix}+9\'d1;')
        for d,w,n in ports:
            target = n if n in ('clk','rst') else 'f_'+n if d=='input' else f'{n}_{i}{suffix}'
            if n in ('dp','e_addr'): target=f'dp_{i}{suffix}'
            if n=='e_pop': target=f'pop_{i}{suffix}'
            if n=='wr_req': target=f'f_wr_req && f_wr_enable[{i}]'
            if d=='output': top.append(f'wire {w} {target};')
            con.append(f'.{n}({target})')
        top.append(f'{mod}{i} #({cfg}) f{i}{suffix}('+','.join(con)+');')
    top.append(f'always @(negedge clk) if (!rst) begin')
    for d,w,n in ports:
        if d!='output': continue
        gate = '1'
        if n=='e_data': gate=f'e_avail_{i}a'
        if n in ('sp_waddr','sp_wdata'): gate=f'sp_wreq_{i}a'
        if n=='sp_raddr': gate=f'sp_rreq_{i}a'
        top.append(f'if ({gate} && {n}_{i}a !== {n}_{i}b) $fatal(1,"front{i} {n} mismatch");')
    top.append(f'if (f{i}a.oq_count !== f{i}b.oq_count) $fatal(1,"front{i} count mismatch");')
    if i in (0,1,4):
        top.append(f'if (f{i}a.oq_have && f{i}a.oq[f{i}a.oq_r] !== f{i}b.oq_data) $fatal(1,"front{i} head mismatch");')
    top.append('end')
top.append('assign front_wait={wr_wait_4a,wr_wait_3a,wr_wait_2a,wr_wait_1a,wr_wait_0a};')
top.append('assign front_pending={f4a.tm.pend,f3a.tm.pend,f2a.tm.pend,f1a.tm.pend,f0a.tm.pend};')
top.append('always @(posedge clk) if(rst) begin front_takes<=0; front_late<=0; front_load44<=0; end else begin front_takes<=front_takes+32\'(f0a.oq_take); front_late<=front_late+32\'(f0a.stand); front_load44<=front_load44+32\'(load44_tail_0a); end endmodule')
src = queue(before, 'oq_before', 'oq[oq_r]') + queue(after, 'oq_after', 'oq_data') + '\n'.join(top)
(out/'wrapper.sv').write_text(src)
# Separate module identities avoid Verilator's parameter-specialization bug
# for $bits(dec_t) when CHEAP and SPILL variants coexist in one hierarchy.
(out/'before.sv').write_text(''.join(before.split('endmodule',1)[0].replace('module gpu3d_gxfront #(', f'module front_before{i} #(',1)+'endmodule\n' for i in range(len(configs))))
(out/'after.sv').write_text(''.join(after.split('endmodule',1)[0].replace('module gpu3d_gxfront #(', f'module front_after{i} #(',1)+'endmodule\n' for i in range(len(configs))))
cmd = [a.verilator, '--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_outcome_ram','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(ROOT/'sim/gpu3d/outcome_ram/main.cpp')]
with (out/'build.log').open('w') as log:
    subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
with (out/'run.log').open('w') as log:
    run = subprocess.run([str(out/'obj/Vtb_outcome_ram')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
receipt = dict(before=a.before, before_sha256=hashlib.sha256(before.encode()).hexdigest(), candidate_sha256=hashlib.sha256(after.encode()).hexdigest(), command=cmd, configs=configs, mutant=a.mutant, exit=run.returncode, pid=os.getpid(), nice=os.getpriority(os.PRIO_PROCESS, 0), jobs=1, threads=1)
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print((out/'run.log').read_text())
if (run.returncode == 0) == a.mutant: raise SystemExit('unexpected result')
if a.mutant and 'queue valid head mismatch' not in (out/'run.log').read_text():
    raise SystemExit('mutant failed without the expected head mismatch')
