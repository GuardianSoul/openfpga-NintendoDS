// nds_vram CAP_DB (sim/ds/capdb_eq.sh): CAP_DB=0 and CAP_DB=1 (CAP_CHAIN=1, the core's capture path) each take
// the same capture halfword stream at their own pace (cap_we held until cap_ready), with their own random
// write acks (cw_ack, vm_ack). Every halfword that reaches VRAM (cw_* pairs, S_CAP's vm_* lone halfwords) goes
// into a per-instance halfword memory; at the end both memories, and the halfword counts taken, must be equal.
// Stream: runs of consecutive halfwords at one a clock (a capture line), gaps, odd starts, lone halfwords,
// rewrites of the same addresses (so the order of writes matters).
//   +seed=S +n=halfwords
`timescale 1ns/1ps
module tb_capdb_eq;
    import gpu2d_pkg::*;
    reg clk = 0; always #1 clk = !clk;
    reg rst = 1;
    integer seed = 1, nhw = 200000;
    initial begin void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("n=%d", nhw)); end
    wire [71:0] vramcnt = 72'h80;
    reg [17:0] s_a [$]; reg [15:0] s_d [$]; integer s_gap [$];
`define CAPDB_INST(p, DB) \
    reg  p``we = 0; reg [17:0] p``a = 0; reg [15:0] p``d = 0; integer p``i = 0, p``gap = 0; \
    reg  p``cw_ack = 0, p``vm_ack = 0; \
    wire p``cap_ready, p``cw_valid, p``vm_req, p``vm_we, p``vm_blk, p``vm_tex; \
    wire [23:0] p``cw_addr; wire [31:0] p``cw_data, p``vm_wdata; wire [1:0] p``cw_he; wire [20:2] p``vm_addr; wire [3:0] p``vm_be; \
    nds_vram #(.CAP_CHAIN(1), .CAP_DB(DB)) u_``p (.clk, .rst, .vramcnt, .c_req(1'b0), .c_cpu(1'b0), .c_dma(1'b0), .c_we(1'b0), \
        .c_addr(22'd0), .c_be(4'd0), .c_wdata(32'd0), .c_ack(), .c_rdata(), .g_req(1'b0), .g_blk('0), .g_ack(), .g_rvalid(), .g_rdata(), \
        .cap_we(p``we), .cap_addr(p``a), .cap_data(p``d), .cap_ready(p``cap_ready), \
        .cw_valid(p``cw_valid), .cw_addr(p``cw_addr), .cw_data(p``cw_data), .cw_he(p``cw_he), .cw_ack(p``cw_ack), .cw_drained(1'b1), \
        .cw_fill(7'd0), .cw_pcnt(7'd0), .sv_req(1'b0), .sv_we(1'b0), .sv_addr(19'd0), .sv_be(4'd0), .sv_wdata(32'd0), .sv_ack(), .sv_rdata(), \
        .vm_req(p``vm_req), .vm_we(p``vm_we), .vm_blk(p``vm_blk), .vm_tex(p``vm_tex), .vm_addr(p``vm_addr), .vm_be(p``vm_be), \
        .vm_wdata(p``vm_wdata), .vm_ack(p``vm_ack), .vm_rvalid(1'b0), .vm_rdata(32'd0), .vramstat()); \
    reg [15:0] p``mem [integer]; integer p``taken = 0, p``ncw = 0, p``nvm = 0, p``busy = 0; \
    always @(posedge clk) if (!rst) begin \
        p``cw_ack <= p``cw_valid && !p``cw_ack && ($urandom % 3 != 0 || p``busy == 0) && (p``busy == 0); \
        p``vm_ack <= p``vm_req && !p``vm_ack && $urandom % 4 == 0; \
        if (p``busy != 0) p``busy--; else if ($urandom % 40 == 0) p``busy = $urandom % 12; \
        if (p``cw_valid && p``cw_ack) begin p``ncw++; \
            if (p``cw_he[0]) p``mem[{p``cw_addr[16:0], 1'b0}] = p``cw_data[15:0]; \
            if (p``cw_he[1]) p``mem[{p``cw_addr[16:0], 1'b1}] = p``cw_data[31:16]; end \
        if (p``vm_req && p``vm_ack && p``vm_we) begin p``nvm++; \
            if (p``vm_be[1:0] != 0) p``mem[{p``vm_addr[18:2], 1'b0}] = p``vm_wdata[15:0]; \
            if (p``vm_be[3:2] != 0) p``mem[{p``vm_addr[18:2], 1'b1}] = p``vm_wdata[31:16]; end \
        if (p``we && p``cap_ready) begin p``taken++; p``we <= 0; end \
        if (!(p``we && !p``cap_ready)) begin \
            if (p``gap != 0) begin p``gap--; p``we <= 0; end \
            else if (p``i < s_a.size()) begin p``we <= 1; p``a <= s_a[p``i]; p``d <= s_d[p``i]; p``gap = s_gap[p``i]; p``i++; end \
        end \
    end
    `CAPDB_INST(o_, 0)
    `CAPDB_INST(n_, 1)
    initial begin
        integer a, k, len;
        void'($urandom(seed));
        a = 0;
        while (s_a.size() < nhw) begin
            k = $urandom % 10;
            if (k < 6) begin   // a run: consecutive halfwords, one a clock (now and then a gap)
                a = (k == 0 ? $urandom % 4096 : ($urandom % 2048) * 2) + ($urandom % 2 ? 0 : 131072 - 8192);
                len = 1 + $urandom % 300;
                repeat (len) begin s_a.push_back(18'(a)); s_d.push_back(16'($urandom)); s_gap.push_back($urandom % 25 == 0 ? $urandom % 8 : 0); a++; end
            end else begin     // lone halfwords
                repeat (1 + $urandom % 4) begin s_a.push_back(18'($urandom % 4096)); s_d.push_back(16'($urandom)); s_gap.push_back($urandom % 6); end
            end
        end
        repeat (4) @(posedge clk);
        rst = 0;
        wait (o_i == s_a.size() && n_i == s_a.size() && !o_we && !n_we);
        repeat (200) @(posedge clk);
        begin
            integer mism = 0, n = 0;
            foreach (o_mem[x]) begin n++; if (!n_mem.exists(x) || n_mem[x] !== o_mem[x]) begin mism++; if (mism < 5) $display("MISMATCH hw %0h: old %h new %s", x, o_mem[x], n_mem.exists(x) ? $sformatf("%h", n_mem[x]) : "none"); end end
            if (n_mem.size() != o_mem.size()) mism++;
            $display("capdb_eq: %0d halfwords, taken %0d/%0d, pairs %0d/%0d, lone %0d/%0d, %0d addresses, %0d mismatches, clocks to take: see below",
                s_a.size(), o_taken, n_taken, o_ncw, n_ncw, o_nvm, n_nvm, n, mism);
            if (mism == 0 && o_taken == s_a.size() && n_taken == s_a.size() && n > 0) $display("PASS"); else $display("FAIL");
        end
        $finish;
    end
    // rate: clocks a run of halfwords waited on cap_ready
    integer o_wait = 0, n_wait = 0;
    always @(posedge clk) begin if (o_we && !o_cap_ready) o_wait++; if (n_we && !n_cap_ready) n_wait++; end
    final $display("capdb_eq: clocks waiting on cap_ready: CAP_DB=0 %0d, CAP_DB=1 %0d", o_wait, n_wait);
endmodule
