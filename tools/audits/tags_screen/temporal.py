"""Source completion projection, row/key ownership, collision sensitivity and cost."""
from pathlib import Path
import ast,json,re,fcntl,os,collections
P=Path(__file__).with_name('screen.py');tree=ast.parse(P.read_text());nodes=[]
for n in tree.body:
 if isinstance(n,ast.Expr)and isinstance(n.value,ast.Call)and isinstance(n.value.func,ast.Name)and n.value.func.id=='status':break
 nodes.append(n)
ns={'__file__':str(P.resolve())};exec(compile(ast.Module(body=nodes,type_ignores=[]),str(P),'exec'),ns)
globals().update({k:v for k,v in ns.items()if k not in ['__name__','__file__']})
result=json.loads((O/'result.json').read_text())
# Extract three unconditional completion cases verbatim except projecting away
# assignments to state not used by this local one-step theorem.
parts=[]
for name,end in [('S_TAGW','S_ITAG'),('S_ITAGW','S_PFCHK'),('S_INV',None)]:
 a=s.index('        '+name+':',s.index('      // ---- the machine'))
 b=s.index('        '+end+':',a)if end else s.index('      endcase',a)
 text=s[a:b];text=re.sub(r'\b(?!st\b)[A-Za-z_][A-Za-z_0-9]*(?:\[[^\]]+\])?\s*<=.*?;','',text,flags=re.S);text=text.replace('st <=','next_st =');parts.append(text)
completion='''module completion(input[3:0]st,input[2:0]dp_kind,input sw_more_d,sw_more_i,iline,pf_run,dp_v,wbuf_v,ev_v,dline,input[31:0]ip_a,input[11:0]inv_n,output reg[3:0]next_st);
'''+const+'''
localparam PF=0;
always @*begin next_st=st;case(st)
'''+''.join(parts)+'''default:next_st=st;endcase end
endmodule
'''
(O/'actual-completion.sv').write_text(completion)
# The relevant commit successors are actual source cases. Other states use an
# explicit source-derived overapproximation of the global control graph.
stateproof='''module ownership(input clk,rst,input[3:0]choose,input more_d,more_i,iline_in,input[7:0]new_dkey,new_ikey,
 input[31:0]new_drow,new_irow,output bad,output[4:0]flags);
'''+const+'''
reg[3:0]st;reg phase,iline;reg d_held,i_held;reg[7:0]dk,ik,sd,si;
reg[31:0]drow,irow,da,ia,save_d,save_i;reg[7:0]dak,iak;
wire bd=(st==S_TAG||st==S_EVRD||st==S_EVRD2||st==S_EVWR||st==S_FILL||st==S_TAGW||((st==S_ITAG||st==S_IFILL||st==S_ITAGW)&&iline)||(st==S_INV&&iline));
wire bi=st==S_ITAG||st==S_IFILL||st==S_ITAGW||(st==S_INV&&!iline);
wire cd=st==S_TAGW,ci=st==S_ITAGW;
wire take_d=st==S_TAG&&phase,take_i=st==S_ITAG&&phase;
wire legal_choose=(st==S_IDLE)?(choose==S_IDLE||choose==S_TAG||choose==S_ITAG||choose==S_INV||choose==S_EVDRN||choose==S_WDRAIN||choose==S_RD1||choose==S_IRD1):
(st==S_TAG&&phase)?(choose==S_TAGW||choose==S_FILL||choose==S_EVRD||choose==S_EVDRN||choose==S_IDLE||choose==S_TAG):
(st==S_ITAG&&phase)?(choose==S_IFILL||choose==S_ITAGW):
(st==S_EVRD)?(choose==S_EVRD||choose==S_EVRD2||choose==S_EVWR):
(st==S_EVRD2)?choose==S_FILL:
(st==S_EVWR)?(choose==S_EVWR||choose==S_EVRD||choose==S_TAGW||choose==S_FILL):
(st==S_FILL)?(choose==S_FILL||choose==S_TAGW):
(st==S_IFILL)?(choose==S_IFILL||choose==S_ITAGW):
(st==S_EVDRN||st==S_WDRAIN||st==S_RD1||st==S_IRD1)?(choose==st||choose==S_IDLE):0;
always @(posedge clk)begin
 if(rst)begin st<=S_IDLE;phase<=0;d_held<=0;i_held<=0;end
 else begin
  // Only captured/synchronously read metadata row is modeled here; writes to
  // other sets are irrelevant. Keys abstract unchanged source set functions.
  da<=drow;ia<=irow;dak<=dk;iak<=ik;
  if(!bd)dk<=new_dkey;if(!bi)ik<=new_ikey;
  if(st==S_IDLE)begin d_held<=0;i_held<=0;iline<=iline_in;drow<=new_drow;irow<=new_irow;end
  if(take_d)begin save_d<=da;sd<=dak;d_held<=1;end
  if(take_i)begin save_i<=ia;si<=iak;i_held<=1;end
  if(cd)begin drow<=new_drow;d_held<=0;st<=more_d?S_TAG:S_IDLE;phase<=0;if(more_d)dk<=new_dkey;end
  else if(ci)begin irow<=new_irow;i_held<=0;st<=more_i?S_ITAG:S_IDLE;phase<=0;if(more_i)ik<=new_ikey;end
  else if(st==S_INV)begin if(iline)drow<=new_drow;else irow<=new_irow;st<=(choose==S_IDLE)?S_IDLE:S_INV;end
  else if((st==S_TAG||st==S_ITAG)&&!phase)phase<=1;
  else if(legal_choose)begin
   if(st==S_TAG&&phase&&(choose==S_TAG||choose==S_IDLE))begin d_held<=0;if(choose==S_TAG)dk<=new_dkey;end
   st<=choose;phase<=0;end
 end
end
// Strengthening relation includes the current synchronous A read; it is
// maintained across the read wait, refill/CMO/eviction and commit boundary.
assign flags={cd&&(!d_held||save_d!=drow||sd!=dk),ci&&(!i_held||save_i!=irow||si!=ik),
 d_held&&bd&&(save_d!=drow||sd!=dk),i_held&&bi&&(save_i!=irow||si!=ik),
 ((st==S_TAG||st==S_ITAG)&&phase)&&((st==S_TAG)?(da!=drow||dak!=dk):(ia!=irow||iak!=ik))};
wire d_need=st==S_EVRD||st==S_EVRD2||st==S_EVWR||st==S_FILL||st==S_TAGW;
wire i_need=st==S_IFILL||st==S_ITAGW;
wire ownership_bad=(d_need&&!d_held)||(i_need&&!i_held)||
(d_held&&(st==S_ITAG||st==S_IFILL||st==S_ITAGW||st==S_INV))||
(i_held&&(st==S_TAG||st==S_EVRD||st==S_EVRD2||st==S_EVWR||st==S_FILL||st==S_TAGW||st==S_INV));
assign bad=|flags||ownership_bad;
endmodule
'''
# Actual response answer blocks with the different poisoned hit and way inputs.
# The state/col implications are local: current write busy, or prior write col.
collision='''module collision(input[3:0]prev,current_st,input[2:0]dp_kind,input more_d,more_i,iline,dline,input[11:0]inv_n,
 input[31:0]ip_a,input prev_dwrite,prev_iwrite,cur_dwrite,cur_iwrite,
 input ho,hn,wo,wn,wr,is_tcm,cp,request_d,request_i,cache_i,cache_d,
 input de_cond,ie_cond,vway,ibuf_hit,rb_hit,output bad);
'''+const+'''
wire[3:0]next_st;wire[3:0]st=(prev_dwrite||prev_iwrite)?next_st:current_st;completion c(prev,dp_kind,more_d,more_i,iline,1'b0,1'b0,1'b0,1'b0,dline,ip_a,inv_n,next_st);
wire allowed_prev_d=(prev==S_TAGW)||(prev==S_INV&&dline);
wire allowed_prev_i=(prev==S_ITAGW)||(prev==S_INV&&!dline);
wire allowed_cur_d=(st==S_TAGW)||(st==S_INV&&dline);
wire allowed_cur_i=(st==S_ITAGW)||(st==S_INV&&!dline);
wire bd=allowed_cur_d,bi=allowed_cur_i;
wire col_d=prev_dwrite,col_i=prev_iwrite;
wire der=de_cond&&!wr&&(st==S_FILL||st==S_TAGW);
wire ier=ie_cond&&!iline&&(st==S_IFILL||st==S_ITAGW);
// Exact cache-relevant priority projection of original answer and F2 gates.
wire do_=cp||is_tcm||der?1'b1:(bd||col_d)?1'b0:wr?1'b1:(cache_d?ho:rb_hit);
wire dn_=cp||is_tcm||der?1'b1:(bd||col_d)?1'b0:wr?1'b1:(cache_d?hn:rb_hit);
wire io_=!request_i||is_tcm?1'b1:cache_i?((ho&&!bi&&!col_i)||ier):ibuf_hit;
wire in_=!request_i||is_tcm?1'b1:cache_i?((hn&&!bi&&!col_i)||ier):ibuf_hit;
wire dway0=der?vway:wo,dway1=der?vway:wn,iway0=ier?vway:wo,iway1=ier?vway:wn;
wire legal=(!prev_dwrite||allowed_prev_d)&&(!prev_iwrite||allowed_prev_i)&&(!cur_dwrite||allowed_cur_d)&&(!cur_iwrite||allowed_cur_i);
wire dt=prev_dwrite||cur_dwrite,it=prev_iwrite||cur_iwrite;
assign bad=legal&&((dt&&request_d&&!cp&&!is_tcm&&(do_!=dn_||(do_&&cache_d&&dway0!=dway1)))||
(it&&request_i&&!is_tcm&&(io_!=in_||(io_&&cache_i&&iway0!=iway1))));
endmodule
'''
# Static source bindings make the control projection's omissions explicit.
for line in ['col_d <= !rst && busy_d;','col_i <= !rst && busy_i;','HUM && st == S_FILL && dp_kind == DK_FILL && !w_we','} else if (busy_d || dp_v || col_d)']:
 if line not in s and line.startswith('}'):continue
 assert line in s,line
for line in ['if (ier) way = vway;',"if (der) begin wd_hit = 1'b1; wd_way = vway; end",'DK_FILL:  st <= S_TAG;','if (ip_cach) st <= S_ITAG;',"else         st <= S_IRD1;",'if (PF && !iline && !pf_run']:
 assert line in s,line
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX);assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
 jobs=[('prefix-capture',prefix,'prep -top prefixproof -flatten\nopt -full\nsat -verify -seq 3 -tempinduct -maxsteps 6 -set-init-zero -prove bad 0\n','Induction step proven: SUCCESS!'),
 ('row-ownership',stateproof,'prep -top ownership -flatten\nopt -full\nsat -verify -seq 4 -tempinduct -maxsteps 10 -set-init-zero -prove bad 0 -show-inputs -show-outputs -dump_json '+str(O/'ownership-witness.json')+'\n','Induction step proven: SUCCESS!'),
 ('mixedport-gates',completion+collision,'prep -top collision -flatten\nopt -full\nsat -verify -prove bad 0 -show-inputs -show-outputs -dump_json '+str(O/'collision-witness.json')+'\n','SUCCESS!')]
 for tag,code,cmd,expect in jobs:
  rc,log=run(tag,code,cmd);ok=rc==0 and expect in log;result['cases']=[x for x in result['cases']if x['tag']!=tag];result['cases'].append(dict(tag=tag,PASS=ok,rc=rc));(O/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(tag,ok,flush=True);assert ok,log[-2300:]
