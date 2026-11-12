#!/usr/bin/env python3
"""Source-extracted initialized binary-state relation, no compiler or DUT."""
from pathlib import Path
import argparse,hashlib,itertools,json,re
P=argparse.ArgumentParser();P.add_argument('--out',type=Path,required=True);A=P.parse_args();HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2]
def need(v,m):
 if not v:raise RuntimeError(m)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def expr(s):
 s=re.sub(r"(\d+)'([bdh])([0-9a-fA-F]+)",lambda m:str(int(m[3],{'b':2,'d':10,'h':16}[m[2]])),s)
 s=re.sub(r'(\w+)\[(\d+):(\d+)\]',lambda m:f'(({m[1]} >> {m[3]}) & {(1<<(int(m[2])-int(m[3])+1))-1})',s)
 return compile(s.replace('&&',' and ').strip(),'<extracted SV>','eval')
def ev(s,**env):return eval(expr(s),{'__builtins__':{}},env)
def unique(pattern,s):
 v=re.findall(pattern,s);need(len(v)==1,'unique source anchor '+pattern);return v[0]
old=(HERE/'reference_video.sv').read_text();new=(ROOT/'rtl/pocket/nds_video.sv').read_text();need(sha(HERE/'reference_video.sv')=='155af22e034df328e194437cb17dbcd6479e273fff4cfea223c16b84ea3efd80','exact6ef fixture')
s=old
for a,b in json.loads((HERE/'rewrite.json').read_text()):need(s.count(a)==1,'rewrite anchor');s=s.replace(a,b)
need(s==new,'all other production bytes unchanged')
block=new[new.index('    always @(posedge clk) begin'):new.index('    assign frame_pulse')];capture=unique(r'if \(line_start\) begin(.*?)end',block.replace('\n',' '));reset=unique(r'if \(reset\) begin(.*?)end',block.replace('\n',' '));need(block.index('if (reset)')>block.index('if (line_start)'),'reset wins')
names=['dl_live','dl_lead','dl_pad','row_phase'];caps=[unique(n+r' <= ([^;]+);',capture)for n in names];resets=[unique(n+r' <= ([^;]+);',reset)for n in names]
oldcaps=unique(r'if \(line_start\) begin hc <= 0; dl <= ([^;]+); end',old);oldreset=unique(r'if \(reset\) begin hc <= 0; dl <= ([^;]+); end',old)
initial=[unique(n+r' = ([^;,]+)',new)for n in names];oldinit=unique(r'reg \[8:0\] dl = ([^;]+);',old)
oldw={n:unique(r'wire '+n+r' = ([^;]+);',old)for n in ['live_line','lead_line','pad_line']};neww={n:unique(r'wire '+n+r' = ([^;]+);',new)for n in oldw};oldm=unique(r'wire \[7:0\] m = ([^;]+);',old)
# Compile extracted expressions once; explicit masks model their declared widths.
cs=list(map(expr,caps));rs=list(map(expr,resets));ows={n:expr(v)for n,v in oldw.items()};nws={n:expr(v)for n,v in neww.items()};om=expr(oldm);oc=expr(oldcaps);orr=expr(oldreset)
e=lambda c,d:eval(c,{'__builtins__':{}},d)
def relation(dl):return (int(e(ows['live_line'],dict(dl=dl))),int(e(ows['lead_line'],dict(dl=dl))),int(dl==195),e(om,dict(dl=dl))&3)
need(tuple(ev(x)for x in initial)==relation(ev(oldinit)),'initialized relation');states=set();trans=pred=addr=0
for dl in range(512):
 state=relation(dl);states.add(state)
 for vc in range(512):
  env=dict(vcount=vc)
  for rst,ls in itertools.product((0,1),repeat=2):
   od=e(orr,env)if rst else(e(oc,env)&511 if ls else dl)
   ns=tuple(e(x,env)&(3 if i==3 else 1)for i,x in enumerate(rs if rst else cs))if rst or ls else state
   need(ns==relation(od),'transition');trans+=1
 for layout in range(4):
  oe=dict(dl=dl,layout=layout);ne=dict(zip(names,state),layout=layout)
  for n in oldw:need(bool(e(ows[n],oe))==bool(e(nws[n],ne)),'visible '+n);pred+=1
 for x in range(256):need(((e(om,dict(dl=dl))&3)<<8|x)==(state[3]<<8|x),'live RAM address');addr+=1
need('live[{m[1:0], live_x[7:0]}]'in old and 'live[{row_phase, live_x[7:0]}]'in new,'actual address wiring')
need(len(states)==10,'reachable representation image')
# Actual module changes output layout only at line2, which clears pad. This
# makes current-layout capture qualification equivalent on ordinary histories;
# the actual negative control uses layout_in instead, not a fabricated witness.
need(re.findall(r'layout <= [^;]+;',new)==['layout <= layout_in;','layout <= gen_layout;'],'layout assignments include gen_layout suffix')
need('if (line_start && vcount == 2) layout <= gen_layout;'in new,'layout transition clears pad')
result=dict(pass_=True,states=512,reachable_encoded_states=len(states),transition_obligations=trans,predicate_obligations=pred,address_obligations=addr,all_four_layout_values=True,source_exact_rewrite=True,reset_priority=True,arbitrary_corrupt_flag_combinations=False,scope='Source-extracted host initialized binary-state relation; no formal compiler equivalence, X/SEU or physical savings claim.',extracted=dict(capture=capture,reset=reset,initial=initial,old_wires=oldw,new_wires=neww),inputs={str(p):sha(p)for p in [Path(__file__),HERE/'rewrite.json',HERE/'reference_video.sv',ROOT/'rtl/pocket/nds_video.sv']})
need(not A.out.exists(),'fresh receipt');A.out.write_text(json.dumps(result,indent=2)+'\n');print('PASS',trans,pred,addr,'states',len(states))
