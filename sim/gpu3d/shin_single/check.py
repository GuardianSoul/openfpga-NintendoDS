#!/usr/bin/env python3
"""Shared-table actual source pair: public events/order/cycles, no old phase identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='8ad7034b376ba0a117f5855e931d2e9784856e00')
p.add_argument('--mutant',action='store_true');p.add_argument('--cancel-only',action='store_true')
p.add_argument('--accepted-mutant',action='store_true');p.add_argument('--late-table',action='store_true');a=p.parse_args()
if a.accepted_mutant:a.mutant=True
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
status=out/'status.json'
def phase(s,active=1):
    r=json.loads(status.read_text())if status.exists()else{};r.update(phase=s,worker=dict(host='Laptop',active=active,controller_pid=os.getpid(),nice=10,jobs=1,threads=1),updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    b=json.dumps(r,indent=2)+'\n';assert len(b.encode())<=2048;t=status.with_suffix('.json.tmp');t.write_text(b);os.replace(t,status)
phase('ShinSingle source-pair build; mutant='+str(a.mutant))
print('SHIN_SINGLE_PID',os.getpid(),'NI10/j1/t1',flush=True)
H=lambda b:hashlib.sha256(b).hexdigest()
fn='rtl/gpu3d/gpu3d_gxlight.sv';old=subprocess.check_output(['git','show',a.before+':'+fn],cwd=ROOT).decode();new=(ROOT/fn).read_text()
if a.mutant:
    needle="4'd8: shin_sel=2'd2;";assert new.count(needle)==1
    new=new.replace(needle,"4'd8: shin_sel=2'd3; // actual wrong table address-owner fault",1)
def unit(s,n):
    return s[s.index('module gpu3d_gxlightp #('):].split('endmodule',1)[0].replace('module gpu3d_gxlightp #(','module '+n+' #(',1)+'endmodule\n'
(out/'before.sv').write_text(''.join(unit(old,'light_before'+str(i))for i in range(4)))
pair=(new[new.index('module gpu3d_gxlight_pair18 ('):].split('endmodule',1)[0]+'endmodule\n')if 'module gpu3d_gxlight_pair18 ('in new else''
(out/'after.sv').write_text(''.join(unit(new,'light_after'+str(i))for i in range(4))+new[new.index('module gpu3d_gxlight_products ('):]+new[new.index('module gpu3d_gxlight_packed18 ('):].split('endmodule',1)[0]+'endmodule\n'+pair)
top=['''module tb_light_products(
input logic clk,clk2,rst,we,start,fast,hold,cancel,material_valid,input logic[3:0]start_mask,input logic[10:0]wa,
input logic[31:0]wd,material_word,input logic[1:0]material_kind,input logic[29:0]nrm,
output logic[3:0]busy,cw,cv,output logic[14:0]cvd[4],output logic[31:0]cwd[4],
output logic[10:0]cwa[4],output logic[29:0]nr[4],output logic[1:0]state[4],
output logic[2:0]count[4],wn[4],output logic[3:0]lm[4]);''']
outs=dict(busy=1,cw=1,cv=1,cvd=15,cwd=32,cwa=11,nr=30)
ins='clk clk2 rst we start fast hold abort material_valid wa wd material_word material_kind nrm'.split()
for i in range(4):
    for side in ['a','b']:
        for n,w in outs.items():top.append(f'wire[{w-1}:0]{n}_{i}{side};')
        con=[f'.{n}('+('start&&start_mask['+str(i)+']'if n=='start'else'cancel'if n=='abort'else n)+')'for n in ins]
        con += [f'.{n}({n}_{i}{side})'for n in outs]
        extra=",.SHARED5(1'b1)"+(",.PACKED18(1'b1)"if side=='b'else'')
        top.append(f'light_{"before"if side=="a"else"after"}{i} #(.MAT_PAR({i//2}),.NOWR({i%2}){extra}) {side}{i}('+','.join(con)+');')
    for n in outs:top.append(f'assign {n}[{i}]={n}_{i}b;')
    for n,k in [('state','st'),('count','cnt'),('wn','wn'),('lm','lm')]:top.append(f'assign {n}[{i}]=b{i}.{k};')
    top.append(f'''always @(negedge clk2)begin
if({{busy_{i}a,cw_{i}a,cv_{i}a,nr_{i}a,a{i}.st,a{i}.cnt,a{i}.wn,a{i}.lm}}!=={{busy_{i}b,cw_{i}b,cv_{i}b,nr_{i}b,b{i}.st,b{i}.cnt,b{i}.wn,b{i}.lm}})$fatal(1,"shin{i} control/event mismatch");
if(!rst&&!cancel)begin
if(cv_{i}a&&cvd_{i}a!==cvd_{i}b)$fatal(1,"shin{i} visible color mismatch old=%04x new=%04x",cvd_{i}a,cvd_{i}b);
if(cw_{i}a&&{{cwa_{i}a,cwd_{i}a}}!=={{cwa_{i}b,cwd_{i}b}})$fatal(1,"shin{i} visible RFwrite mismatch");
for(int c=0;c<3;c++)begin
if(a{i}.memi[c]!==b{i}.memi[c]||a{i}.mdif_cache[c]!==b{i}.mdif_cache[c]||a{i}.mamb_cache[c]!==b{i}.mamb_cache[c]||a{i}.mspe_cache[c]!==b{i}.mspe_cache[c])$fatal(1,"shin{i} architectural material mismatch");
end
for(int k=0;k<16;k++)if(a{i}.vec[k]!==b{i}.vec[k])$fatal(1,"shin{i} vector state mismatch");
for(int l=0;l<4;l++)begin
for(int k=0;k<16;k++)if(a{i}.lt[l][k]!==b{i}.lt[l][k])$fatal(1,"shin{i} light state mismatch");
end
end
end''')
if a.accepted_mutant:
    # Defer only the early advertised data checks. Control, imported inputs,
    # timing and address checks remain, so the fault must reach an actual
    # accepted SYS colour/RF edge rather than the preceding valid interval.
    for i in range(4):
        early=f'if(cv_{i}a&&cvd_{i}a!==cvd_{i}b)$fatal(1,"shin{i} visible color mismatch old=%04x new=%04x",cvd_{i}a,cvd_{i}b);'
        earlyrf=f'if(cw_{i}a&&{{cwa_{i}a,cwd_{i}a}}!=={{cwa_{i}b,cwd_{i}b}})$fatal(1,"shin{i} visible RFwrite mismatch");'
        assert sum(s.count(early) for s in top)==1
        assert sum(s.count(earlyrf) for s in top)==1
        top=[s.replace(early,'').replace(earlyrf,'') for s in top]
        top.append(f'''always @(posedge clk) if(!rst&&!cancel)begin
if(cv_{i}a&&cvd_{i}a!==cvd_{i}b)$fatal(1,"shin{i} ACCEPTED CV SYS edge old=%04x new=%04x",cvd_{i}a,cvd_{i}b);
if(cw_{i}a&&!we&&{{cwa_{i}a,cwd_{i}a}}!=={{cwa_{i}b,cwd_{i}b}})$fatal(1,"shin{i} ACCEPTED RF SYS edge");
end''')
top.append('endmodule\n');(out/'wrapper.sv').write_text('\n'.join(top))
actor=(ROOT/'sim/gpu3d/light_five/main.cpp').read_text()
if a.late_table:
    # New storage-specific actor: make four distinct, observable table
    # indices and table writes on the final DLY SYS edge. The independent
    # color model sees the original SYS write semantics.
    needle='for(unsigned job=0;job<(cancel_only?128U:1152U);++job){'
    setup="""defaults();wr(0xd3,4);wr(0xe1,1);
 for(unsigned l=0;l<4;l++){wr(0x100+16*l+3,512+4*l);for(unsigned c=0;c<3;c++)wr(0x104+16*l+c,31);}
 for(unsigned c=0;c<3;c++){wr(0x158+c,0);wr(0x15b+c,0);wr(0x15e + c,31);wr(0x161+c,0);}
 d.nrm=256U<<20;d.fast=1;d.start=1;cycle();d.start=0;++starts;while(d.busy)cycle();
 """
    assert actor.count(needle)==1;actor=actor.replace(needle,setup+needle)
    needle='wr(0xe1,job&1);';assert actor.count(needle)==1
    actor=actor.replace(needle,'wr(0xe1,(job>>1)&1);')
    needle='d.wd=random();++late;';assert actor.count(needle)==1
    actor=actor.replace(needle,'d.wd=random();++late;if(d.count[0]==2){d.wa=0x180;d.wd=(job*17+33)&255;++late_table;}')
    needle='uint64_t clocks=0,';assert actor.count(needle)==1
    actor=actor.replace(needle,'uint64_t late_table=0;uint64_t clocks=0,')
    actor=actor.rsplit('}',1)[0]+'if(!late_table)throw std::runtime_error("no finalDLY table writes");std::printf("FINAL_DLY_TABLE_WRITES=%llu\\n",(unsigned long long)late_table);\n}'+actor.rsplit('}',1)[1]
if a.accepted_mutant:
    needle='!valid[i]||d.cvd[i]!=expected[i]';assert actor.count(needle)==1
    actor=actor.replace(needle,'!valid[i]')
    needle='||d.cwd[i]!=((color<<12)|4095)';assert actor.count(needle)==1
    actor=actor.replace(needle,'')
(out/'main.cpp').write_text(actor)
files=[ROOT/'rtl/gpu3d/gpu3d_ram.sv',out/'before.sv',out/'after.sv',out/'wrapper.sv',out/'main.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_light_products','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS','-std=c++20 -O1']+list(map(str,files))
(out/'load.txt').write_text(subprocess.check_output(['uptime'],text=True))
with(out/'build.log').open('w')as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'build failed'
print('SHIN_SINGLE_BUILD_PASS',flush=True);phase('ShinSingle public source-pair running; mutant='+str(a.mutant))
exe=out/'obj/Vtb_light_products'
with(out/'run.log').open('w')as f:r=subprocess.run([str(exe)]+(['--cancel-only']if a.cancel_only else[]),stdout=f,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text()
rec=dict(before=a.before,mutant=a.mutant,cancel_only=a.cancel_only,accepted_mutant=a.accepted_mutant,late_table=a.late_table,PID=os.getpid(),command=cmd,exit=r.returncode,
         before_sha256=H(old.encode()),candidate_sha256=H(new.encode()),binary_sha256=H(exe.read_bytes()),
         files_sha256={str(f):H(f.read_bytes())for f in files},output=log,
         scope='All4 MAT_PAR/NOWR configurations, public event/order/cycle edge equivalence and independent exact color/RF model under component legal-input protocol. Actual caller sampling proof remains separate. No old internal NT/DOT or material-cache phase identity. PACKED18 defaults0; MAT_PAR0 fallback remains five-lane.',
         negative_exceptions='Accepted-only negative defers early advertised color/RF data and their matching actor data comparisons, retaining control/valid/address/time/import checks; literal posedge clk accepted CV/RF comparisons detect the actual RTL wrong-lane fault.'if a.accepted_mutant else None)
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n');print(log,flush=True)
phase('ShinSingle source-pair terminal rc='+str(r.returncode)+' mutant='+str(a.mutant),0)
if a.mutant:assert r.returncode!=0 and any(t in log for t in (['ACCEPTED CV SYS edge','ACCEPTED RF SYS edge']if a.accepted_mutant else['visible color mismatch','visible RFwrite mismatch']))
else:assert r.returncode==0
