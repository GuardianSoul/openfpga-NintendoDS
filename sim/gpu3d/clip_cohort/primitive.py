#!/usr/bin/env python3
"""Bounded nine-lane source pair and independent quotient/control oracle."""
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
p.add_argument('--before', default='ba29970820b84b260d69663b049c5e7063ef74ca')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
print('COHORT_PRIMITIVE_PID', os.getpid(), 'NI10/j1/t1', flush=True)
paths = ['rtl/gpu3d/gpu3d_gxvfin.sv', 'rtl/gpu3d/gpu3d_gxdiv.sv']
old = {n: subprocess.check_output(['git', 'show', a.before+':'+n], cwd=ROOT).decode() for n in paths}
new = {n: (ROOT/n).read_text() for n in paths}


def bank(s):
    return 'module gpu3d_gxclip_input_bank'+s.split('module gpu3d_gxclip_input_bank', 1)[1].split('endmodule', 1)[0]+'endmodule\n'


def renamed(s):
    for name in ['gpu3d_gxclip_input_bank', 'gpu3d_gxdivk', 'gpu3d_gxdiv']:
        s = re.sub(r'\b'+name+r'\b', name+'_before', s)
    return s


(out/'before.sv').write_text(renamed(bank(old[paths[0]])+old[paths[1]]))
(out/'after.sv').write_text(bank(new[paths[0]])+new[paths[1]])
(out/'wrapper.sv').write_text('''module tb_clip_cohort(
input logic clk,clk2,rst,go,start,input logic[31:0]dv[9],m0[9],nm,den,
input logic[8:0]signs,output wire[8:0]busy,output wire[31:0]q[9]);
wire[8:0]old_busy;wire[31:0]old_q[9];
gpu3d_gxclip_input_bank_before a(.clk,.clk2,.rst,.go,.start,.dv,.m0,.nm,.signs,.den,.busy(old_busy),.q(old_q));
gpu3d_gxclip_input_bank #(.COHORT(1'b1)) b(.clk,.clk2,.rst,.go,.start,.dv,.m0,.nm,.signs,.den,.busy,.q);
logic valid=0;
always @(posedge clk)if(rst)valid<=0;else if(start)valid<=1;
always @(negedge clk)if(!rst)begin
 if(old_busy!==busy)$fatal(1,"cohort busy relation old=%h new=%h",old_busy,busy);
 if(valid)for(int i=0;i<9;i++)if(old_q[i]!==q[i])$fatal(1,"cohort q[%0d] relation",i);
end
endmodule
''')
(out/'main.cpp').write_bytes(Path(__file__).with_suffix('.cpp').read_bytes())
cmd = ['build/tools/oss-cad-suite/bin/verilator', '--cc', '--exe', '--build', '-j', '1', '--threads', '1', '--assert', '-Wno-fatal', '--top-module', 'tb_clip_cohort', '--Mdir', str(out/'obj'), '-CFLAGS', '-std=c++20 -O1', str(out/'before.sv'), str(out/'after.sv'), str(out/'wrapper.sv'), str(out/'main.cpp')]
with (out/'build.log').open('w') as log:
    rc = subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
if rc:
    raise SystemExit('COHORT_BUILD_FAIL '+str(rc))
print('COHORT_BUILD_PASS', flush=True)
with (out/'run.log').open('w') as log:
    rc = subprocess.run([str(out/'obj/Vtb_clip_cohort')], cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
rec = dict(before=a.before, exit=rc, command=cmd, controller=os.getpid(), nice=10, jobs=1, threads=1,
           old_source={n:hashlib.sha256(v.encode()).hexdigest() for n,v in old.items()},
           new_source={n:hashlib.sha256(v.encode()).hexdigest() for n,v in new.items()})
(out/'receipt.json').write_text(json.dumps(rec, indent=2)+'\n')
print((out/'run.log').read_text(), flush=True)
raise SystemExit(rc)
