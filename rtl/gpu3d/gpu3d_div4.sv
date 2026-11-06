// Restoring divider, two quotient bits per clock (two radix-2 steps per
// cycle). floor(num / den) and the remainder for a QB-bit quotient
// (QB even); requires num < den << QB, which callers guarantee.
module gpu3d_div4 #(
    parameter int NW = 32,
    parameter int DW = 25,
    parameter int QB = 10,
    parameter int SPC = 2            // radix-2 steps per clock (QB a multiple of SPC)
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          start,
    input  logic [NW-1:0] num,
    input  logic [DW-1:0] den,
    output logic          busy,
    output logic          done,      // one-cycle pulse
    output logic [QB-1:0] q,
    output logic [DW-1:0] r
);
    logic [DW-1:0] d;
    logic [QB-1:0] n_lo;             // numerator bits still to bring down
    logic [5:0]    cnt;

    function automatic [DW:0] step(input [DW-1:0] rem, input b, input [DW-1:0] dd);
        // {quotient bit, new remainder}
        logic [DW:0]   sh;
        logic [DW+1:0] t;
        sh = {rem, b};
        t  = {1'b0, sh} - {2'b0, dd};
        step = t[DW+1] ? {1'b0, sh[DW-1:0]} : {1'b1, t[DW-1:0]};
    endfunction

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) busy <= 1'b0;
        else if (start) begin
            busy <= 1'b1;
            d    <= den;
            r    <= DW'(num >> QB);
            n_lo <= num[QB-1:0];
            q    <= '0;
            cnt  <= 6'(QB / SPC);
`ifndef SYNTHESIS
            if (den == 0) $error("gpu3d_div4: divide by zero");
            if ((num >> QB) >= NW'(den)) $error("gpu3d_div4: quotient overflow num=%h den=%h", num, den);
`endif
        end else if (busy) begin
            logic [DW:0] s;
            logic [DW-1:0] rr;
            logic [QB-1:0] qq, nn;
            rr = r; qq = q; nn = n_lo;
            for (int i = 0; i < SPC; i++) begin
                s  = step(rr, nn[QB-1], d);
                rr = s[DW-1:0];
                qq = {qq[QB-2:0], s[DW]};
                nn = {nn[QB-2:0], 1'b0};
            end
            r    <= rr;
            q    <= qq;
            n_lo <= nn;
            cnt  <= cnt - 6'd1;
            if (cnt == 6'd1) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
endmodule

// floor(2^26 / n) for n = 1..512 (addr = n - 1), registered read: one
// table for (1<<18)/ylen, (1<<22)/ylen, (1<<22)/xdiff (>> 8, >> 4: exact,
// floor(floor(a/n)/m) = floor(a/(n*m))) and the exact small divisions.
module gpu3d_recip (
    input  logic        clk,
    input  logic [8:0]  addr,
    output logic [26:0] q
);
    logic [26:0] rom [0:511];
    initial for (int i = 0; i < 512; i++) rom[i] = 27'((64'd1 << 26) / 64'(i + 1));
    always_ff @(posedge clk) q <= rom[addr];
endmodule

// gpu3d_recip with two registered read ports (the span stage's and the edge
// unit's copy in one block)
module gpu3d_recip2 (
    input  logic        clk,
    input  logic [8:0]  addr_a, addr_b,
    output logic [26:0] q_a, q_b
);
    logic [26:0] rom [0:511];
    initial for (int i = 0; i < 512; i++) rom[i] = 27'((64'd1 << 26) / 64'(i + 1));
    always_ff @(posedge clk) q_a <= rom[addr_a];
    always_ff @(posedge clk) q_b <= rom[addr_b];
endmodule

// ceil(2^37 / n) for n = 0..1023 (0 for n = 0), registered read: with it,
// floor(d * f / n) = (d * f * q) >> 37 exactly for d * f < 2^27 and n < 2^10
// (the error of the rounded-up reciprocal stays below one step)
module gpu3d_lrecip (
    input  logic        clk,
    input  logic [9:0]  addr,
    output logic [37:0] q
);
    logic [37:0] rom [0:1023];
    initial begin
        rom[0] = '0;
        for (int i = 1; i < 1024; i++) rom[i] = 38'(((64'd1 << 37) + 64'(i - 1)) / 64'(i));
    end
    always_ff @(posedge clk) q <= rom[addr];
endmodule

// the same table with two registered read ports (one true-dual-port ROM in
// place of two copies): port a the span's xdiff, port b the edge's ylen
module gpu3d_lrecip2 (
    input  logic        clk,
    input  logic [9:0]  addr_a, addr_b,
    output logic [37:0] q_a, q_b
);
    logic [37:0] rom [0:1023];
    initial begin
        rom[0] = '0;
        for (int i = 1; i < 1024; i++) rom[i] = 38'(((64'd1 << 37) + 64'(i - 1)) / 64'(i));
    end
    always_ff @(posedge clk) q_a <= rom[addr_a];
    always_ff @(posedge clk) q_b <= rom[addr_b];
endmodule

// floor(2^20 / (1024 + i + 1)), i = 0..1023, registered read: the
// perspective factor's reciprocal for a denominator normalised to
// [2^24, 2^25) and indexed by its 10 bits below the leading one; it
// underestimates, so (mn * R) >> 26 is floor(256 * mn / dn) or one less
module gpu3d_frecip (
    input  logic        clk,
    input  logic [9:0]  addr,
    output logic [10:0] q
);
    // 2^20 / (1025 + i) is 512..1023 for every i: bits 10 and 9 are 0 and 1,
    // so only bits 8:0 are stored (1 M10K, not 2)
    logic [8:0] rom [0:1023];
    logic [8:0] q9;
    initial for (int i = 0; i < 1024; i++) rom[i] = 9'((64'd1 << 20) / 64'(1024 + i + 1));
    always_ff @(posedge clk) q9 <= rom[addr];
    assign q = {2'b01, q9};
endmodule

// gpu3d_div4 with the quotient width chosen per division: mode 0 a 10-bit
// quotient (the edge unit), mode 1 a 32-bit one (the span stage). Shared
// by both through the owner register in gpu3d_front.
module gpu3d_div4m (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        mode,
    input  logic [31:0] num,
    input  logic [24:0] den,
    output logic        busy,
    output logic [31:0] q,
    output logic [24:0] r
);
    logic [24:0] d;
    logic [31:0] n_lo;               // numerator bits still to bring down, MSB first
    logic [4:0]  cnt;

    function automatic [25:0] step(input [24:0] rem, input b, input [24:0] dd);
        logic [25:0] sh;
        logic [26:0] t;
        sh = {rem, b};
        t  = {1'b0, sh} - {2'b0, dd};
        step = t[26] ? {1'b0, sh[24:0]} : {1'b1, t[24:0]};
    endfunction

    always_ff @(posedge clk) begin
        if (rst) busy <= 1'b0;
        else if (start) begin
            busy <= 1'b1;
            d    <= den;
            r    <= mode ? 25'd0 : 25'(num >> 10);
            n_lo <= mode ? num : {num[9:0], 22'b0};
            q    <= '0;
            cnt  <= mode ? 5'd16 : 5'd5;
`ifndef SYNTHESIS
            if (den == 0) $error("gpu3d_div4m: divide by zero");
            if (!mode && (num >> 10) >= 32'(den)) $error("gpu3d_div4m: quotient overflow num=%h den=%h", num, den);
`endif
        end else if (busy) begin
            logic [25:0] s1, s2;
            s1 = step(r, n_lo[31], d);
            s2 = step(s1[24:0], n_lo[30], d);
            r    <= s2[24:0];
            q    <= {q[29:0], s1[25], s2[25]};
            n_lo <= {n_lo[29:0], 2'b00};
            cnt  <= cnt - 5'd1;
            if (cnt == 5'd1) busy <= 1'b0;
        end
    end
endmodule
