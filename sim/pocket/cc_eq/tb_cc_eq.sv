// cc_eq: nds_cart_cache (the reference) against nds_cart_scpu (SERV and
// sw/scpu firmware) on the same client reads. Each has its own SDRAM and
// APF model; the APF's latency and errors follow the command's index, the
// SDRAM's latencies are random. Checks: every client read returns the ROM's
// bytes, both send the same APF commands in the same order, and at the end
// the table, the owners, ready and fail are the same.
//   +seed=N +ops=N +ndt=0/1 +errmod=N (SLOTS fixed at build)
`timescale 1ns/1ps
module tb_cc_eq;
    localparam integer SLOTS = 64;
    localparam [23:0] TABLE_W = 24'h30_0000, OWNER_W = 24'h34_0000, CACHE_W = 24'h40_0000, NDT_W = TABLE_W - 24'h400;
    localparam [23:0] FW_W = 24'h2C_0800;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1, start = 0;
    reg [31:0] rom_size;
    integer seed, ops, use_ndt, errmod;
    function automatic [31:0] romw(input [31:0] a);   // ROM word at byte a (a multiple of 4)
        romw = a * 32'h9E3779B1 ^ (a >> 7) * 32'h85EBCA6B ^ 32'h5A5A1234;
    endfunction

    // ---------------- per DUT: SDRAM, APF, client ----------------
    `define SIDE(P) \
    wire P``c_ready, P``r_valid, P``fc_send, P``m_valid, P``m_write, P``m_quad, P``ready, P``fail; \
    wire [31:0] P``r_data, P``m_wdata; wire [119:0] P``fc_data; wire [23:0] P``m_addr; wire [3:0] P``m_be; \
    reg P``c_valid = 0; reg [31:0] P``c_addr = 0; \
    reg P``fc_busy = 0, P``mk_valid = 0; reg [2:0] P``mk_err = 0; \
    reg P``m_ready = 0, P``m_rvalid = 0; reg [31:0] P``m_rdata = 0; \
    int unsigned P``mem [int unsigned]; \
    function automatic [31:0] P``rd(input [23:0] w); P``rd = P``mem.exists(w) ? P``mem[w] : 32'h0; endfunction \
    /* SDRAM: accept after 0-3 clocks, data 2-9 clocks later */ \
    int P``acc = -1, P``lat = 0, P``n = 0; reg [23:0] P``a = 0; reg P``q = 0, P``busy = 0; \
    always @(posedge clk) begin \
        P``m_ready <= 0; P``m_rvalid <= 0; \
        if (P``m_valid && !P``busy && !P``m_ready) begin \
            if (P``acc < 0) P``acc = $urandom % 4; \
            if (P``acc == 0) begin \
                P``acc = -1; P``m_ready <= 1; \
                if (P``m_write) begin \
                    reg [31:0] o; o = P``rd(P``m_addr); \
                    for (int b = 0; b < 4; b++) if (P``m_be[b]) o[b*8 +: 8] = P``m_wdata[b*8 +: 8]; \
                    P``mem[P``m_addr] = o; \
                end else begin P``busy = 1; P``a = P``m_addr; P``q = P``m_quad; P``n = 0; P``lat = 2 + $urandom % 8; end \
            end else P``acc--; \
        end \
        if (P``busy) begin \
            if (P``lat > 0) P``lat--; \
            else begin \
                P``m_rvalid <= 1; P``m_rdata <= P``rd(P``a + P``n); P``n++; \
                if (!P``q || P``n == 4) P``busy = 0; \
            end \
        end \
    end \
    /* APF: a command's data into its slots, then its marker */ \
    reg [119:0] P``cmds [0:4095]; int P``ncmd = 0, P``cd = -1, P``bz = 0; reg [119:0] P``cur; \
    always @(posedge clk) begin \
        P``mk_valid <= 0; \
        if (P``bz > 0) P``bz--; else P``fc_busy <= 0; \
        if (P``fc_send) begin \
            P``cmds[P``ncmd] = P``fc_data; P``cur = P``fc_data; \
            P``cd = 20 + (P``ncmd * 7919 + seed) % 300; P``ncmd++; P``fc_busy <= 1; P``bz = 3; \
        end else if (P``cd > 0) P``cd--; \
        else if (P``cd == 0) begin \
            int len, lb, nb; len = P``cur[119:105]; lb = P``cur[102:85]; nb = P``cur[72:70]; \
            for (int i = 0; i * 4 < len; i++) begin \
                int k; k = i / 1024; \
                P``mem[CACHE_W + {P``cur[k*14 +: 14], 10'd0} + i % 1024] = romw((lb * 4096) + i * 4); \
            end \
            P``mk_valid <= 1; P``mk_err <= ((P``ncmd * 31 + seed) % errmod == 0 || errmod == 1) ? 3'd2 : 3'd0; P``cd = -1; \
        end \
    end

    `SIDE(a_)
    `SIDE(b_)

    nds_cart_cache #(.SLOTS(SLOTS)) ref_c (.clk, .reset, .start, .rom_size, .ready(a_ready), .fail(a_fail), .init_capped(),
        .c_valid(a_c_valid), .c_addr(a_c_addr), .c_ready(a_c_ready), .r_valid(a_r_valid), .r_data(a_r_data),
        .fc_send(a_fc_send), .fc_data(a_fc_data), .fc_busy(a_fc_busy), .mk_valid(a_mk_valid), .mk_err(a_mk_err),
        .m_valid(a_m_valid), .m_write(a_m_write), .m_quad(a_m_quad), .m_addr(a_m_addr), .m_wdata(a_m_wdata), .m_be(a_m_be),
        .m_ready(a_m_ready), .m_rvalid(a_m_rvalid), .m_rdata(a_m_rdata),
        .stat_clear(1'b0), .tick_ms(1'b0), .st_lookups(), .st_fast(), .st_cmds(), .st_blocks(), .st_evict(), .st_wait(),
        .st_errors(), .st_spans(), .st_marks(), .dg_wait(), .dg_cmd());
    nds_cart_scpu #(.SLOTS(SLOTS)) new_c (.clk, .reset, .start, .rom_size, .ready(b_ready), .fail(b_fail),
        .c_valid(b_c_valid), .c_addr(b_c_addr), .c_ready(b_c_ready), .r_valid(b_r_valid), .r_data(b_r_data),
        .fc_send(b_fc_send), .fc_data(b_fc_data), .fc_busy(b_fc_busy), .mk_valid(b_mk_valid), .mk_err(b_mk_err),
        .m_valid(b_m_valid), .m_write(b_m_write), .m_quad(b_m_quad), .m_addr(b_m_addr), .m_wdata(b_m_wdata), .m_be(b_m_be),
        .m_ready(b_m_ready), .m_rvalid(b_m_rvalid), .m_rdata(b_m_rdata),
        .stat_clear(1'b0), .tick_ms(1'b0), .st_lookups(), .st_cmds(), .st_blocks(), .st_wait(), .dg_wait(), .dg_cmd());

    // ---------------- the client reads (the same list for both) ----------------
    reg [31:0] op_a [0:65535];
    int op_g [0:65535];
    int bad = 0;
    `define CLIENT(P) \
    int P``i = 0, P``w = 0, P``got = 0, P``gap = 0; reg P``wait_d = 0; reg [31:0] P``qa; \
    always @(posedge clk) if (!reset && P``ready) begin \
        if (P``c_ready) begin P``c_valid <= 0; P``wait_d <= 1; P``got = 0; end \
        if (P``r_valid) begin \
            if (P``qa + P``got * 4 < rom_size && P``r_data !== romw(P``qa + P``got * 4)) begin \
                if (bad < 5) $display("read %h word %0d: %h, ROM %h", P``qa, P``got, P``r_data, romw(P``qa + P``got * 4)); \
                bad++; \
            end \
            P``got++; if (P``got == 4) begin P``wait_d <= 0; P``i++; P``gap = op_g[P``i]; end \
        end \
        if (!P``c_valid && !P``wait_d && !P``c_ready && P``i < ops) begin \
            if (P``gap > 0) P``gap--; else begin P``c_valid <= 1; P``c_addr <= op_a[P``i]; P``qa = op_a[P``i]; end \
        end \
    end
    `CLIENT(a_)
    `CLIENT(b_)

    // +dbgslot=N: every write of slot N's reference bit, both sides
    int dbgslot = -1;
    initial void'($value$plusargs("dbgslot=%d", dbgslot));
    always @(posedge clk) if (dbgslot >= 0) begin
        if (ref_c.ref_we && ref_c.ref_waddr == dbgslot) $display("%0t ref: slot %0d <= %0d (op %0d, cmds %0d, st %0d)", $time, dbgslot, ref_c.ref_wd, a_i, a_ncmd, ref_c.st);
        if (new_c.ref_we && new_c.ref_waddr == dbgslot) $display("%0t new: slot %0d <= %0d (op %0d, cmds %0d, st %0d)", $time, dbgslot, new_c.ref_wd, b_i, b_ncmd, new_c.st);
    end
    initial begin
        reg [31:0] fw [0:4095];
        int nb, a, run, fs;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("ops=%d", ops)) ops = 3000;
        if (!$value$plusargs("ndt=%d", use_ndt)) use_ndt = seed % 2;
        if (!$value$plusargs("errmod=%d", errmod)) errmod = 11;   // every errmod-th command fails (1: all)
        void'($urandom(seed));
        rom_size = (32'd40 + $urandom % 200) * 4096 + ($urandom % 256) * 16;
        nb = (rom_size + 4095) / 4096;
        // firmware into the new side's SDRAM
        for (int i = 0; i < 4096; i++) fw[i] = 32'h0;
        $readmemh("build/cc_eq/cache.hex", fw);
        for (int i = 0; i < 4096; i++) if (fw[i] !== 32'h0) b_mem[FW_W + i] = fw[i];
        // the plugin's table (files of 1-40 blocks), or garbage the cache must clear
        if (use_ndt) begin
            a_mem[NDT_W] = 32'h3154_444E; a_mem[NDT_W + 1] = 1; a_mem[NDT_W + 3] = rom_size;
            fs = 0;
            while (fs < nb) begin
                int len; len = 1 + $urandom % 40; if (fs + len > nb) len = nb - fs;
                for (int k = 0; k < len; k++) a_mem[TABLE_W + fs + k] = (len - 1 - k > 4 ? 4 : len - 1 - k) << 29;
                fs += len;
            end
        end else for (int b = 0; b < nb; b++) a_mem[TABLE_W + b] = $urandom;
        for (int s = 0; s < SLOTS; s++) a_mem[OWNER_W + s] = $urandom;
        foreach (a_mem[k]) b_mem[k] = a_mem[k];
        // client reads: streams (sequential quads) and jumps, with gaps
        a = 0; run = 0;
        for (int i = 0; i < ops; i++) begin
            if (run == 0) begin a = ($urandom % (rom_size / 16)) * 16; run = 1 + $urandom % 120; end
            op_a[i] = a; op_g[i] = ($urandom % 8 == 0) ? $urandom % 3000 : $urandom % 4;
            a += 16; run--; if (a >= rom_size) run = 0;
        end
        repeat (5) @(posedge clk); reset = 0;
        repeat (3) @(posedge clk); start = 1;
        fork
            begin wait (a_i == ops && b_i == ops); repeat (60000) @(posedge clk); end
            begin repeat (200000000) @(posedge clk); $display("TIMEOUT a %0d b %0d of %0d", a_i, b_i, ops); end
        join_any
        // compare
        if (a_ncmd != b_ncmd) begin $display("commands: ref %0d, new %0d", a_ncmd, b_ncmd); bad++; end
        for (int i = 0; i < a_ncmd && i < b_ncmd; i++) if (a_cmds[i] !== b_cmds[i]) begin
            if (bad < 10) $display("command %0d: ref %h new %h", i, a_cmds[i], b_cmds[i]); bad++;
        end
        for (int b = 0; b < nb; b++) if (a_rd(TABLE_W + b) !== b_rd(TABLE_W + b)) begin
            if (bad < 10) $display("table %0d: ref %h new %h", b, a_rd(TABLE_W + b), b_rd(TABLE_W + b)); bad++;
        end
        for (int s = 0; s < SLOTS; s++) if (a_rd(OWNER_W + s) !== b_rd(OWNER_W + s)) begin
            if (bad < 10) $display("owner %0d: ref %h new %h", s, a_rd(OWNER_W + s), b_rd(OWNER_W + s)); bad++;
        end
        if (a_ready !== b_ready || a_fail !== b_fail) begin $display("ready/fail differ"); bad++; end
        if (a_i != ops || b_i != ops) bad++;
        $display("%s seed %0d ndt %0d: %0d reads, %0d commands, rom %0d blocks, fail %0d, %0d mismatches",
                 bad ? "FAIL" : "PASS", seed, use_ndt, ops, a_ncmd, nb, a_fail, bad);
        $finish;
    end
endmodule
