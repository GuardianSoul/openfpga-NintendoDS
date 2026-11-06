// System-block RAMs (docs/system-blocks.md). Simple dual-port, one write
// port and one registered read port, single clock. Written as Quartus's
// byte-enable template (unrolled lane writes, no initialiser): the generic
// loop form does not infer M10K (nds-fit #27, docs/2d-engine.md). All are
// pinned to M10K: they are small, and LABs are the scarce resource.

// 96-bit words in three 32-bit lanes, a byte enable per byte (the DMA state).
module sys_ram96 #(
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          we,
    input  logic [11:0]   be,
    input  logic [AW-1:0] waddr,
    input  logic [95:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [95:0]   rdata
);
    (* ramstyle = "M10K" *) logic [11:0][7:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[0])  mem[waddr][0]  <= wdata[7:0];
            if (be[1])  mem[waddr][1]  <= wdata[15:8];
            if (be[2])  mem[waddr][2]  <= wdata[23:16];
            if (be[3])  mem[waddr][3]  <= wdata[31:24];
            if (be[4])  mem[waddr][4]  <= wdata[39:32];
            if (be[5])  mem[waddr][5]  <= wdata[47:40];
            if (be[6])  mem[waddr][6]  <= wdata[55:48];
            if (be[7])  mem[waddr][7]  <= wdata[63:56];
            if (be[8])  mem[waddr][8]  <= wdata[71:64];
            if (be[9])  mem[waddr][9]  <= wdata[79:72];
            if (be[10]) mem[waddr][10] <= wdata[87:80];
            if (be[11]) mem[waddr][11] <= wdata[95:88];
        end
        rdata <= mem[raddr];
    end
endmodule

// Plain words (the IPC FIFOs).
module sys_ram #(
    parameter int W  = 32,
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = "M10K" *) logic [W-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// 32-bit words with byte enables (DMA CNT).
module sys_ram32be #(
    parameter int AW = 3
) (
    input  logic          clk,
    input  logic          we,
    input  logic [3:0]    be,
    input  logic [AW-1:0] waddr,
    input  logic [31:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [31:0]   rdata
);
    (* ramstyle = "M10K" *) logic [3:0][7:0] mem [0:(1<<AW)-1];
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

// 64-bit words in two 32-bit lanes with byte enables (the register copy).
module sys_ram64be #(
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          we,
    input  logic [7:0]    be,
    input  logic [AW-1:0] waddr,
    input  logic [63:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [63:0]   rdata
);
    (* ramstyle = "M10K" *) logic [7:0][7:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[waddr][0] <= wdata[7:0];
            if (be[1]) mem[waddr][1] <= wdata[15:8];
            if (be[2]) mem[waddr][2] <= wdata[23:16];
            if (be[3]) mem[waddr][3] <= wdata[31:24];
            if (be[4]) mem[waddr][4] <= wdata[39:32];
            if (be[5]) mem[waddr][5] <= wdata[47:40];
            if (be[6]) mem[waddr][6] <= wdata[55:48];
            if (be[7]) mem[waddr][7] <= wdata[63:56];
        end
        rdata <= mem[raddr];
    end
endmodule
// The same 64-bit words double-pumped (PUMP; docs/system-blocks.md): one
// 32-bit-wide block on clk2 = 2 x clk (phase 0, the same PLL), the word as
// two halves {addr, half}, so 2 M10Ks become 1. At the clk edge E (the clk2
// edge that coincides with it) the block reads the low half at raddr and
// writes the high half of the write sampled at the edge before; at the clk2
// edge in the middle it reads the high half (raddr registered at E), writes
// the low half of the write sampled at E, and keeps the low half read at E.
// rdata = {high, low} from then until the next E: what the plain form reads
// at E (old data on a same-address write) half a clk cycle later.
// `mid` is true in the middle clk2 edge (arm_regfile's PUMP).
module sys_ram64p #(
    parameter int AW   = 5,
    parameter bit INIT = 0          // contents start at 0 (as sys_ram's)
) (
    input  logic          clk,
    input  logic          clk2,
    input  logic          we,
    input  logic [7:0]    be,
    input  logic [AW-1:0] waddr,
    input  logic [63:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [63:0]   rdata
);
    (* ramstyle = "M10K" *) logic [3:0][7:0] mem [0:(2<<AW)-1];
    initial if (INIT) for (int i = 0; i < (2<<AW); i++) mem[i] = '0;
    logic          tg = 1'b0, tq = 1'b0;
    logic          w_v = 1'b0;
    logic [AW-1:0] wa_q, ra_q;
    logic [63:0]   wd_q;
    logic [7:0]    be_q;
    logic [31:0]   rda, hold;
    wire           mid = tg != tq;
    always_ff @(posedge clk) begin
        tg <= ~tg;
        w_v <= we; wa_q <= waddr; wd_q <= wdata; be_q <= be; ra_q <= raddr;
    end
    wire [AW:0]  wa  = {wa_q, !mid};
    wire [3:0]   wbe = w_v ? (mid ? be_q[3:0] : be_q[7:4]) : 4'd0;
    wire [31:0]  wd  = mid ? wd_q[31:0] : wd_q[63:32];
    always_ff @(posedge clk2) begin
        tq <= tg;
        if (wbe[0]) mem[wa][0] <= wd[7:0];
        if (wbe[1]) mem[wa][1] <= wd[15:8];
        if (wbe[2]) mem[wa][2] <= wd[23:16];
        if (wbe[3]) mem[wa][3] <= wd[31:24];
        rda <= mem[mid ? {ra_q, 1'b1} : {raddr, 1'b0}];
        if (mid) hold <= rda;
    end
    assign rdata = {rda, hold};
endmodule
// 64-bit words written whole, read a 32-bit half at a time (sys_math's
// results, PUMP): one 32-bit block, 2 M10Ks become 1. The write port runs on
// clk2 = 2 x clk (phase 0): at the clk edge E (the clk2 edge that coincides
// with it) it writes the low half of the write sampled there, at the middle
// edge the high half (registered at E); so both are in before the next clk
// edge, as the plain form's write at E. The read port is on clk: rdata is the
// half rhi of the word at raddr, read at E as the plain form's. A read and a
// write never meet on one address in a clk cycle (the user reads one bank
// and writes the other), so the two clocks' read-during-write is never seen.
module sys_ram64w #(
    parameter int AW = 3
) (
    input  logic          clk,
    input  logic          clk2,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [63:0]   wdata,
    input  logic [AW-1:0] raddr,
    input  logic          rhi,
    output logic [31:0]   rdata
);
    (* ramstyle = "M10K" *) logic [31:0] mem [0:(2<<AW)-1];
    initial for (int i = 0; i < (2<<AW); i++) mem[i] = '0;
    logic          tg = 1'b0, tq = 1'b0;
    logic          w_v = 1'b0;
    logic [AW-1:0] wa_q;
    logic [31:0]   wd_q;
    wire           mid = tg != tq;
    always_ff @(posedge clk) begin
        tg <= ~tg;
        w_v <= we; wa_q <= waddr; wd_q <= wdata[63:32];
        rdata <= mem[{raddr, rhi}];
    end
    always_ff @(posedge clk2) begin
        tq <= tg;
        if (mid ? w_v : we) mem[mid ? {wa_q, 1'b1} : {waddr, 1'b0}] <= mid ? wd_q : wdata[31:0];
    end
endmodule
