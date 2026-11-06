// Two clients on nds_vram's 32-byte block port (docs/phase2-integration.md,
// "3D"): the 2D engine (a, first: it has line deadlines) and the 3D
// texture/palette caches (b). The port acknowledges a request in the cycle
// it is presented (both clients hold theirs until ack), so the choice is
// combinational. Blocks may be in flight from both clients at once; their
// four beats each come back in acknowledge order, and an owner queue routes
// them.
module nds_blk_arb
    import gpu2d_pkg::*;
(
    input  logic clk,
    input  logic rst,
    input  logic a_req,
    input  blk_t a_blk,
    output logic a_ack,
    output logic a_rvalid,
    input  logic b_req,
    input  blk_t b_blk,
    output logic b_ack,
    output logic b_rvalid,
    output logic g_req,
    output blk_t g_blk,
    input  logic g_ack,
    input  logic g_rvalid
);
    wire pick_b = !a_req;
    assign g_req = a_req || b_req;
    assign g_blk = pick_b ? b_blk : a_blk;
    assign a_ack = g_ack && !pick_b;
    assign b_ack = g_ack && pick_b;
    // owners of the blocks acknowledged and not yet delivered
    logic [3:0] own;
    logic [1:0] rp, wp, beat;
    wire        head = own[rp];
    assign a_rvalid = g_rvalid && !head;
    assign b_rvalid = g_rvalid && head;
    always_ff @(posedge clk) begin
        if (rst) begin rp <= 2'd0; wp <= 2'd0; beat <= 2'd0; end
        else begin
            if (g_ack) begin own[wp] <= pick_b; wp <= wp + 2'd1; end
            if (g_rvalid) begin
                beat <= beat + 2'd1;
                if (beat == 2'd3) rp <= rp + 2'd1;
            end
        end
    end
endmodule
