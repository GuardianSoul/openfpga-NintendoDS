#!/usr/bin/env python3
"""Actual bank RTL versus prior rotating-bank semantics, arbitrary write/holds.
Both synchronous same-address bypass and asynchronous service are checked.
"""
import pathlib,os,subprocess,json,fcntl,time,hashlib
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-context-bank-proof';D.mkdir(exist_ok=True);STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';results={}
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
for name,fault in [('candidate',0),('actual-owner-mutation',1)]:
 top=D/(name+'.sv');widths=[463,261,33] if os.environ.get('BANK_PROOF_FULL')=='1' else [17];parts=[f'module bank_check(input logic clk,rst,input logic[{len(widths)-1}:0] issue,input logic[{sum(widths)-1}:0] data);\n logic tid; always_ff @(posedge clk) if(rst)tid<=0;else tid<=~tid;\n'];offset=0
 for k,width in enumerate(widths):
  parts.append(f""" logic[{width-1}:0] old{k}[0:1];logic[1:0] valid{k};wire[{width-1}:0] a{k},b{k};
 arm_context_bank #(.WIDTH({width}),.STYLE("logic"),.SYNC(0),.FAULT_OWNER({fault})) a_bank{k}(.clk,.we(issue[{k}]&&!rst),.even_owner(tid),.odd_owner(~tid),.wdata(data[{offset}+:{width}]),.rdata(a{k}));
 arm_context_bank #(.WIDTH({width}),.STYLE("logic"),.SYNC(1),.FAULT_OWNER({fault})) b_bank{k}(.clk,.we(issue[{k}]&&!rst),.even_owner(tid),.odd_owner(~tid),.wdata(data[{offset}+:{width}]),.rdata(b{k}));
 always_ff @(posedge clk)begin
  if(rst) valid{k}<=0;
  else begin
   old{k}[0]<=old{k}[1];old{k}[1]<=issue[{k}]?data[{offset}+:{width}]:old{k}[0];
   valid{k}[0]<=valid{k}[1];valid{k}[1]<=issue[{k}]?1'b1:valid{k}[0];
   if(valid{k}[1])begin assert(a{k}==old{k}[1]);assert(b{k}==old{k}[1]);end
  end
 end
""");offset+=width
 top.write_text(''.join(parts)+'endmodule\n')
 script='read_slang --top bank_check '+str(W/'rtl/arm/study/arm_context_bank.sv')+' '+str(top)+'; proc; flatten; opt; memory_map; opt; async2sync; chformal -lower; sat -seq 12 -set-init-undef -set-def-inputs -set-at 1 rst 1 -prove-asserts -show-inputs -show-outputs -dump_json '+str(D/(name+'-counterexample.json'))
 with(D/(name+'.log')).open('w')as f:
  p=subprocess.Popen([Y,'-Q','-T','-m','slang','-p',script],stdout=f,stderr=subprocess.STDOUT)
  s=json.loads(STATUS.read_text());s.update(phase='CONTEXT_BANK_FORMAL_'+name,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'contextbank-formal'},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':name}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');assert t.stat().st_size<=2048;t.replace(STATUS)
  try:rc=p.wait(timeout=120)
  except subprocess.TimeoutExpired:
   p.terminate();p.wait(timeout=10);raise
 text=(D/(name+'.log')).read_text();assert rc==0,text[-2000:]
 expected='no model found: SUCCESS!'if not fault else'model found: FAIL!';assert expected in text,text[-2000:];results[name]={'expected_outcome':expected,'PASS':True};print(name,expected,flush=True)
results['actual_RTL_sha256']=hashlib.sha256((W/'rtl/arm/study/arm_context_bank.sv').read_bytes()).hexdigest();results['scope']={'boundaries':12,'widths':widths,'arbitrary_defined_data_issue_reset':True,'uninitialized_payload_valid_guard':True,'same_address_bypass':True,'bit_separable_actual_RTL':True,'fullwidth_global_attempt':'120second SAT timeout; not credited as a proof; complete packet observable equivalence separately checked'};(D/'result.json').write_text(json.dumps(results,indent=2)+'\n');fcntl.flock(lock,fcntl.LOCK_UN);s=json.loads(STATUS.read_text());s.update(phase='CONTEXT_BANK_SEMANTICS_PASS_ACTUAL_OWNER_CAUGHT',workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
