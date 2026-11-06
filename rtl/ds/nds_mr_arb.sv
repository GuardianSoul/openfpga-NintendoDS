// Two clients on the main-RAM port (PSRAM, docs/phase2-integration.md,
// "3D"): the bus fabric (a: CPUs, DMA, sound; first) and the 3D polygon
// store (b, nds_g3d_store, at 0x400000 and up), taking turns when both
// wait. A request is held until ack;
// a read then returns four words (rvalid), and the port stays with its
// client until the fourth.
module nds_mr_arb (
    input  logic        clk,
    input  logic        rst,
    input  logic        a_req,
    input  logic        a_we,
    input  logic [21:2] a_addr,
    input  logic [3:0]  a_be,
    input  logic [31:0] a_wdata,
    output logic        a_ack,
    output logic        a_rvalid,
    input  logic        a_n8,               // a 32-byte block (nds_fabric MR_BLOCK): 8 read words / mr_wnext writes
    output logic        a_wnext,
    input  logic        b_req,
    input  logic        b_we,
    input  logic [22:2] b_addr,
    input  logic [31:0] b_wdata,
    output logic        b_ack,
    output logic        b_rvalid,
    output logic        mr_req,
    output logic        mr_we,
    output logic [22:2] mr_addr,
    output logic [3:0]  mr_be,
    output logic [31:0] mr_wdata,
    input  logic        mr_ack,
    input  logic        mr_rvalid,
    output logic        mr_n8,
    input  logic        mr_wnext
);
    typedef enum logic [1:0] { O_NONE, O_A, O_B } own_t;
    own_t       own;
    logic [2:0] beat;
    logic       rd;                       // waiting for the read's words
    logic       last_a;
    wire sel_n8 = own == O_A && a_n8;
    always_ff @(posedge clk) begin
        if (rst) begin own <= O_NONE; rd <= 1'b0; beat <= 3'd0; last_a <= 1'b0; end
        else if (own == O_NONE) begin
            if (a_req && !(b_req && last_a && !b_we)) begin own <= O_A; last_a <= 1'b1; end     // the store's writes wait in its queue behind the CPUs and DMA
            else if (b_req) begin own <= O_B; last_a <= 1'b0; end
        end else if (!rd) begin
            if (mr_ack) begin
                if (mr_we) own <= O_NONE;
                else begin rd <= 1'b1; beat <= 3'd0; end
            end
        end else if (mr_rvalid) begin
            beat <= beat + 3'd1;
            if (beat == (sel_n8 ? 3'd7 : 3'd3)) begin rd <= 1'b0; own <= O_NONE; end
        end
    end
    wire sel_b = own == O_B;
    assign mr_n8   = sel_n8;
    assign a_wnext = own == O_A && !rd && mr_wnext;
    assign mr_req   = own != O_NONE && !rd;
    assign mr_we    = sel_b ? b_we : a_we;
    assign mr_addr  = sel_b ? b_addr : {1'b0, a_addr};
    assign mr_be    = sel_b ? 4'hF : a_be;
    assign mr_wdata = sel_b ? b_wdata : a_wdata;
    assign a_ack    = own == O_A && !rd && mr_ack;
    assign b_ack    = sel_b && !rd && mr_ack;
    assign a_rvalid = own == O_A && rd && mr_rvalid;
    assign b_rvalid = sel_b && rd && mr_rvalid;
endmodule
