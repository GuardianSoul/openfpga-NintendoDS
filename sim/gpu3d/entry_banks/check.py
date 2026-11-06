#!/usr/bin/env python3
"""Actual entry-RAM and spill-consumer relation, single leased worker."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='d75f3dc3')
p.add_argument('--mutant', action='store_true')
p.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
a = p.parse_args()
os.setpriority(os.PRIO_PROCESS, 0, 10)
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=True)
status = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json')
starttime = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]
def phase(value):
    d = json.loads(status.read_text())
    d.update(phase=value, worker={'host': 'Desktop', 'controller_pid': os.getpid(),
             'starttime': starttime, 'active': 1, 'nice': 10, 'jobs': 1, 'threads': 1},
             updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
    text = json.dumps(d, indent=2)+'\n'; assert len(text.encode()) <= 2048
    temp = status.with_suffix('.tmp'); temp.write_text(text); os.replace(temp, status)
phase('entrybank source-specific controller starting before compiler; mutant='+str(a.mutant))
print(f'controller_pid={os.getpid()} starttime={starttime} nice=10 jobs=1 threads=1', flush=True)
path = 'rtl/gpu3d/gpu3d_gxfront.sv'
old = subprocess.check_output(['git', 'show', a.before+':'+path], cwd=ROOT).decode()
new = (ROOT/path).read_text()
if a.mutant:
    needle = 'bank_q <= raddr[11];'
    assert new.count(needle) == 1
    new = new.replace(needle, 'bank_q <= ~raddr[11]; // deliberate actual selector fault')
helper = new[new.index('module gpu3d_gxentry_banks #('):].split('endmodule', 1)[0]+'endmodule\n'
ports = '''input logic clk,rst,ram_we,do_exec,e_pop,oq_full,sp_wack,sp_wdrained,sp_rack,sp_rvalid,
input logic [39:0] ram_wd,input logic [8:0] e_addr,dp,mx,wr,input logic [31:0] sp_rdata,
output logic [39:0] e_data,output logic e_avail,e_more,sp_full,sp_wreq,sp_rreq,
output logic [12:0] sp_used,output logic [23:0] sp_waddr,sp_raddr,output logic [31:0] sp_wdata,
output wire [12:0] occupancy,output wire [18:0] spilled,output wire [11:0] rp,
output wire mem_we,output wire [11:0] mem_wa,output wire [1:0] guards'''
def consumer(src, name):
    block = src[src.index('        // u_ent holds the engine'):src.index('    // Engine outcomes are independent')]
    return f'''module {name}({ports});
localparam bit DSX=1,CHEAP=0,GATH16=1;
localparam int SP_ON=4096,SP_AW=18;
localparam logic [23:0] SP_BASEW=24'h0c0000;
generate begin:g_spill
{block}
assign occupancy=13'(g_spill.occ); assign spilled=g_spill.sq;
assign rp=g_spill.g_wide_read.rp; assign mem_we=g_spill.ent_we;
assign mem_wa=g_spill.oc; assign guards={{g_spill.w2,g_spill.w1}};
endmodule
'''
(out/'before.sv').write_text(consumer(old, 'spill_before'))
(out/'after.sv').write_text(consumer(new, 'spill_after')+helper)
outputs = {'e_data':40,'e_avail':1,'e_more':1,'sp_full':1,'sp_wreq':1,'sp_rreq':1,
           'sp_used':13,'sp_waddr':24,'sp_raddr':24,'sp_wdata':32,'occupancy':13,
           'spilled':19,'rp':12,'mem_we':1,'mem_wa':12,'guards':2}
ins = 'clk,rst,ram_we,do_exec,e_pop,oq_full,sp_wack,sp_wdrained,sp_rack,sp_rvalid,ram_wd,e_addr,dp,mx,wr,sp_rdata'.split(',')
top = [f'''module tb_entry_banks({ports},
input logic m_we,m_valid,input logic [11:0] m_wa,m_ra,input logic [39:0] m_wd,
output logic [39:0] m_q);
wire [39:0] m_old;
gpu3d_ram #(.W(40),.AW(12)) ram_before(.clk,.we(m_we),.waddr(m_wa),.wdata(m_wd),.raddr(m_ra),.rdata(m_old));
gpu3d_gxentry_banks ram_after(.clk,.we(m_we),.waddr(m_wa),.wdata(m_wd),.raddr(m_ra),.rdata(m_q));
always @(negedge clk) if(m_valid && m_old !== m_q) $fatal(1,"entry full40 bank/selector mismatch old=%010x new=%010x",m_old,m_q);
''']
for suffix, mod in [('a','spill_before'),('b','spill_after')]:
    top.extend(f'wire [{w-1}:0] {n}_{suffix};' for n,w in outputs.items())
    top.append(f'{mod} {suffix}('+','.join([f'.{n}({n})' for n in ins]+[f'.{n}({n}_{suffix})' for n in outputs])+');')
top.extend(f'assign {n}={n}_a;' for n in outputs)
top.append('always @(negedge clk) if(!rst) begin')
for n in outputs:
    gate = 'e_avail_a' if n=='e_data' else 'sp_wreq_a' if n in ('sp_waddr','sp_wdata') else 'sp_rreq_a' if n=='sp_raddr' else '1'
    top.append(f'if({gate} && {n}_a !== {n}_b) $fatal(1,"spill consumer {n} mismatch");')
for n in 'oc occ sw swb nb adv_q sr ul wact wsec wwd ract rreq_q rw w1 w2'.split():
    top.append(f'if(a.g_spill.{n} !== b.g_spill.{n}) $fatal(1,"spill control {n} mismatch");')
top.append('end\nendmodule\n')
(out/'wrapper.sv').write_text('\n'.join(top))
(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/entry_banks/main.cpp').read_bytes())
cmd = [a.verilator,'--cc','--exe','--build','-j','1','--threads','1','--assert',
       '-DSYNTHESIS','-Wno-fatal','--top-module','tb_entry_banks','--Mdir',str(out/'obj'),
       '-CFLAGS','-std=c++20 -O1',str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),
       str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]
def capacity():
    rows = [s.split(None,3) for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'], text=True).splitlines()[1:]]
    parent = {int(pid):int(ppid) for pid,ppid,_,_ in rows}
    def ancestors(pid):
        seen=set()
        while pid in parent and pid not in seen: seen.add(pid); pid=parent[pid]
        return seen
    heavy={int(pid) for pid,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census')) or c in ('cc1plus','cc1','lto1')}
    leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other} for other in heavy)}
    foreign=[pid for pid in leaves if os.getpid() not in ancestors(pid)]
    with (out/'capacity.jsonl').open('a') as f: f.write(json.dumps({'time':time.time(),'foreign':foreign,'max_foreign':2})+'\n')
    return len(foreign)<=2
def run(cmd, name):
    while not capacity(): print('WAIT global<=3', flush=True); time.sleep(5)
    with (out/name).open('w') as log:
        return subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT).returncode
rc=run(cmd,'build.log')
if rc: raise SystemExit('build failed '+str(rc))
print('BUILD_PASS', flush=True); phase('entrybank BUILD_PASS; scoped consumer relation running, mutant='+str(a.mutant))
rc=run([str(out/'obj/Vtb_entry_banks')], 'run.log')
receipt={'before':a.before,'before_sha256':hashlib.sha256(old.encode()).hexdigest(),
         'candidate_sha256':hashlib.sha256(new.encode()).hexdigest(),
         'command':cmd,'mutant':a.mutant,'exit':rc,'controller':os.getpid(),
         'starttime':starttime,'nice':10,'jobs':1,'threads':1,
         'scope':'actual RAM helper and literal spill consumer; production paths unchanged except entry bank instance',
         'SYNTHESIS':'excludes only old simulation shadow bookkeeping; host has independent full40/queue scoreboard'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
log=(out/'run.log').read_text();print(log,flush=True)
if (rc==0)==a.mutant: raise SystemExit('unexpected proof verdict')
if a.mutant and 'entry full40 bank/selector mismatch' not in log: raise SystemExit('wrong mutant failure')
phase('entrybank component terminal PASS, mutant='+str(a.mutant))
