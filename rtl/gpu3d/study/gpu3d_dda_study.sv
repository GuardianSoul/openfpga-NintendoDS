// COST STUDY ONLY: exact linear interpolation y0 + d*x/xdiff for five
// attributes (r, g, b, s, t) at one pixel per clock, by stepping quotient
// and remainder (q += d/xdiff, r += d%xdiff, carry when r >= xdiff). The
// per-span start values come from the span-setup divider.
module gpu3d_dda_study (
    input  logic        clk,
    input  logic        load,
    input  logic        step,
    input  logic [9:0]  xdiff,
    input  logic [4:0][16:0] q0, qs,      // start quotient, step quotient
    input  logic [4:0][9:0]  r0, rs,      // start remainder, step remainder
    output logic [4:0][16:0] val
);
    logic [4:0][9:0] r;
    for (genvar i = 0; i < 5; i++) begin : g
        wire [10:0] rn = {1'b0, r[i]} + {1'b0, rs[i]};
        wire        c  = rn >= {1'b0, xdiff};
        always_ff @(posedge clk) begin
            if (load) begin val[i] <= q0[i]; r[i] <= r0[i]; end
            else if (step) begin
                val[i] <= val[i] + qs[i] + {16'b0, c};
                r[i]   <= c ? 10'(rn - {1'b0, xdiff}) : rn[9:0];
            end
        end
    end
endmodule
