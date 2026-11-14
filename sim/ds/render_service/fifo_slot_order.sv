`timescale 1ns/1ps
module fifo_slot_order;
    logic clk = 0;
    always #5 clk = !clk;
    logic reset = 1, full = 0, ring_last = 0;
    logic video_req = 0, ring_req = 0, capture_req = 0;
    logic cap_slot_tight = 0, cap_pair_assembling = 0, cap_pair_ready = 0;
    wire video_ack, ring_ack, capture_ack;
    wire old_video, old_ring, old_capture;
    wire [2:0] grants = {capture_ack,ring_ack,video_ack};

    nds_ring_post_arb dut (.*);
    nds_ring_post_arb_control baseline (.clk,.reset,.full,.ring_last,.video_req,.ring_req,.capture_req,
        .video_ack(old_video),.ring_ack(old_ring),.capture_ack(old_capture));

    task automatic edge_check(input logic [2:0] expected, input string reason);
        #1;
        if (grants !== expected) $fatal(1, "%s actual=%b expected=%b", reason, grants, expected);
        @(negedge clk);
    endtask

    task automatic restart;
        reset = 1;
        @(negedge clk);
        reset = 0;
    endtask

    logic [15:0] lfsr = 16'h618d;
    initial begin
        @(negedge clk);
        reset = 0;
        repeat (2048) begin
            lfsr = {lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            {full,ring_last,video_req,ring_req,capture_req,cap_pair_assembling,cap_pair_ready} = lfsr[6:0];
            #1;
            if (grants !== {old_capture,old_ring,old_video} ||
                {dut.active,dut.owner,dut.cursor,dut.count} !==
                {baseline.active,baseline.owner,baseline.cursor,baseline.count})
                $fatal(1, "DISABLED_POSTER_INVERSE");
            @(negedge clk);
        end

        restart();
        full = 0; ring_last = 0; video_req = 0; ring_req = 1; capture_req = 0;
        cap_slot_tight = 1; cap_pair_assembling = 1; cap_pair_ready = 0;
        edge_check(0,"FREE_SLOT_CONSUMED_BEFORE_PAIR");
        cap_pair_assembling = 0; cap_pair_ready = 1; capture_req = 1;
        edge_check(3'b100,"RESERVATION_LOST_AT_PAIR");
        cap_pair_ready = 0; capture_req = 0; cap_pair_assembling = 1;
        edge_check(3'b010,"REPEATED_RESERVATION_WITHOUT_RING_SERVICE");

        // A started ring group owns all its remaining accepted words.
        cap_pair_assembling = 1;
        repeat (7) edge_check(3'b010,"STARTED_RING_GROUP_SPLIT");
        cap_pair_assembling = 0; cap_pair_ready = 1; capture_req = 1;
        edge_check(3'b100,"CAPTURE_LOST_AFTER_RING_GROUP");

        // A full FIFO can postpone the paired post. A CPU write ACK while
        // the pair is still assembling must not end the reservation.
        restart();
        cap_pair_ready = 0; capture_req = 0; cap_pair_assembling = 1;
        edge_check(0,"RESERVE_DURING_ASSEMBLY");
        capture_req = 1;
        edge_check(3'b100,"CPU_POST_EXEMPT");
        full = 1; cap_pair_assembling = 0; cap_pair_ready = 1;
        edge_check(0,"FULL_FIFO_ACCEPTED");
        full = 0;
        edge_check(3'b100,"PAIR_LOST_WHILE_FULL");

        // A lone-half timeout ends the reservation without a pair ACK.
        restart();
        capture_req = 0; cap_pair_ready = 0; cap_pair_assembling = 1;
        edge_check(0,"RESERVE_BEFORE_TIMEOUT");
        cap_pair_assembling = 0;
        edge_check(3'b010,"RING_STARVED_AFTER_TIMEOUT");
        $display("FIFO_SLOT_ORDER_PASS inverse_cycles=2048");
        $finish;
    end
endmodule
