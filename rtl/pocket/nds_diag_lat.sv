// SPDX-License-Identifier: MIT
// A latency for nds_diag's histograms (docs/diag.md), on clk_sys: start (a request accepted) and stop (its first
// data) are pulses, answered in order, up to DEPTH in flight; at each stop, v pulses with the bin of the clocks
// from its start. A start and a stop in the same clock are both taken (the stop is an older request's).
// MODE 0: log2 (0 -> 0, 1 -> 1, 2-3 -> 2, 4-7 -> 3, ..., 16384 and up -> 15)
// MODE 1: STEP clocks a bin (15: 15 * STEP and up)
// MODE 2: under 16 -> 0, 16-43 by 2 -> 1-14, 44 and up -> 15 (the VRAM block port)
// MODE 3: 0-47 by 4 -> 0-11, 48-63 -> 12, 64-127 -> 13, 128-255 -> 14, 256 and up -> 15 (the 2D VRAM port)
`default_nettype none
module nds_diag_lat #(
    parameter integer MODE = 0,
    parameter integer STEP = 4,
    parameter integer DEPTH = 4
) (
    input wire clk, rst,
    input wire start, stop,
    output reg v = 0,
    output reg [3:0] bin = 0
);
    localparam integer AW = $clog2(DEPTH);
    reg [15:0] now = 0;
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] t [0:DEPTH-1];   // (an M10K in #608: none to spare)
    reg [AW:0] wp = 0, rp = 0;
    wire empty = wp == rp;
    wire [15:0] lat = now - t[rp[AW-1:0]];
    function automatic [3:0] bin_of(input [15:0] l);
        integer i;
        case (MODE)
            0: begin bin_of = 0; for (i = 0; i < 15; i = i + 1) if (l >= (16'd1 << i)) bin_of = i + 1; end
            1: bin_of = l >= 15 * STEP ? 4'd15 : 4'(l / STEP);
            2: bin_of = l < 16 ? 4'd0 : l >= 44 ? 4'd15 : 4'((l - 16) / 2 + 1);
            default: bin_of = l < 48 ? 4'(l / 4) : l < 64 ? 4'd12 : l < 128 ? 4'd13 : l < 256 ? 4'd14 : 4'd15;
        endcase
    endfunction
    always @(posedge clk) begin
        now <= now + 1'b1;
        v <= 0;
        if (rst) begin wp <= 0; rp <= 0; end
        else begin
            if (start && (wp - rp) != DEPTH) begin t[wp[AW-1:0]] <= now; wp <= wp + 1'b1; end
            if (stop && !empty) begin v <= 1; bin <= bin_of(lat); rp <= rp + 1'b1; end
        end
    end
endmodule
`default_nettype wire
