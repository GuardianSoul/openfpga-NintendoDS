#!/usr/bin/env python3
"""Actual UX B2/operand relation, with original preview and a source oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='ecf3ce4cf7169f04cbf78a96a88249075b3ae2da')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
print('BROM_UNIT_PID', os.getpid(), 'NI10/j1/t1', flush=True)
path = 'rtl/gpu3d/gpu3d_gxrom_ux.sv'
old = subprocess.check_output(['git', 'show', a.before+':'+path], cwd=ROOT).decode()
(out/'before.sv').write_text(old.replace('module gpu3d_gxrom_ux #', 'module gpu3d_gxrom_ux_before #', 1))
b = {int(i):int(v, 16) for i,v in re.findall(r"rb\[(\d+)\] = 35'h([a-fA-F0-9]+);", old)}
imm = {int(i):int(v, 16) for i,v in re.findall(r"imt\[(\d+)\] = 32'h([a-fA-F0-9]+);", old)}
assert len(b) == 2048 and len(imm) == 128
(out/'oracle.h').write_text('#include <cstdint>\nstatic constexpr uint64_t B[2048]={'+','.join(hex(b[i])+'ULL' for i in range(2048))+'};\nstatic constexpr uint32_t IMM[128]={'+','.join(hex(imm[i])+'U' for i in range(128))+'};\n')
(out/'wrapper.sv').write_text('''module tb_brom(input logic clk,clk2,rst,input logic[10:0]addr,
output wire[34:0]q,preview,output wire[31:0]operand);
wire[34:0]old_q,old_p;wire[31:0]old_t;wire[69:0]a0,a1;
gpu3d_gxrom_ux_before #(.B2(1),.A_DICT(1)) a(.clk,.clk2,.rst,.a_addr(11'd40),.a_q(a0),.b_addr(addr),.b_q(old_q),.b_p(old_p),.t_idx(old_p[18:12]),.t_imm(old_t));
gpu3d_gxrom_ux #(.B2(1),.A_DICT(1),.B_DICT(1)) b(.clk,.clk2,.rst,.a_addr(11'd40),.a_q(a1),.b_addr(addr),.b_q(q),.b_p(preview),.t_idx(preview[18:12]),.t_imm(operand));
logic valid=0;always @(posedge clk)valid<=1;
always @(negedge clk2)if(valid)begin
 if(q!==old_q||preview!==old_p||operand!==old_t)$fatal(1,"BROM B/preview/operand relation");
 if(a0!==a1)$fatal(1,"BROM unchanged A side");
end
endmodule
''')
(out/'main.cpp').write_bytes(Path(__file__).with_suffix('.cpp').read_bytes())
files = [out/'before.sv', ROOT/path, ROOT/'rtl/gpu3d/gpu3d_gxrom_adict.sv', ROOT/'rtl/gpu3d/gpu3d_gxrom_bdict.sv', out/'wrapper.sv', out/'main.cpp']
cmd = ['build/tools/oss-cad-suite/bin/verilator', '--cc', '--exe', '--build', '-j', '1', '--threads', '1', '--assert', '-Wno-fatal', '--top-module', 'tb_brom', '--Mdir', str(out/'obj'), '-CFLAGS', '-std=c++20 -O1', *map(str, files)]
with (out/'build.log').open('w') as log:
    rc = subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
if rc:
    raise SystemExit('BROM_BUILD_FAIL '+str(rc))
print('BROM_BUILD_PASS', flush=True)
with (out/'run.log').open('w') as log:
    rc = subprocess.run([str(out/'obj/Vtb_brom')], cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
rec = dict(before=a.before, exit=rc, command=cmd, PID=os.getpid(), nice=10, jobs=1, threads=1,
           before_sha256=hashlib.sha256(old.encode()).hexdigest(),
           inputs={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files})
(out/'receipt.json').write_text(json.dumps(rec, indent=2)+'\n')
print((out/'run.log').read_text(), flush=True)
raise SystemExit(rc)
