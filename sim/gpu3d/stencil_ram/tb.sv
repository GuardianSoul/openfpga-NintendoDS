module tb_stencil_ram (
    input logic clk, we,
    input logic [8:0] waddr, raddr,
    input logic [1:0] wdata,
    output logic [1:0] before_q, after_q, mutant_q
);
    gpu3d_ram #(.W(2), .AW(9)) u_before (
        .clk, .we, .waddr, .wdata, .raddr, .rdata(before_q));
    gpu3d_ram #(.W(2), .AW(9), .STYLE("M10K")) u_after (
        .clk, .we, .waddr, .wdata, .raddr, .rdata(after_q));
    gpu3d_ram #(.W(2), .AW(9), .STYLE("M10K")) u_mutant (
        .clk, .we, .waddr, .wdata(wdata & 2'b01), .raddr, .rdata(mutant_q));
endmodule
