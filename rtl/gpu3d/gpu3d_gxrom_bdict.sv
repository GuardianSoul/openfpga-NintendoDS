// Exact B word and its expanded immediate in the existing two SYS stages.
// No reset or new clock: like the original B2/TIMM path, both stages keep
// running through reset. The actual caller removes its preview feedback.
module gpu3d_gxrom_bdict #(
    parameter logic [18431:0] INDEX_BITS = '0,
    parameter logic [34303:0] WORD_BITS = '0
) (
    input logic clk,
    input logic [10:0] addr,
    output logic [66:0] q
);
    (* romstyle = "M10K", rom_style = "block" *) logic [8:0] index_mem [0:2047];
    (* romstyle = "M10K", rom_style = "block" *) logic [66:0] word_mem [0:511];
    logic [8:0] index_q;
    initial begin
        for (int i = 0; i < 2048; i++) index_mem[i] = INDEX_BITS[9*i +: 9];
        for (int i = 0; i < 512; i++) word_mem[i] = WORD_BITS[67*i +: 67];
    end
    always_ff @(posedge clk) begin
        index_q <= index_mem[addr];
        q <= word_mem[index_q];
    end
endmodule
