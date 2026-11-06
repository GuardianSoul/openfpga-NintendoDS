#!/usr/bin/env python3
"""Generate the input-only bind, field ABI and focused fixture. No build/run."""
import argparse,hashlib,json,re,sys
from pathlib import Path
from schema import FIELDS,GROUPS,BITS
HERE=Path(__file__).resolve().parent
def generate(dst):
 dst.mkdir(parents=True,exist_ok=True)
 root=HERE.parents[2];compiled=json.loads((root/'build/turn69r1/candidate-host/compiled-inputs.json').read_text());used=set();recorders={}
 for n,h in compiled.items():
  p=Path(n)
  if p.suffix not in ['.sv','.v','.cpp','.cc']:continue
  data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==h
  ids={int(x)for x in re.findall(rb'pair_capture_emit\(\s*(\d+)',data)}
  if ids:used|=ids;recorders[n]=dict(sha256=h,event_ids=sorted(ids))
 assert not used&set(range(64,85)),used
 (dst/'namespace.json').write_text(json.dumps(dict(existing_ids=sorted(used),new_ids=list(range(64,85)),compiled_recorders=recorders),indent=2)+'\n')
 header=['#pragma once',f'constexpr unsigned PUB70_BITS={BITS};']
 for f in FIELDS:header += [f'#define O_{f["name"]} {f["offset"]}',f'#define W_{f["name"]} {f["width"]}']
 header+=['struct Pub70Group { unsigned kind,o,n; };','constexpr Pub70Group pub70_groups[] = {']
 for k,rows in GROUPS.items():header+=[f'{{{k},{rows[0]["offset"]},{sum(f["width"]for f in rows)}}},']
 header+=['};'];(dst/'fields.h').write_text('\n'.join(header)+'\n')
 schema=dict(event_namespace={k:k+5 for k in range(59,80)},bits=BITS,fields=FIELDS,groups={k:dict(offset=rows[0]['offset'],bits=sum(f['width']for f in rows),fields=[f['name']for f in rows])for k,rows in GROUPS.items()},encoding='fieldsLSBfirst; addr/data/x/y/z as192payloadbits; port high16 subtype low16 chunk')
 (dst/'schema.json').write_text(json.dumps(schema,indent=2)+'\n')
 sv=f'''// Generated read-only observer; no output/inout/ref ports or DUT assignments.
module nds_publication70_observer(input logic clk,input bit enabled,input bit [{BITS-1}:0] values);
 timeunit 1ps;timeprecision 1ps;
 import "DPI-C" function void publication70_tick(input longint unsigned t,input bit [{BITS-1}:0] v);
 always @(posedge clk) if(enabled) publication70_tick($time,values);
endmodule
bind tb_ds_pocket nds_publication70_observer u_publication70 (
 .clk(dut.clk_sys),.enabled(u_scene_capture.enabled && !u_scene_capture.trace_stop),
 .values({{
'''
 sv+=',\n'.join(f" {f['width']}'({f['expression']})"for f in reversed(FIELDS))+'\n }));\n'
 assert not re.search(r'\b(output|inout|ref|force|release|assign|export)\b',sv.split('\n',1)[1])
 assert all(re.fullmatch(r'[A-Za-z0-9_.$\[\] :?!{}<>=|&+\-\',()]+',f['expression'])for f in FIELDS)
 (dst/'observer.sv').write_text(sv)
 (dst/'observer.cpp').write_bytes((HERE/'observer.cpp').read_bytes())
 unit=r'''#include <array>
#include <cstdint>
#include <cstdio>
#include "fields.h"
extern "C" void publication70_tick(unsigned long long,const uint32_t*);
extern "C" void publication70_boundary(int,unsigned long long);
struct Event{uint64_t t;uint32_t k,p,a,d,x,y;uint64_t z;};static_assert(sizeof(Event)==40);
FILE*sink;unsigned long long events=0;
extern "C" void pair_capture_emit(unsigned k,unsigned p,unsigned long long t,unsigned a,unsigned d,unsigned x,unsigned y,unsigned long long z){Event e{t,k,p,a,d,x,y,z};fwrite(&e,40,1,sink);events++;}
void put(uint32_t*v,unsigned o,unsigned n,uint64_t d){for(unsigned j=0;j<n;j++){auto&m=v[(o+j)/32];unsigned b=(o+j)%32;m=(m&~(1u<<b))|(uint32_t((d>>j)&1)<<b);}}
#define S(n,x) put(v.data(),O_##n,W_##n,(x))
int main(int argc,char**argv){sink=fopen(argv[1],"wb");bool on=argc<3;std::array<uint32_t,(PUB70_BITS+31)/32>v{};std::array<uint32_t,1024>top{},st{};std::array<uint32_t,512>rb{};uint32_t tq=0,sq=0,rq=0;uint64_t hash=1469598103934665603ULL;
 for(unsigned i=0;i<4096;i++){
  unsigned ta=i%1024,sa=(i*3)%1024,ra=i%512;bool wr=i<2048;uint32_t td=((i+1)*0x45d9f3b)&0x7fffff,sd=((i+7)*0x9e3779b9)&0x7fffff,rd=((i+19)*0x85ebca6b)&0x7fffff;
  S(top_we,wr);S(top_wa,ta);S(top_lo,td);S(top_mid,0);S(top_hi,0);S(st_we,wr);S(st_wa,sa);S(st_wd,sd);S(st_ra,sa);S(st_q,sq);S(rb_we,wr);S(rb_wa,ra);S(rb_wd,rd);S(rb_ra,ra);S(rb_q,rq);S(ll_ack,1);S(ll_slot,ta/256);S(ll_x,ta%256);S(ll_q,tq);
  S(j_valid,i%3==0);S(j_ready,1);S(j_credit,1);S(j_used,i%1100);S(j_req,1);S(j_ack,i%2==0);S(j_word,(i/2)%8);S(q_req,1);S(q_ack,i%3==0);S(q_addr,(i/3)%8);S(draw_gen,23846);S(ps_y,131);S(ps_req,i==5);S(ps_v,i==55);S(ps_r,1);S(ps_t,i==55?3:0);S(f_st,i%13);S(fr_st,i%9);S(r_phase,i%7);S(pipe_mask,i%1024);
  uint64_t t=357000000000ULL+14919ULL*i;if(on)publication70_tick(t,v.data());
  tq=top[ta];sq=st[sa];rq=rb[ra];if(wr){top[ta]=td;st[sa]=sd;rb[ra]=rd;}
  for(auto x:{tq,sq,rq}){hash^=x;hash*=1099511628211ULL;}
 }
 if(on)publication70_boundary(1,357000000000ULL+14919ULL*4096);fclose(sink);printf("PASS_PARENT_OBSERVABLE_HASH %016llx events %llu\n",(unsigned long long)hash,events);
}
'''
 (dst/'unit.cpp').write_text(unit)
 contract=dict(kind='STRUCTURAL_NO_FEEDBACK_EQUIVALENCE',module_ports='input only',DPI='void sink, const input vector; no DUT API',production_edits=0,fields=len(FIELDS),bits=BITS,namespace='64..84, all compiled recorders checked',files={n:hashlib.sha256((dst/n).read_bytes()).hexdigest()for n in ['observer.sv','observer.cpp','fields.h','schema.json','unit.cpp','namespace.json']},scope='Source-level input-only composition plus event/RAM OLD_DATA fixture; native output equality remains mandatory, not claimed here.')
 (dst/'source-contract.json').write_text(json.dumps(contract,indent=2)+'\n');print(json.dumps(contract))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('destination',type=Path);generate(p.parse_args().destination)
