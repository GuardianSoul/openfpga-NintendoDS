#!/usr/bin/env python3
"""Check exact additive CPU/wrapper porting and all enable guard routes."""
from pathlib import Path
import argparse,hashlib,json,os,resource,subprocess,time

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_CPU,(120,120))
git=lambda n:subprocess.check_output(['git','-c','core.packedGitWindowSize=16m','show','de6039a5:'+n],cwd=R).decode()
def erase(text,parts):
    for part in parts:
        assert text.count(part)==1,part
        text=text.replace(part,'',1)
    return text
domain=(R/'rtl/arm/cpu_domain.sv').read_text();before=git('rtl/arm/cpu_domain.sv')
parts=[
 '  parameter bit A7_IF_COMMIT = 0,       // local held next-F handshake; qualified single-clock FLOW only\n',
 '  localparam bit IF_COMMIT = A7_IF_COMMIT && IF_FLOW;\n',
 '  logic        a7_i_commit_valid, a7_i_commit_accept;\n  logic [31:0] a7_i_commit_addr;\n',
 '.A7_IF_COMMIT(IF_COMMIT), ',
 '      .a7_i_commit_valid, .a7_i_commit_addr, .a7_i_commit_accept,\n',
 "    assign a7_i_commit_valid = 1'b0;\n    assign a7_i_commit_addr = '0;\n",
 "        .i_commit_valid(IF_COMMIT && a7_i_commit_valid), .i_commit_addr(IF_COMMIT ? a7_i_commit_addr : 32'd0), .i_commit_accept(a7_i_commit_accept),\n",
 "    assign a7_i_commit_accept = 1'b0;\n"]
def strip_domain(s):return erase(s,parts).replace('a7_i_redirect || (IF_COMMIT && c_cpu_rst)','a7_i_redirect')
assert strip_domain(domain)==before,'non-additive domain change'
cpu=(R/'rtl/arm/arm_cpu.sv').read_text()
cpu_parts=[
 "  parameter bit          A7_IF_COMMIT = 1'b0, // local sequential MAIN finish/held-commit producer\n",
 '  output logic        a7_i_commit_valid,\n  output logic [31:0] a7_i_commit_addr,\n  input  logic        a7_i_commit_accept,\n',
 '.MAIN_IF_COMMIT(A7_IF_COMMIT && A7_IF_FLOW && SLOW), ',
 '      .i_commit_valid(a7_i_commit_valid), .i_commit_addr(a7_i_commit_addr), .i_commit_accept(a7_i_commit_accept),\n',
 "    assign a7_i_commit_valid = 1'b0;\n    assign a7_i_commit_addr = '0;\n"]
assert erase(cpu,cpu_parts)==git('rtl/arm/arm_cpu.sv'),'non-additive arm_cpu change'
leaf=(R/'rtl/arm/arm7_ds.sv').read_text()
erased=erase(leaf,[
 '  parameter bit MAIN_IF_COMMIT = 0, // qualified finish/prepare/held next-F handshake\n',
 '  output logic        i_commit_valid,\n  output logic [31:0] i_commit_addr,\n  input  logic        i_commit_accept,\n'])
start=erased.index('  localparam bit IF_COMMIT =');end=erased.index('  wire        pipe_fire =',start)
erased=erased[:start]+"  wire        if_wait = MAIN_IF_FLOW && !tbit && f_rq && pc_f[31:24] == 8'h02 && !i_ok && !e_busy;\n"+erased[end:]
erased=erased.replace('fetch_ok','i_ok').replace('fetch_data','i_rdata')
assert erased==git('rtl/arm/arm7_ds.sv'),'non-additive arm7 change'
faults={
 'forward_disabled':domain.replace('.A7_IF_COMMIT(IF_COMMIT)',".A7_IF_COMMIT(1'b0)",1),
 'producer_disconnected':domain.replace('.a7_i_commit_valid, .a7_i_commit_addr, .a7_i_commit_accept,','.a7_i_commit_valid(), .a7_i_commit_addr(), .a7_i_commit_accept(),',1)}
for name,text in faults.items():
    assert text!=domain
    try:ok=strip_domain(text)==before
    except AssertionError:ok=False
    assert not ok,name
    (D/(name+'.sv')).write_text(text)
files=[R/'rtl/arm'/(n+'.sv') for n in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds cpu_domain cdc_req cdc_fifo cdc_a7'.split()]
files +=[R/n for n in ['rtl/ds/nds_arm7_port.sv','rtl/ds/nds_arm7_port_min.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']]
S=D/'source';S.mkdir()
for f in files:(S/f.name).write_bytes(f.read_bytes())
assert hashlib.sha256((S/'nds_arm7_port.sv').read_bytes()).hexdigest()=='dacb3dc37fbfc75b23ba47ec1873753e95d7c3f8138841b64df561e4ddd43016'
result=dict(base='de6039a5',P7_dependency='d087bb7f',erased_original_exact=['arm7_ds','arm_cpu','cpu_domain'],
    caller_source_faults_caught=list(faults),source_SHA256={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},stages=[])
routes=[('default',0,0,1,0,0,0),('shared-request',0,0,1,1,1,1),('split-request',3,0,1,1,1,1),
 ('independent-off',5,0,1,1,1,0),('independent-on',5,0,1,1,1,1),('fast-request',5,1,1,1,1,1),
 ('minimal-port',5,0,0,1,1,1),('flow-off',5,0,1,0,1,1),('quad-off',5,0,1,1,0,1)]
for tag,solo,fast,cache,flow,quad,commit in routes:
    expected=bool(commit and flow and quad and not fast and cache and solo&4 and not solo&2)
    assert expected==(tag=='independent-on')
    cmd=['build/tools/oss-cad-suite/bin/verilator','--lint-only','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--top-module','cpu_domain','--Mdir',D/'obj',
      '-GA9_SOLO='+str(solo),'-GCPU_FAST='+str(fast),'-GARM7_CACHE='+str(cache),'-GA7_IF_FLOW='+str(flow),'-GA7_IF_QUAD='+str(quad),'-GA7_IF_COMMIT='+str(commit),*map(lambda f:S/f.name,files)]
    begin=time.monotonic()
    with (D/(tag+'.log')).open('w') as out:
        child=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=out,stderr=subprocess.STDOUT)
        row=dict(tag=tag,PID=child.pid,command=list(map(str,cmd)),expected_enable=expected)
        row['exit']=child.wait(timeout=60);row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3))
    result['stages'].append(row);(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    assert row['exit']==0,(tag,(D/(tag+'.log')).read_text()[-2200:])
    print(tag,'PASS elaboration',flush=True)
result['status']='PASS additive three-file erasure, two caller-source guard faults, nine route elaborations with actual P7d087; runtime/physical qualification scoped separately'
(D/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(result['status'],flush=True)
