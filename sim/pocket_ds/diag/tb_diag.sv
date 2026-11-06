// nds_diag (rtl/pocket/nds_diag.sv) on random events: every frame record in the SDRAM model must hold, for each
// event, its count up to the clock the scanner sampled it (and the frame's values), the per-second copies the
// same, the histograms the counted bins, and the header the totals. Small rings and SEC_EVERY 10, so the rings
// wrap and several second dumps happen. diag.sh runs it.
`timescale 1ns/1ps
module tb_diag;
    `ifndef TB_NL
`define TB_NL 2
`endif
    localparam integer NE = 40, N2 = 8, NT = 48, NV = 6, NH = 4, NL = `TB_NL, NL1 = NL > 0 ? NL : 1, FS = 16, SS = 4, SE = 10;
    localparam [23:0] BASE = 24'h10_0000;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    int unsigned seed, frames;
    logic frame = 0;
    logic [NE-1:0] ev = 0;
    logic [N2*2-1:0] ev2 = 0;
    logic [NV*32-1:0] val = 0;
    logic [NH-1:0] h_v = 0;
    logic [NH*4-1:0] h_bin = 0;
    logic [NL1-1:0] l_v = 0;
    logic [NL1*9-1:0] l_line = 0;
    wire w_req;
    wire [23:0] w_addr;
    wire [31:0] w_data;
    logic w_ack = 0;
    nds_diag #(.NE(NE), .N2(N2), .NV(NV), .NH(NH), .NL(NL), .BASE_W(BASE), .SEC_SLOTS(SS), .FRAME_SLOTS(FS), .SEC_EVERY(SE),
               .GAP(4), .CONFIG(32'hC0FF_EE01)) dut (.clk, .rst, .frame, .ev, .ev2, .val, .h_v, .h_bin, .l_v, .l_line,
               .w_req, .w_addr, .w_data, .w_ack);

    // SDRAM: random delays
    logic [31:0] mem [int];
    int wdel = -1;
    always @(posedge clk) begin
        w_ack <= 0;
        if (w_req && !w_ack) begin
            if (wdel < 0) wdel <= $urandom % 6;
            else if (wdel == 0) begin w_ack <= 1; mem[w_addr] = w_data; wdel <= -1; end
            else wdel <= wdel - 1;
        end
    end

    // the expected records: each event's count before the clock the scanner sampled it, by frame number
    longint unsigned cum [NT];
    logic [31:0] exp_rec [int][NT];
    logic [31:0] exp_val [int][NV];
    int unsigned hcnt [NH][16];
    int unsigned lcnt [NL1][32];
    int unsigned errors = 0;
    task automatic err(input string s);
        errors++;
        if (errors <= 12) $display("ERROR %s", s);
    endtask
    always @(posedge clk) if (!rst) begin
        if (dut.snap_n != 0) exp_rec[dut.fno][dut.scan] = cum[dut.scan];
        for (int k = 0; k < NE; k++) if (ev[k]) cum[k]++;
        for (int k = 0; k < N2; k++) cum[NE + k] += ev2[k*2 +: 2];
        for (int h = 0; h < NH; h++) if (h_v[h]) hcnt[h][h_bin[h*4 +: 4]]++;
        for (int l = 0; l < NL; l++) if (l_v[l]) lcnt[l][l_line[l*9 +: 9] > 255 ? 31 : l_line[l*9 +: 9] / 8]++;
    end

    int dens [NT];
    int hgap [NH];
    int unsigned fno_tb = 0;
    bit quiet = 0;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("frames=%d", frames)) frames = 60;
        void'($urandom(seed));
        for (int k = 0; k < NT; k++) dens[k] = $urandom % 101;                 // percent of clocks
        for (int h = 0; h < NH; h++) hgap[h] = 0;
        repeat (100) @(posedge clk);
        rst <= 0;
        repeat (600) @(posedge clk);                                           // the histogram clear
        fork
            // events
            forever begin
                @(posedge clk);
                for (int k = 0; k < NE; k++) ev[k] <= !quiet && ($urandom % 100) < dens[k];
                for (int k = 0; k < N2; k++) ev2[k*2 +: 2] <= quiet ? 2'd0 : 2'(($urandom % 100) < dens[NE + k] ? 1 + $urandom % 3 : 0);
                for (int h = 0; h < NH; h++) begin
                    // at least two clocks apart per histogram (the taps' events are)
                    if (!quiet && hgap[h] == 0 && $urandom % 5 == 0) begin h_v[h] <= 1; h_bin[h*4 +: 4] <= $urandom; hgap[h] = 2; end
                    else begin h_v[h] <= 0; if (hgap[h] > 0) hgap[h]--; end
                end
                for (int l = 0; l < NL; l++) begin
                    l_v[l] <= !quiet && $urandom % 40 == 0 && !l_v[l]; l_line[l*9 +: 9] <= $urandom % 280;
                end
            end
            // frames: a pulse every 3000-5000 clocks, with new values
            begin
                for (int f = 0; f < frames; f++) begin
                    repeat (3000 + $urandom % 2000) @(posedge clk);
                    if (f == frames - 2 * SE) quiet = 1;                       // the last two seconds: no histogram events
                    frame <= 1;
                    for (int v = 0; v < NV; v++) val[v*32 +: 32] <= $urandom;
                    @(posedge clk); frame <= 0;
                    fno_tb++;
                    for (int v = 0; v < NV; v++) exp_val[fno_tb][v] = val[v*32 +: 32];
                end
            end
        join_any
        repeat (20000) @(posedge clk);
        check();
        begin
            string fn;
            if ($value$plusargs("dump=%s", fn)) begin
                // the log region as the Pocket would save it (<game>.ndg), little-endian words
                int fd;
                fd = $fopen(fn, "wb");
                for (int i = 0; i < 24'h2_0000; i++) begin
                    logic [31:0] x;
                    x = mem.exists(BASE + i) ? mem[BASE + i] : 32'd0;
                    $fwrite(fd, "%c%c%c%c", x[7:0], x[15:8], x[23:16], x[31:24]);
                end
                $fclose(fd);
            end
        end
        $display("diag: seed %0d, %0d frames, %0d errors", seed, frames, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    task automatic check_rec(input int base, input string what);
        int unsigned n;
        n = mem.exists(base) ? mem[base] : 0;
        if (n == 0) begin err($sformatf("%s: no record", what)); return; end
        for (int k = 0; k < NT; k++)
            if (mem[base + 1 + k] !== exp_rec[n][k]) err($sformatf("%s frame %0d event %0d: %0d, expected %0d", what, n, k, mem[base + 1 + k], exp_rec[n][k]));
        for (int v = 0; v < NV; v++)
            if (mem[base + 1 + NT + v] !== exp_val[n][v]) err($sformatf("%s frame %0d value %0d: %h, expected %h", what, n, v, mem[base + 1 + NT + v], exp_val[n][v]));
    endtask
    task automatic check();
        int unsigned frs, secs;
        // header
        if (mem[BASE] !== 32'h3147_444E) err("header magic");
        if (mem[BASE + 3] !== 32'hC0FF_EE01) err("header config");
        frs = mem[BASE + 4]; secs = mem[BASE + 5];
        if (frs != fno_tb) err($sformatf("header: %0d frames, expected %0d", frs, fno_tb));
        if (secs != fno_tb / SE) err($sformatf("header: %0d seconds, expected %0d", secs, fno_tb / SE));
        if (mem[BASE + 10] !== 0) err($sformatf("header: %0d histogram updates lost", mem[BASE + 10]));
        // every frame slot holds one of the last FS frames, the newest at next-slot - 1
        for (int s = 0; s < FS; s++) check_rec(BASE + 24'h4400 + 64 * s, $sformatf("frame slot %0d", s));
        if (mem[BASE + 24'h4400 + 64 * ((mem[BASE + 8] + FS - 1) % FS)] != frs) err("newest frame slot");
        for (int s = 0; s < SS; s++) check_rec(BASE + 24'h400 + 64 * s, $sformatf("second slot %0d", s));
        for (int h = 0; h < NH; h++) for (int b = 0; b < 16; b++)
            if (mem[BASE + 24'h40 + 16 * h + b] !== hcnt[h][b]) err($sformatf("histogram %0d bin %0d: %0d, expected %0d", h, b, mem[BASE + 24'h40 + 16 * h + b], hcnt[h][b]));
        for (int l = 0; l < NL; l++) for (int b = 0; b < 32; b++)
            if (mem[BASE + 24'h100 + 32 * l + b] !== lcnt[l][b]) err($sformatf("line histogram %0d bin %0d: %0d, expected %0d", l, b, mem[BASE + 24'h100 + 32 * l + b], lcnt[l][b]));
    endtask
    initial begin #50ms; $display("TIMEOUT"); $display("FAIL"); $finish; end
endmodule
