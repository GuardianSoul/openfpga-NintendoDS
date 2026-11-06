  // Observation only. These assertions do not drive pipeline or service.
  logic slot_cpu_stalled = 0;
  logic [31:0] slot_cpu_stalled_address;
  integer slot_cpu_offers = 0, slot_cpu_accepts = 0, slot_cpu_waits = 0;
  integer slot_cpu_cancels = 0;
  always @(posedge clk) begin
    if (rst) begin
      slot_cpu_stalled <= 0;
      slot_cpu_offers <= 0; slot_cpu_accepts <= 0;
      slot_cpu_waits <= 0; slot_cpu_cancels <= 0;
    end else begin
      if (slot_cpu_stalled && !i_redirect)
        assert (i_commit_valid && i_commit_addr == slot_cpu_stalled_address)
          else $fatal(1,"CPU_SLOT_UNACCEPTED_OFFER_CHANGED");
      if (phase_commit_pending)
        assert (!i_consume) else $fatal(1,"CPU_SLOT_PENDING_OVERWRITE");
      if (phase_prepare)
        assert (phase_owner_live || phase_f_finish)
          else $fatal(1,"CPU_SLOT_PREPARE_WITHOUT_MATCHING_FINISH");
      if (phase_next_commit) begin
        slot_cpu_offers <= slot_cpu_offers + 1;
        assert (i_consume && !e_busy && phase_prepared && phase_owner_live &&
                phase_prepared_address == {phase_f_owner,2'b00} + 32'd4 &&
                phase_prepared_address == i_addr + 32'd4)
          else $fatal(1,"CPU_SLOT_COMMIT_WRONG_ORIGINAL_F_OWNER");
      end
      if (i_commit_accept) begin
        slot_cpu_accepts <= slot_cpu_accepts + 1;
        assert (i_commit_valid && !i_redirect && i_arm &&
                i_commit_addr[31:24] == 8'h02 && i_commit_addr[1:0] == 0)
          else $fatal(1,"CPU_SLOT_ACCEPT_WITHOUT_OFFER");
      end
      if (i_commit_valid && !i_commit_accept)
        slot_cpu_waits <= slot_cpu_waits + 1;
      if (i_redirect) begin
        if (phase_commit_pending) slot_cpu_cancels <= slot_cpu_cancels + 1;
        assert (!i_commit_valid) else $fatal(1,"CPU_SLOT_OFFER_ON_REDIRECT");
      end
      slot_cpu_stalled <= i_commit_valid && !i_commit_accept;
      slot_cpu_stalled_address <= i_commit_addr;
    end
  end
