#!/usr/bin/env python3
"""Fixed-slot arithmetic, private snapshot and context port proof (not frontend).
Original publication oracle must already have passed, including actual faults.
"""
from pathlib import Path
import argparse,importlib.util,json,os,shutil,time
R=Path(__file__).resolve().parents[3];parser=argparse.ArgumentParser();parser.add_argument('--out',required=True);B=R/parser.parse_args().out;S=Path(__file__).with_name('runner.py');sp=importlib.util.spec_from_file_location('es_runner',S);run=importlib.util.module_from_spec(sp);sp.loader.exec_module(run)
proof=json.loads((R/'build/raster-symptoms/edge-span-original-gate.json').read_text());assert proof['result']=='PASS_ORIGINAL_PUBLICATION_AND_TWO_ACTUAL_FAULTS';assert not B.exists();B.mkdir()
s=(R/'rtl/gpu3d/gpu3d_edge_span.sv').read_text();n='s_product<=product;';bad='s_product<=product ^ 54\'($test$plusargs("wrong_slot_result"));';assert s.count(n)==1;s=s.replace(n,bad)
n2='.raddr({held_slot,!middle})';b2='.raddr({held_slot ^ $test$plusargs("wrong_snapshot_owner"),!middle})';assert s.count(n2)==1;s=s.replace(n2,b2)
n3='.wdata(wd[owner])';b3='.wdata(wd[owner ^ int\'($test$plusargs("wrong_context_owner"))])';assert s.count(n3)==2;s=s.replace(n3,b3)
assert s.replace(bad,n).replace(b2,n2).replace(b3,n3)==(R/'rtl/gpu3d/gpu3d_edge_span.sv').read_text();(B/'probe.sv').write_text(s);shutil.copyfile(R/'rtl/gpu3d/gpu3d_ram.sv',B/'gpu3d_ram.sv')
(B/'tb.sv').write_text('''module es_tb(input logic clk,clk2,rst,
input logic[26:0]e_ma,e_mb,s_ma,s_mb,input logic signed[24:0]e_a,e_b,s_a,s_b,
output logic[53:0]e_product,e_registered_product,s_product,
output logic[24:0]e_difference,e_minimum,s_difference,s_minimum,
output logic e_less,e_equal,s_less,s_equal,
input logic[31:0]e_add_a,e_add_b,s_add_a,s_add_b,input logic e_carry,output logic[31:0]e_sum,s_sum,
input logic sw,ws,side,req,rs,tr,input logic[3:0]item,input logic[115:0]wd,
output logic[24:0]a,b,output logic valid,slot_out,output logic[3:0]item_out,
input logic[1:0]cwe,input logic[1:0][4:0]wa,ra,rb,input logic[1:0][63:0]cwd,
output logic[1:0][63:0]qa,qb);
gpu3d_es_math2x math(.clk,.clk2,.e_ma,.e_mb,.s_ma,.s_mb,.e_a,.e_b,.s_a,.s_b,.e_add_a,.e_add_b,.s_add_a,.s_add_b,.e_carry,.e_sum,.s_sum,.e_product,.e_registered_product,.s_product,.e_difference,.e_minimum,.s_difference,.s_minimum,.e_less,.e_equal,.s_less,.s_equal);
gpu3d_es_vertex_snapshot snap(.clk,.clk2,.rst,.we(sw),.write_slot(ws),.write_side(side),.req,.read_slot(rs),.toon_red(tr),.item,.wdata(wd),.a,.b,.valid,.slot_out,.item_out);
gpu3d_es_context ctx(.clk2,.we(cwe),.wa,.ra,.rb,.wd(cwd),.qa,.qb);
endmodule
''')
(B/'main.cpp').write_text(r'''#include "Ves_tb.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
static int32_t sx(uint32_t v,unsigned n){return int32_t(v<<(32-n))>>(32-n);}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);Ves_tb m;uint64_t state=0xe5a315acbf127ULL;
auto rnd=[&](){state^=state<<13;state^=state>>7;state^=state<<17;return uint32_t(state);};
std::array<std::array<std::array<uint32_t,4>,2>,2>vert{};uint64_t ctx[2][32]{};bool known[2][32]{};uint64_t math_checks=0,snapshot_checks=0,context_checks=0,dual_writes=0,late=0;
auto itemval=[](const std::array<uint32_t,4>&v,unsigned k,bool tr){
 auto bits=[&](unsigned lo,unsigned n){uint64_t w=uint64_t(v[lo/32])|(lo/32+1<4?uint64_t(v[lo/32+1])<<32:0);return uint32_t(w>>(lo%32))&((1u<<n)-1);};
 switch(k){case 0:return bits(41,16);case 6:return bits(17,24);case 7:return bits(57,9)&0x1f0u;case 1:return tr?(bits(57,9)&0x1f0u):bits(57,9);case 2:return bits(66,9);case 3:return bits(75,9);case 4:return uint32_t(sx(bits(84,16),16))&0x1ffffffu;default:return uint32_t(sx(bits(100,16),16))&0x1ffffffu;}
};
auto fail=[&](const char*s,uint64_t c){printf("ES_SUBASSEMBLY_FAIL %s cycle=%llu\n",s,(unsigned long long)c);throw std::runtime_error(s);};
auto math_set=[&](){m.e_ma=rnd()&0x7ffffff;m.e_mb=rnd()&0x7ffffff;m.s_ma=rnd()&0x7ffffff;m.s_mb=rnd()&0x7ffffff;m.e_a=rnd()&0x1ffffff;m.e_b=rnd()&0x1ffffff;m.s_a=rnd()&0x1ffffff;m.s_b=rnd()&0x1ffffff;m.e_add_a=rnd();m.e_add_b=rnd();m.s_add_a=rnd();m.s_add_b=rnd();m.e_carry=rnd()&1;};
uint64_t previous_span=0;uint32_t sd=0,sm=0,ssum=0;bool sl=0,se=0,span_live=false;
bool pending=false;unsigned pslot=0,pitem=0;bool ptr=false;
m.clk=0;m.clk2=0;m.rst=1;m.sw=0;m.req=0;m.cwe=0;m.eval();
try{for(unsigned cycle=0;cycle<100000;cycle++){
 math_set();m.rst=cycle<8||cycle%1021==0;
 if(pending&&!m.rst){if(!m.valid||m.slot_out!=pslot||m.item_out!=pitem||m.a!=itemval(vert[pslot][0],pitem,ptr)||m.b!=itemval(vert[pslot][1],pitem,ptr))fail("snapshot_owner_item",cycle);snapshot_checks++;}
 // Write only the inactive previous owner; reads and writes may overlap
 // across the two private edge slots without touching a live record.
 m.req=cycle>=8&&cycle%7!=0;m.rs=rnd()&1;m.item=rnd()%8;m.tr=rnd()&1;
 m.sw=cycle<4||cycle%5==0;m.ws=cycle<4?cycle/2:1-pslot;m.side=cycle<4?cycle%2:rnd()&1;
 if(pending&&m.ws==pslot)m.sw=0;
 for(int i=0;i<4;i++)m.wd[i]=rnd();m.wd[3]&=0xfffff;
 unsigned ns=m.rs,ni=m.item;bool nt=m.tr,npend=m.req&&!m.rst;
 auto context_inputs=[&](){m.cwe=rnd()&3;m.wa=0;m.ra=0;m.rb=0;for(int j=0;j<2;j++){unsigned w=rnd()%32,a=(w+1+rnd()%15)%32,b=(w+17+rnd()%14)%32;m.wa|=w<<(j*5);m.ra|=a<<(j*5);m.rb|=b<<(j*5);m.cwd[j*2]=rnd();m.cwd[j*2+1]=rnd();}};
 auto context_after=[&](){for(int j=0;j<2;j++){unsigned w=(m.wa>>(j*5))&31,a=(m.ra>>(j*5))&31,b=(m.rb>>(j*5))&31;if(m.cwe>>j&1){ctx[j][w]=uint64_t(m.cwd[j*2])|(uint64_t(m.cwd[j*2+1])<<32);known[j][w]=true;}uint64_t va=uint64_t(m.qa[j*2])|(uint64_t(m.qa[j*2+1])<<32),vb=uint64_t(m.qb[j*2])|(uint64_t(m.qb[j*2+1])<<32);if((known[j][a]&&va!=ctx[j][a])||(known[j][b]&&vb!=ctx[j][b]))fail("context_owner",cycle);context_checks+=known[j][a]+known[j][b];}if(m.cwe==3)dual_writes++;};
 context_inputs();m.clk=0;m.clk2=0;m.eval();uint64_t ep=uint64_t(m.e_ma)*m.e_mb;int32_t ea=sx(m.e_a,25),eb=sx(m.e_b,25);uint32_t ed=uint32_t(ea<eb?eb-ea:ea-eb)&0x1ffffffu,emin=uint32_t(ea<eb?ea:eb)&0x1ffffffu;
 if(m.e_product!=ep||m.e_difference!=ed||m.e_minimum!=emin||m.e_less!=(ea<eb)||m.e_equal!=(ea==eb)||m.e_sum!=uint32_t(m.e_add_a+m.e_add_b+m.e_carry))fail("edge_before_SYS",cycle);
 m.clk=1;m.clk2=1;m.eval();if(m.e_registered_product!=ep)fail("registered_edge_date",cycle);math_checks+=2;
 if(m.sw)for(int i=0;i<4;i++)vert[m.ws][m.side][i]=m.wd[i];context_after();
 if(span_live&&(m.s_product!=previous_span||m.s_difference!=sd||m.s_minimum!=sm||m.s_less!=sl||m.s_equal!=se||m.s_sum!=ssum))fail("span_changed_at_SYS",cycle);
 // SYS producers may change after E. M consumes this span context once.
 math_set();context_inputs();uint64_t sp=uint64_t(m.s_ma)*m.s_mb;int32_t sa=sx(m.s_a,25),sb=sx(m.s_b,25);sd=uint32_t(sa<sb?sb-sa:sa-sb)&0x1ffffffu;sm=uint32_t(sa<sb?sa:sb)&0x1ffffffu;sl=sa<sb;se=sa==sb;ssum=m.s_add_a+m.s_add_b;
 m.clk2=0;m.eval();m.clk=0;m.clk2=1;m.eval();if(m.s_product!=sp||m.s_difference!=sd||m.s_minimum!=sm||m.s_less!=sl||m.s_equal!=se||m.s_sum!=ssum)fail("span_middle_owner",cycle);context_after();previous_span=sp;span_live=true;math_checks++;
 m.clk2=0;m.eval();m.s_ma^=0x7ffffff;m.s_mb^=0x3fffff;m.s_a^=0x1555555;m.s_b^=0xaaaaaa;m.eval();late++;
 if(m.s_product!=previous_span||m.s_sum!=ssum)fail("late_span_hold",cycle);pending=npend;pslot=ns;pitem=ni;ptr=nt;
 }
 if(snapshot_checks<50000||context_checks<500000||dual_writes<10000)fail("coverage",100000);
 printf("PASS_ES_SUBASSEMBLY SYS100000 math%llu snapshots%llu context%llu dualWrites%llu lateSpan%llu\n",(unsigned long long)math_checks,(unsigned long long)snapshot_checks,(unsigned long long)context_checks,(unsigned long long)dual_writes,(unsigned long long)late);m.final();return 0;
}catch(const std::exception&){return 1;}}
''')
files=['probe.sv','gpu3d_ram.sv','tb.sv','main.cpp'];run.put(B/'snapshot.json',dict(at=time.time(),source_sha256=run.sha(R/'rtl/gpu3d/gpu3d_edge_span.sv'),original_gate_sha256=run.sha(R/'build/raster-symptoms/edge-span-original-gate.json'),inputs={n:run.sha(B/n)for n in files},inverse_probe_exact=True,scope='Isolated subassembly; random sums/carry, known-only context rows; no zero-init assumption; context read-during-current-write addresses excluded. Native context RAW forwarding and full frontend remain pending.'))
for n in files:(B/n).chmod(0o444)
V='build/tools/oss-cad-suite/bin/verilator';cmd=[V,'--cc','--exe','--build','--no-timing','--assert','-j','1','--threads','1','-Wno-fatal','--compiler','clang','-CFLAGS','-std=c++20 -O1','-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','es_tb','--Mdir',B/'obj',*[B/n for n in files]]
rc,t=run.worker(B,'build',cmd,build=True);assert rc==0,t[-3000:];run.put(B/'model.json',dict(sha256=run.sha(B/'obj/Ves_tb'),snapshot_sha256=run.sha(B/'snapshot.json')))
results={}
for name,args,needle in [('positive',[],None),('result-owner',['+wrong_slot_result'],'span_middle_owner'),('snapshot-owner',['+wrong_snapshot_owner'],'snapshot_owner_item'),('context-owner',['+wrong_context_owner'],'context_owner')]:
 rc,t=run.worker(B,name,[B/'obj/Ves_tb',*args]);good=(rc!=0 and needle in t)if needle else(rc==0 and'PASS_ES_SUBASSEMBLY'in t);results[name]=dict(passed=good,exit=rc,tail=t.splitlines()[-5:]);run.put(B/'result.json',dict(result='IN_PROGRESS',cases=results));assert good,t[-3000:]
run.put(B/'result.json',dict(result='PASS_UNCONNECTED_SUBASSEMBLY',cases=results,remaining='Full frontend integration, controller/RF RAW/epoch contracts, native RAM and strictFAST timing, wholearea/game. No savings claim.'));print('PASS_UNCONNECTED_SUBASSEMBLY')
