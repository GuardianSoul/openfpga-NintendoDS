// gpu3d_lmac (altera_mult_add, Intel's simulation model) against the behaviour gxeng a1x relies on:
// q <= en ? (ld ? 0 : q) + a_r * b_r : q, a_r/b_r the inputs a clock before, modulo 2^WR. Two instances as the
// lanes use them: the high half (16 x 16) and the low half (17 x 16, the low 16 bits zero-extended).
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg signed [19:0] ah = 0; reg signed [15:0] b = 0;
    reg signed [19:0] al = 0;
    reg en = 0, ld = 0;
    wire [43:0] qh, ql;
    gpu3d_lmac #(.WA(20), .WB(16), .WR(44)) u_h (.clk(clk), .a(ah), .b(b), .en(en), .ld(ld), .q(qh));
    gpu3d_lmac #(.WA(20), .WB(16), .WR(44)) u_l (.clk(clk), .a(al), .b(b), .en(en), .ld(ld), .q(ql));
    reg signed [19:0] ah_r, al_r; reg signed [15:0] b_r;
    reg [43:0] rh, rl; reg known = 0;
    integer seed = 77, checks = 0, loads = 0, holds = 0;
    always @(posedge clk) begin
        ah_r <= ah; al_r <= al; b_r <= b;
        if (en) begin
            rh <= (ld ? 44'd0 : rh) + 44'($signed(ah_r) * $signed(b_r));
            rl <= (ld ? 44'd0 : rl) + 44'($signed(al_r) * $signed(b_r));
            if (ld) known <= 1;
        end
    end
    initial begin
        for (integer i = 0; i < 40000; i++) begin
            @(negedge clk);
            if (known) begin
                if (qh !== rh || ql !== rl) $fatal(1, "LMAC mismatch at %0d: h %h/%h l %h/%h", i, qh, rh, ql, rl);
                checks++;
            end
            ah = 20'($signed(16'($random(seed)))); b = $random(seed); al = {4'd0, 16'($random(seed))};
            if (i % 37 == 0) begin ah = -32768; b = -32768; al = 20'h0FFFF; end
            en = ($unsigned($random(seed)) % 4) != 0;
            ld = i < 3 || ($unsigned($random(seed)) % 9) == 0;
            if (en && ld) loads++;
            if (!en) holds++;
        end
        if (checks < 39000 || loads < 1000 || holds < 1000) $fatal(1, "LMAC coverage checks %0d loads %0d holds %0d", checks, loads, holds);
        $display("PASS LMAC checks=%0d loads=%0d holds=%0d", checks, loads, holds);
        $finish;
    end
endmodule
