// Passive same-edge comparison against the exact before CPU. Both receive
// identical memory replies; every admitted/request/retirement/write owner
// must agree before the shared testbench can advance its bus service.
integer pair_cycles=0,pair_retired=0,pair_writes=0,pair_secondary=0;
always @(posedge clk) if(!rst)begin
  pair_cycles++;
  assert(dut.u_core.ce==prior.u_core.ce)else $fatal(1,"RF_PAIR_CE");
  assert(dbg_retire==p_dbg_retire)else $fatal(1,"RF_PAIR_RETIRE_VALID");
  if(dbg_retire)begin
    pair_retired++;
    assert({dbg_tid,dbg_pc,dbg_cpsr}=={p_dbg_tid,p_dbg_pc,p_dbg_cpsr})
      else $fatal(1,"RF_PAIR_RETIRE_STATE_ORDER");
  end
  assert(dbg_wen==p_dbg_wen)else $fatal(1,"RF_PAIR_WRITE_VALID");
  if(dbg_wen)begin
    pair_writes++;
    assert({dbg_wa,dbg_wd}=={p_dbg_wa,p_dbg_wd})else $fatal(1,"RF_PAIR_WRITE_STATE_ORDER");
  end
  assert(dut.u_core.rf_we2==prior.u_core.rf_we2)else $fatal(1,"RF_PAIR_SECONDARY_VALID");
  if(dut.u_core.rf_we2)begin
    pair_secondary++;
    assert({dut.u_core.rf_wa2,dut.u_core.rf_wd2}=={prior.u_core.rf_wa2,prior.u_core.rf_wd2})
      else $fatal(1,"RF_PAIR_SECONDARY_STATE_ORDER");
  end
  assert({dut.u_core.rf_a,dut.u_core.rf_b,dut.u_core.rf_c}==
         {prior.u_core.rf_a,prior.u_core.rf_b,prior.u_core.rf_c})else $fatal(1,"RF_PAIR_READS");
  for(int r=0;r<64;r++)
    assert(dut.u_core.u_rf.g_dual.regs[r]==prior.u_core.u_rf.g_dual.regs[r])
      else $fatal(1,"RF_PAIR_LOGICAL_STATE address%0d",r);
  assert(b9_req==p_b9_req)else $fatal(1,"RF_PAIR_BUS_REQUEST");
  if(b9_req)begin
    assert({b9_we,b9_addr,b9_be}=={p_b9_we,p_b9_addr,p_b9_be})else $fatal(1,"RF_PAIR_BUS_OWNER");
    if(b9_we)assert(b9_wdata==p_b9_wdata)else $fatal(1,"RF_PAIR_BUS_WRITE");
    assert({dut.b9_ldm,dut.b9_ldm_meta,dut.b9_n8,dut.b9_wnext}==
           {prior.b9_ldm,prior.b9_ldm_meta,prior.b9_n8,prior.b9_wnext})else $fatal(1,"RF_PAIR_BUS_METADATA");
  end
  assert(a7_i_req==p_a7_i_req&&a7_d_req==p_a7_d_req)else $fatal(1,"RF_PAIR_CONTEXT_REQUEST");
  if(a7_i_req)assert(a7_i_addr==p_a7_i_addr)else $fatal(1,"RF_PAIR_CONTEXT_FETCH");
  if(a7_d_req)begin
    assert({a7_d_we,a7_d_addr,a7_d_be}=={p_a7_d_we,p_a7_d_addr,p_a7_d_be})else $fatal(1,"RF_PAIR_CONTEXT_DATA");
    if(a7_d_we)assert(a7_d_wdata==p_a7_d_wdata)else $fatal(1,"RF_PAIR_CONTEXT_WRITE");
  end
end
final $display("SWP_CPU_PAIR_PASS cycles%0d retired%0d writes%0d secondary%0d",pair_cycles,pair_retired,pair_writes,pair_secondary);

integer tag_ihit=0,tag_dhit=0,tag_dtwrite=0,tag_itwrite=0;
always @(posedge clk)if(!rst)begin
 assert({dut.u_mem9.dt_aq,dut.u_mem9.dt_bq,dut.u_mem9.it_aq,dut.u_mem9.it_bq}===
        {prior.u_mem9.dt_aq,prior.u_mem9.dt_bq,prior.u_mem9.it_aq,prior.u_mem9.it_bq})
   else $fatal(1,"TAG_CONSUMER_WORD_OR_COLLISION_MASK");
 assert({dut.u_mem9.wd_hit,dut.u_mem9.wd_way,dut.u_mem9.i_ok,dut.u_mem9.i_abort}===
        {prior.u_mem9.wd_hit,prior.u_mem9.wd_way,prior.u_mem9.i_ok,prior.u_mem9.i_abort})
   else $fatal(1,"TAG_CONSUMER_HIT_OR_READY");
 if(dut.u_mem9.f_req&&dut.u_mem9.f_cach&&dut.u_mem9.i_ok)tag_ihit++;
 if(dut.u_mem9.w_req&&dut.u_mem9.wd_cach&&dut.u_mem9.wd_hit)tag_dhit++;
 if(|dut.u_mem9.dt_we)tag_dtwrite++;
 if(|dut.u_mem9.it_we)tag_itwrite++;
end
final $display("SWP_DEFAULT_CACHE_CONSUMERS ihit%0d dhit%0d dtwrite%0d itwrite%0d",tag_ihit,tag_dhit,tag_dtwrite,tag_itwrite);
