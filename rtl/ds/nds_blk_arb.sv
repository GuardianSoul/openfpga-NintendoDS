// Two clients on nds_vram's 32-byte block port (docs/phase2-integration.md,
// "3D"): the 2D engine (a, first: it has line deadlines) and the 3D
// texture/palette caches (b). The port acknowledges a request in the cycle
// it is presented (both clients hold theirs until ack), so the choice is
// combinational. Blocks may be in flight from both clients at once; their
// four beats each come back in acknowledge order, and an owner queue routes
// them.
module nds_blk_arb
    import gpu2d_pkg::*;
#(
    // TXF (the 2D block-read fix): the 3D texture / palette blocks (b) go first unless the 2D engine's line is near its
    // deadline (a_hurry: nds_disp HURRY_AT); 0: the 2D engine (a) always first. The 2D side keeps its line's slack, the
    // raster stops waiting behind 2D prefetch bursts
    parameter bit TXF = 0
) (
    input  logic clk,
    input  logic rst,
    input  logic a_req,
    input  logic a_hurry,        // TXF: the 2D engine's blocks are urgent (hurry2d)
    input  blk_t a_blk,
    input  logic [1:0] a_word,   // a's first 64-bit word (gpu2d CWF; b's blocks start at 0)
    output logic a_ack,
    output logic a_rvalid,
    input  logic b_req,
    input  blk_t b_blk,
    output logic b_ack,
    output logic b_rvalid,
    output logic g_req,
    output blk_t g_blk,
    output logic [1:0] g_word,
    input  logic g_ack,
    input  logic g_rvalid
);
    wire pick_b = TXF ? b_req && !(a_req && a_hurry) : !a_req;
    assign g_req = a_req || b_req;
    assign g_blk = pick_b ? b_blk : a_blk;
    assign g_word = pick_b ? 2'd0 : a_word;
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
