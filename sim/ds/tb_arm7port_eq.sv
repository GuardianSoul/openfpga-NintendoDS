// nds_arm7_port against its version before (nds_arm7_port_ref, made from git
// by sim/ds/arm7port_eq.sh): the same random pipeline requests, SRAM and
// fabric answers and other masters' writes go to both, and every output is
// compared every cycle. The memory models answer the reference's requests
// (the two must ask the same anyway).
//   +cycles=N  +seed=S
module tb_arm7port_eq;
    parameter int IL = 7;
    parameter int DL = 6;
    parameter TAG_STYLE = "M10K";

    logic clk = 0;
    always #5 clk = !clk;
    logic rst = 1;

    logic [1:0]  wramcnt = 2'd3;
    logic [15:0] biosprot = 16'h1204;
    logic        i_req = 0, d_req = 0, d_we = 0;
    logic        dw_q = 0;                      // the request answered now was a store
    always @(posedge clk) dw_q <= d_we;
    logic [31:0] i_addr = 0, d_addr = 0, d_wdata = 0;
    logic [3:0]  d_be = 0;
    logic [31:0] i_boot_q = 0, d_boot_q = 0;
    logic        x_done = 0, f_ack = 0, inv = 0, wr_mon = 0;
    logic [31:0] x_rdata = 0, f_rdata = 0, wr_addr = 0;
    logic [17:2] inv_addr = 0;

    // the two ports' outputs: {reference, new}
    logic [31:0] i_rdata [2], d_rdata [2], x_wdata [2], f_addr [2], f_wdata [2];
    logic        i_ok [2], d_ok [2], d_boot [2], x_req [2], x_we [2], x_stores [2], f_req [2], f_we [2];
    logic [10:0] ib_addr [2], db_addr [2];
    logic [17:2] x_addr [2];
    logic [3:0]  x_be [2], f_be [2];

    nds_arm7_port_ref #(.IL(IL), .DL(DL)) u_ref (.clk, .rst, .wramcnt,
        .i_req, .i_addr, .i_rdata(i_rdata[0]), .i_ok(i_ok[0]),
        .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata(d_rdata[0]), .d_ok(d_ok[0]),
        .ib_addr(ib_addr[0]), .i_boot_q, .db_addr(db_addr[0]), .d_boot(d_boot[0]), .d_boot_q,
        .x_req(x_req[0]), .x_we(x_we[0]), .x_addr(x_addr[0]), .x_be(x_be[0]), .x_wdata(x_wdata[0]),
        .x_stores(x_stores[0]), .x_done, .x_rdata, .inv, .inv_addr,
        .f_req(f_req[0]), .f_we(f_we[0]), .f_addr(f_addr[0]), .f_be(f_be[0]), .f_wdata(f_wdata[0]),
        .f_ack, .f_rdata, .wr_mon, .wr_addr);
    nds_arm7_port #(.IL(IL), .DL(DL), .TAG_STYLE(TAG_STYLE)) u_new (.clk, .rst, .wramcnt,
        .i_req, .i_addr, .i_rdata(i_rdata[1]), .i_ok(i_ok[1]),
        .d_req, .d_we, .d_be, .d_addr, .d_wdata, .d_rdata(d_rdata[1]), .d_ok(d_ok[1]),
        .ib_addr(ib_addr[1]), .i_boot_q, .db_addr(db_addr[1]), .d_boot(d_boot[1]), .d_boot_q,
        .x_req(x_req[1]), .x_we(x_we[1]), .x_addr(x_addr[1]), .x_be(x_be[1]), .x_wdata(x_wdata[1]),
        .x_stores(x_stores[1]), .x_done, .x_rdata, .inv, .inv_addr,
        .f_req(f_req[1]), .f_we(f_we[1]), .f_addr(f_addr[1]), .f_be(f_be[1]), .f_wdata(f_wdata[1]),
        .f_ack, .f_rdata, .wr_mon, .wr_addr);

    // ---- memory models
    logic [31:0] sram [0:65535];
    initial for (int i = 0; i < 65536; i++) sram[i] = $urandom;
    int x_wait = 0, f_wait = 0;
    logic x_on = 0, f_on = 0;

    // ---- stimulus
    int unsigned seed = 1;
    longint cycles = 1000000, cyc = 0, errs = 0;
    longint n_iok = 0, n_dok = 0, n_x = 0, n_f = 0, n_inv = 0, n_st = 0, n_ih = 0, n_dh = 0, n_ic = 0, n_dc = 0, n_q = 0;
    logic [31:0] hot_i, hot_d;          // where the code and data are now
    logic [15:0] ld_be [logic [29:0]];  // per word: the byte-enable patterns loads asked for

    // an address in one of the regions, mostly near the hot spot
    function automatic logic [31:0] addr_of(input logic [31:0] hot);
        int r = $urandom % 16;
        logic [31:0] a;
        if (r < 10) a = hot + (($urandom % 256) << 2);
        else case (r)
            10: a = {18'd0, 14'($urandom)};                      // BIOS7
            11: a = 32'h0000_8000 | 32'($urandom % 8192);        // boot ROM
            12: a = 32'h0300_0000 | 32'($urandom % 32768);       // shared WRAM
            13: a = 32'h0200_0000 | 32'($urandom % 4096);        // fabric: main RAM
            14: a = 32'h0400_0000 | 32'($urandom % 1024);        // fabric: I/O
            default: a = 32'h0380_0000 | 32'($urandom % 65536);  // ARM7 WRAM
        endcase
        return {a[31:2], 2'b00};
    endfunction
    function automatic logic [31:0] hot_new();
        int r = $urandom % 4;
        case (r)
            0: return 32'h0380_0000 | 32'($urandom % 65536) & ~32'h3FF;
            1: return 32'h0300_0000 | 32'($urandom % 32768) & ~32'h3FF;
            2: return 32'h0000_0000 | 32'($urandom % 16384) & ~32'h3FF;
            default: return 32'h0200_0000 | 32'($urandom % 4096) & ~32'h3FF;
        endcase
    endfunction

    task automatic cmp(input string what, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin
            errs++;
            if (errs < 10) $display("cycle %0d: %s: reference %h, new %h", cyc, what, a, b);
        end
    endtask

    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        hot_i = hot_new(); hot_d = hot_new();
        repeat (4) @(posedge clk);
        rst <= 0;
        // the tag stores' reset sweep (2^IL cycles), during which the
        // pipeline is still held (cpu_rst)
        repeat ((1 << IL) + 4) @(posedge clk);
        while (cyc < cycles) begin
            @(negedge clk);
            // ---- compare every output
            cmp("i_ok", i_ok[0], i_ok[1]);
            cmp("d_ok", d_ok[0], d_ok[1]);
            if (i_ok[0]) cmp("i_rdata", i_rdata[0], i_rdata[1]);
            // (a store's answer carries no data: only a read's d_rdata is compared)
            if (d_ok[0] && !dw_q) cmp("d_rdata", d_rdata[0], d_rdata[1]);
            cmp("ib/db/d_boot", {ib_addr[0], db_addr[0], d_boot[0]}, {ib_addr[1], db_addr[1], d_boot[1]});
            cmp("x_req/we/stores", {x_req[0], x_we[0], x_stores[0]}, {x_req[1], x_we[1], x_stores[1]});
            if (x_req[0]) cmp("x_addr/be", {x_addr[0], x_be[0]}, {x_addr[1], x_be[1]});
            if (x_req[0] && x_we[0]) cmp("x_wdata", x_wdata[0], x_wdata[1]);
            cmp("f_req/we", {f_req[0], f_we[0]}, {f_req[1], f_we[1]});
            // a data read's byte enables are the load's (the reference sent
            // 4'hF until 1f7e66c): checked against the load below
            if (f_req[0]) cmp("f_addr", f_addr[0], f_addr[1]);
            if (f_req[0] && (f_we[0] || u_ref.rp_i)) cmp("f_be", f_be[0], f_be[1]);
            // (any load of that word since its last fabric read: a refused
            // load may be given up for another before its read ends)
            if (f_req[1] && !f_we[1] && !u_new.rp_i && !ld_be[f_addr[1][31:2]][f_be[1]]) begin
                errs++;
                if (errs < 10) $display("cycle %0d: fabric read of %h with byte enables %b, not a load's (%b)", cyc, f_addr[1], f_be[1], ld_be[f_addr[1][31:2]]);
            end
            if (f_ack && !f_we[1] && !u_new.rp_i) ld_be[f_addr[1][31:2]] = '0;
            if (f_req[0] && f_we[0]) cmp("f_wdata", f_wdata[0], f_wdata[1]);
            if (i_ok[0]) n_iok++;
            // coverage: cache hits (the reference's) and tag-checked clears
            if (u_ref.ia_v && u_ref.ic_hit) n_ih++;
            if (u_ref.da_v && u_ref.dc_hit) n_dh++;
            // (clears counted in the new port; the outputs say whether they match)
            if (u_new.ic_inv) n_ic++;
            if (u_new.dc_inv) n_dc++;
            if (u_new.u_itag.qv != 0 || u_new.u_dtag.qv != 0) n_q++;
            if (d_ok[0]) n_dok++;

            // ---- the pipeline: a fetch and a data access most cycles; the
            // same request again until answered, sometimes given up (an IRQ)
            if ($urandom % 2048 == 0) hot_i = hot_new();
            if ($urandom % 1024 == 0) hot_d = hot_new();
            if (!i_req || i_ok[0] || $urandom % 64 == 0) begin
                i_req = $urandom % 8 != 0;
                i_addr = (i_ok[0] && $urandom % 4 != 0) ? i_addr + 4 : addr_of(hot_i);
                // now and then a fetch at, or just below, the BIOSPROT boundary
                if ($urandom % 64 == 0) i_addr = {16'd0, biosprot} - (($urandom % 2) ? 32'd4 : 32'd0);
            end
            if (!d_req || d_ok[0] || $urandom % 64 == 0) begin
                d_req = $urandom % 3 == 0;
                d_we = $urandom % 3 == 0;
                // stores into the code now and then (self-modifying code)
                d_addr = (d_we && $urandom % 8 == 0) ? addr_of(hot_i) : addr_of(hot_d);
                // stores and loads of every size (byte, halfword, word)
                d_be = d_we ? 4'($urandom % 15 + 1) :
                       ($urandom % 3 == 0) ? 4'b0001 << ($urandom % 4) :
                       ($urandom % 2 == 0) ? (($urandom % 2) ? 4'b1100 : 4'b0011) : 4'hF;
                if (d_req && !d_we) ld_be[d_addr[31:2]][d_be] = 1'b1;
                d_wdata = $urandom;
                if (d_req && d_we) n_st++;
            end
            if ($urandom % 50000 == 0) wramcnt = 2'($urandom);
            i_boot_q = $urandom; d_boot_q = $urandom;

            // ---- the SRAM (held request, done after 1..4 cycles) and the
            // fabric (1..12); others' writes
            x_done = 1'b0; f_ack = 1'b0; inv = 1'b0; wr_mon = 1'b0;
            if (x_req[0]) begin
                if (!x_on) begin x_on = 1; x_wait = $urandom % 4; end
                else if (x_wait > 0) x_wait--;
                if (x_on && x_wait == 0) begin
                    x_done = 1'b1; x_on = 0; n_x++;
                    x_rdata = sram[x_addr[0]];
                    if (x_we[0]) for (int b = 0; b < 4; b++)
                        if (x_be[0][b]) sram[x_addr[0]][b*8 +: 8] = x_wdata[0][b*8 +: 8];
                end
            end
            if (f_req[0]) begin
                if (!f_on) begin f_on = 1; f_wait = $urandom % 12; end
                else if (f_wait > 0) f_wait--;
                if (f_on && f_wait == 0) begin f_ack = 1'b1; f_on = 0; f_rdata = $urandom; n_f++; end
            end
            if (!x_done && $urandom % 6 == 0) begin
                // someone else writes the SRAM (mostly near the ARM7's hot spots)
                logic [17:0] xa;
                xa = $urandom % 2 ? {2'b00, hot_i[15:0]} + 18'(($urandom % 256) << 2) : 18'($urandom);
                inv = 1'b1; inv_addr = xa[17:2]; n_inv++;
                sram[xa[17:2]] = $urandom;
            end
            if ($urandom % 5 == 0) begin
                wr_mon = 1'b1;
                wr_addr = $urandom % 2 ? addr_of(hot_i) : 32'h0200_0000 | 32'($urandom % 4096);
            end
            if ($urandom % 200000 == 0) begin
                // a reset: both empty, then the sweep
                rst = 1'b1;
                @(posedge clk);
                @(negedge clk);
                rst = 1'b0;
                i_req = 0; d_req = 0; x_on = 0; f_on = 0; x_done = 0; f_ack = 0; inv = 0; wr_mon = 0;
                repeat ((1 << IL) + 4) @(negedge clk);
            end
            @(posedge clk);
            cyc++;
        end
        $display("arm7port_eq IL %0d DL %0d: %0d cycles, %0d fetches and %0d data accesses answered, %0d stores, %0d SRAM and %0d fabric accesses, %0d others' writes; hits %0d fetch %0d data, clears %0d fetch %0d data, %0d cycles queued: %0d differences",
                 IL, DL, cyc, n_iok, n_dok, n_st, n_x, n_f, n_inv, n_ih, n_dh, n_ic, n_dc, n_q, errs);
        if (errs || n_ih == 0 || n_dh == 0 || n_ic == 0 || n_dc == 0 || n_q == 0) begin $display("FAIL"); $fatal(1); end
        $display("PASS");
        $finish;
    end
endmodule
