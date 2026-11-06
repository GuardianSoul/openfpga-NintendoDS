// nds_sdram_mc equivalence: this tree's controller against REF's (nds_sdram_mc_ref), same requests, same chain
// FIFO, same read data on DQ; every pin and client output compared each clock. REF's power-up wait is shortened and
// its init released so that both start the chip's init sequence on the same clock.
`timescale 1ns/1ps
module tb_mc_eq;
    logic clk = 0; always #5 clk = !clk;
    longint cycles = 2000000, n = 0, bad = 0, n_rd = 0, n_wr = 0, n_ch = 0, seen_ready = 0;
    int seed = 1;
    logic c_valid = 0, c_hurry = 0, c_we = 0;
    logic [23:0] c_addr = 0;
    logic [3:0] c_n = 1, c_be = 4'hF;
    logic [31:0] c_wdata = 0;
    logic bw_valid = 0;
    logic [23:0] bw_addr = 0;
    logic [31:0] bw_data = 0;
    logic [15:0] drive = 0;
    wire [14:0] c_rb = c_addr[22:8];
    wire init_n = 1'b0;
    wire init_r = !(u_new.power_done || (u_new.ref_timer == 0 && u_new.init_step == u_new.POWER_TICKS));
    `define MC(M, NM, X, INIT, PARAMS) \
        wire [15:0] dq_``X = NM.p_dq_oe ? 16'bz : drive; \
        wire ready_``X, c_ready_``X, r_valid_``X, r_last_``X, bw_read_``X, ref_late_``X, ldqm_``X, udqm_``X, we_``X, ras_``X, cas_``X, cke_``X, sclk_``X; \
        wire [31:0] r_data_``X; wire [12:0] a_``X; wire [1:0] ba_``X; \
        M #(.OPEN(1), .OUT_REG(1) PARAMS) NM (.clk, .init(INIT), .ready(ready_``X), .c_valid(c_valid && !c_ready_``X), .c_hurry, .c_we, .c_addr, .c_rb, .c_n, .c_wdata, .c_be, \
            .c_ready(c_ready_``X), .r_valid(r_valid_``X), .r_data(r_data_``X), .r_last(r_last_``X), .bw_valid, .bw_addr, .bw_data, .bw_read(bw_read_``X), .ref_late(ref_late_``X), \
            .SDRAM_DQ(dq_``X), .SDRAM_A(a_``X), .SDRAM_BA(ba_``X), .SDRAM_DQML(ldqm_``X), .SDRAM_DQMH(udqm_``X), .SDRAM_nWE(we_``X), .SDRAM_nRAS(ras_``X), .SDRAM_nCAS(cas_``X), .SDRAM_CKE(cke_``X), .SDRAM_CLK(sclk_``X));
    `MC(nds_sdram_mc, u_new, n, init_n, )
    `MC(nds_sdram_mc_ref, u_ref, r, init_r, `COMMA .POWERUP_CYCLES(1))
    wire [100:0] on = {ready_n, c_ready_n, r_valid_n, r_last_n, bw_read_n, ref_late_n, r_data_n, a_n, ba_n, ldqm_n, udqm_n, we_n, ras_n, cas_n, dq_n, 11'd0};
    wire [100:0] or_ = {ready_r, c_ready_r, r_valid_r, r_last_r, bw_read_r, ref_late_r, r_data_r, a_r, ba_r, ldqm_r, udqm_r, we_r, ras_r, cas_r, dq_r, 11'd0};
    // both controllers' first commands line up from the PRECHARGE on
    logic go = 0;
    always_ff @(posedge clk) if (u_new.power_done) go <= 1'b1;
    always @(posedge clk) if (go) begin
        n++;
        if (on !== or_) begin bad++; if (bad <= 5) $display("cycle %0d: differ new %h ref %h (st %0d/%0d)", n, on, or_, u_new.st, u_ref.st); end
    end
    function automatic int r(int m); return $urandom(seed) % m; endfunction
    int unsigned rs;
    function automatic int rnd(int m); rs = rs * 32'd1664525 + 32'd1013904223; return (rs >> 8) % m; endfunction
    logic [23:0] bw_next = 0; int bw_runleft = 0;
    logic [23:0] last_c = 0;
    always @(negedge clk) begin
        drive <= rnd(65536);
        c_hurry <= rnd(16) == 0;
        // the port: a request held until c_ready, the next soon after or in a burst of nearby rows
        if (c_valid && c_ready_r) begin c_valid <= 1'b0; if (c_we) n_wr++; else n_rd++; end
        else if (!c_valid && ready_r && rnd(6) == 0) begin
            logic [23:0] a; logic [3:0] w;
            a = rnd(3) ? last_c + 24'(rnd(32)) : 24'({rnd(256), rnd(65536)});
            a[23] = rnd(2);
            w = 4'(1 + rnd(8));
            if (rnd(2)) w = 4'd8;
            if (a[7:0] > 8'd255 - 8'(w) + 8'd1) a[7:0] = 8'd255 - 8'(w) + 8'd1;     // within the row
            last_c <= a; c_addr <= a; c_n <= w; c_we <= rnd(4) == 0; c_wdata <= {rnd(65536), rnd(65536)}; c_be <= 4'(rnd(16)); c_valid <= 1'b1;
        end
        // the chain's FIFO head: runs of consecutive words, some across a row's end; a new word now and then
        if (bw_valid && bw_read_r) begin bw_valid <= 1'b0; n_ch++; end
        if ((!bw_valid || bw_read_r) && ready_r && rnd(3) != 0) begin
            logic [23:0] a;
            if (bw_runleft == 0) begin a = 24'({rnd(256), rnd(65536)}); if (rnd(4) == 0) a[7:0] = 8'hF0 + 8'(rnd(16)); else if (rnd(3) == 0) a[7:0] = bw_next[7:0]; bw_runleft = rnd(40); end
            else begin a = bw_next; bw_runleft--; end
            bw_next <= a + 24'd1; bw_addr <= a; bw_data <= {rnd(65536), rnd(65536)}; bw_valid <= 1'b1;
        end
    end
    initial begin
        void'($value$plusargs("seed=%d", seed)); void'($value$plusargs("cycles=%d", cycles)); rs = seed * 32'd2654435761;
        wait (n >= cycles);
        $display("%s: %0d cycles, %0d reads, %0d writes, %0d chain words, %0d differing", bad == 0 && n_rd > 100 && n_ch > 100 ? "EQUIVALENT" : "DIFFER", n, n_rd, n_wr, n_ch, bad);
        $finish;
    end
endmodule
