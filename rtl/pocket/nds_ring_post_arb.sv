// Bounded SYS-side posters into the existing shared SDRAM write FIFO.
// A ring/spill/store block stays atomic (up to8 words, or rg_last at4).
// Other sources release their turn when empty or after8 accepted words.
module nds_ring_post_arb (
    input logic clk, reset,
    input logic video_req, ring_req, capture_req, ring_last, full,
    output logic video_ack, ring_ack, capture_ack
);
    logic active;
    logic [1:0] owner, cursor;
    logic [2:0] count;
    wire [2:0] requests = {capture_req,ring_req,video_req};
    logic any;
    logic [1:0] pick;
    function automatic [1:0] successor(input logic [1:0] p);
        return p == 2 ? 2'd0 : p + 2'd1;
    endfunction
    always_comb begin
        logic [1:0] start, p;
        start = active ? successor(owner) : cursor;
        any = 0; pick = 0;
        for (int n = 2; n >= 0; n--) begin
            p = start + 2'(n);
            // The sum must not wrap modulo4 before reducing modulo3.
            if (int'(start) + n >= 3) p = 2'(int'(start) + n - 3);
            if (requests[p]) begin any = 1; pick = p; end
        end
        if (active && requests[owner]) begin any = 1; pick = owner; end
    end
    assign video_ack = !reset && !full && any && pick == 0;
    assign ring_ack = !reset && !full && any && pick == 1;
    assign capture_ack = !reset && !full && any && pick == 2;
    always_ff @(posedge clk) begin
        if (reset) begin active <= 0; owner <= 0; cursor <= 0; count <= 0; end
        else begin
            if (active && !requests[owner]) begin active <= 0; cursor <= successor(owner); count <= 0; end
            if (video_ack || ring_ack || capture_ack) begin
                owner <= pick;
                if (active && pick == owner) count <= count + 3'd1;
                else count <= 3'd1;
                if ((active && pick == owner && count == 7) || (pick == 1 && ring_last)) begin
                    active <= 0; count <= 0; cursor <= successor(pick);
                end else active <= 1;
            end
        end
    end
endmodule
