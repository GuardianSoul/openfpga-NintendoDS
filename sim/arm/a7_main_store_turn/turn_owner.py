#!/usr/bin/env python3
"""Affected MAIN tail ownership/priority checks and actual RTL faults."""
from pathlib import Path
import importlib.util,json,shutil
ROOT=Path(__file__).resolve().parents[3]
s=importlib.util.spec_from_file_location('worker',ROOT/'sim/arm/a7_main_store_turn/run.py');w=importlib.util.module_from_spec(s);s.loader.exec_module(w)
w.OUT=ROOT/'build/a7-if-turn-owner';w.OUT.mkdir(exist_ok=True)
tb=(ROOT/'sim/arm/a7_main_store_turn/tb_rejoin.sv').read_text();tb=tb[:tb.index(' initial begin\n  run_case')]
tb=tb.replace('module tb_rejoin;', 'module tb_turn;').replace('.MAIN_IF_REJOIN(`REJOIN)', '.MAIN_IF_TURN(`TURN),.MAIN_IF_REJOIN(1)')
tb+=r'''
 task automatic held_n(input int kind=0);
  begin_old(2);target=base+24;redirects_n(1);
  if(kind!=1)begin ia=target;ir=1;iseq=0;logical_start=cycle;tick();ir=0;tick();end
  else begin ia=target;ir=0;end
  if(kind==2)ia=base+40; // no new actual request for this orphan lookup
  if(kind==4)begin dr=1;dwe=1;da=32'h02002000;dd=32'h45671234;tick();dr=0;dwe=0;tick();end
  if(kind==5)begin dr=1;dwe=0;da=32'h02002004;tick();dr=0;tick();end
  beat(2,base);tick();
  if(kind==3)redirect=1;
  beat(3,base);redirect=0;
  if(kind==0)begin
   if(`TURN)begin
    if(!fr||fw||fa!==(target&32'hfffffff0)||fseq||fgen!==dut.if_gen||fword!==target[3:2])
     $fatal(1,"held N physical descriptor mismatch");
   end else if(fr)$fatal(1,"default changed old tail behavior");
   answer();
  end else if(kind==4)begin
   if(!fr||!fw||fa!==32'h02002000)$fatal(1,"held N passed older posted write");
  end else if(fr)begin
   if(kind==2)$fatal(1,"orphan tail generated physical request");
   else $fatal(1,"tail launched without owned eligible demand");
  end
  cases++;$display("HELD_N_CASE %0d kind%0d",cases,kind);
 endtask
 task automatic first_s(input bit invalid=0);
  int n=0;bit got=0;
  reset_case();ia=base+8;target=ia;ir=1;iseq=0;logical_start=cycle;tick();ir=0;physical();
  for(int k=0;k<3;k++)beat(k,base);
  // N may finish while its owned last word is still waiting physically.
  while(!got)begin
   ir=1;tick();got=io;
   if(got&&iq!==word_value(base,2))$fatal(1,"N target payload");
   ir=0;tick();if(n++>30)$fatal(1,"N price timeout");
  end
  consume=1;tick();consume=0;
  ia=base+12;ir=1;iseq=1;
  if(invalid)begin mon=1;monaddr=(base+12)^32'h00400000;fresh=1;end
  beat(3,base);ir=0;mon=0;
  if(io)$fatal(1,"first S price bypassed on arriving tail");
  if(invalid)begin
   if(!fr||fa!==base)$fatal(1,"stale S tail bypassed real demand");
  end else if(`TURN)begin
   if(!fr||fa!==base+16||!fseq||fgen!==dut.if_gen)$fatal(1,"real first-S tail did not admit authorized quad");
  end else if(fr)$fatal(1,"default changed first-S tail behavior");
  cases++;$display("FIRST_S_CASE %0d invalid%0d",cases,invalid);
 endtask
 initial begin
  for(int kind=0;kind<6;kind++)held_n(kind);
  first_s(0);first_s(1);
  // Reset at the old final ACK cancels the real held demand as well.
  begin_old(2);target=base+24;redirects_n(1);ia=target;ir=1;iseq=0;tick();ir=0;beat(2,base);
  rst=1;ack=1;rv=1;fq=word_value(base,3);tick();ack=0;rv=0;tick();rst=0;tick();
  if(fr||io||dut.flow_v)$fatal(1,"reset retained held N");cases++;
  $display("TURN_OWNER_PASS cases%0d",cases);$finish;
 end
 initial begin #200000;$fatal(1,"turn owner timeout");end
endmodule
'''
source=(ROOT/'rtl/ds/nds_arm7_port.sv').read_text()
variants=[('enabled',source,1,None),('default',source,0,None),
 ('fault-premature',source.replace("f_ack && il_beat && rp_k == 2'd3;",'il_beat;'),1,'old physical owner changed before tail ACK'),
 ('fault-target',source.replace("rp_a <= {i_addr[31:4], 4'd0};", "rp_a <= {i_addr[31:4], 4'd0} ^ (flow_n_turn ? 32'h10 : 32'd0);"),1,'held N physical descriptor mismatch'),
 ('fault-orphan',source.replace('&& flow_v && flow_a == i_addr[31:2] && !i_seq && !i_consume', '&& flow_v && !i_seq && !i_consume'),1,'orphan tail generated physical request'),
 ('fault-freshness',source.replace('&& rp_ifgen == if_gen && !rp_stale && !rp_bad && !il_kill && !i_redirect;', '&& rp_ifgen == if_gen && !rp_stale && !i_redirect;'),1,'stale S tail bypassed real demand')]
out={}
for name,body,option,fault in variants:
 if fault:assert body!=source,name
 d=w.OUT/name;d.mkdir(exist_ok=True);(d/'nds_arm7_port.sv').write_text(body);(d/'tb.sv').write_text(tb)
 for rel in ['rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']:shutil.copyfile(ROOT/rel,d/Path(rel).name)
 files=sorted(d.glob('*.sv'));(d/'inputs.json').write_text(json.dumps({p.name:w.sha(p)for p in files},indent=2)+'\n');model=d/'obj/Vtb_turn'
 w.call([w.V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',f'+define+TURN={option}','+define+REJOIN=1','--top-module','tb_turn','--Mdir',model.parent,*files],d,'build');w.prune(model.parent)
 text=w.call([model],d,'run',fault)
 if not fault:assert'TURN_OWNER_PASS cases9'in text
 out[name]=dict(model_sha256=w.sha(model),verdict=fault or 'PASS9',run_sha256=w.sha(d/'run.log'))
 (w.OUT/'summary.json').write_text(json.dumps(out,indent=2)+'\n');print('TURN_DONE',name,out[name]['verdict'],flush=True)
w.status('TURN owner terminal PASS;9cases+4actualfaults')
