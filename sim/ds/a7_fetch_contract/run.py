#!/usr/bin/env python3
"""Count current fabric reuse/typed-owner behavior; no production RTL delta."""
from pathlib import Path
import hashlib,json,os,resource,subprocess,sys,re,shutil
ROOT=Path(__file__).resolve().parents[3]
G=ROOT/'build/a7-fetch-contract';G.mkdir(parents=True,exist_ok=True)
os.chdir(ROOT);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
assert '--allocated' in sys.argv
sys.path.insert(0,str(ROOT/'sim/arm/ncnb_store'))
from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(ROOT/'sim/arm/ncnb_store/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
def record(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def call(cmd,path):
 guard();cmd=list(map(str,cmd))
 with path.open('w')as out:
  child=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  row=dict(pid=child.pid,NI=os.getpriority(os.PRIO_PROCESS,child.pid),cmd=cmd,log=str(path))
  with(G/'processes.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
  print(json.dumps(row),flush=True);rc=wait_owned(child)
 return rc,path.read_text()
V='build/tools/oss-cad-suite/bin/verilator'
# Adapt the existing a7_quad payload/ordering/reset/foreign-write fixture.
# Metadata wiring follows the existing psram_if4/metadata.py gate.
tb=(ROOT/'sim/ds/a7_quad/tb.sv').read_text()
tb=tb.replace('.mr_req(fm_req),','.mr_if4(fm_if4), .mr_req(fm_req),',1)
tb=tb.replace('.a_ack(fm_ack),','.a_if4(fm_if4 && !arb.rd), .mr_if4, .a_ack(fm_ack),',1)
observer='''
    wire fm_if4, mr_if4;
    int typed_issues=0, polygon_issues=0, hits1=0, misses1=0;
    bit saved_if4;
    always @(posedge clk) if(!rst) begin
        if(dut.st==dut.S_IDLE && dut.grant!=0)
            $display("GRANT cycle%0d owner%0d a7n4%0d addr%h",cycle,dut.grant,a7_n4,dut.grant[2]?a7_addr:dut.grant[1]?a9_addr:dut.grant[0]?dm_addr:sn_addr);
        if(dut.st==dut.S_GO && dut.tgt==dut.T_MAIN && !dut.we && !dut.sd_busy && !dut.blk) begin
            $display("CACHE cycle%0d master%0d class%0d addr%h hit%0d q7%0d",cycle,dut.mst,dut.cls,dut.addr,dut.lb_hit,dut.q7);
            if(dut.cls==1)begin if(dut.lb_hit)hits1++;else misses1++;end
        end
        if(fm_req && fm_if4!==(ENABLE && quad_active && !fm_we && !fm_n8))
            $fatal(1,"IF4 descriptor classification");
        if(state==0 && mr_req && !mr_ack)begin
            saved_if4<=mr_if4;
            if(arb.own==2'd1 && mr_if4!==fm_if4)$fatal(1,"IF4 owner capture");
            if(arb.own==2'd2 && mr_if4)$fatal(1,"IF4 leaked to polygon");
            if(mr_if4)typed_issues++;
            if(arb.own==2'd2)polygon_issues++;
            $display("PHYSICAL cycle%0d owner%0d addr%h we%0d n8%0d if4%0d",cycle,arb.own,mr_addr,mr_we,mr_n8,mr_if4);
        end
        // Producer type deliberately drops after acceptance. Captured owner
        // must retain the type while all returned words drain.
        if((state==1 || state==2) && mr_if4!==saved_if4)
            $fatal(1,"IF4 owner lifetime");
        if(a7_rvalid)$display("IFWORD cycle%0d addr%h ack%0d data%h",cycle,a7_addr,a7_ack,a7_rdata);
    end
    final begin
        if(typed_issues<30 || polygon_issues==0 || hits1==0 || misses1==0)$fatal(1,"metadata coverage");
        $display("CONTRACT_COUNTS typed%0d polygon%0d class1hits%0d class1misses%0d",typed_issues,polygon_issues,hits1,misses1);
    end
'''
tb=tb[:tb.rfind('\nendmodule')]+observer+tb[tb.rfind('\nendmodule'):]
(G/'tb.sv').write_text(tb)
rels=['rtl/gpu2d/gpu2d_ram.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_fabric.sv']
sources=G/'source';sources.mkdir(exist_ok=True)
for rel in rels:shutil.copyfile(ROOT/rel,sources/Path(rel).name)
results={}
for label in ['current','mutation-owner']:
 out=G/label;out.mkdir(exist_ok=True)
 paths=[sources/Path(x).name for x in rels]
 if label=='mutation-owner':
  old='assign mr_if4  = own == O_A && if4;';s=(sources/'nds_mr_arb.sv').read_text();assert s.count(old)==1
  p=out/'nds_mr_arb.sv';p.write_text(s.replace(old,'assign mr_if4  = own == O_A && a_if4;'));paths[2]=p
 model=out/'Vtb_a7_quad'
 rc,t=call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_a7_quad','-GENABLE=1','--Mdir',out,*paths,G/'tb.sv'],out/'build.log')
 assert rc==0,t[-2500:]
 rc,t=call([model],out/'run.log')
 if label=='current':
  assert rc==0 and 'PASS A7 quad' in t,t[-2500:]
  counts=re.search(r'CONTRACT_COUNTS typed(\d+) polygon(\d+) class1hits(\d+) class1misses(\d+)',t)
  assert counts
  results[label]=dict(model_sha256=sha(model),counts=dict(zip(['typed_issues','polygon_issues','class1_hits','class1_misses'],map(int,counts.groups()))),result=re.search(r'^PASS A7.*',t,re.M)[0])
 else:
  assert rc!=0 and 'IF4 owner lifetime' in t,(rc,t[-2000:])
  results[label]=dict(caught=True,assertion='IF4 owner lifetime',exit=rc,model_sha256=sha(model))
 record(G/'results.json',dict(base=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),production={rel:sha(ROOT/rel)for rel in rels},scope='Unchanged fabric + actual MR arbiter, existing a7_quad fixture with controlled backend; no CPU, native, DS timing or cache-policy claim',cases=results))
 for f in out.iterdir():
  if f.name not in ['Vtb_a7_quad','build.log','run.log','nds_mr_arb.sv']:
   if f.is_dir():shutil.rmtree(f)
   else:f.unlink()
print('A7 FETCH CONTRACT COUNTS PASS',json.dumps(results),flush=True)
