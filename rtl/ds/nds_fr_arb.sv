// The external SRAM's clients (docs/phase2-integration.md, "First fit with
// 3D"): the BIOS7 loader at start-up, the ARM7 port (its store FIFO and
// cache fills) and the fabric (ARM9, DMA, sound to shared WRAM, ARM7 WRAM,
// BIOS7). One access at a time, each request held until done.
//
// The ARM7's posted stores drain before anyone else reads, so a reader never
// sees older data than the ARM7 wrote; otherwise the ARM7 port and the
// fabric take turns. A completed write from the fabric or the loader is
// reported to the ARM7 port (inv) so its caches forget that line.
module nds_fr_arb (
    input  logic        clk,
    input  logic        rst,
    // loader (writes)
    input  logic        l_req,
    input  logic [17:2] l_addr,
    input  logic [31:0] l_wdata,
    output logic        l_done,
    // ARM7 port
    input  logic        a_req,
    input  logic        a_we,
    input  logic [17:2] a_addr,
    input  logic [3:0]  a_be,
    input  logic [31:0] a_wdata,
    input  logic        a_stores,
    output logic        a_done,
    // fabric
    input  logic        f_req,
    input  logic        f_we,
    input  logic [17:2] f_addr,
    input  logic [3:0]  f_be,
    input  logic [31:0] f_wdata,
    output logic        f_done,
    // to the ARM7 port: someone else wrote this word
    output logic        inv,
    output logic [17:2] inv_addr,
    // the SRAM
    output logic        fr_req,
    output logic        fr_we,
    output logic [17:2] fr_addr,
    output logic [3:0]  fr_be,
    output logic [31:0] fr_wdata,
    input  logic        fr_done
);
    typedef enum logic [1:0] { O_NONE, O_L, O_A, O_F } own_t;
    own_t own;
    logic last_f;                       // the fabric went last
    always_ff @(posedge clk) begin
        inv <= 1'b0;
        if (rst) begin own <= O_NONE; last_f <= 1'b0; end
        else if (own == O_NONE) begin
            if (l_req) own <= O_L;
            else if (a_req && (a_stores || last_f || !f_req)) begin own <= O_A; last_f <= 1'b0; end
            else if (f_req && !a_stores) begin own <= O_F; last_f <= 1'b1; end
        end else if (fr_done) begin
            own <= O_NONE;
            if (own == O_L || (own == O_F && f_we)) begin inv <= 1'b1; inv_addr <= fr_addr; end
        end
    end
    assign fr_req   = own != O_NONE;
    assign fr_we    = own == O_L ? 1'b1 : own == O_A ? a_we : f_we;
    assign fr_addr  = own == O_L ? l_addr : own == O_A ? a_addr : f_addr;
    assign fr_be    = own == O_L ? 4'hF : own == O_A ? a_be : f_be;
    assign fr_wdata = own == O_L ? l_wdata : own == O_A ? a_wdata : f_wdata;
    assign l_done   = own == O_L && fr_done;
    assign a_done   = own == O_A && fr_done;
    assign f_done   = own == O_F && fr_done;
endmodule
