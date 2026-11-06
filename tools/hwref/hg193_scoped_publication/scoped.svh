// Simulation-only, owner-specific proposal. No native caller installs it.
// Existing caller.svh and matcher.svh supply the ARM9 ledger/content check.
localparam bit HG193_SCOPED_DEFAULT_ENABLE=0;
function automatic bit hg193_scope_arm9();
 return hg193_bootstrap_reads::permit(0,1,
  hg193_actual_read_view(hg_scope_held,hg_scope_original_phase,hg_scope_content)) &&
  hg_read_accepted_v && hg_read_accepted_addr==32'h023091c0 &&
  hg_read_physical_v && hg_read_physical_words==4 && hg_read_physical_returned==3 &&
  `HG_READ_PHY.s_rvalid && !`HG_READ_PHY.busy && `HG_READ_PHY.out_n==0 &&
  `HG_READ_MEM.ibuf_v && `HG_READ_MEM.ibuf_a==32'h023091bc &&
  `HG_READ_MEM.ibuf_d==32'he1dde3b0;
endfunction
function automatic bit hg193_scope_arm7();
 // A held BOOT_FAB request phase, not an exemption for any cache/IL contents.
 // No instruction packet/window is pending; KEYINPUT is queued, never sampled here.
 return hg_scope_held && hg_scope_original_phase && hg_scope_content &&
  `HG_SCOPE_P7.BOOT_FAB==1 && `HG_SCOPE_P7.i_req &&
  `HG_SCOPE_P7.i_addr==32'h000094b4 && `HG_SCOPE_P7.ireg==0 &&
  !`HG_SCOPE_P7.ia_v && `HG_SCOPE_P7.ia_r==0 &&
  !`HG_SCOPE_P7.i_ok && !`HG_SCOPE_P7.i_consume &&
  `HG_SCOPE_P7.i_rdata==32'h1afffffa &&
  `HG_SCOPE_P7.d_req && !`HG_SCOPE_P7.d_we && `HG_SCOPE_P7.d_be==3 &&
  `HG_SCOPE_P7.d_addr==32'h04000130 && !`HG_SCOPE_P7.d_ok &&
  `HG_SCOPE_P7.rp_v && !`HG_SCOPE_P7.rp_i &&
  `HG_SCOPE_P7.rp_a==32'h04000130 && `HG_SCOPE_P7.rp_be==3 &&
  !`HG_SCOPE_P7.rp_bad && !`HG_SCOPE_P7.rp_flow && !`HG_SCOPE_P7.rp_stale &&
  !`HG_SCOPE_P7.rp_rejoin_window && !`HG_SCOPE_P7.rp_rejoined &&
  `HG_SCOPE_P7.busy && !`HG_SCOPE_P7.busy_w && !`HG_SCOPE_P7.wb_v &&
  !`HG_SCOPE_P7.rb_v && !`HG_SCOPE_P7.fl_v && !`HG_SCOPE_P7.xs_busy &&
  !`HG_SCOPE_P7.su_v && `HG_SCOPE_P7.sf_n==0 &&
  !`HG_SCOPE_P7.flow_v && !`HG_SCOPE_P7.flow_qv && !`HG_SCOPE_P7.flow_pv &&
  !`HG_SCOPE_P7.w_req && !`HG_SCOPE_P7.x_req &&
  `HG_SCOPE_P7.f_req && !`HG_SCOPE_P7.f_we && !`HG_SCOPE_P7.f_n4 &&
  `HG_SCOPE_P7.f_addr==32'h04000130 && `HG_SCOPE_P7.f_be==3 &&
  !`HG_SCOPE_P7.f_ack && !`HG_SCOPE_P7.f_rvalid &&
  `HG_READ_FAB.a7_req===`HG_SCOPE_P7.f_req &&
  `HG_READ_FAB.a7_addr===`HG_SCOPE_P7.f_addr &&
  `HG_READ_FAB.a7_be===`HG_SCOPE_P7.f_be &&
  `HG_READ_FAB.a7_we===`HG_SCOPE_P7.f_we &&
  `HG_READ_FAB.mst==1 && `HG_READ_FAB.st==`HG_READ_FAB.S_FILL &&
  hg193_scope_arm9();
endfunction
function automatic bit hg193_scope_bridge();
 bit histories;
 histories=1;
 for(int i=0;i<4;i++)histories &= hg_bridge_valid[i] &&
  hg_bridge_addr[i]==32'hf8001000 && hg_bridge_read[i] && !hg_bridge_write[i];
 return hg_scope_held && hg_scope_original_phase && histories &&
  hg_bridge_rd && !hg_bridge_wr && hg_bridge_current==32'hf8001000 &&
  `HG_SCOPE_MBOX.el && `HG_SCOPE_MBOX.in_cmd && `HG_SCOPE_MBOX.b_map==96 &&
  `HG_SCOPE_MBOX.b_addr==96 && !`HG_SCOPE_MBOX.b_we && `HG_SCOPE_MBOX.wf_n==7 &&
  !`HG_SCOPE_MBOX.f0 && !`HG_SCOPE_MBOX.f1 && !`HG_SCOPE_MBOX.f2 && !`HG_SCOPE_MBOX.fw_v &&
  `HG_SCOPE_MBOX.b_q==32'h6f6b0000 && `HG_SCOPE_MBOX.b_qr==32'h6f6b0000 &&
  `HG_SCOPE_MBOX.b_q2==32'h6f6b0000 && `HG_SCOPE_MBOX.bridge_rd_data==32'h00006b6f;
endfunction
// Family order is exactly the original combined-drain function's eleven terms.
// Each scoped bit replaces only its own family's affected clause, with all
// residual clauses retained by generated_scoped_drain.svh. Unaffected bits
// cannot be replaced, including FIFO/controller/GPU microphase predicates.
function automatic bit hg193_scoped_combine(input bit enable,
 input bit [10:0] original,input bit [10:0] scoped);
 bit [10:0] result;
 if(!enable)return &original;
 result=original | (scoped & 11'b10001001111);
 return &result;
endfunction
