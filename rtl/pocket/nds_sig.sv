// SPDX-License-Identifier: MIT
// Checksums for the Phase 1 test core (docs/phase1-foundation.md).
//
// nds_sig: an order-independent, position-dependent 64-bit signature of a
//   set of (word index, data) pairs: sum of mix(i, d) and XOR of mix(i, ~d).
//   Pass A (direct APF reads) and pass B (reads through the SDRAM ROM cache,
//   in a scrambled order) must give the same value for the same file: a word
//   from the wrong block, slot or offset changes it. mix uses adds and XORs
//   only (no multipliers); tools/phase1/decode.py has the same function.
// nds_crc32_word: CRC-32 (zlib: reflected, polynomial EDB88320) of one
//   little-endian 32-bit word, `bytes` of its low bytes (1..4).
`default_nettype none

package nds_sig_pkg;
    // mix in two halves, one adder each, so nds_sig can pipeline it
    function automatic [63:0] mix_a(input [31:0] i, input [31:0] d);
        reg [31:0] h, t;
        h = i ^ {i[18:0], 13'b0} ^ {7'b0, i[31:7]} ^ 32'h9E37_79B9;
        t = d ^ h;
        t = t + {t[26:0], 5'b0};
        mix_a = {h, t};
    endfunction
    function automatic [31:0] mix_b(input [63:0] ht);
        reg [31:0] h, t;
        h = ht[63:32]; t = ht[31:0];
        t = t ^ {11'b0, t[31:11]};
        t = t + (h ^ {t[23:0], 8'b0});
        mix_b = t ^ {16'b0, t[31:16]};
    endfunction
    function automatic [31:0] mix(input [31:0] i, input [31:0] d);
        mix = mix_b(mix_a(i, d));
    endfunction

    function automatic [31:0] crc32_word(input [31:0] crc, input [31:0] w, input [2:0] bytes);
        reg [31:0] c;
        c = crc;
        for (integer k = 0; k < 32; k = k + 1)
            if (k < bytes * 8) c = (c >> 1) ^ (((c[0] ^ w[k]) != 0) ? 32'hEDB8_8320 : 32'h0);
        crc32_word = c;
    endfunction
endpackage

// Three pipeline stages; takes one word per clock.
module nds_sig (
    input wire clk,
    input wire clear,
    input wire valid,
    input wire [31:0] index,        // word index in the file (byte offset / 4)
    input wire [31:0] data,
    output reg [63:0] sig = 0       // {xor lane, sum lane}
);
    import nds_sig_pkg::*;
    reg v1 = 0, v2 = 0;
    reg [63:0] a_sum = 0, a_xor = 0;
    reg [31:0] m_sum = 0, m_xor = 0;
    always @(posedge clk) begin
        v1 <= valid && !clear;
        v2 <= v1 && !clear;
        a_sum <= mix_a(index, data);
        a_xor <= mix_a(index, ~data);
        m_sum <= mix_b(a_sum);
        m_xor <= mix_b(a_xor);
        if (clear) sig <= 0;
        else if (v2) sig <= {sig[63:32] ^ m_xor, sig[31:0] + m_sum};
    end
endmodule
`default_nettype wire
