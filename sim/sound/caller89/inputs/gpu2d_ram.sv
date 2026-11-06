// Simple dual-port RAM: one write port, one registered read port that
// re-reads its address every clock (callers hold the address to stall).
// Maps to M10K/MLAB. Same-address read/write returns old data.
module gpu2d_ram #(
    parameter int W  = 8,
    parameter int AW = 8
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    logic [W-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// 32-bit words with byte enables (palette and OAM: the CPU writes bytes,
// halfwords and words). Written as Quartus's byte-enable RAM template --
// unrolled byte writes, no initialiser -- because the generic loop form did
// not infer M10K (nds-fit #27: palette and OAM became 16K ALUTs of
// registers and read muxes).
module gpu2d_ram_be #(
    parameter int AW = 8
) (
    input  logic          clk,
    input  logic          we,
    input  logic [3:0]    be,
    input  logic [AW-1:0] waddr,
    input  logic [31:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [31:0]   rdata
);
    logic [3:0][7:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[waddr][0] <= wdata[7:0];
            if (be[1]) mem[waddr][1] <= wdata[15:8];
            if (be[2]) mem[waddr][2] <= wdata[23:16];
            if (be[3]) mem[waddr][3] <= wdata[31:24];
        end
        rdata <= mem[raddr];
    end
endmodule

// MLAB that keeps gpu2d_ram's same-address read/write result (old data):
// no no_rw_check, so Quartus must honour it (a cache's tag RAM is read at
// the index its fill writes: the stalled lookup must see the old tag that
// clock, as the data RAM still holds the old block)
module gpu2d_mlab_od #(
    parameter int W  = 32,
    parameter int AW = 6
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = "MLAB" *) logic [W-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// Small register files: the same, kept in MLAB (M10K is the chip's scarce
// RAM; nds-fit #173).
module gpu2d_mlab #(
    parameter int W  = 32,
    parameter int AW = 6,
    // "M10K": the same registered read in a block (old data on a
    // same-address read and write), where the chip is short of LABs, not M10K
    parameter     STYLE = "MLAB, no_rw_check"
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = STYLE *) logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// MLAB with byte enables (small register banks written by the CPU): one
// gpu2d_mlab per byte lane. (A single array with per-byte writes is not
// inferred as MLAB by Quartus: it became 205 ALMs of logic per 32 words in
// nds-fit #357.)
module gpu2d_mlab_be #(
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic [3:0]    we,
    input  logic [AW-1:0] waddr,
    input  logic [31:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [31:0]   rdata
);
    logic [31:0] q;
    genvar b;
    generate for (b = 0; b < 4; b = b + 1) begin : g_lane
        gpu2d_mlab #(.W(8), .AW(AW)) u_lane (.clk, .we(we[b]), .waddr, .wdata(wdata[b*8 +: 8]), .raddr, .rdata(q[b*8 +: 8]));
    end endgenerate
`ifdef VERILATOR
    // simulation: an MLAB's read of the address written at the same edge is
    // undefined, so it reads as garbage
    logic col;
    always_ff @(posedge clk) col <= we != 4'd0 && waddr == raddr;
    assign rdata = col ? ~q : q;
`else
    assign rdata = q;
`endif
endmodule

// M10K, explicitly (a small table Quartus would otherwise put in MLAB);
// a read of the address written at the same edge gives the old data
module gpu2d_m10k #(
    parameter int W  = 32,
    parameter int AW = 6
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = "M10K" *) logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
