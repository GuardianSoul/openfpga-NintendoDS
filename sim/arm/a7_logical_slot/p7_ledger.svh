    // Independent observations of actual handshake and the next stored
    // owner. No ledger bit drives service, ACK, payload or arbitration.
    logic slot_prev_accept = 0, slot_prev_cancel = 0, slot_stalled = 0;
    logic [31:0] slot_accepted_address, slot_stalled_address;
    integer slot_accepts = 0, slot_wait_edges = 0, slot_same_edge = 0;
    logic slot_packet_held = 0;
    logic [37:0] slot_packet_descriptor;
    always @(posedge clk) begin
        if (rst) begin
            slot_prev_accept <= 0; slot_prev_cancel <= 0; slot_stalled <= 0;
            slot_accepts <= 0; slot_wait_edges <= 0; slot_same_edge <= 0;
            slot_packet_held <= 0;
        end else begin
            if (slot_prev_accept)
                assert (flow_v && flow_a == slot_accepted_address[31:2])
                    else $fatal(1, "P7_SLOT_ACCEPTED_OWNER_DROPPED");
            if (slot_prev_cancel)
                assert (!flow_v) else $fatal(1, "P7_SLOT_CANCEL_LOST_PRIORITY");
            if (slot_stalled && !i_redirect)
                assert (i_commit_valid && i_commit_addr == slot_stalled_address)
                    else $fatal(1, "P7_SLOT_PRODUCER_CHANGED_UNACCEPTED_OWNER");
            if (i_commit_valid && !i_commit_accept && !i_redirect)
                slot_wait_edges <= slot_wait_edges + 1;
            if (i_commit_accept) begin
                assert (i_commit_valid && !i_redirect && FLOW && i_arm
                    && i_commit_addr[31:24] == 8'h02 && i_commit_addr[1:0] == 0
                    && (!flow_v || (i_consume && flow_main && flow_ready)))
                    else $fatal(1, "P7_SLOT_ACCEPT_WITHOUT_FREE_OWNER");
                slot_accepts <= slot_accepts + 1;
                if (flow_v) slot_same_edge <= slot_same_edge + 1;
            end
            if (i_redirect)
                assert (!i_commit_accept) else $fatal(1, "P7_SLOT_ACCEPT_ON_CANCEL");
            // CPU-only reset is ORed into i_redirect by the local fixture;
            // the port reset above is a different service boundary.
            if (slot_packet_held)
                assert (f_req && {f_addr, f_ifseq, f_ifgen, f_ifword, f_n4} == slot_packet_descriptor)
                    else $fatal(1, "P7_SLOT_PHYSICAL_OWNER_CHANGED_BEFORE_ACK");
            slot_packet_held <= f_req && f_n4 && !f_ack;
            if (f_req && f_n4)
                slot_packet_descriptor <= {f_addr, f_ifseq, f_ifgen, f_ifword, f_n4};
            slot_prev_accept <= i_commit_accept;
            slot_accepted_address <= i_commit_addr;
            slot_prev_cancel <= i_redirect;
            slot_stalled <= i_commit_valid && !i_commit_accept && !i_redirect;
            slot_stalled_address <= i_commit_addr;
        end
    end
