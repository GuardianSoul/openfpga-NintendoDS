"""Private source-bound metadata lemmas and complete changed-cone cost screen."""
from pathlib import Path
import os,json,re,subprocess,hashlib,fcntl,collections
R=Path(__file__).resolve().parents[3];O=R/'build/rc10-tags-screen';O.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');Y='build/tools/oss-cad-suite/bin/yosys'
s=subprocess.check_output(['git','show','af2b633e:rtl/arm/arm9_mem.sv'],cwd=R,text=True)
a=s.index('  always_comb begin\n    // port A defaults:');b=s.index('  // the bus',a)if '  // the bus'in s[a:]else s.index('  always_comb begin\n    b_req',a)
writer=s[a:b];writer=writer[:writer.rfind('  end')+5]
# Original parameter definitions, state enum and set/way address helpers.
enum=s[s.index('  typedef enum logic [3:0] {'):s.index('  st_t',s.index('  typedef enum logic [3:0] {'))]
functions=''
for name in ['sw_dset','sw_iset']:
 pos=s.index(' '+name+'(');a=s.rfind('  function automatic',0,pos);b=s.index('  endfunction',pos)+len('  endfunction');f=s[a:b];f=re.sub(r'return (.*?);',lambda m:name+' = '+m[1]+';',f);functions+=f+'\n'
const="""localparam WAYS=2,WB=1,DSB=8,ISB=8,DTW=19,ITW=19,DLW=21,ILW=20,XD=2,XI=1;localparam MEM1=1,HUM=1;
localparam[2:0]DK_FILL=0,DK_RD1=1,DK_INV_D=2,DK_INV_I=3,DK_LINE=4,DK_DRAIN=5;
"""+enum+functions
header='''module writer(input[3:0]st,input[2:0]dp_kind,input[15:0]cmo_op,input[31:0]xw_a,xw_d,dp_a,dp_val,ip_a,b_rdata,
input[3:0]xw_be,swa_d,swa_i,input xw_way,xw_dc,xw_tag,iline,vway,tlru,ilru,dline,
input[2:0]k,fsd,fsi,input b_ack,input[11:0]inv_n,input[20:0]ev_lane,input[1:0]imask,
output logic[62:0]dt_ad,output logic[59:0]it_ad,output logic[2:0]dt_we,it_we,output logic[7:0]dt_aa,it_aa,output logic busy_d,busy_i);
'''+const+'''
wire[31:0]ia=ip_a;wire pf_run=0;wire[20:0]tlane=ev_lane;
wire[7:0]dset=(dp_kind==DK_LINE&&cmo_op[2:0]==2)?sw_dset(dp_val,swa_d):dp_a[12:5];
logic[10:0]dc_aa,ic_aa;logic[31:0]dc_ad,ic_ad;logic[3:0]dc_we[0:1];logic[1:0]ic_we;
'''
writer_module=header+writer+'\nendmodule\n';(O/'actual-writer.sv').write_text(writer_module)
# Expanded full tag rows omit the syntactically constant D dirty bit, just as2170 did.
func='''
function[20:0]pd(input[40:0]x);begin pd={x[40],x[39],x[28:20],x[19],x[8:0]};end endfunction
function[24:0]pi(input[40:0]x);begin pi={x[40],x[39],x[30:20],x[19],x[10:0]};end endfunction
function[40:0]ed(input[20:0]x);begin ed={x[20],x[19],10'h008,x[18:10],x[9],10'h008,x[8:0]};end endfunction
function[40:0]ei(input[24:0]x);begin ei={x[24],x[23],8'h02,x[22:12],x[11],8'h02,x[10:0]};end endfunction
function eqrow(input[40:0]a,b);begin eqrow=a[40]==b[40]&&a[19]==b[19]&&a[39]==b[39]&&(!a[19]||a[18:0]==b[18:0])&&(!a[39]||a[38:20]==b[38:20]);end endfunction
function vp_d(input[40:0]x);begin vp_d=(!x[19]||x[18:9]==10'h008)&&(!x[39]||x[38:29]==10'h008);end endfunction
function vp_i(input[40:0]x);begin vp_i=(!x[19]||x[18:11]==8'h02)&&(!x[39]||x[38:31]==8'h02);end endfunction
function[1:0]hf(input[40:0]row,input[31:0]a);begin hf={row[39]&&row[38:20]==a[31:13],row[19]&&row[18:0]==a[31:13]};end endfunction
function[1:0]hd(input[20:0]row,input[31:0]a);begin hd={row[19]&&a[31:22]==10'h008&&row[18:10]==a[21:13],row[9]&&a[31:22]==10'h008&&row[8:0]==a[21:13]};end endfunction
function[1:0]hi(input[24:0]row,input[31:0]a);begin hi={row[23]&&a[31:24]==8'h02&&row[22:12]==a[23:13],row[11]&&a[31:24]==8'h02&&row[10:0]==a[23:13]};end endfunction
'''
rowproof='''module rowproof(input[40:0]drow,irow,input[31:0]query,mva,alloc_d,alloc_i,
input[1:0]dwe,iwe,input drwe,irwe,rr_d,rr_i,input[39:0]dnew,inew,input way,input[7:0]setidx,input[2:0]word,
output bad,output[6:0]parts,output actual_fill);
'''+func+'''
wire[20:0]dp=pd(drow);wire[24:0]ip=pi(irow);
reg[40:0]dout,iout;reg[20:0]dpacked;reg[24:0]ipacked;
always @*begin
 dout=drow;iout=irow;dpacked=dp;ipacked=ip;
 for(integer w=0;w<2;w=w+1)begin
  if(dwe[w])begin dout[w*20+:20]=dnew[w*20+:20];dpacked[w*10+:10]={dnew[w*20+19],dnew[w*20+:9]};end
  if(iwe[w])begin iout[w*20+:20]=inew[w*20+:20];ipacked[w*12+:12]={inew[w*20+19],inew[w*20+:11]};end
 end
 if(drwe)begin dout[40]=rr_d;dpacked[20]=rr_d;end
 if(irwe)begin iout[40]=rr_i;ipacked[24]=rr_i;end
 if(!( |dwe)&&!drwe)dpacked=dp;
 if(!( |iwe)&&!irwe)ipacked=ip;
end
wire initial_ok=vp_d(drow)&&vp_i(irow);
wire writes_ok=(!dwe[0]||!dnew[19]||dnew[18:9]==10'h008)&&(!dwe[1]||!dnew[39]||dnew[38:29]==10'h008)&&(!iwe[0]||!inew[19]||inew[18:11]==8'h02)&&(!iwe[1]||!inew[39]||inew[38:31]==8'h02);
wire[18:0]evtag=way?drow[38:20]:drow[18:0];wire evvalid=way?drow[39]:drow[19];
wire[8:0]evtiny=way?dp[18:10]:dp[8:0];
assign parts={initial_ok&&(hf(drow,query)!=hd(dp,query)||hf(irow,query)!=hi(ip,query)),
initial_ok&&(hf(drow,mva)!=hd(dp,mva)||hf(irow,mva)!=hi(ip,mva)),
initial_ok&&evvalid&&{evtag,setidx,word,2'b0}!={10'h008,evtiny,setidx,word,2'b0},
initial_ok&&(way?drow[39]:drow[19])!=(way?dp[19]:dp[9]),
initial_ok&&writes_ok&&!eqrow(dout,ed(dpacked)),
initial_ok&&writes_ok&&!eqrow(iout,ei(ipacked)),
initial_ok&&writes_ok&&(hf(dout,query)!=hd(dpacked,query)||hf(iout,query)!=hi(ipacked,query))};
// A concrete source-style fill: RR selects invalidway0, new validprefix tag
// differs from retained way1, and the observed lookup uses this same set.
assign actual_fill=(dwe==1)&&drwe&&!drow[40]&&!drow[19]&&drow[39]&&rr_d&&dnew[19]&&dnew[18:9]==10'h008&&dnew[18:0]!=drow[38:20]&&query[12:5]==setidx;
assign bad=|parts;
endmodule
'''
update_module="""module packed_update(input[20:0]d_saved,input[24:0]i_saved,input[39:0]d_new,i_new,
input[1:0]d_we,i_we,input d_rr_we,i_rr_we,d_rr,i_rr,output reg[20:0]d_next,output reg[24:0]i_next);
always @*begin
 d_next=d_saved;i_next=i_saved;
 for(integer w=0;w<2;w=w+1)begin
  if(d_we[w])d_next[w*10+:10]={d_new[w*20+19],d_new[w*20+:9]};
  if(i_we[w])i_next[w*12+:12]={i_new[w*20+19],i_new[w*20+:11]};
 end
 if(d_rr_we)d_next[20]=d_rr;if(i_rr_we)i_next[24]=i_rr;
end
endmodule
"""
ra=rowproof.index('reg[40:0]dout');rb=rowproof.index('wire initial_ok',ra)
replacement="""reg[40:0]dout,iout;wire[20:0]dpacked,up_d;wire[24:0]ipacked,up_i;
packed_update u(dp,ip,dnew,inew,dwe,iwe,drwe,irwe,rr_d,rr_i,up_d,up_i);
assign dpacked=(|dwe)||drwe?up_d:dp;assign ipacked=(|iwe)||irwe?up_i:ip;
always @*begin
 dout=drow;iout=irow;
 for(integer w=0;w<2;w=w+1)begin
  if(dwe[w])dout[w*20+:20]=dnew[w*20+:20];
  if(iwe[w])iout[w*20+:20]=inew[w*20+:20];
 end
 if(drwe)dout[40]=rr_d;if(irwe)iout[40]=rr_i;
end
"""
rowproof=update_module+rowproof[:ra]+replacement+rowproof[rb:]
fault=rowproof.replace('d_next=d_saved;','d_next=21\'d0;');assert fault!=rowproof
(O/'actual-packed-update.sv').write_text(update_module)
(O/'fault-packed-update.sv').write_text(update_module.replace('d_next=d_saved;','d_next=21\'d0;'))
(O/'rowproof.sv').write_text(rowproof);(O/'actual-untouchedway-fault.sv').write_text(fault)
# Real capture + response logic establishes the range invariant at pending descriptors.
a=s.index('  // the answer\n');a=s.index('  always_comb begin',a);b=s.index('  always_comb begin\n    if (SLOW)',a);answer=s[a:b]
a=s.index('      // The request registers load');b=s.index('      // an uncached fetch result',a);capture=s[a:b]
# Drop irrelevant CMO receipt writes; keep request kind/address and real ITCM miss gate.
capture=re.sub(r'      if \(wcp_e && cp_isop.*?      end\n','',capture,flags=re.S)
prefix='''module prefixproof(input clk,rst,done_d,done_i,request_f,request_d,kill,input[3:0]st,
input[31:0]w_addr,w_wdata,f_addr,input[19:0]itcm_mask,input mpu_en,ic_en,dc_en,attr,wd_hit,wd_buf,wd_itcm,wd_dtcm,der,rbvalid,wb_full,busy_d,busy_i,col_d,col_i,
input cp,input cp_isop_in,input[2:0]cp_kind_in,input w_we,input[7:0]reqflags,output bad);
'''+const+'''
wire wq_e=request_d&&!kill,wcp_e=cp&&!kill;
// Actual CP kind enumeration excludes DK_FILL: c7 decode sets only INV_D/INV_I/LINE/DRAIN.
wire cp_isop=cp_isop_in;wire[2:0]cp_kind=(cp_kind_in==2)?DK_INV_D:(cp_kind_in==3)?DK_INV_I:(cp_kind_in==4)?DK_LINE:DK_DRAIN;
wire wd_cach=mpu_en&&dc_en&&(w_addr[31:22]==10'h008)&&attr;
wire wd_abort=0;wire[31:0]rbuf_a=w_addr;wire rbuf_v=rbvalid;
logic d_ok,d_abort,wd_store_cache,wd_push,wd_need,wd_tcmw,cp_ok;logic[2:0]wd_kind;
reg dp_v,ip_v;reg[2:0]dp_kind;reg[31:0]dp_a,dp_val,ip_a;reg ip_cach;
wire f_req=request_f;wire i_abort=reqflags[0],i_ok=reqflags[1],itcm_en=reqflags[2],itcm_ld=reqflags[3],f_tm=reqflags[4];localparam SLOW=1;
wire f_cach=mpu_en&&ic_en&&f_addr[31:24]==8'h02;
'''+answer+'''
always @(posedge clk)begin
 if(rst)begin dp_v<=0;ip_v<=0;end
 else begin
'''+capture+'''
 if(!ip_v&&!busy_i)ip_cach<=f_cach;
 if(done_d)dp_v<=0;if(done_i)ip_v<=0;
 end
end
assign bad=(dp_v&&dp_kind==DK_FILL&&dp_a[31:22]!=10'h008)||(ip_v&&ip_cach&&ip_a[31:24]!=8'h02);
endmodule
'''
(O/'prefixproof.sv').write_text(prefix)
result={'source':'af2b633e','source_SHA256':hashlib.sha256(s.encode()).hexdigest(),'actual_writer_SHA256':hashlib.sha256(writer.encode()).hexdigest(),'actual_answer_SHA256':hashlib.sha256(answer.encode()).hexdigest(),'actual_capture_SHA256':hashlib.sha256(capture.encode()).hexdigest(),'cases':[]}
def status(phase,pid):
 d=json.loads(S.read_text());d.update(phase=phase,workers=[dict(host='Desktop',controller=os.getpid(),child=pid,NI=10,jobs=1,threads=1)]);t=S.with_name(S.name+'.'+str(os.getpid())+'.tmp');t.write_text(json.dumps(d));t.replace(S)
def run(tag,code,cmd):
 p=O/(tag+'.sv');p.write_text(code);ys=O/(tag+'.ys');ys.write_text('read_verilog -sv '+str(p)+'\n'+cmd)
 with(O/(tag+'.log')).open('w')as f:
  c=subprocess.Popen([Y,'-Q','-T','-s',str(ys)],stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status(tag,c.pid)
  try:rc=c.wait(timeout=120)
  except subprocess.TimeoutExpired:c.terminate();c.wait();raise
 return rc,(O/(tag+'.log')).read_text()
status('TAGS_SCREEN_WAIT_GLOBAL_MUTEX',os.getpid())
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX);assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
 for tag,code,cmd,expect in [
 ('writer-source',writer_module,'prep -top writer\ncheck -assert\n',''),
 ('prefix-capture',prefix,'prep -top prefixproof -flatten\nopt -full\nsat -verify -seq 3 -tempinduct -maxsteps 6 -set-init-zero -prove bad 0 -show-inputs -show-outputs\n','Induction step proven: SUCCESS!'),
 ('row-equivalence',rowproof,'prep -top rowproof -flatten\nopt -full\nsat -verify -prove bad 0 -show-inputs -show-outputs\n','SUCCESS!'),
 ('actual-untouchedway-fault',fault,'prep -top rowproof -flatten\nopt -full\nsat -falsify -set actual_fill 1 -set iwe 0 -set irwe 0 -prove parts[0] 0 -show-inputs -show-outputs -dump_json '+str(O/'untouchedway-witness.json')+'\n','model found: FAIL!')]:
  rc,log=run(tag,code,cmd);ok=rc==0 and expect in log;result['cases'].append(dict(tag=tag,PASS=ok,rc=rc));(O/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(tag,ok,flush=True);assert ok,log[-2500:]
