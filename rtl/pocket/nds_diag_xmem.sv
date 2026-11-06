// SPDX-License-Identifier: MIT
// clk_mem events for nds_diag (docs/diag.md: the SDRAM bus's grant waits and refresh), counted where they
// happen and crossed to clk_sys: each event has a 4-bit Gray counter on clk_mem, synchronised by two flops on
// clk_sys; clk_sys takes the difference from the last sample into a pending count and hands nds_diag 0-3 of it
// a clock (inc, its ev2), so a burst larger than 3 in one clk_sys clock is passed on over the next ones and
// nothing is lost. The Gray code keeps a sample taken mid-change one count off at most, never torn.
`default_nettype none
module nds_diag_xmem #(parameter integer N = 8) (
    input wire clk_mem, clk_sys, rst_sys,
    input wire [N-1:0] ev_mem,
    output reg [N*2-1:0] inc = 0
);
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_e
        reg [3:0] cnt = 0, gray = 0;
        always @(posedge clk_mem) begin
            cnt <= cnt + {3'd0, ev_mem[g]};
            gray <= (cnt + {3'd0, ev_mem[g]}) ^ ((cnt + {3'd0, ev_mem[g]}) >> 1);
        end
        (* async_reg = "true" *) reg [3:0] s1 = 0, s2 = 0;
        reg [3:0] last = 0;
        reg [5:0] pend = 0;
        wire [3:0] bin = s2 ^ (s2 >> 1) ^ (s2 >> 2) ^ (s2 >> 3);   // Gray to binary
        wire [3:0] d = bin - last;
        wire [5:0] p = pend + {2'd0, d};
        wire [1:0] o = p > 6'd3 ? 2'd3 : p[1:0];
        always @(posedge clk_sys) begin
            s1 <= gray; s2 <= s1;
            if (rst_sys) begin last <= bin; pend <= 0; inc[g*2 +: 2] <= 0; end
            else begin last <= bin; pend <= p - {4'd0, o}; inc[g*2 +: 2] <= o; end
        end
    end endgenerate
endmodule
`default_nettype wire
