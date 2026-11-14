// gxeng a4's three blocks under Intel's model (lmac_vendor.py): gpu3d_lmac 16 x 17 (32-bit sum), gpu3d_lmac 17 x 17
// (64-bit sum: a load adds 2^63, which gxeng flips back) and gpu3d_lmac2 (two 17 x 17 products, 48-bit sum), against
// q <= en ? (ld ? 2^63 mod 2^WR : q) + products of the inputs a clock before : q.
`timescale 1ns/1ps
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg signed [15:0] ah = 0;
    reg signed [16:0] bh = 0, bl = 0, al = 0;
    reg en = 0, ld = 0;
    wire [31:0] q32; wire [63:0] q0; wire [47:0] q16;
    gpu3d_lmac  #(.WA(16), .WB(17), .WR(32)) u_32 (.clk(clk), .a(ah), .b(bh), .en(en), .ld(ld), .q(q32));
    gpu3d_lmac  #(.WA(17), .WB(17), .WR(64)) u_0  (.clk(clk), .a(al), .b(bl), .en(en), .ld(ld), .q(q0));
    gpu3d_lmac2 #(.WA(17), .WB(17), .WR(48)) u_16 (.clk(clk), .a0(17'($signed(ah))), .b0(bl), .a1(al), .b1(bh), .en(en), .ld(ld), .q(q16));
    reg signed [15:0] ah_r; reg signed [16:0] bh_r, bl_r, al_r;
    reg [31:0] r32; reg [63:0] r0; reg [47:0] r16; reg known = 0;
    integer seed = 91, checks = 0, loads = 0, holds = 0;
    always @(posedge clk) begin
        ah_r <= ah; bh_r <= bh; bl_r <= bl; al_r <= al;
        if (en) begin
            r32 <= (ld ? 32'd0 : r32) + 32'($signed(ah_r) * $signed(bh_r));
            r0  <= (ld ? 64'h8000_0000_0000_0000 : r0) + 64'($signed(al_r) * $signed(bl_r));
            r16 <= (ld ? 48'd0 : r16) + 48'($signed(ah_r) * $signed(bl_r)) + 48'($signed(al_r) * $signed(bh_r));
            if (ld) known <= 1;
        end
    end
    initial begin
        for (integer i = 0; i < 40000; i++) begin
            @(negedge clk);
            if (known) begin
                if (q32 !== r32 || q0 !== r0 || q16 !== r16)
                    $fatal(1, "LMAC mismatch at %0d: 32 %h/%h 0 %h/%h 16 %h/%h", i, q32, r32, q0, r0, q16, r16);
                checks++;
            end
            ah = $random(seed); bh = 17'($random(seed)); bl = {1'b0, 16'($random(seed))}; al = {1'b0, 16'($random(seed))};
            if (i % 37 == 0) begin ah = -32768; bh = 17'h10000; bl = 17'h0FFFF; al = 17'h0FFFF; end
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
