// nds_vram with randomized traffic (docs/phase2-integration.md, "VRAM
// bandwidth"): 2D block reads (bank A through the LCDC view, some beyond
// it, which must read as zero), CPU reads and writes through the ARM9's
// LCDC view and save-port accesses, all interleaved, against an external
// memory that accepts a new request while it still streams the last one's
// words, with random latencies. Every word the 2D engine and the CPU get
// is checked against a reference copy, in order. Run by sim/ds/vram_test.py.
`timescale 1ns/1ps
module tb_vram;
    import gpu2d_pkg::*;
    reg clk = 0; always #1 clk = !clk;
    reg rst = 1;
    integer seed = 1, n_blocks = 3000;
    initial begin void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("blocks=%d", n_blocks)); end

    // bank A enabled, LCDC (MST 0), everything else off
    wire [71:0] vramcnt = 72'h80;
    // ---- DUT ports
    reg  c_req = 0, c_we = 0;
    reg  [23:2] c_addr = 0;
    reg  [3:0]  c_be = 0;
    reg  [31:0] c_wdata = 0;
    wire        c_ack;
    wire [31:0] c_rdata;
    reg  g_req = 0;
    reg  [17:0] g_blk = 0;
    wire g_ack, g_rvalid;
    wire [63:0] g_rdata;
    wire vm_req, vm_we, vm_blk, vm_ack, vm_rvalid;
    wire [20:2] vm_addr;
    wire [3:0] vm_be;
    wire [31:0] vm_wdata, vm_rdata;
    reg  sv_req = 0;
    wire sv_ack;
    wire [31:0] sv_rdata;
`ifndef TB_PF
`define TB_PF 0
`endif
    // TB_PF=1: VR_RDB, VR_CWF and VR_PF (the next-line prefetch for DMA reads; +cseq=1 makes the CPU's reads DMA runs)
    reg c_dma = 0;
    nds_vram #(.VR_RDB(`TB_PF), .VR_CWF(`TB_PF), .VR_PF(`TB_PF)) dut (.clk, .rst, .vramcnt,
        .c_req, .c_cpu(1'b0), .c_dma, .c_we, .c_addr, .c_be, .c_wdata, .c_ack, .c_rdata,
        .g_req, .g_blk, .g_ack, .g_rvalid, .g_rdata,
        .cap_we(1'b0), .cap_addr(18'd0), .cap_data(16'd0), .cap_ready(),
        .sv_req, .sv_we(1'b0), .sv_addr(17'd5), .sv_be(4'hF), .sv_wdata(32'd0), .sv_ack, .sv_rdata,
        .vm_req, .vm_we, .vm_blk, .vm_addr, .vm_be, .vm_wdata, .vm_ack, .vm_rvalid, .vm_rdata,
        .vramstat());

    // ---- external memory: requests queue up; words stream in order with gaps
    reg [31:0] mem [0:(1<<19)-1];          // 2 MiB physical (VRAM + save)
    reg [31:0] ref_ [0:32767];             // bank A as the CPU and 2D engine should see it
    integer q_addr [$], q_n [$];
    integer ack_wait = 0, word_wait = 0, cur_a = -1, cur_left = 0;
    reg ack_r = 0, rv_r = 0;
    reg [31:0] rd_r = 0;
    assign vm_ack = ack_r, vm_rvalid = rv_r, vm_rdata = rd_r;
    always @(posedge clk) begin
        ack_r <= 0; rv_r <= 0;
        if (vm_req && !ack_r) begin
            if (ack_wait == 0) begin
                ack_r <= 1;
                if (vm_we) begin
                    for (int b = 0; b < 4; b++) if (vm_be[b]) mem[vm_addr][b*8 +: 8] = vm_wdata[b*8 +: 8];
                end else begin
                    q_addr.push_back(vm_blk ? {vm_addr[20:5], 3'b000} : vm_addr);
                    q_n.push_back(vm_blk ? 8 : 1);
                end
                ack_wait = $urandom % 6;
            end else ack_wait--;
        end
        if (cur_left == 0 && q_addr.size() > 0) begin cur_a = q_addr.pop_front(); cur_left = q_n.pop_front(); word_wait = 1 + $urandom % 8; end  // words never come with the ack
        if (cur_left != 0) begin
            if (word_wait == 0) begin
                rv_r <= 1; rd_r <= mem[cur_a]; cur_a++; cur_left--;
                word_wait = $urandom % 3;
            end else word_wait--;
        end
    end

    integer n_pf = 0;          // VR_PF: prefetch blocks the port took
    always @(posedge clk) if (`TB_PF != 0 && vm_req && vm_ack && dut.st == 4'd12) n_pf++;
    // ---- traffic and checks
    integer errors = 0, g_done = 0, c_done = 0, g_issued = 0;
    integer g_exp [$];                      // block index per accepted 2D request (-1: unmapped)
    integer g_beat = 0;
    // 2D requests: random blocks, 1 in 6 beyond bank A (unmapped -> zero), in
    // bursts (a line's fetches) with gaps where the CPU gets its turns
    reg g_burst = 0;
    always @(posedge clk) if (!rst) begin
        if ($urandom % 150 == 0) g_burst <= !g_burst;
        if (g_ack) begin
            g_exp.push_back(g_blk[13:0] < 14'd4096 ? int'(g_blk[13:0]) : -1);
            g_req <= 0;
        end
        if ((!g_req || g_ack) && g_issued < n_blocks && g_burst && $urandom % 2 == 0) begin
            g_req <= 1; g_issued <= g_issued + 1;
            g_blk <= {SP_LCDC, 1'b0, ($urandom % 6 == 0) ? 14'(4096 + $urandom % 4096) : 14'($urandom % 4096)};
        end
    end
    always @(posedge clk) if (g_rvalid) begin
        integer b;
        b = g_exp[0];
        if (b < 0) begin
            if (g_rdata !== 64'd0) begin errors++; if (errors < 10) $display("ERROR unmapped block beat %0d: %h", g_beat, g_rdata); end
        end else if (g_rdata !== {ref_[b * 8 + g_beat * 2 + 1], ref_[b * 8 + g_beat * 2]}) begin
            errors++;
            if (errors < 10) $display("ERROR block %0d beat %0d: %h, expected %h", b, g_beat, g_rdata,
                                      {ref_[b * 8 + g_beat * 2 + 1], ref_[b * 8 + g_beat * 2]});
        end
        g_beat = g_beat + 1;
        if (g_beat == 4) begin g_beat = 0; void'(g_exp.pop_front()); g_done++; end
    end
    // CPU: reads and writes of bank A words through the LCDC view (0x06800000)
    integer c_w;
    integer c_span = 32768;   // +cspan=N: CPU words from the first N only (read-line hits and writes into the line)
    initial void'($value$plusargs("cspan=%d", c_span));
    integer c_seq = 0;        // +cseq=1: reads in sequential runs (a DMA's: c_dma), writes now and then anywhere near
    initial void'($value$plusargs("cseq=%d", c_seq));
    integer c_next = 0;
    reg c_isw = 0;
    always @(posedge clk) if (!rst) begin
        if (c_ack) begin
            c_req <= 0; c_done++;
            if (!c_isw && c_rdata !== ref_[c_w]) begin
                errors++; if (errors < 10) $display("ERROR CPU read %0d: %h, expected %h", c_w, c_rdata, ref_[c_w]);
            end
        end
        if (!c_req && $urandom % 8 == 0 && g_issued < n_blocks) begin
            c_w = $urandom % c_span;
            c_isw = $urandom % 2;
            if (c_seq != 0) begin
                c_isw = $urandom % 12 == 0;
                if (c_isw) c_w = (c_next + $urandom % 24) % c_span;          // into this line or the next ones
                else begin
                    if ($urandom % 200 == 0) c_next = $urandom % c_span;     // a new run
                    c_w = c_next; c_next = (c_next + 1) % c_span;
                end
                c_dma <= !c_isw || $urandom % 2;
            end
            c_req <= 1; c_we <= c_isw; c_addr <= 22'h20_0000 | c_w; c_be <= 4'hF;
            if (c_isw) begin c_wdata <= $urandom; end
        end
    end
    // a CPU write changes the reference when it is accepted (later block reads see it)
    always @(posedge clk) if (c_req && c_we && c_ack) ref_[c_w] = c_wdata;
    // save port: occasional reads, answered from the save region (not checked here)
    always @(posedge clk) if (!rst) begin
        if (sv_ack) sv_req <= 0;
        else if (!sv_req && $urandom % 200 == 0) sv_req <= 1;
    end

    initial begin
        void'($urandom(seed));
        for (int i = 0; i < (1 << 19); i++) mem[i] = $urandom;
        for (int i = 0; i < 32768; i++) ref_[i] = mem[i];
        repeat (4) @(posedge clk);
        rst = 0;
        wait (g_done == n_blocks || $time > 64'd200_000_000);
        repeat (50) @(posedge clk);
        $display("blocks %0d, CPU accesses %0d, errors %0d, prefetches %0d", g_done, c_done, errors, n_pf);
        if (g_done != n_blocks) $display("stuck: st %0d bw_left %0d g_req %b c_req %b sv_req %b q %0d left %0d exp %0d", dut.st, dut.bw_left, g_req, c_req, sv_req, q_addr.size(), cur_left, g_exp.size());
        if (errors == 0 && g_done == n_blocks) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
