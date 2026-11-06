// nds_cart_cache against nds_cart_cache_ref (its version at a git ref, cc_eq.sh), clock by clock.
// Random ROM sizes, with and without a valid ROM table (<game>.ndt in SDRAM: random read-ahead fields), a
// client reading 16-byte quads in sequential runs (streams, so prefetches start) and random jumps, an APF side
// that answers each fetch command after a random delay (sometimes with an error) and an SDRAM that answers the
// reference's requests with random delays. Every output of the two must agree in every clock (the SDRAM
// request's fields while it is raised; the fetch command's fields while it is sent and outstanding).
`timescale 1ns/1ps
module tb_cc_eq;
    parameter integer SLOTS = 64;
    logic clk = 0, reset = 1;
    always #5 clk = !clk;
    int unsigned seed, ops;
    localparam [23:0] TABLE_W = 24'h30_0000, NDT_W = TABLE_W - 24'h400;

    logic        start = 0, c_valid = 0, fc_busy = 0, mk_valid = 0, m_ready = 0, m_rvalid = 0, tick_ms = 0, stat_clear = 0;
    logic [31:0] rom_size = 0, c_addr = 0, m_rdata = 0;
    logic [2:0]  mk_err = 0;

    wire rdy_a, rdy_b, fail_a, fail_b, cap_a, cap_b, cr_a, cr_b, rv_a, rv_b, fs_a, fs_b;
    wire mv_a, mv_b, mw_a, mw_b, mq_a, mq_b;
    wire [31:0] rd_a, rd_b, wd_a, wd_b;
    wire [119:0] fd_a, fd_b;
    wire [23:0] ma_a, ma_b;
    wire [3:0] be_a, be_b;
    wire [31:0] s_a [9], s_b [9];
    wire [15:0] se_a, se_b;
    nds_cart_cache #(.SLOTS(SLOTS)) dut (.clk, .reset, .start, .rom_size, .ready(rdy_a), .fail(fail_a), .init_capped(cap_a),
        .c_valid, .c_addr, .c_ready(cr_a), .r_valid(rv_a), .r_data(rd_a), .fc_send(fs_a), .fc_data(fd_a), .fc_busy,
        .mk_valid, .mk_err, .m_valid(mv_a), .m_write(mw_a), .m_quad(mq_a), .m_addr(ma_a), .m_wdata(wd_a), .m_be(be_a),
        .m_ready, .m_rvalid, .m_rdata, .stat_clear, .tick_ms,
        .st_lookups(s_a[0]), .st_fast(s_a[1]), .st_cmds(s_a[2]), .st_blocks(s_a[3]), .st_evict(s_a[4]), .st_wait(s_a[5]),
        .st_errors(se_a), .st_spans(s_a[6]), .st_marks(s_a[7]));
    nds_cart_cache_ref #(.SLOTS(SLOTS)) ref_ (.clk, .reset, .start, .rom_size, .ready(rdy_b), .fail(fail_b), .init_capped(cap_b),
        .c_valid, .c_addr, .c_ready(cr_b), .r_valid(rv_b), .r_data(rd_b), .fc_send(fs_b), .fc_data(fd_b), .fc_busy,
        .mk_valid, .mk_err, .m_valid(mv_b), .m_write(mw_b), .m_quad(mq_b), .m_addr(ma_b), .m_wdata(wd_b), .m_be(be_b),
        .m_ready, .m_rvalid, .m_rdata, .stat_clear, .tick_ms,
        .st_lookups(s_b[0]), .st_fast(s_b[1]), .st_cmds(s_b[2]), .st_blocks(s_b[3]), .st_evict(s_b[4]), .st_wait(s_b[5]),
        .st_errors(se_b), .st_spans(s_b[6]), .st_marks(s_b[7]));

    // ---------------- SDRAM (the reference's requests) ----------------
    logic [31:0] mem [int];
    function automatic logic [31:0] rdw(input int a);
        return mem.exists(a) ? mem[a] : (a * 32'h9E37_79B9) ^ 32'h5A5A_1234;
    endfunction
    int m_wait = -1, m_left = 0, m_gap = 0;
    logic [23:0] m_at;
    logic m_q;
    always @(posedge clk) begin
        m_ready <= 0; m_rvalid <= 0;
        if (mv_b && !m_ready && m_left == 0) begin
            if (m_wait < 0) m_wait <= $urandom % 6;
            else if (m_wait == 0) begin
                m_ready <= 1; m_wait <= -1;
                if (mw_b) begin
                    logic [31:0] v;
                    v = rdw(ma_b);
                    for (int b = 0; b < 4; b++) if (be_b[b]) v[b*8 +: 8] = wd_b[b*8 +: 8];
                    mem[ma_b] = v;
                end else begin m_left <= mq_b ? 4 : 1; m_at <= mq_b ? {ma_b[23:2], 2'b00} : ma_b; m_q <= mq_b; m_gap <= 1 + $urandom % 4; end
            end else m_wait <= m_wait - 1;
        end
        if (m_left != 0) begin
            if (m_gap != 0) m_gap <= m_gap - 1;
            else begin
                m_rvalid <= 1; m_rdata <= rdw(m_at); m_at <= m_at + 1; m_left <= m_left - 1; m_gap <= $urandom % 2;
            end
        end
    end

    // ---------------- the APF side: a fetch command, its data into SDRAM, then the marker ----------------
    int f_wait = -1;
    logic [119:0] f_cmd;
    int unsigned cmds = 0, errs = 0;
    localparam integer SB = $clog2(SLOTS);
    always @(posedge clk) begin
        mk_valid <= 0;
        if (fs_b) begin fc_busy <= 1; f_cmd <= fd_b; f_wait <= 20 + $urandom % 200; end
        else if (fc_busy) begin
            if (f_wait > 0) f_wait <= f_wait - 1;
            else begin
                // the run's blocks: offset = f_cmd[101:70]..., slots in [69:0]; write a word per block's quads
                logic [2:0] n;
                logic [31:0] off;
                n = f_cmd[72:70];
                off = f_cmd[104:73];
                for (int k = 0; k < 5; k++) if (k < n) begin
                    int s;
                    s = f_cmd[14 * k +: 14];
                    for (int w = 0; w < 1024; w += 37) mem[24'h40_0000 + 1024 * s + w] = off + 4096 * k + 4 * w;
                end
                fc_busy <= 0; mk_valid <= 1; cmds++;
                mk_err <= ($urandom % 16 == 0) ? 3'd1 + $urandom % 7 : 3'd0;
                if (mk_err != 0) errs++;
            end
        end
    end

    // ---------------- compare ----------------
    int unsigned errors = 0, cycles = 0, quads = 0;
    task automatic err(input string what);
        errors++;
        if (errors <= 10) $display("ERROR %0d: %s", cycles, what);
    endtask
    always @(negedge clk) if (!reset) begin
        cycles++;
        if (rdy_a !== rdy_b) err("ready");
        if (fail_a !== fail_b) err("fail");
        if (cap_a !== cap_b) err("init_capped");
        if (cr_a !== cr_b) err("c_ready");
        if (rv_a !== rv_b || (rv_b && rd_a !== rd_b)) err($sformatf("r_valid/r_data %h %h", rd_a, rd_b));
        if (fs_a !== fs_b) err("fc_send");
        if ((fs_b || fc_busy) && fd_a !== fd_b) err($sformatf("fc_data %h %h", fd_a, fd_b));
        if (mv_a !== mv_b) err("m_valid");
        if (mv_b && (mw_a !== mw_b || mq_a !== mq_b || ma_a !== ma_b || be_a !== be_b || (mw_b && wd_a !== wd_b)))
            err($sformatf("m_* w%b/%b q%b/%b a%h/%h be%h/%h d%h/%h", mw_a, mw_b, mq_a, mq_b, ma_a, ma_b, be_a, be_b, wd_a, wd_b));
        for (int i = 0; i < 8; i++) if (s_a[i] !== s_b[i]) err($sformatf("statistic %0d", i));
        if (se_a !== se_b) err("st_errors");
        if (rv_b) quads++;
    end

    // ---------------- client and the run ----------------
    initial begin
        int unsigned nblk;
        logic ndt;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("ops=%d", ops)) ops = 3000;
        void'($urandom(seed));
        // a ROM of 3..600 blocks, often not a multiple of 4 KiB
        nblk = 3 + $urandom % 598;
        rom_size = nblk * 4096 - (($urandom % 2) ? $urandom % 4096 : 0);
        ndt = $urandom % 3 != 0;
        if (ndt) begin
            mem[NDT_W] = 32'h3154_444E; mem[NDT_W + 1] = ($urandom % 8 == 0) ? 32'd2 : 32'd1;
            mem[NDT_W + 3] = ($urandom % 8 == 0) ? rom_size + 1 : rom_size;
            // the plugin's rule, roughly: files of random lengths, each block min(4, blocks left in its file)
            for (int b = 0; b < nblk;) begin
                int len;
                len = 1 + $urandom % 12;
                for (int k = 0; k < len && b < nblk; k++, b++) mem[TABLE_W + b] = {(len - k - 1 > 4 ? 3'd4 : 3'(len - k - 1)), 29'd0};
            end
        end
        repeat (5) @(posedge clk);
        reset <= 0;
        @(posedge clk); start <= 1;
        fork
            forever begin @(posedge clk); tick_ms <= $urandom % 50 == 0; stat_clear <= $urandom % 4000 == 0; end
        join_none
        wait (rdy_b);
        begin
            logic [31:0] a;
            a = 0;
            for (int i = 0; i < ops; i++) begin
                int r;
                r = $urandom % 100;
                if (r < 70) a = a + 16;                                       // stream on
                else if (r < 85) a = ($urandom % nblk) * 4096 + ($urandom % 256) * 16;
                else a = ($urandom % nblk) * 4096;
                if (a >= rom_size) a = 0;
                repeat ($urandom % 4) @(posedge clk);
                if ($urandom % 40 == 0) repeat (100 + $urandom % 600) @(posedge clk);   // idle: prefetches run
                c_valid <= 1; c_addr <= {a[31:4], 4'b0};
                @(posedge clk);
                while (!cr_b) @(posedge clk);
                c_valid <= 0;
                begin
                    int got;
                    got = 0;
                    while (got < 4) begin @(posedge clk); if (rv_b) got++; end
                end
            end
        end
        repeat (200) @(posedge clk);
        $display("cc_eq: seed %0d, %0d blocks, ndt %0d, %0d quads, %0d commands (%0d errors), %0d cycles, %0d differences",
                 seed, nblk, ndt, quads, cmds, errs, cycles, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #400ms; $display("TIMEOUT"); $display("FAIL"); $finish; end
endmodule
