"""Bounded current queue transition proof and Cyclone V inference screen only."""
from pathlib import Path
import os,json,subprocess,hashlib,fcntl,collections,re
R=Path(__file__).resolve().parents[3];O=R/'build/rc10-queue-screen';O.mkdir(parents=True,exist_ok=True)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
Y='build/tools/oss-cad-suite/bin/yosys'
os.setpriority(os.PRIO_PROCESS,0,10)
def status(phase,pid):
 d=json.loads(S.read_text());d.update(phase=phase,workers=[dict(host='Desktop',controller=os.getpid(),child=pid,NI=10,jobs=1,threads=1)]);t=S.with_name(S.name+'.'+str(os.getpid())+'.tmp');t.write_text(json.dumps(d));t.replace(S)
def run(tag,sv,commands):
 p=O/(tag+'.sv');p.write_text(sv);ys=O/(tag+'.ys');ys.write_text('read_verilog -sv '+str(p)+'\n'+commands)
 with(O/(tag+'.log')).open('w')as f:
  c=subprocess.Popen([Y,'-Q','-T','-s',str(ys)],stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status(tag,c.pid)
  try:rc=c.wait(timeout=180)
  except subprocess.TimeoutExpired:c.terminate();c.wait();raise
 return rc,(O/(tag+'.log')).read_text()
source=subprocess.check_output(['git','show','66372894:rtl/arm/arm9_core.sv'],cwd=R,text=True)
start=source.index('      // the queue: D takes');end=source.index('      // ---- D',start)
oldblock=source[start:end];decl=source[source.index('  logic [1:0]  q_n;'):source.index('  logic        f_ans, f_take')]
# These actual unchanged source equations define upstream answer acceptance/admission and queue pop.
for line in ['assign f_ans  = f1_v && f1_ep == ep;','assign f_take = f_ans && i_ok;','assign have = h_v && !hold;','(flush || (!(i_one && f1_v) && ({1\'b0, q_n} + {2\'b00, f1_v}) <= 3\'d2))']:
 assert line in source,line
old='''module before_queue #(parameter OBSERVE_ORDER=0)(input clk,rst,flush,hold,stall,inject,mf,
 input f1_v,f1_ep,ep,i_ok,f1_th,i_abort,tx_pcalign,input[31:0]f1_pc,a_ins,
 input[15:0]a_hw,input[4:0]a_cls,input[2:0]tx_kind,
 output[1:0]count,output[31:0]head_pc,output[58:0]head,
 output[176:0]ordered,output overflow,output port_collision);
 localparam[2:0]TK_ARM=0;
'''+decl+'''
 wire h_v=q_n!=0;wire have=h_v&&!hold;wire f_ans=f1_v&&f1_ep==ep;wire f_take=f_ans&&i_ok;
 assign count=q_n;assign head_pc=q_hpc;
 assign head={q_w[0],q_hw[0],q_cls[0],q_kind[0],q_pa[0],q_th[0],q_ab[0]};
 assign ordered=OBSERVE_ORDER?{q_w[2],q_hw[2],q_cls[2],q_kind[2],q_pa[2],q_th[2],q_ab[2],q_w[1],q_hw[1],q_cls[1],q_kind[1],q_pa[1],q_th[1],q_ab[1],head}:177'd0;
 wire pop=have&&!stall&&!inject&&!mf;
 assign overflow=q_n==3&&!pop&&f_take&&!flush;
 assign port_collision=0;
 always @(posedge clk) begin
  if(rst)q_n<=0;
  else begin
'''+oldblock+'''
  end
 end
 endmodule
'''
new='''module after_queue #(parameter OBSERVE_ORDER=0)(input clk,rst,flush,hold,stall,inject,mf,
 input f1_v,f1_ep,ep,i_ok,f1_th,i_abort,tx_pcalign,input[31:0]f1_pc,a_ins,
 input[15:0]a_hw,input[4:0]a_cls,input[2:0]tx_kind,
 output[1:0]count,output[31:0]head_pc,output[58:0]head,
 output[176:0]ordered,output overflow,output port_collision);
 reg[1:0]q_n,rd,wr;reg[31:0]q_hpc;reg[58:0]hq;
 (* ramstyle="MLAB, no_rw_check" *) reg[58:0]tail[0:2];
 function[1:0]bump(input[1:0]p);begin bump=(p==2)?0:p+2'd1;end endfunction
 wire[58:0]tail_read=tail[rd];
 wire[58:0]incoming={a_ins,a_hw,a_cls,f1_th?tx_kind:3'd0,f1_th&&tx_pcalign,f1_th,i_abort};
 wire h_v=q_n!=0;wire have=h_v&&!hold;wire f_ans=f1_v&&f1_ep==ep;wire f_take=f_ans&&i_ok;
 wire pop=have&&!stall&&!inject&&!mf;
 wire read_tail=pop&&q_n>1;
 wire write_tail=f_take&&!flush&&(q_n-{1'b0,pop})!=0;
 assign count=q_n;assign head_pc=q_hpc;assign head=hq;
 assign ordered=OBSERVE_ORDER?{tail[bump(rd)],tail_read,hq}:177'd0;
 assign overflow=q_n==3&&!pop&&f_take&&!flush;
 // Proof-only occupancy/pointer relation strengthens induction; excluded from cost top.
 wire pointer_bad=rd>2||wr>2||((q_n<2)?wr!=rd:(q_n==2)?wr!=bump(rd):wr!=bump(bump(rd)));
 assign port_collision=(!rst&&!flush&&read_tail&&write_tail&&rd==wr)||(OBSERVE_ORDER&&pointer_bad);
 always @(posedge clk)begin
  if(rst)begin q_n<=0;rd<=0;wr<=0;end
  else begin : queue_transition
   reg[1:0]n;
   n=q_n;
   if(pop)begin
    if(q_n>1)begin hq<=tail_read;rd<=bump(rd);end
    n=n-2'd1;
    q_hpc<=q_hpc+(hq[1]?32'd2:32'd4);
   end
   if(f_take&&!flush)begin
    if(n==0)begin q_hpc<=f1_pc;hq<=incoming;end
    else begin tail[wr]<=incoming;wr<=bump(wr);end
    n=n+2'd1;
   end
   q_n<=flush?2'd0:n;
   if(flush)begin rd<=0;wr<=0;end
  end
 end
 endmodule
'''
# This is the candidate synthesizable leaf, not a hand-written mutation of the verifier.
fault=new.replace('hq<=tail_read;rd<=bump(rd);','hq<=tail[bump(rd)];rd<=bump(rd);');assert fault!=new
(O/'before-queue.sv').write_text(old);(O/'after-queue.sv').write_text(new);(O/'actual-wrongslot-queue.sv').write_text(fault)
wrapper='''
module miter(input clk,rst,flush,hold,stall,inject,mf,run,halted,wfi,e_exec,i_ok,
input[31:0]fetch_pc,a_ins,input fetch_th,i_abort,tx_pcalign,
input[15:0]a_hw,input[4:0]a_cls,input[2:0]tx_kind,
output bad,output[7:0]parts,output[1:0]count0,count1,output[31:0]pc0,pc1);
reg f1_v,f1_ep,ep,i_one,f1_th;reg[31:0]f1_pc;
wire[58:0]h0,h1;wire[176:0]o0,o1;wire ov0,ov1,collision0,collision1;
wire f_ans=f1_v&&f1_ep==ep;wire f_take=f_ans&&i_ok;wire f_rew=f_ans&&!i_ok;
wire fetch_en=run&&!halted&&!rst&&!(e_exec&&wfi)&&(flush||(!(i_one&&f1_v)&&({1'b0,count0}+{2'b00,f1_v})<=3'd2));
always @(posedge clk)begin
 if(rst)begin f1_v<=0;ep<=0;i_one<=0;end
 else begin
  f1_v<=fetch_en;f1_pc<=fetch_pc;f1_th<=fetch_th;f1_ep<=flush?!ep:ep;
  if(flush||f_rew)ep<=!ep;
  if(flush)i_one<=0;else if(f_rew)i_one<=1;else if(f_take)i_one<=0;
 end
end
before_queue #(.OBSERVE_ORDER(1))p(clk,rst,flush,hold,stall,inject,mf,f1_v,f1_ep,ep,i_ok,f1_th,i_abort,tx_pcalign,f1_pc,a_ins,a_hw,a_cls,tx_kind,count0,pc0,h0,o0,ov0,collision0);
after_queue #(.OBSERVE_ORDER(1))n(clk,rst,flush,hold,stall,inject,mf,f1_v,f1_ep,ep,i_ok,f1_th,i_abort,tx_pcalign,f1_pc,a_ins,a_hw,a_cls,tx_kind,count1,pc1,h1,o1,ov1,collision1);
assign parts={count0!=count1,count0!=0&&h0!=h1,count0!=0&&pc0!=pc1,count0>1&&o0[117:59]!=o1[117:59],count0>2&&o0[176:118]!=o1[176:118],!rst&&(ov0||ov1),collision1,({1'b0,count0}+{2'b00,f1_v})>3'd3};
assign bad=|parts;
endmodule
'''
result={'source':'66372894','parent_block_SHA256':hashlib.sha256(oldblock.encode()).hexdigest(),'parent_core_SHA256':hashlib.sha256(source.encode()).hexdigest(),'candidate_leaf_SHA256':hashlib.sha256(new.encode()).hexdigest(),'actual_wrongslot_SHA256':hashlib.sha256(fault.encode()).hexdigest(),'cases':[],'clock_correction':'CLOCK_NS10 parameter, actual PLL SYS14.917ns/FAST7.458ns; not10ns clock requirement','scope':'Actual priorqueue transition/answer acceptance/admission. Common arbitrary late payload/class/kind/Thumb/abort, holds/inject/mf, flush/epoch/refusal. Fpc generation outside leaf unchanged; f1_pc captures arbitrary common fetch_pc. No wholeCPU/fit or accepted suite repeat.'}
status('QUEUE_SCREEN_WAIT_GLOBAL_MUTEX',os.getpid())
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024,'need12GiB after mutex'
 for tag,code,isfault in [('reset-base',new,False),('queue-equivalence',new,False),('actual-wrongslot',fault,True)]:
  cmd='prep -top miter -flatten\nmemory_map\nopt -full\nsat '+('-verify -seq 2 -set-at 1 rst 1 -prove-skip 1'if tag=='reset-base'else('-falsify -seq 8 -set-init-zero'if isfault else'-verify -seq 4 -tempinduct -maxsteps 12 -set-init-zero'))+' -prove bad 0 -show-inputs -show-outputs -dump_json '+str(O/(tag+'-witness.json'))+'\n'
  rc,log=run(tag,old+code+wrapper,cmd);ok=rc==0 and ('model found: FAIL!'if isfault else('SUCCESS!'if tag=='reset-base'else'Induction step proven: SUCCESS!'))in log
  result['cases'].append(dict(tag=tag,PASS=ok,rc=rc));(O/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(tag,ok,flush=True);assert ok,log[-3000:]
 # Identical head/count/PC visible ports; proof-only ordered reads are disabled at synthesis.
 for tag,code,top in [('before',old,'before_queue'),('after',new,'after_queue')]:
  rc,log=run(tag+'-intel',code,'synth_intel_alm -top '+top+' -family cyclonev -nobram -nodsp -noiopad -noclkbuf\nwrite_json '+str(O/(tag+'-intel.json'))+'\n')
  assert rc==0,log[-3000:]
  cells=json.loads((O/(tag+'-intel.json')).read_text())['modules'][top]['cells'];counts=dict(collections.Counter(c['type']for c in cells.values()));result[tag+'_intel_cells']=counts;print(tag,counts,flush=True)
 mem=[c for c in cells.values()if c['type']=='MISTRAL_MLAB']
 ports={name:len({tuple(c['connections'][name])for c in mem})for name in ['A1ADDR','B1ADDR','A1EN','CLK1']}
 assert len(mem)==59 and set(ports.values())=={1}
 result['port_inference']={'onebit_lanes':59,'unique_write_address_read_address_enable_clock':ports,'asynchronous_read':True,'nominal_32x20_MLAB_blocks':3,'not_Quartus_placement':True}
 for tag in ['before','after']:
  c=result[tag+'_intel_cells'];result[tag+'_summary']={'regular_LUT_cells':sum(v for k,v in c.items()if k.startswith('MISTRAL_ALUT')and k!='MISTRAL_ALUT_ARITH'),'arithmetic_cells':c.get('MISTRAL_ALUT_ARITH',0),'FF':c['MISTRAL_FF'],'inverters':c.get('MISTRAL_NOT',0),'MLAB_onebit_lanes':c.get('MISTRAL_MLAB',0)}
 result['generic_deltas']={k:result['after_summary'][k]-result['before_summary'][k]for k in result['before_summary']}
 result['disposition']='Credible cone mechanism; Rootreview before wholeCPU/Quartus/fit. No ALM/timing credit.'
 result['qualification_limit']='Source leaf wrongslot SAT catch, not fullCPU runtime; proof-only order/pointer observations disabled in cost top. No productionRTL edit.'
 result['PASS']=True
 (O/'result.json').write_text(json.dumps(result,indent=2)+'\n')
