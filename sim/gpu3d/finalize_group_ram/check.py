#!/usr/bin/env python3
"""Affected-source finalize relation and independent full-width 4R/1W oracle."""
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
p.add_argument('--before', default='123bd63982305aa36b9ac6334a91a312a9e8e717')
p.add_argument('--mutant', action='store_true')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
pid = os.getpid()
started = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
status = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')


def phase(value, active=1):
    d = json.loads(status.read_text())
    d.update(phase=value, worker=dict(host='Desktop', controller_pid=pid,
             starttime=started, active=active, nice=10, jobs=1, threads=1),
             updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    s = json.dumps(d, indent=2) + '\n'
    assert len(s.encode()) < 2048
    tmp = status.with_suffix('.tmp')
    tmp.write_text(s)
    tmp.replace(status)


phase('finram56 full relation preparing mutant=' + str(a.mutant))
print(f'controller_pid={pid} starttime={started} NI10/j1/t1 out={out}', flush=True)
vfn = 'rtl/gpu3d/gpu3d_gxvfin.sv'
old = subprocess.check_output(['git', 'show', a.before + ':' + vfn], cwd=ROOT).decode()
new = (ROOT/vfn).read_text()


def unit(src, name, newname):
    return src[src.index('module ' + name + '\n'):].split('endmodule', 1)[0].replace(
        'module ' + name + '\n', 'module ' + newname + '\n', 1) + 'endmodule\n'


helper = new[new.index('module gpu3d_gxfin_group_ram ('):].split('endmodule', 1)[0] + 'endmodule\n'
if a.mutant:
    needle = '.b_addr(mid ? pending_wa : ra[2*gp+1])'
    assert helper.count(needle) == 1
    helper = helper.replace(needle,
        ".b_addr(mid ? pending_wa : (ra[2*gp+1] ^ (gp == 0 ? 9'd1 : 9'd0)))")
(out/'before.sv').write_text(unit(old, 'gpu3d_gxfin', 'fin_before'))
(out/'after.sv').write_text(unit(new, 'gpu3d_gxfin', 'fin_after') + helper)
pkg = (ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
constants = {n: int(v, 16) for n, v in re.findall(
    r"localparam logic \[10:0\] (\w+) = 11'h([0-9A-Fa-f]+)", pkg)}
(out/'addresses.h').write_text(''.join(f'constexpr unsigned {n}=0x{v:x};\n' for n, v in constants.items()))
params = ','.join(f'.{n}({v})' for n, v in {
    'A_LA':'FU_A_LA','A_LN':'FU_A_LN','A_CS':'FU_A_CS','A_TEXPAL':'FU_A_TEXPAL',
    'A_FACING':'FU_A_FACING','A_FATTR':'FU_A_FATTR','A_TRT':'FU_A_TRT','A_TRA':'FU_A_TRA',
    'A_VP':'FU_A_VP','A_CATTR':'LU_A_CATTR','A_TEXP':'FU_A_TEXP','G_FZ':'FU_G_FZ'}.items())
outputs = {'cond':1,'pidx':11,'rd':1,'sop':1,'sm':3,'sr':32,'cw':1,'cwa':11,
           'cwd':32,'pv':1,'ptype':1,'pd':128,'key':32,'busy':1,'ready':1}
inputs = 'clk clk2 rst we wa wd run xarg np sct wfree ofree hgo h_la h_ln h_cs h_face h_wb'.split()
top = ['''module tb_finram(
input logic clk,clk2,rst,we,run,wfree,ofree,hgo,h_face,h_wb,bad_write,
input logic [10:0] wa,h_la[4], input logic [31:0] wd,sct,
input logic [2:0] xarg, input logic [11:0] np,
input logic [3:0] h_ln, input logic [1:0] h_cs,
input logic oracle_we, input logic [8:0] oracle_wa,oracle_ra[4],
input logic [31:0] oracle_wd, output wire [31:0] oracle_q[4],
output wire cond,ready,busy,cw,pv,ptype,q_active,rd,stage_read,reused,fin_mid,
output wire [10:0] cwa, output wire [31:0] cwd,
output wire [8:0] read_addr[4],
output wire result_write,output wire [1:0] ak,output wire [3:0] ai,
output wire new_result,z_skip,publish_pending,sort_op);
import gpu3d_gxu_pkg::*;
gpu3d_gxfin_group_ram oracle_dut(.clk,.clk2,.we(oracle_we),.wa(oracle_wa),
    .wd(oracle_wd),.ra(oracle_ra),.q(oracle_q));
wire [31:0] bad_a,bad_b;
gpu3d_tdp2c #(.W(32),.AW(9)) collision_dut(.clk_a(clk),.clk_b(clk2),
    .a_addr(9'd0),.a_q(bad_a),.b_addr(9'd0),.b_we(bad_write),.b_d(32'd0),.b_q(bad_b));
''']
for suffix, module in [('a', 'fin_before'), ('b', 'fin_after')]:
    top += [f'wire [{w-1}:0] {n}_{suffix};' for n, w in outputs.items()]
    con = [f'.{n}({n})' for n in inputs] + [f'.{n}({n}_{suffix})' for n in outputs]
    top.append(f"{module} #({params},.DIV_P2X(1'b1)) {suffix}(" + ','.join(con) + ');')
for n in ['cond', 'ready', 'busy', 'cw', 'pv', 'ptype', 'cwa', 'cwd', 'rd']:
    top.append(f'assign {n}={n}_a;')
top.append('''assign q_active=a.q_on; assign read_addr=a.gra;
assign stage_read=a.pst==a.P_VP&&a.a_on&&!a.a_rdy&&a.ak!=0;
assign reused=!a.anew;assign ak=a.ak;assign ai=a.ai;
assign fin_mid=b.g_group_pump.u_groups.mid;
assign result_write=a.p_we||a.z_we||a.c_we;
assign new_result=a.b_fin;assign z_skip=a.b_fin&&!a.z_we;
assign publish_pending=a.q_on&&a.wany;assign sort_op=sop_a;
logic armed=0;
always @(posedge clk2) if(b.g_group_pump.u_groups.mid) armed<=1;
always @(posedge clk) if(armed) begin
if(b.g_group_pump.u_groups.mid) $fatal(1,"RAM phase: M at SYS read edge");
''')
if not a.mutant:
    top.append('for(int i=0;i<4;i++) if(a.gqr[i]!==b.gqr[i]) $fatal(1,"consuming SYS raw RAM port%0d mismatch old=%h new=%h",i,a.gqr[i],b.gqr[i]);')
top.append('end\nalways @(posedge clk) if(!rst) begin')
for n in ['cwa', 'cwd']:
    top.append(f'if(cw_a&&wfree&&{n}_a!=={n}_b) $fatal(1,"consumed CW {n} mismatch old=%h new=%h",{n}_a,{n}_b);')
for n in ['pidx', 'ptype', 'pd']:
    top.append(f'if(pv_a&&ofree&&{n}_a!=={n}_b) $fatal(1,"consumed PV {n} mismatch old=%h new=%h",{n}_a,{n}_b);')
top.append('end')
if not a.mutant:
    top.append('always @(negedge clk) if(!rst) begin')
    for n in outputs:
        gate = 'cw_a' if n in ['cwa', 'cwd'] else 'pv_a' if n in ['ptype', 'pd', 'pidx'] else 'sop_a' if n in ['key', 'sm', 'sr'] else '1'
        top.append(f'if({gate}&&{n}_a!=={n}_b) $fatal(1,"finalize {n} mismatch");')
    states = '''pst fin a_on a_rdy b_on b_dv dstart so_on q_on q_auto thdr ti sk ai ak bi pln pcs auto wb fst
    kt kb wo_r deg pnp q_kt q_kb q_wo q_deg q_wbuf q_texpal q_facing q_trtra q_cattr q_texp q_ln q_pnp
    work_bank published_bank p0 p1 p2 p3 c0 c1 c2 t0 t1 aw azn apx apy aden anx any anz
    bw bzn bnx bny bden bnz bts btt dbx dby dbz dqx dqy dqz sn_ln sn_cs sn_texpal sn_facing
    sn_trt sn_tra sn_cattr sn_texp sn_wbuf texpal facing trtra cattr texp wbuf slot_version'''.split()
    for n in states:
        top.append(f'if(a.{n}!==b.{n}) $fatal(1,"finalize state {n} mismatch");')
    for name, size in [('wpend',10),('rg',10),('la',10),('sn_la',10),('vp',4),('sn_vp',4),
                       ('bc',3),('snapshot_slot',4),('snapshot_version',4),('snapshot_word',16),('gqf',4)]:
        top.append(f'for(int i=0;i<{size};i++)if(a.{name}[i]!==b.{name}[i])$fatal(1,"finalize {name} mismatch");')
    for name in ['u_result_p_bg','u_result_p_beat','u_result_z_bg','u_result_z_beat','u_result_c_bg','u_result_c_beat']:
        top.append(f'for(int i=0;i<32;i++)if(a.{name}.mem[i]!==b.{name}.mem[i])$fatal(1,"finalize result memory {name} mismatch");')
    top.append('end')
top.append('endmodule\n')
(out/'wrapper.sv').write_text('\n'.join(top))
(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/finalize_group_ram/main.cpp').read_bytes())
files = [ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv', ROOT/'rtl/gpu3d/gpu3d_ram.sv',
         ROOT/'rtl/gpu3d/gpu3d_gxdiv.sv', out/'before.sv', out/'after.sv', out/'wrapper.sv', out/'main.cpp']
hashes = {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
cmd = ['build/tools/oss-cad-suite/bin/verilator',
       '--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal',
       '--top-module','tb_finram','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0',
       '-CFLAGS',f'-std=c++20 -O1 -I{out}'] + [str(f) for f in files]


def capacity():
    rows = [s.split(None,3) for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'], text=True).splitlines()[1:]]
    parents = {int(p):int(pp) for p,pp,_,_ in rows}
    def ancestors(n):
        seen = set()
        while n in parents and n not in seen:
            seen.add(n)
            n = parents[n]
        return seen
    heavy = {int(p) for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census')) or c in ('cc1plus','cc1','lto1')}
    leaves = {n for n in heavy if not any(n in ancestors(o)-{o} for o in heavy)}
    foreign = [n for n in leaves if pid not in ancestors(n)]
    with (out/'capacity.jsonl').open('a') as f:
        f.write(json.dumps(dict(time=time.time(), foreign=foreign, max_foreign=2, load=os.getloadavg()))+'\n')
    return len(foreign)<=2


while not capacity():
    print('WAIT global<=3', flush=True)
    time.sleep(5)
phase('finram56 building full relation mutant='+str(a.mutant))
with (out/'build.log').open('w') as f:
    rc = subprocess.run(cmd, cwd=out, stdout=f, stderr=subprocess.STDOUT).returncode
if rc:
    phase('finram56 build failed '+str(rc), 0)
    raise SystemExit('build failed')
print('BUILD_PASS', flush=True)
phase('finram56 full relation running mutant='+str(a.mutant))
while not capacity():
    time.sleep(5)
run = [str(out/'obj/Vtb_finram')] + (['--consumer-fault'] if a.mutant else [])
with (out/'run.log').open('w') as f:
    rc = subprocess.run(run, cwd=out, stdout=f, stderr=subprocess.STDOUT).returncode
assert hashes == {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
collision_runs = []
if not a.mutant and rc == 0:
    for order in ['A-first', 'B-first']:
        c = [str(out/'obj/Vtb_finram'), '--collision-'+order]
        with (out/('collision-'+order+'.log')).open('w') as f:
            fault_rc = subprocess.run(c, cwd=out, stdout=f, stderr=subprocess.STDOUT).returncode
        fault_log = (out/('collision-'+order+'.log')).read_text()
        assert fault_rc != 0 and "gpu3d_tdp2c: a port-B write at a port-A read's edge" in fault_log
        collision_runs.append(dict(command=c, exit=fault_rc, order=order))
        print('COLLISION_GUARD_CAUGHT '+order, flush=True)
r = dict(before=a.before, before_sha256=hashlib.sha256(old.encode()).hexdigest(),
         candidate_sha256=hashlib.sha256(new.encode()).hexdigest(), hashes=hashes,
         command=cmd, run_command=run, mutant=a.mutant, exit=rc, controller=pid,
         starttime=started, nice=10, jobs=1, threads=1, collision_runs=collision_runs)
(out/'receipt.json').write_text(json.dumps(r, indent=2)+'\n')
log = (out/'run.log').read_text()
print(log, flush=True)
phase('finram56 terminal rc='+str(rc)+' mutant='+str(a.mutant), 0)
if (rc==0)==a.mutant:
    raise SystemExit('unexpected verdict')
if a.mutant and not any(x in log for x in ['consumed CW cwd mismatch', 'consumed PV pd mismatch']):
    raise SystemExit('actual B-port fault did not reach consumed CW/PV data')
