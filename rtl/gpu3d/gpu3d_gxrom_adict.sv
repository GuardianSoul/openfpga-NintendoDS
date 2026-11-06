// Full-word A-ROM dictionary. M samples the PC class; E returns its exact
// word at the old SYS instruction edge. The caller supplies aligned clk2
// and SYS-held non-reset addresses. Actual Pocket reset release is SYS.
module gpu3d_gxrom_adict #(
    parameter logic [20479:0] INDEX_BITS = '0,
    parameter logic [35839:0] WORD_LO_BITS = '0,
    parameter logic [35839:0] WORD_HI_BITS = '0,
    parameter logic [69:0] RESET_WORD = '0
) (
    input logic clk, clk2, rst,
    input logic [10:0] addr,
    output wire [69:0] q
);
    (* romstyle = "M10K", rom_style = "block" *) logic [9:0] index_mem [0:2047];
    (* romstyle = "M10K", rom_style = "block" *) logic [69:0] word_mem [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 2048; i = i + 1) index_mem[i] = INDEX_BITS[10*i +: 10];
        for (i = 0; i < 512; i = i + 1) word_mem[i] = WORD_LO_BITS[70*i +: 70];
        for (i = 0; i < 512; i = i + 1) word_mem[i+512] = WORD_HI_BITS[70*i +: 70];
    end
    logic tg = 1'b0, tq = 1'b0, ph = 1'b0;
    logic [9:0] index_q;
    logic [69:0] word_q;
    logic reset_q;
    // As the existing private pumps: ph is true at M, false at E once
    // aligned. Phase continues during reset; Pocket holds reset for three
    // SYS edges after PLL lock. The reset word covers acquisition/first E.
    always_ff @(posedge clk) begin
        tg <= !tg;
        reset_q <= rst;
    end
    always_ff @(posedge clk2) begin
        tq <= tg;
        ph <= tg == tq;
        if (ph) index_q <= index_mem[addr];
        else word_q <= word_mem[index_q];
    end
    // Assertion can arrive after M. Sample it at E, just as the original
    // ROM samples rst ? RESET : next_pc; never change q asynchronously.
    assign q = reset_q ? RESET_WORD : word_q;
endmodule
