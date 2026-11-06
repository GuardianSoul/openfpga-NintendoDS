// COST STUDY ONLY (not used by gpu3d_raster, not simulated): the perspective
// factor divider a one-pixel-per-clock pipeline needs, num/den with a
// 10-bit quotient (melonDS Interpolator::SetX), one restoring stage per
// pipeline stage.
module gpu3d_pdiv_study (
    input  logic        clk,
    input  logic [31:0] num,
    input  logic [24:0] den,
    output logic [9:0]  q
);
    logic [24:0] rem [0:10];
    logic [24:0] d   [0:10];
    logic [9:0]  nl  [0:10];
    logic [9:0]  qq  [0:10];
    always_comb begin rem[0] = {3'b0, num[31:10]}; d[0] = den; nl[0] = num[9:0]; qq[0] = '0; end
    for (genvar i = 0; i < 10; i++) begin : g
        wire [25:0] sh = {rem[i], nl[i][9]};
        wire [26:0] t  = {1'b0, sh} - {2'b0, d[i]};
        always_ff @(posedge clk) begin
            rem[i+1] <= t[26] ? sh[24:0] : t[24:0];
            qq[i+1]  <= {qq[i][8:0], ~t[26]};
            nl[i+1]  <= {nl[i][8:0], 1'b0};
            d[i+1]   <= d[i];
        end
    end
    assign q = qq[10];
endmodule
