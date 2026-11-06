"""Generate four literal public-CPU lanes from the frozen measurement fixture."""
from pathlib import Path

def lanes(root: Path):
    original=(root/'sim/arm/a7_mulphase/tb.sv').read_text()
    oracle=(root/'sim/arm/a7_mulphase/oracle.svh').read_text().replace('pins','pinsn')
    answer=[]
    for mode in range(4):
        s=original.replace('module tb;',f'module lane{mode}(output bit done=0);\n localparam int MODE={mode};')
        s=s.replace('logic clk=0,clk_mem=0,clk_cram=0,rst=1,run=0;',
            'logic clk=0,clk_mem=0,clk_cram=0,rst=1,run=0,cpu_reset=0,irq=0;\n wire cpu_rst=rst||cpu_reset;\n int variant=0,scenario=0,pause_left=0;bit intervention=0;\n logic xr,xwe,xdone=0;logic[17:2]xa;logic[31:0]xq=0;\n logic[10:0]ib;logic[5:0]wa_public;assign wa=wa_public[4:0];')
        s=s.replace('int sym_call,sym_done,sym_rs,sym_loops,sym_entry;',
            'int sym_call,sym_done,sym_rs,sym_loops,sym_entry,sym_finished,sym_irq_enable;')
        begin=s.index(' arm7_ds #(');end=s.index('\n nds_arm7_port',begin)
        typ='arm_cpu_before' if mode==0 else 'arm_cpu'
        param='' if mode in [0,1] else f',.A7_MUL_META({int(mode==3)})'
        ports='' if mode==0 else '.a7_mul_request(mul_request),.a7_mul_advance(mul_advance),'
        instance=f''' {typ} #(.A7_DS(1),.A7_IF_FLOW(1),.A7_WRAM_SWP_PIPE(1),.A9_SOLO(1),.SLOW(1){param})cpu(
 .clk,.rst(cpu_rst),.run({{run,1'b0}}),.reset_pc0(32'h02000000),.reset_pc1(32'h03808000),.hivecs7(1'b0),.irq({{irq,1'b0}}),.fiq(2'b0),.wake7(1'b0),
 .b9_wnext(1'b0),.b9_ack(1'b0),.b9_rdata(32'd0),
 .a7_i_req(ir),.a7_i_addr(ia),.a7_i_rdata(iq),.a7_i_ok(io),.a7_d_req(dr),.a7_d_we(dw),.a7_d_be(db),.a7_d_addr(da),.a7_d_wdata(dd),.a7_d_rdata(dq),.a7_d_ok(dok),
 .a7_i_seq(iseq),.a7_i_arm(iarm),.a7_i_redirect(iredirect),.a7_i_consume(iconsume),.a7_exec_meta(full_observer),{ports}
 .dbg_wen(wen),.dbg_wa(wa_public),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr));
'''
        s=s[:begin]+instance+s[end:]
        # Rewrite only old direct-core observations; the public instance stays cpu.
        for field in ['pipe_fire','e_mul','opa','opb','mterm','pc','esub','e_busy','dm_rq','ins','st','ph','wcnt','if_wait']:
            s=s.replace('cpu.'+field,'cpu.g_a7ds.u_a7.'+field)
        s=s.replace('.ib_addr(),.i_boot_q(32\'d0)',".ib_addr(ib),.i_boot_q(ib==11'd6 ? 32'he25ef004 : 32'd0)")
        s=s.replace(".x_req(),.x_we(),.x_addr(),.x_be(),.x_wdata(),.x_stores(),.x_done(1'b0),.x_rdata(32'd0)",
            '.x_req(xr),.x_we(xwe),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xq)')
        s=s.replace('  return 0;\n endfunction',"  if(a==32'h18)return 32'he25ef004;\n  return 0;\n endfunction",1)
        s=s.replace('if(!rst&&iconsume)','if(!cpu_rst&&iconsume)')
        s=s.replace('if(!rst&&cpu.g_a7ds.u_a7.pipe_fire&&cpu.g_a7ds.u_a7.e_mul)',
            'if(!cpu_rst&&cpu.g_a7ds.u_a7.pipe_fire&&cpu.g_a7ds.u_a7.e_mul&&in_body(cpu.g_a7ds.u_a7.pc))')
        s=s.replace('always @(negedge clk)if(!rst)begin', 'always @(negedge clk)if(!cpu_rst)begin')
        s=s.replace('if(in_body(pc))mul_retired++;',"if(in_body(pc)&&psr[4:0]!=M_IRQ)mul_retired++;")
        s=s.replace('if(pc==32\'(sym_done))begin end_tick=cycle;active=0;finished=1;run=0;end',
            "if(pc==32'(sym_done))begin end_tick=cycle;active=0;end\n   if(pc==32'(sym_finished))begin finished=1;run=0;end")
        s=s.replace('  m_ref=caseid+1;', '''  void'($value$plusargs("variant=%d",variant));void'($value$plusargs("scenario=%d",scenario));
  if(!$value$plusargs("finished=%h",sym_finished)||!$value$plusargs("irq_enable=%h",sym_irq_enable))$fatal(1,"missing adverse symbols");
  out={out,"-m",$sformatf("%0d",MODE)};
  m_ref=caseid+1;''')
        s=s.replace('  for(int j=0;j<1024;j++)begin', '''  if(!variant)ram[(sym_done&65535)/4]=32'hea000000|32'((sym_finished-sym_done-8)/4);
  if(scenario==3)ram[32'h8000/4]=32'hea000000|32'((sym_irq_enable-32'h03808008)/4);
  for(int j=0;j<1024;j++)begin''')
        s=s.replace('  $fclose(statefd);$fclose(datafd);$fclose(edgefd);$finish;', '''  if(variant)begin
   assert(failed_mul_seen>0&&forwarded_seen>0&&held_drain>0)else $fatal(1,"adverse coverage failed%0d forwarded%0d drain%0d",failed_mul_seen,forwarded_seen,held_drain);
  end
  if(scenario!=0)assert(intervention)else $fatal(1,"intervention never triggered");
  if(scenario==3)assert(mul_discards>0)else $fatal(1,"IRQ did not discard held MUL owner");
  $display("MUL_META_COVER mode%0d faults%0d held_drain%0d failed%0d forwarded%0d discards%0d intervention%0d",MODE,metadata_faults,held_drain,failed_mul_seen,forwarded_seen,mul_discards,intervention);
  $fclose(statefd);$fclose(datafd);$fclose(edgefd);done=1;''')
        # Mutations affect the enabled real RTL. Other routes remain exact controls.
        observation=oracle
        if mode==0:
            observation=observation.replace('`PROBE(cpu.g_a7ds.u_a7)','`PROBE(cpu.g_a7ds.u_a7)\nassign mul_request=\'0;assign mul_advance=\'0;')
        intervention='''
 // BIOS7 uses the SRAM map, unlike the distinct 0x8000 boot-ROM input.
 // Supply only the four-word IRQ vector line, through P7's real x handshake.
 always @(posedge clk)begin
  xdone<=!rst&&xr&&!xdone;
  if(!rst&&xr&&!xdone)begin
   assert(!xwe&&{xa,2'b00}>=18'h18000&&{xa,2'b00}<18'h1c000)else $fatal(1,"unexpected BIOS fixture transaction");
   xq<=xa==16'h6006 ? 32'he25ef004 : 32'd0;
  end
 end
 always @(negedge clk)begin
  if(!rst&&!finished)begin
   if(!intervention&&active&&executed_mul&&pesub==1&&ref_owned&&held_expected.valid)begin
    if(scenario==1||scenario==2)begin
     intervention=1;run=0;pause_left=8;
     if(scenario==2)begin
      cpu_reset=1;active=0;start_tick=-1;end_tick=-1;mul_steps=0;mul_retired=0;
      i_during_mul=0;consume_during_mul=0;fetches=0;phys_requests=0;
      $fdisplay(statefd,"RESET,%0d",cycle);$fdisplay(datafd,"RESET,%0d",cycle);
     end
    end else if(scenario==3)begin intervention=1;irq=1;end
   end else if(pause_left>0)begin
    pause_left--;if(pause_left==0)begin cpu_reset=0;run=1;end
   end
   if(irq&&pmode==5'h12)irq=0;
  end
 end
'''
        s=s.replace(' initial begin\n  if(!$value',observation+'\n'+intervention+'\n initial begin\n  if(!$value',1)
        answer.append(s)
    top='''
module tb;
 wire d0,d1,d2,d3;
 lane0 l0(d0);lane1 l1(d1);lane2 l2(d2);lane3 l3(d3);
 integer edges=0;
 always @(posedge l0.clk)if(!l0.rst)begin
  edges++;
  assert(l0.core_state===l1.core_state&&l0.core_state===l2.core_state&&l0.core_state===l3.core_state)else $fatal(1,"MUL_PAIR_CORE_STATE cycle%0d",l0.cycle);
  assert(l0.rf_state===l1.rf_state&&l0.rf_state===l2.rf_state&&l0.rf_state===l3.rf_state&&l0.rfb_state===l1.rfb_state&&l0.rfb_state===l2.rfb_state&&l0.rfb_state===l3.rfb_state)else $fatal(1,"MUL_PAIR_FULL_REGISTER_STATE");
'''
    signals='ir,ia,io,iq,dr,dw,db,da,dd,dq,dok,iseq,iarm,iredirect,iconsume,fr,fn,fw,fa,fd,ack,rv,fq,wr,ww,wa_mem,wb,wwd,wen,wa_public,wd,ret,pc,psr,pins,run,cpu_rst'
    lhs='{'+','.join('l0.'+x for x in signals.split(','))+'}'
    for mode in [1,2,3]:
        rhs='{'+','.join(f'l{mode}.'+x for x in signals.split(','))+'}'
        top+=f'  assert({lhs}==={rhs})else $fatal(1,"MUL_PAIR_PORTS lane{mode}");\n'
    top+=''' end
 initial begin
  wait(d0&&d1&&d2&&d3);
  $display("MUL_FOUR_LANE_BEHAVIOR_PASS edges%0d",edges);
  if(l0.metadata_faults+l1.metadata_faults+l2.metadata_faults+l3.metadata_faults!=0)$fatal(1,"MUL_METADATA_MUTATION_CAUGHT faults%0d",l0.metadata_faults+l1.metadata_faults+l2.metadata_faults+l3.metadata_faults);
  $display("MUL_FOUR_LANE_METADATA_PASS");$finish;
 end
endmodule
'''
    return '\n'.join(answer)+top
