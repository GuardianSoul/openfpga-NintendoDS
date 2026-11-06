// sys_ram64p (double-pumped) against the plain forms it replaces, on random
// traffic over a small address space (same-address reads and writes often):
// sys_ram64be (byte enables, either or both halves) and sys_ram W=64 (whole
// words, contents from 0). rdata of both, every clk cycle, just before the
// next clk edge. sim/sys/ram64p_test.sh; MUTATE: see there.
`timescale 1ns/1ps
module tb_ram64p;
    logic clk = 0, clk2 = 0;
    always #4 clk = ~clk;                       // clk period 8, clk2 period 4, rising edges coincide
    always #2 clk2 = ~clk2;
    logic        we, we2;
    logic [7:0]  be;
    logic [2:0]  wa, ra, wa2, ra2;
    logic [63:0] wd, wd2;
    logic [63:0] q_be, q_bp, q_w, q_wp;
    sys_ram64be #(.AW(3))           u_be (.clk, .we, .be, .waddr(wa), .wdata(wd), .raddr(ra), .rdata(q_be));
    sys_ram64p  #(.AW(3))           u_bp (.clk, .clk2, .we, .be, .waddr(wa), .wdata(wd), .raddr(ra), .rdata(q_bp));
    sys_ram     #(.W(64), .AW(3))   u_w  (.clk, .we(we2), .waddr(wa2), .wdata(wd2), .raddr(ra2), .rdata(q_w));
    sys_ram64p  #(.AW(3), .INIT(1)) u_wp (.clk, .clk2, .we(we2), .be(8'hFF), .waddr(wa2), .wdata(wd2), .raddr(ra2), .rdata(q_wp));
    int n = 0, bad = 0;
    initial begin
        we = 0; we2 = 0; be = 0; wa = 0; ra = 0; wa2 = 0; ra2 = 0; wd = 0; wd2 = 0;
        // the byte-enable pair starts from the same contents: every word written once
        for (int i = 0; i < 8; i++) begin
            @(posedge clk); #1 we = 1; be = 8'hFF; wa = 3'(i); wd = {$urandom, $urandom};
        end
        @(posedge clk); #1 we = 0;
        repeat (2) @(posedge clk);
        repeat (200000) begin
            @(posedge clk);
            #1;                                 // inputs change after the edge, before the middle one
            we = $urandom_range(0, 1); be = 8'($urandom); wa = 3'($urandom); ra = $urandom_range(0, 3) == 0 ? wa : 3'($urandom);
            wd = {$urandom, $urandom};
            we2 = $urandom_range(0, 2) == 0; wa2 = 3'($urandom); ra2 = $urandom_range(0, 3) == 0 ? wa2 : 3'($urandom);
            wd2 = {$urandom, $urandom};
            #5;                                 // after the middle edge, before the next clk edge
            n++;
            if (q_be !== q_bp) begin bad++; if (bad < 5) $display("cycle %0d: be %016x pumped %016x", n, q_be, q_bp); end
            if (q_w !== q_wp) begin bad++; if (bad < 5) $display("cycle %0d: word %016x pumped %016x", n, q_w, q_wp); end
        end
        $display("%s: %0d cycles, %0d mismatches", bad == 0 ? "PASS" : "FAIL", n, bad);
        $finish;
    end
endmodule
