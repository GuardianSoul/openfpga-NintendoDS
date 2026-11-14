"""Generate private paired actual controllers; no production RTL mutation."""
from pathlib import Path
import subprocess,hashlib,json
R=Path(__file__).resolve().parents[3];O=R/'build/rc10-tags-controller';O.mkdir(parents=True,exist_ok=True)
G=lambda ref,p:subprocess.check_output(['git','show',ref+':'+p],cwd=R,text=True)
original=G('af2b633e','rtl/arm/arm9_mem.sv');s=(R/'rtl/arm/arm9_mem.sv').read_text();assert hashlib.sha256(s.encode()).hexdigest()=='1ef37d8ca591c8abef3a6d967251b6e5a7df1979ddc6bbbd4787f133a80191e8';a=s.index('  arm9_ram #(.AW(DSB), .LANES(WAYS+1)');b=s.index('  // ---------------------------------------------------------------- state machine state',a);old=s[a:b]
update=G('bab41b03','docs/results/rc10-tags-screen-20261110/actual-packed-update.sv')
assert 'd_next=d_saved;'in update
backend='''  // PRIVATE screened backend: two independent full-word true-dual-port banks.
  logic [31:0] packed_d_aq, packed_d_bq, packed_i_aq, packed_i_bq;
  logic [24:0] packed_saved;
  logic packed_owner_i, packed_saved_valid;
  logic [7:0] packed_saved_set;
  wire [39:0] packed_d_new = {dt_ad[41],dt_ad[39:21],dt_ad[20],dt_ad[18:0]};
  wire [20:0] packed_d_word;
  wire [24:0] packed_i_word;
  packed_update u_packed_update(packed_saved[20:0],packed_saved,packed_d_new,it_ad[39:0],
    dt_we[1:0],it_we[1:0],dt_we[2],it_we[2],dt_ad[42],it_ad[40],packed_d_word,packed_i_word);
  arm9_ram #(.AW(8),.LANES(1),.LANE_W(32),.FOLD(0))u_packed_d(.clk(clk),.a_addr(dt_aa),.a_we(|dt_we),.a_d({11'd0,packed_d_word}),.a_q(packed_d_aq),.b_addr(d_addr[12:5]),.b_q(packed_d_bq));
  arm9_ram #(.AW(8),.LANES(1),.LANE_W(32),.FOLD(0))u_packed_i(.clk(clk),.a_addr(it_aa),.a_we(|it_we),.a_d({7'd0,packed_i_word}),.a_q(packed_i_aq),.b_addr(i_addr[12:5]),.b_q(packed_i_bq));
  function automatic [62:0] packed_expand_d(input[31:0]q);
    return {20'd0,q[20],q[19],1'b0,10'h008,q[18:10],q[9],1'b0,10'h008,q[8:0]};
  endfunction
  function automatic [59:0] packed_expand_i(input[31:0]q);
    return {19'd0,q[24],q[23],8'h02,q[22:12],q[11],8'h02,q[10:0]};
  endfunction
  assign dt_aq=packed_expand_d(packed_d_aq);assign dt_bq=packed_expand_d(packed_d_bq);
  assign it_aq=packed_expand_i(packed_i_aq);assign it_bq=packed_expand_i(packed_i_bq);

'''
checks='''
  // PRIVATE unconditional real-controller hooks; no legal-transaction assumption.
  integer audit_d_fill=0,audit_i_fill=0,audit_d_cmo=0,audit_i_cmo=0;
  integer audit_der=0,audit_ier=0,audit_hum=0,audit_d_poison=0,audit_i_poison=0;
  logic audit_prev_d_poison=0,audit_prev_i_poison=0;
  always_ff @(posedge clk) begin
    audit_prev_d_poison <= !rst && (|dt_we) && dt_aa==d_addr[DSB+4:5];
    audit_prev_i_poison <= !rst && (|it_we) && it_aa==i_addr[ISB+4:5];
    if(!rst)begin
      for(int z=0;z<WAYS;z++)begin
        if(dt_we[z]&&dt_ad[z*DLW+DTW+1]&&dt_ad[z*DLW+9+:10]!=10'h008)$fatal(1,"D_VALID_PREFIX");
        if(it_we[z]&&it_ad[z*ILW+ITW]&&it_ad[z*ILW+11+:8]!=8'h02)$fatal(1,"I_VALID_PREFIX");
      end
      if(st==S_TAGW&&dp_kind!=DK_LINE)begin
        if(dp_kind!=DK_FILL||dp_a[31:22]!=10'h008)$fatal(1,"D_CACHED_TRANSACTION");
        audit_d_fill<=audit_d_fill+1;
      end
      if(st==S_ITAGW&&!iline)begin
        if(!ip_cach||ip_a[31:24]!=8'h02||pf_run)$fatal(1,"I_CACHED_TRANSACTION");
        audit_i_fill<=audit_i_fill+1;
      end
      if(st==S_TAGW&&dp_kind==DK_LINE)audit_d_cmo<=audit_d_cmo+1;
      if(st==S_ITAGW&&iline)audit_i_cmo<=audit_i_cmo+1;
      if(der&&wq_e&&d_ok)audit_der<=audit_der+1;
      if(ier&&f_req&&i_ok)audit_ier<=audit_ier+1;
      if(HUM&&st==S_FILL&&dp_kind==DK_FILL&&!w_we&&wd_cach&&wd_hit&&w_addr[DSB+4:5]!=dp_a[DSB+4:5]&&wq_e&&d_ok)audit_hum<=audit_hum+1;
      if(audit_prev_d_poison&&wq_e&&!wcp_e&&!wd_itcm&&!wd_dtcm)begin
        audit_d_poison<=audit_d_poison+1;
        if(d_ok&&!der)$fatal(1,"LIVE_D_POISON");
        if(d_ok&&der&&wd_way!=vway)$fatal(1,"D_POISON_WAY");
      end
      if(audit_prev_i_poison&&f_req&&f_cach&&!(itcm_en&&!itcm_ld&&f_tm))begin
        audit_i_poison<=audit_i_poison+1;
        if(i_ok&&!ier)$fatal(1,"LIVE_I_POISON");
        if(i_ok&&ier&&i_rdata!==ic_bq[vway])$fatal(1,"I_POISON_WAY");
      end
    end
  end
'''
cand_checks='''
  initial if(WAYS!=2||DSB!=8||ISB!=8||!MEM1||PF)$fatal(1,"UNSUPPORTED_PRIVATE_PROFILE");
  always_ff @(posedge clk)begin
    if(rst)packed_saved_valid<=0;
    else begin
      if(st==S_TAG&&k!=0)begin packed_saved<={4'd0,packed_d_aq[20:0]};packed_owner_i<=0;packed_saved_set<=dt_aa;packed_saved_valid<=1;end
      if(st==S_ITAG&&k!=0)begin packed_saved<=packed_i_aq[24:0];packed_owner_i<=1;packed_saved_set<=it_aa;packed_saved_valid<=1;end
      if(st==S_TAGW)begin
        if(!packed_saved_valid||packed_owner_i||packed_saved_set!=dt_aa||packed_saved[20:0]!==packed_d_aq[20:0])$fatal(1,"D_SNAPSHOT_KEY_ROW");
        packed_saved_valid<=0;
      end
      if(st==S_ITAGW)begin
        if(!packed_saved_valid||!packed_owner_i||packed_saved_set!=it_aa||packed_saved!==packed_i_aq[24:0])$fatal(1,"I_SNAPSHOT_KEY_ROW");
        packed_saved_valid<=0;
      end
    end
  end
'''
candidate=s.replace(old,backend);assert candidate.replace(backend,old)==s
before=s.replace('module arm9_mem import','module arm9_mem_before import').replace('\nendmodule','\n'+checks+'\nendmodule')
after=candidate.replace('module arm9_mem import','module arm9_mem_after import').replace('\nendmodule','\n'+checks+cand_checks+'\nendmodule')
(O/'before.sv').write_text(before);(O/'after.sv').write_text(after);(O/'packed_update.sv').write_text(update);(O/'fault-packed_update.sv').write_text(update.replace('d_next=d_saved;',"d_next=21'd0;"))
# Real RAM source is unmodified, including FOLD/mixed-port poison behavior.
for n in ['arm9_ram','arm_pkg']:(O/(n+'.sv')).write_text(G('af2b633e','rtl/arm/'+n+'.sv'))
H=lambda t:hashlib.sha256(t.encode()).hexdigest()
(O/'binding.json').write_text(json.dumps(dict(parent='af2b633e+minimal-I-setway-continuation-fix',original_parent_SHA256=H(original),screen='bab41b03',parent_SHA256=H(s),before_SHA256=H(before),after_SHA256=H(after),updater_SHA256=H(update),exact_controller_inverse=True,only_changes='Private tag backend replacement/snapshot and simulation checks/module names. No controller/request/response/state/CP/TCM/data/dirty edit.',shared_updater_fault='d_next=d_saved -> d_next=0',native_RAM='Unmodifiedaf2arm9_ram, behavioralnative-clock and poison contract; no Quartus claim'),indent=2)+'\n')
print('actual controller inverse + shared updater binding PASS')

(O/'original-before.sv').write_text(original.replace('module arm9_mem import','module arm9_mem_before import'))
(O/'fixed-after-unpacked.sv').write_text(s.replace('module arm9_mem import','module arm9_mem_after import'))
(O/'reverted-after-unpacked.sv').write_text(original.replace('module arm9_mem import','module arm9_mem_after import'))
