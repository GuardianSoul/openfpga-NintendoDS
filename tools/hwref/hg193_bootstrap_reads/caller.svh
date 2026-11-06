// Read-only observer for the exact CPU_FAST0/A9_SOLO5 path. No DUT writes.
// Define HG_READ_MEM, HG_READ_FAB, HG_READ_ARB, HG_READ_PHY,
// HG_READ_CLK, HG_READ_RST and HG_READ_DOMAIN_MATCH before including.
// Observer ordinals are labels, not invented DUT transaction IDs.
logic hg_read_bad=0,hg_read_accepted_v=0,hg_read_physical_v=0;
logic [63:0] hg_read_serial=0,hg_read_accepted_id=0,hg_read_physical_id=0;
logic [31:0] hg_read_accepted_addr=0,hg_read_physical_base=0;
logic [1:0] hg_read_accepted_master=0,hg_read_physical_owner=0;
logic hg_read_accepted_write=0,hg_read_accepted_block=0;
logic hg_read_physical_write=0,hg_read_physical_typed=0;
logic [3:0] hg_read_physical_words=0,hg_read_physical_returned=0;
logic hg_read_i_done_v=0,hg_read_d_done_v=0,hg_read_key_v=0;
logic [31:0] hg_read_i_done_a=0,hg_read_i_done_d=0,hg_read_d_done_a=0,hg_read_d_done_d=0;
logic [31:0] hg_read_key_data=0;
logic [63:0] hg_read_i_done_id=0,hg_read_d_done_id=0,hg_read_key_id=0;
wire hg_read_key_sample = `HG_READ_FAB.io_ack && !`HG_READ_FAB.we &&
 `HG_READ_FAB.mst==1 && `HG_READ_FAB.addr==32'h04000130 &&
 ((`HG_READ_FAB.st==`HG_READ_FAB.S_GO && `HG_READ_FAB.io_sent) ||
  (`HG_READ_FAB.st==`HG_READ_FAB.S_WAIT && `HG_READ_FAB.tgt_q==`HG_READ_FAB.T_IO));
// With IO_GRANT_EARLY0 the sample occurs in S_WAIT; with1 in S_GO.
always @(posedge `HG_READ_CLK) begin
 if(`HG_READ_RST)begin
  hg_read_bad<=0;hg_read_serial<=0;hg_read_accepted_v<=0;hg_read_physical_v<=0;
  hg_read_i_done_v<=0;hg_read_d_done_v<=0;hg_read_key_v<=0;
  hg_read_physical_returned<=0;
 end else begin
  if(`HG_READ_FAB.st==`HG_READ_FAB.S_IDLE && |`HG_READ_FAB.grant)begin
   hg_read_serial<=hg_read_serial+1;
   if(&hg_read_serial)hg_read_bad<=1; // no observer ordinal wrap
   hg_read_accepted_v<=1;hg_read_accepted_id<=hg_read_serial+1;
   hg_read_accepted_master<=`HG_READ_FAB.grant[0]?0:`HG_READ_FAB.grant[1]?1:`HG_READ_FAB.grant[2]?2:3;
   hg_read_accepted_addr<=`HG_READ_FAB.grant[1]?`HG_READ_FAB.a9_addr:`HG_READ_FAB.g_addr;
   hg_read_accepted_write<=`HG_READ_FAB.grant[1]?`HG_READ_FAB.a9_we:`HG_READ_FAB.g_we;
   hg_read_accepted_block<=`HG_READ_FAB.grant[1] && `HG_READ_FAB.a9_n8;
  end
  if(`HG_READ_FAB.st!=`HG_READ_FAB.S_IDLE && `HG_READ_FAB.done)
   hg_read_accepted_v<=0;
  if(`HG_READ_PHY.s_req && `HG_READ_PHY.s_ack)begin
   if(!`HG_READ_PHY.s_we)begin
    if(hg_read_physical_v)hg_read_bad<=1;
    hg_read_physical_v<=1;hg_read_physical_owner<=`HG_READ_ARB.own;
    hg_read_physical_id<=hg_read_accepted_id;
    hg_read_physical_base<={9'd0,`HG_READ_ARB.mr_addr[22:4],4'd0};
    hg_read_physical_write<=`HG_READ_PHY.s_we;
    hg_read_physical_typed<=`HG_READ_PHY.s_if4 || `HG_READ_PHY.s_ld4 || `HG_READ_PHY.s_dmaw;
    hg_read_physical_words<=`HG_READ_PHY.s_n8?8:4;hg_read_physical_returned<=0;
   end
  end
  if(`HG_READ_PHY.s_rvalid)begin
   if(!hg_read_physical_v || hg_read_physical_returned>=hg_read_physical_words)
    hg_read_bad<=1;
   else begin
    hg_read_physical_returned<=hg_read_physical_returned+1;
    if(hg_read_physical_returned+1==hg_read_physical_words)hg_read_physical_v<=0;
   end
  end
  if(hg_read_key_sample)begin
   hg_read_key_v<=1;hg_read_key_data<=`HG_READ_FAB.io_rdata;
   hg_read_key_id<=hg_read_accepted_id;
  end
  if(`HG_READ_MEM.b_req && `HG_READ_MEM.b_ack && !`HG_READ_MEM.b_we)begin
   if(((`HG_READ_MEM.st==`HG_READ_MEM.S_IRD1 && hg193_bootstrap_reads::stub_word(`HG_READ_MEM.ip_a)) ||
       (`HG_READ_MEM.st==`HG_READ_MEM.S_RD1 && `HG_READ_MEM.dp_a==32'h04000130)) &&
      (!hg_read_accepted_v || `HG_READ_FAB.mst!=1 ||
       hg_read_accepted_addr!=`HG_READ_MEM.b_addr))hg_read_bad<=1;
   if(`HG_READ_MEM.st==`HG_READ_MEM.S_IRD1)begin
    hg_read_i_done_v<=1;hg_read_i_done_a<=`HG_READ_MEM.ip_a;
    hg_read_i_done_d<=`HG_READ_MEM.b_rdata;hg_read_i_done_id<=hg_read_accepted_id;
   end
   if(`HG_READ_MEM.st==`HG_READ_MEM.S_RD1 && `HG_READ_MEM.dp_a==32'h04000130)begin
    hg_read_d_done_v<=1;hg_read_d_done_a<=`HG_READ_MEM.dp_a;
    hg_read_d_done_d<=`HG_READ_MEM.b_rdata;hg_read_d_done_id<=hg_read_accepted_id;
    if(hg_read_key_sample)begin
     if(`HG_READ_MEM.b_rdata!==`HG_READ_FAB.io_rdata)hg_read_bad<=1;
    end else if(!hg_read_key_v || hg_read_key_id!=hg_read_accepted_id ||
                hg_read_key_data!==`HG_READ_MEM.b_rdata)hg_read_bad<=1;
   end
  end
 end
end
function automatic bit hg193_read_transport_known();
 bit logical_ok,physical_ok,returns_ok;
 logical_ok=(`HG_READ_FAB.st==`HG_READ_FAB.S_IDLE && !hg_read_accepted_v) ||
  (hg_read_accepted_v && `HG_READ_FAB.st!=`HG_READ_FAB.S_IDLE &&
   hg_read_accepted_master===2'd1 && `HG_READ_FAB.mst===2'd1 &&
   !hg_read_accepted_write && !hg_read_accepted_block && !`HG_READ_FAB.we && !`HG_READ_FAB.blk &&
   hg_read_accepted_addr===`HG_READ_FAB.addr &&
   `HG_READ_MEM.b_req && !`HG_READ_MEM.b_we && `HG_READ_MEM.b_addr===hg_read_accepted_addr &&
   (hg193_bootstrap_reads::stub_word(hg_read_accepted_addr) || hg_read_accepted_addr===32'h04000130));
 // The physical quad lives independently of any logical word completion.
 // Unknown pre-ACK/CDC/typed/side/foreign debt remains a rejection.
 physical_ok=(!hg_read_physical_v && `HG_READ_ARB.own==0 && !`HG_READ_ARB.rd &&
    !`HG_READ_PHY.busy && !`HG_READ_PHY.s_req && !`HG_READ_PHY.s_ack && !`HG_READ_PHY.s_rvalid &&
    `HG_READ_PHY.out_n==0 && !`HG_READ_PHY.m_busy &&
    `HG_READ_PHY.req_t==`HG_READ_PHY.req_seen && `HG_READ_PHY.done_t==`HG_READ_PHY.done_seen) ||
  (hg_read_physical_v && hg_read_physical_owner===2'd1 && `HG_READ_ARB.own===2'd1 && `HG_READ_ARB.rd &&
   !hg_read_physical_write && !hg_read_physical_typed && hg_read_physical_words==4 &&
   hg_read_physical_returned<4 && `HG_READ_ARB.beat==hg_read_physical_returned[2:0] &&
   hg_read_physical_id==hg_read_accepted_id && hg_read_accepted_v &&
   `HG_READ_FAB.st==`HG_READ_FAB.S_FILL && `HG_READ_FAB.mst==1 && !`HG_READ_FAB.we &&
   hg193_bootstrap_reads::stub_word(hg_read_accepted_addr) &&
   hg_read_physical_base=={10'd0,hg_read_accepted_addr[21:4],4'd0} &&
   {9'd0,`HG_READ_PHY.b_word,2'd0}==hg_read_physical_base &&
   {`HG_READ_ARB.mr_addr[22:4],2'd0}==hg_read_physical_base[22:2] &&
   ((`HG_READ_PHY.busy && hg_read_physical_returned==0 && `HG_READ_PHY.out_n==0) ||
    `HG_READ_PHY.out_n+hg_read_physical_returned+4'(`HG_READ_PHY.s_rvalid)==4));
 returns_ok=(!`HG_READ_MEM.ibuf_v || (hg_read_i_done_v &&
    `HG_READ_MEM.ibuf_a===hg_read_i_done_a && `HG_READ_MEM.ibuf_d===hg_read_i_done_d)) &&
  (!`HG_READ_MEM.rbuf_v || (hg_read_d_done_v && `HG_READ_MEM.rbuf_a===hg_read_d_done_a &&
    `HG_READ_MEM.rbuf_d===hg_read_d_done_d && hg_read_d_done_a===32'h04000130));
 return !hg_read_bad && logical_ok && physical_ok && returns_ok && (`HG_READ_DOMAIN_MATCH) &&
  `HG_READ_FAB.sd_st==`HG_READ_FAB.SD_IDLE && `HG_READ_FAB.ra_st==`HG_READ_FAB.RA_IDLE &&
  !`HG_READ_FAB.ld4_active && !`HG_READ_FAB.ld4_pending && !`HG_READ_FAB.ld4_req &&
  !`HG_READ_PHY.bw_c && !`HG_READ_PHY.blk && !`HG_READ_PHY.strm &&
  !`HG_READ_PHY.g_active && !`HG_READ_PHY.g_last_pending && `HG_READ_PHY.g_count==0;
endfunction
function automatic hg193_bootstrap_reads::view_t hg193_actual_read_view(
 input bit held,phase_original,stub_bytes_match);
 hg193_bootstrap_reads::view_t v;
 v='0;v.held=held;v.phase_original=phase_original;v.stub_bytes_match=stub_bytes_match;
 v.owner_snapshot_complete=hg193_read_transport_known();
 v.ctrl=`HG_READ_MEM.ctrl;v.fetch_pc=`HG_READ_FETCH_PC;
 v.i_req=`HG_READ_MEM.i_req;v.i_addr=`HG_READ_MEM.i_addr;
 v.f_req=`HG_READ_MEM.f_req;v.f_addr=`HG_READ_MEM.f_addr;
 v.d_req=`HG_READ_MEM.d_req;v.d_we=`HG_READ_MEM.d_we;v.d_addr=`HG_READ_MEM.d_addr;
 v.w_req=`HG_READ_MEM.w_req;v.w_we=`HG_READ_MEM.w_we;v.w_addr=`HG_READ_MEM.w_addr;
 v.cp_req=`HG_READ_MEM.cp_req;v.w_cp=`HG_READ_MEM.w_cp;
 v.dp_v=`HG_READ_MEM.dp_v;v.dp_read=`HG_READ_MEM.dp_kind==1;v.dp_a=`HG_READ_MEM.dp_a;
 v.ip_v=`HG_READ_MEM.ip_v;v.ip_a=`HG_READ_MEM.ip_a;
 v.b_req=`HG_READ_MEM.b_req;v.b_we=`HG_READ_MEM.b_we;v.b_addr=`HG_READ_MEM.b_addr;
 v.ibuf_v=`HG_READ_MEM.ibuf_v;v.ibuf_a=`HG_READ_MEM.ibuf_a;
 v.rbuf_v=`HG_READ_MEM.rbuf_v;v.rbuf_a=`HG_READ_MEM.rbuf_a;v.state=`HG_READ_MEM.st;
 v.pending_write_or_maintenance=`HG_READ_MEM.pf_run || `HG_READ_MEM.wbuf_v ||
  `HG_READ_MEM.nb_owned || `HG_READ_MEM.ev_v || `HG_READ_MEM.qw_v || `HG_READ_MEM.pw_v ||
  `HG_READ_MEM.cmo_done || `HG_READ_MEM.busy_d || `HG_READ_MEM.busy_i ||
  `HG_READ_MEM.col_d || `HG_READ_MEM.col_i;
 v.accepted.valid=hg_read_accepted_v;v.accepted.known=v.owner_snapshot_complete;
 v.accepted.arm9=hg_read_accepted_master==1;v.accepted.write=hg_read_accepted_write;
 v.accepted.address=hg_read_accepted_addr;v.accepted.owner_tag=hg_read_accepted_id[15:0];
 v.accepted.physical_class=hg_read_accepted_addr==32'h04000130 ? 2 : 1;
 v.completed.valid=v.rbuf_v || v.ibuf_v;v.completed.known=v.owner_snapshot_complete;
 v.completed.arm9=1;v.completed.write=0;
 v.completed.address=v.rbuf_v?hg_read_d_done_a:hg_read_i_done_a;
 v.completed.data=v.rbuf_v?hg_read_d_done_d:hg_read_i_done_d;
 v.completed.owner_tag=v.rbuf_v?hg_read_d_done_id[15:0]:hg_read_i_done_id[15:0];
 v.completed.physical_class=v.rbuf_v?2:1;
 return v;
endfunction
function automatic bit hg193_actual_caller_defaultoff(input bit original_strict,
 input bit held,phase_original,stub_bytes_match);
 return hg193_bootstrap_reads::permit(original_strict,
  hg193_bootstrap_reads::PROPOSAL_DEFAULT_ENABLE,
  hg193_actual_read_view(held,phase_original,stub_bytes_match));
endfunction
// Called only as diagnostics before the original first strict assertion.
task automatic hg193_actual_read_diagnostics;
 hg193_bootstrap_reads::view_t v;
 // No claim about stub bytes until exact current stub verification is wired.
 v=hg193_actual_read_view(0,0,0);
 $display("HG193_OWNER known=%0b bad=%0b logical_v=%0b id=%0d master=%0d addr=%08h write=%0b block=%0b physical_v=%0b owner=%0d base=%08h id=%0d words=%0d returned=%0d",v.owner_snapshot_complete,hg_read_bad,hg_read_accepted_v,hg_read_accepted_id,hg_read_accepted_master,hg_read_accepted_addr,hg_read_accepted_write,hg_read_accepted_block,hg_read_physical_v,hg_read_physical_owner,hg_read_physical_base,hg_read_physical_id,hg_read_physical_words,hg_read_physical_returned);
 $display("HG193_OWNER_RET ibuf_v=%0b known=%0b addr=%08h data=%08h id=%0d rbuf_v=%0b known=%0b addr=%08h data=%08h id=%0d key_v=%0b key_data=%08h key_id=%0d default_enable=%0b",`HG_READ_MEM.ibuf_v,hg_read_i_done_v,hg_read_i_done_a,hg_read_i_done_d,hg_read_i_done_id,`HG_READ_MEM.rbuf_v,hg_read_d_done_v,hg_read_d_done_a,hg_read_d_done_d,hg_read_d_done_id,hg_read_key_v,hg_read_key_data,hg_read_key_id,hg193_bootstrap_reads::PROPOSAL_DEFAULT_ENABLE);
 $display("HG193_OWNER_RAW fab_st=%0d mst=%0d addr=%08h we=%0b grant=%h fm_req=%0b fm_ack=%0b fm_rvalid=%0b arb_own=%0d rd=%0b beat=%0d mr_addr=%h phy_busy=%0b out_n=%0d rvalid=%0b b_word=%h req_t=%0b req_seen=%0b done_t=%0b done_seen=%0b domain=%0b",`HG_READ_FAB.st,`HG_READ_FAB.mst,`HG_READ_FAB.addr,`HG_READ_FAB.we,`HG_READ_FAB.grant,`HG_READ_FAB.mr_req,`HG_READ_FAB.mr_ack,`HG_READ_FAB.mr_rvalid,`HG_READ_ARB.own,`HG_READ_ARB.rd,`HG_READ_ARB.beat,`HG_READ_ARB.mr_addr,`HG_READ_PHY.busy,`HG_READ_PHY.out_n,`HG_READ_PHY.s_rvalid,`HG_READ_PHY.b_word,`HG_READ_PHY.req_t,`HG_READ_PHY.req_seen,`HG_READ_PHY.done_t,`HG_READ_PHY.done_seen,(`HG_READ_DOMAIN_MATCH));
endtask
