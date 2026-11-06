#!/usr/bin/env python3
"""Four native partial pairs: literal before/new stages and retained consumers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='49746326')
p.add_argument('--mutant', action='store_true')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
started = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
status = out / 'status.json'

def phase(value, active=1):
    d = json.loads(status.read_text()) if status.exists() else {}
    d.update(phase=value, worker={'host': 'Laptop', 'controller_pid': os.getpid(),
             'starttime': started, 'active': active, 'nice': 10, 'jobs': 1, 'threads': 1},
             updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    text = json.dumps(d, indent=2) + '\n'
    assert len(text.encode()) <= 2048
    tmp = status.with_suffix('.tmp')
    tmp.write_text(text)
    tmp.replace(status)

phase('MAC actual product/consumer relation starting; mutant=' + str(a.mutant))
print(f'controller_pid={os.getpid()} starttime={started} NI10/j1/t1 out={out}', flush=True)
fn = 'rtl/gpu3d/gpu3d_gxeng.sv'
old = subprocess.check_output(['git', 'show', a.before + ':' + fn], cwd=ROOT).decode()
new = (ROOT / fn).read_text()
if a.mutant:
    needle = 'vp3 <= product1;'
    assert new.count(needle) == 1
    new = new.replace(needle, "vp3 <= product1 ^ (44'd1 << 32); // actual late-vector product fault")
pkg = (ROOT / 'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
constants = {n: int(v) for n, v in re.findall(r'localparam int ((?:ACC|MB)_\w+) = (\d+);', pkg)}
(out / 'constants.h').write_text(''.join(f'constexpr unsigned {n}={v};\n' for n,v in constants.items()))

def block(src, start):
    """Original text of one begin/end block, skipping comments when balancing."""
    depth = 0
    for m in re.finditer(r'//[^\n]*|/\*[\s\S]*?\*/|\bbegin\b|\bend\b', src[start:]):
        if m.group().startswith('/'):
            continue
        depth += 1 if m.group() == 'begin' else -1
        if depth == 0:
            return src[start:start + m.end()]
    raise AssertionError('unterminated source block')

def always(src, anchor):
    pos = src.index(anchor)
    return block(src, src.rfind('    always_ff @(posedge clk)', 0, pos))

scalar = lambda src: always(src, '        R <= res;')
accum = lambda src: src[src.index('    wire        acc_sub ='):src.index('    // FF: the vector MAC.')]
vector = lambda src: always(src, '            if (v_op) vcnt <=')
consumer = lambda src: src[src.index('        wire [43:0] vsel ='):src.index('`ifndef SYNTHESIS', src.index('        wire [43:0] vsel ='))]
assert accum(old) == accum(new)
assert consumer(old) == consumer(new)
# Fallback scalar and vector arithmetic retain their exact expressions.
assert 'always_ff @(posedge clk) pr <= ma * mb;' in new
assert "for (int c = 1; c < 4; c++) vpr[c] <= 44'(vma[c] * $signed(mb[15:0]));" in new
outputs = {'R': 32, 'ma': 32, 'mb': 32, 'pr': 64, 'acc': 64, 'kreg': 6,
           'acc_m': 3, 'acc_a': 3, 'we_m': 1, 'out_m': 4, 'sm_m': 3, 'wa_m': 11,
           'fl_p': 1, 'fz_h': 1, 'fn': 1, 'fc': 1, 'flt': 1, 'fz': 1,
           'a63': 1, 'az': 1, 'nfit': 1, 'vcnt': 5, 'vx_q': 32,
           'vma': (32,4), 'vpr': (44,4), 'vacc': (44,4), 'vx_lane': (32,4)}
inputs = '''input logic clk, clk_2x, rst,
input logic [31:0] res, qa, qb, imm, vm_q [4],
input logic [15:0] at_v [3], input logic [4:0] v_row,
input logic b_ma, b_fl, fl_sort, lt_s, s_sign, we_o,
input logic [1:0] b_mb, input logic [2:0] b_acc, b_xsh,
input logic [9:0] od_ro, input logic [5:0] k4_k,
input logic [32:0] sum, input logic [3:0] b_out,
input logic [10:0] wa_o'''
in_names = 'clk clk_2x rst res qa qb imm vm_q at_v v_row b_ma b_fl fl_sort lt_s s_sign we_o b_mb b_acc b_xsh od_ro k4_k sum b_out wa_o'.split()
def declaration(n,w,prefix='output logic'):
    if isinstance(w,tuple):
        return f'{prefix} [{w[0]-1}:0] {n} [{w[1]}]'
    return f'{prefix} [{w-1}:0] {n}'

def unit(src, name, current):
    s = f'module {name} #(parameter bit SMALL=1) (\n{inputs},\n'
    s += ',\n'.join(declaration(n,w,'output logic signed' if n in {'ma','mb','pr','acc','vma','vpr','vacc'} else 'output logic') for n,w in outputs.items()) + '\n);\n'
    s += '''import gpu3d_gxu_pkg::*;
localparam bit FF=1, PU=1;
localparam int VAW=5;
typedef struct packed {logic [9:0] ro;} odec_t;
odec_t od;
assign od.ro=od_ro;
wire [31:0] vm0_q=vm_q[0];
wire v_op=b_acc==3'(ACC_VLD)||b_acc==3'(ACC_VADD)||b_acc==3'(ACC_VLDT);
wire v_opo=v_op;
'''
    s += src[src.index('    localparam int RO_SUM ='):src.index('    typedef struct packed {', src.index('    localparam int RO_SUM ='))]
    s += 'assign fz=fl_p ? R==32\'d0 : fz_h;\n'
    s += scalar(src) + '\n' + accum(src) + '\n' + vector(src) + '\n'
    # Lane0's otherwise unused vector-array words are fixture aliases only.
    s += "assign vma[0]='0; assign vpr[0]='0; assign vacc[0]='0;\n"
    if current:
        s += 'generate\n' + block(src, src.index('        if (PU) begin : g_shared_products')) + '\nendgenerate\n'
    s += consumer(src) + '\nendmodule\n'
    return s

def helper(src, name):
    return src[src.index('module '+name+' ('):].split('endmodule',1)[0]+'endmodule\n'
old_helper=helper(old,'gpu3d_gxmac_products').replace('gpu3d_gxmac_products','gpu3d_gxmac_products_before')
old_units=''.join(unit(old.replace('gpu3d_gxmac_products','gpu3d_gxmac_products_before'),'mac_before'+str(i),True)for i in range(2))
(out/'before.sv').write_text(old_units+old_helper)
pair=helper((ROOT/'rtl/gpu3d/gpu3d_gxlight.sv').read_text(),'gpu3d_gxlight_pair18')
(out/'after.sv').write_text(''.join(unit(new,'mac_after'+str(i),True)for i in range(2))+helper(new,'gpu3d_gxmac_products')+pair)
top = ['module tb_mac_products(\n' + inputs + ',\ninput logic check,\n']
qs=[]
for n,w in outputs.items():
    qs.append(f'output logic [{w[0]-1 if isinstance(w,tuple)else w-1}:0] q_{n} [2]' + (f'[{w[1]}]'if isinstance(w,tuple)else''))
top += [',\n'.join(qs), '\n);\n']
for i in range(2):
    for side in ['a','b']:
        for n,w in outputs.items():
            top.append(declaration(n+'_'+str(i)+side,w,'wire signed' if n in {'ma','mb','pr','acc','vma','vpr','vacc'} else 'wire')+';')
        cons = [f'.{n}({n})' for n in in_names] + [f'.{n}({n}_{i}{side})' for n in outputs]
        top.append(f'mac_{"before"if side=="a"else"after"}{i} #(.SMALL({i})) {side}{i}(' + ','.join(cons) + ');')
    for n,w in outputs.items():
        if isinstance(w,tuple):
            for c in range(w[1]):top.append(f'assign q_{n}[{i}][{c}]={n}_{i}b[{c}];')
        else:top.append(f'assign q_{n}[{i}]={n}_{i}b;')
    top.append('always @(negedge clk) if(check) begin')
    top.append(f'if(vx_q_{i}a!==vx_q_{i}b)$fatal(1,"MAC{i} consumer XS mismatch old=%08x new=%08x",vx_q_{i}a,vx_q_{i}b);')
    top.append(f'for(int c=1;c<4;c++) if(vacc_{i}a[c]!==vacc_{i}b[c]||vx_lane_{i}a[c]!==vx_lane_{i}b[c])$fatal(1,"MAC{i} consumer vacc/lane mismatch lane=%0d",c);')
    for n,w in outputs.items():
        if n in ['vx_q','vacc','vx_lane']:continue
        if isinstance(w,tuple):
            for c in range(1,w[1]):
                if a.mutant and n=='vpr' and c==3:continue
                top.append(f'if({n}_{i}a[{c}]!=={n}_{i}b[{c}])$fatal(1,"MAC{i} {n}[{c}] mismatch");')
        else:top.append(f'if({n}_{i}a!=={n}_{i}b)$fatal(1,"MAC{i} {n} mismatch old=%h new=%h",{n}_{i}a,{n}_{i}b);')
    top.append('end')
top.append('endmodule\n')
(out/'wrapper.sv').write_text('\n'.join(top))
(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/mac_products/main.cpp').read_bytes())
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_mac_products','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]

def capacity():
    rows=[s.split(None,3)for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]]
    parent={int(p):int(pp)for p,pp,_,_ in rows}
    def ancestors(pid):
        seen=set()
        while pid in parent and pid not in seen:seen.add(pid);pid=parent[pid]
        return seen
    heavy={int(p)for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census'))or c in('cc1plus','cc1','lto1')}
    leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other}for other in heavy)}
    foreign=[pid for pid in leaves if os.getpid()not in ancestors(pid)]
    with(out/'capacity.jsonl').open('a')as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'max_foreign':2})+'\n')
    return len(foreign)<=2
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
with(out/'build.log').open('w')as f:rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
if rc:phase('MAC relation build failed '+str(rc),0);raise SystemExit('build failed '+str(rc))
print('BUILD_PASS',flush=True)
phase('MAC relation running; mutant='+str(a.mutant))
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
run=[str(out/'obj/Vtb_mac_products')]+(['--consumer-fault']if a.mutant else[])
with(out/'run.log').open('w')as f:rc=subprocess.run(run,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
receipt={'before':a.before,'before_sha256':hashlib.sha256(old.encode()).hexdigest(),'candidate_sha256':hashlib.sha256(new.encode()).hexdigest(),'command':cmd,'run_command':run,'mutant':a.mutant,'exit':rc,'controller':os.getpid(),'starttime':started,'nice':10,'jobs':1,'threads':1,'configs':['PU1/SMALL0','PU1/SMALL1'],'scope':'literal scalar/vector stages, retained accumulators/flags/XS, independent arithmetic; no closedGX or currentlighting repeat','negative_checker_exception':'Only immediate vpr[3] comparison omitted in negative run to reach actual retained consumer'if a.mutant else None}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
log=(out/'run.log').read_text();print(log,flush=True)
phase('MAC relation terminal rc='+str(rc)+' mutant='+str(a.mutant),0)
if(rc==0)==a.mutant:raise SystemExit('unexpected verdict')
if a.mutant and not any(x in log for x in ['consumer XS mismatch','consumer vacc/lane mismatch','oracle consumer']):raise SystemExit('actual fault not caught at retained consumer')
