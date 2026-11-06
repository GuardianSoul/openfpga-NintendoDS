// Independent sampled owner ledger; no bit below drives service or payload.
bit rx_live=0,rx_check=0;
logic[31:0]rx_address;
logic[1:0]rx_generation;
integer rx_advances=0,rx_commits=0,rx_starts=0,rx_cancels=0;
logic[4:0]rx_expected_left;
always @(posedge clk)begin
 rx_check=0;
 if(!PHASE_SERVICE)begin
  if(p7.phase_live||p7.phase_commit)$fatal(1,"PHASE_RX_DISABLED_ACTIVE");
 end else if(cpu_rst||iredirect||phase_meta.cancel||!phase_meta.owner_valid)begin
  if(rx_live&&(cpu_rst||iredirect||phase_meta.cancel))rx_cancels++;
  rx_live=0;rx_advances=0;
 end else begin
  if(phase_meta.start)begin
   if(rx_live)$fatal(1,"PHASE_RX_DUPLICATE_OWNER");
   rx_live=1;rx_address=cpu.pc+32'd12;rx_generation=phase_meta.generation;rx_advances=0;rx_starts++;
  end
  if(phase_meta.advance)begin
   if(!rx_live||!run||!cpu.ph)$fatal(1,"PHASE_RX_PHANTOM_ADVANCE");
   if(rx_advances<3)rx_advances++;
  end
  if(ca)begin
   if(!rx_live||rx_address!=cvaddr||rx_generation!=phase_meta.generation||rx_advances<1||!p7.phase_commit||p7.phase_advances_now!=rx_advances)
    $fatal(1,"PHASE_RX_OWNER_OR_COUNT");
   rx_expected_left=5'(16-2*rx_advances);rx_check=1;rx_commits++;rx_live=0;rx_advances=0;
  end
 end
end
always @(negedge clk)if(PHASE_SERVICE&&!cpu_rst&&!iredirect)begin
 if(rx_check&&(!p7.flow_v||{p7.flow_a,2'b00}!=rx_address||p7.flow_left!=rx_expected_left))$fatal(1,"PHASE_RX_COMMIT_ELIGIBILITY");
 if(rx_live&&(!p7.phase_live||{p7.phase_address,2'b00}!=rx_address||p7.phase_generation!=rx_generation||p7.phase_advances!=rx_advances))$fatal(1,"PHASE_RX_CAPTURE_OWNER");
end
final $display("PHASE_RECEIVER_CHECK starts%0d commits%0d cancels%0d",rx_starts,rx_commits,rx_cancels);
