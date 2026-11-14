"""One bounded complete result/formatter/Q-sign cone screen; common DSP cut."""
from pathlib import Path
import os,json,subprocess,hashlib,fcntl,collections
R=Path(__file__).resolve().parents[3];O=R/'build/rc10-mac-screen';O.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');Y='build/tools/oss-cad-suite/bin/yosys'
s=subprocess.check_output(['git','show','af2b633e:rtl/arm/arm9_core.sv'],cwd=R,text=True)
a=s.index('  always_comb begin\n    logic [63:0] p, ps, acc;');b=s.index('  // ---------------------------------------------------------------- M',a);oldbody=s[a:b]
common='''module CONE(input clk,e_live,mul_start,mulhi,macc,mlong,wy,stall,
input[32:0]mul_a,mul_b,input[31:0]e_c,
input signed[33:0]partial_hh,input signed[34:0]partial_mid,input[31:0]partial_ll,
input w_go,w_mulw,w_mulhi,w_mq,
output[63:0]full_sum,output[31:0]lo,hi,output nz_n,nz_z,q_overflow);
logic[32:0]mq_a,mq_b;
logic mq_wy,mq_long,mp_wy,mp_long;
logic[31:0]mq_acc,mp_acc,mq_acch,mh_q;
logic signed[33:0]r_hh;logic signed[34:0]r_mid;logic[31:0]r_ll;
logic[63:0]m_prod,m_sum;logic mzl_q,m_prod_s31;
SIGN_DECL
always @(posedge clk)begin
 if(e_live&&mul_start)begin
  mq_a<=mul_a;mq_b<=mul_b;mq_wy<=wy;mq_long<=mlong;mq_acc<=macc?e_c:32'd0;
  SIGN_E
 end
 if(e_live&&mulhi)mq_acch<=macc?e_c:32'd0;
 if(!stall)begin
  r_hh<=partial_hh;r_mid<=partial_mid;r_ll<=partial_ll;
  mp_acc<=mq_acc;mp_wy<=mq_wy;mp_long<=mq_long;
  SIGN_MP
 end
 if(w_go&&w_mulw&&!w_mulhi)begin mh_q<=m_sum[63:32];mzl_q<=m_sum[31:0]==0;end
end
BODY
assign full_sum=m_sum;assign lo=m_sum[31:0];assign hi=mh_q;
assign nz_n=w_mulhi?mh_q[31]:m_sum[31];
assign nz_z=w_mulhi?(mzl_q&&(mh_q==0)):(m_sum[31:0]==0);
SIGN_ASSIGN
assign q_overflow=w_mq&&(m_sum[31]!=mp_acc[31])&&(m_prod_s31==mp_acc[31]);
endmodule
'''
newbody='''always_comb begin
 logic[63:0]a,b,c,ss,cc,f;
 a={r_hh[31:0],r_ll};
 b={{29{r_mid[34]}},r_mid}<<16;
 c=mp_wy?{16'd0,mp_acc,16'd0}:{mp_long?mq_acch:32'd0,mp_acc};
 ss=a^b^c;cc=((a&b)|(a&c)|(b&c))<<1;
 f=ss+cc;
 m_sum=mp_wy?{{16{f[63]}},f[63:16]}:f;
end
'''
old=common.replace('CONE','before_cone').replace('SIGN_DECL','').replace('SIGN_E','').replace('SIGN_MP','').replace('BODY',oldbody).replace('SIGN_ASSIGN','assign m_prod_s31=mp_wy?m_prod[47]:m_prod[31];')
new=common.replace('CONE','after_cone').replace('SIGN_DECL','logic mq_negative,mp_negative;').replace('SIGN_E','mq_negative<=(mul_a[32]^mul_b[32])&&(mul_a!=0)&&(mul_b!=0);').replace('SIGN_MP','mp_negative<=mq_negative;').replace('BODY',newbody).replace('SIGN_ASSIGN','assign m_prod_s31=mp_negative;')
# Bind the common sequential cut to exact source capture equations and endpoints.
for x in ['mq_a <= mul_a; mq_b <= mul_b;','mq_wy <= eu.mul_kind == MK_WY;','mq_long <= eu.mlong;','mq_acc <= eu.macc ? e_c : 32\'h0;','if (e_live && eu.mulhi) mq_acch <= eu.macc ? e_c : 32\'h0;','mp_acc <= mq_acc; mp_wy <= mq_wy; mp_long <= mq_long;','mh_q <= m_sum[63:32];','mzl_q <= m_sum[31:0] == 32\'h0;','assign m_prod_s31 = mp_wy ? m_prod[47] : m_prod[31];']:
 assert x in s,x
res=dict(source='af2b633e',source_SHA256=hashlib.sha256(s.encode()).hexdigest(),before_body_SHA256=hashlib.sha256(oldbody.encode()).hexdigest(),before_leaf_SHA256=hashlib.sha256(old.encode()).hexdigest(),after_leaf_SHA256=hashlib.sha256(new.encode()).hexdigest(),scope='Complete soft reconstruction/formatter/accumulator/Q-sign+high/low/NZ capture cone. Shared three-DSP generator cut at registered partial input update; unchanged operand formation/DSPs/common operand FF excluded equally. No arithmetic equivalence established by this cost screen.',counts={})
def status(phase,pid):
 d=json.loads(S.read_text());d.update(phase=phase,workers=[dict(host='Desktop',controller=os.getpid(),child=pid,NI=10,threads=1,jobs=1)]);t=S.with_name(S.name+'.'+str(os.getpid())+'.tmp');t.write_text(json.dumps(d));t.replace(S)
status('MAC_SCREEN_WAIT_GLOBAL_MUTEX',os.getpid())
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
 for tag,code,top in [('before',old,'before_cone'),('after',new,'after_cone')]:
  p=O/(tag+'.sv');p.write_text(code);ys=O/(tag+'.ys');ys.write_text('read_verilog -sv '+str(p)+'\nsynth_intel_alm -top '+top+' -family cyclonev -nobram -nodsp -noiopad -noclkbuf\nwrite_json '+str(O/(tag+'.json'))+'\n')
  with(O/(tag+'.log')).open('w')as f:
   c=subprocess.Popen([Y,'-Q','-T','-s',str(ys)],stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status('MAC_COMPLETE_'+tag+'_CONE_COST',c.pid)
   try:rc=c.wait(timeout=180)
   except subprocess.TimeoutExpired:c.terminate();c.wait();raise
  assert rc==0,(O/(tag+'.log')).read_text()[-2200:]
  m=json.loads((O/(tag+'.json')).read_text())['modules'][top]['cells'];counts=dict(collections.Counter(c['type']for c in m.values()));res['counts'][tag]=counts;print(tag,counts,flush=True)
res['summary']={}
for tag,c in res['counts'].items():res['summary'][tag]=dict(regular_LUT=sum(v for k,v in c.items()if k.startswith('MISTRAL_ALUT')and k!='MISTRAL_ALUT_ARITH'),arithmetic=c.get('MISTRAL_ALUT_ARITH',0),FF=c.get('MISTRAL_FF',0),inverters=c.get('MISTRAL_NOT',0))
res['delta']={k:res['summary']['after'][k]-res['summary']['before'][k]for k in res['summary']['before']};res['tool_mapping_PASS']=True
res['gain_gate']='FAIL_NO_GAIN'
res['disposition']='STOP: candidate adds regularLUT/FF with no arithmetic-chain reduction; no pipelineproof/production/fullCPU/fit.'
res['qualification']='Cost-only; equivalence, WYrange/tagalignment and actualfault are unrun, not accepted.'
for tag in ['before','after']:
 m=json.loads((O/(tag+'.json')).read_text())['modules'][tag+'_cone']['cells'];a={n:c for n,c in m.items()if c['type']=='MISTRAL_ALUT_ARITH'};co={tuple(c['connections']['CO']):n for n,c in a.items()};pred={n:co.get(tuple(c['connections']['CI']))for n,c in a.items()};succ={v:k for k,v in pred.items()if v is not None};lengths=[]
 for n,parent in pred.items():
  if parent is not None:continue
  chain=[n]
  while chain[-1]in succ:chain.append(succ[chain[-1]])
  lengths.append(len(chain))
 res.setdefault('arithmetic_CI_CO_chains',{})[tag]={'lengths':sorted(lengths,reverse=True),'cells_total':len(a),'all_cells_accounted':sum(lengths)==len(a)}
(O/'cost-result.json').write_text(json.dumps(res,indent=2)+'\n');print('delta',res['delta'],flush=True)
