 // Independent logical-owner ledger. It changes no CPU/P7 stimulus or
 // original captures. Raw qualified I events and architectural E PC are
 // joined to the new exported channel, without assigning any service cost.
 bit phase_obs_live=0;
 logic [31:0] phase_obs_addr;
 logic [1:0] phase_obs_gen=0;
 integer phase_obs_starts=0,phase_obs_advances=0,phase_obs_accepts=0,phase_obs_cancels=0;
 integer phase_obs_fd;
 string phase_obs_path;
 initial begin
  if(!$value$plusargs("phase_out=%s",phase_obs_path))phase_obs_path="if-phase.csv";
  phase_obs_fd=$fopen(phase_obs_path,"w");assert(phase_obs_fd)else $fatal(1,"PHASE_META_LOG");
  $fdisplay(phase_obs_fd,"cycle,pc,raw_start,raw_advance,old_commit,old_accept,cancel,generation,owner_valid,start,advance,address,commit,accepted");
 end
 always @(posedge clk)begin
  if(!PHASE_META||!COMMIT)begin
   assert(phase_meta=='0)else $fatal(1,"PHASE_META_DISABLED_NONZERO");
  end else begin
   assert(phase_meta.cancel==(cpu_rst||iredirect))else $fatal(1,"PHASE_META_CANCEL");
   if(cpu_rst)begin
    phase_obs_live=0;phase_obs_gen=0;
    phase_obs_starts=0;phase_obs_advances=0;phase_obs_accepts=0;phase_obs_cancels=0;
   end else begin
    assert(phase_meta.generation==phase_obs_gen)else $fatal(1,"PHASE_META_GENERATION");
    if(iredirect)begin
     assert(!phase_meta.owner_valid&&!phase_meta.start&&!phase_meta.advance&&!phase_meta.commit_valid&&!phase_meta.commit_accepted&&phase_meta.address==0)
      else $fatal(1,"PHASE_META_CANCEL_PRIORITY");
     if(phase_obs_live)phase_obs_cancels++;
     phase_obs_live=0;phase_obs_gen=phase_obs_gen+2'd1;
    end else begin
     assert(phase_meta.start==cpu.phase_prepare&&phase_meta.advance==cpu.phase_internal_start)
      else $fatal(1,"PHASE_META_REAL_ADVANCE");
     assert(phase_meta.commit_valid==cv&&phase_meta.commit_accepted==(cv&&ca))
      else $fatal(1,"PHASE_META_ADMISSION_CHANGED");
     if(phase_meta.start)begin
      assert(!phase_obs_live&&phase_meta.advance)else $fatal(1,"PHASE_META_DUPLICATE_START");
      phase_obs_live=1;phase_obs_addr=cpu.pc+32'd12;phase_obs_starts++;
     end
     assert(phase_meta.owner_valid==phase_obs_live)else $fatal(1,"PHASE_META_OWNER_LIFETIME");
     if(phase_obs_live)assert(phase_meta.address==phase_obs_addr)
      else $fatal(1,"PHASE_META_WRONG_OWNER_ADDRESS expected%h actual%h",phase_obs_addr,phase_meta.address);
     else assert(phase_meta.address==0)else $fatal(1,"PHASE_META_INACTIVE_ADDRESS");
     if(phase_meta.advance)begin
      assert(phase_obs_live&&run&&cpu.ph&&!cpu.halted)else $fatal(1,"PHASE_META_PHANTOM_ADVANCE");
      phase_obs_advances++;
     end
     if(phase_meta.commit_accepted)begin
      assert(phase_obs_live)else $fatal(1,"PHASE_META_UNOWNED_ACCEPT");
      phase_obs_live=0;phase_obs_accepts++;
     end
    end
   end
   $fdisplay(phase_obs_fd,"%0d,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08x,%0d,%0d",
    cycle,cpu.pc,cpu.phase_prepare,cpu.phase_internal_start,cv,ca,phase_meta.cancel,phase_meta.generation,
    phase_meta.owner_valid,phase_meta.start,phase_meta.advance,phase_meta.address,phase_meta.commit_valid,phase_meta.commit_accepted);
  end
 end
