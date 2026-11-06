// psx_pq_psram against its version at a git ref (psx_pq_psram_ref, pq_eq.sh),
// clock by clock: the same random requests, addresses, data, WAIT and DQ
// input to both, every output (and cram_data, the DQ output register, even
// while it isn't driven) compared on every clock. Two parameter sets: the
// Pocket's 100.54 MHz and the PSX default 48 MHz with WRITE_EXTRA 2.
`timescale 1ns/1ps
module pq_pair #(parameter real MHZ = 100.541946, parameter integer WX = 0, parameter integer ID = 0) (
    input wire clk, input wire [31:0] seed, output reg [31:0] errs = 0, output reg [31:0] reqs = 0);
    reg bank = 0, wen = 0, hb = 0, lb = 0, ren = 0, sen = 0, cen = 0, wt = 0;
    reg [21:0] addr = 0; reg [15:0] din = 0, cfg = 0, rdq = 0; reg [5:0] blen = 0;
    wire [15:0] dq_r, dq_n;
    `define PQ_PORTS(dq) .clk(clk), .bank_sel(bank), .addr(addr), .write_en(wen), .data_in(din), .write_high_byte(hb), \
        .write_low_byte(lb), .read_en(ren), .sync_burst_en(sen), .sync_burst_len(blen), .config_en(cen), .config_data(cfg), \
        .cram_dq(dq), .cram_wait(wt)
    psx_pq_psram_ref #(.CLOCK_SPEED(MHZ), .WRITE_EXTRA(WX)) r (`PQ_PORTS(dq_r));
    psx_pq_psram     #(.CLOCK_SPEED(MHZ), .WRITE_EXTRA(WX)) n (`PQ_PORTS(dq_n));
    assign dq_r = r.data_out_en ? 16'hzzzz : rdq;
    assign dq_n = n.data_out_en ? 16'hzzzz : rdq;
    wire [255:0] o_r = {r.read_avail, r.data_out, r.busy, r.dbg_wait_seen, r.dbg_wait_cycles, r.dbg_burst_count,
        r.dbg_stale_count, r.cram_a, r.cram_clk, r.cram_adv_n, r.cram_cre, r.cram_ce0_n, r.cram_ce1_n, r.cram_oe_n,
        r.cram_we_n, r.cram_ub_n, r.cram_lb_n, r.data_out_en, r.cram_data, r.state};
    wire [255:0] o_n = {n.read_avail, n.data_out, n.busy, n.dbg_wait_seen, n.dbg_wait_cycles, n.dbg_burst_count,
        n.dbg_stale_count, n.cram_a, n.cram_clk, n.cram_adv_n, n.cram_cre, n.cram_ce0_n, n.cram_ce1_n, n.cram_oe_n,
        n.cram_we_n, n.cram_ub_n, n.cram_lb_n, n.data_out_en, n.cram_data, n.state};
    integer s;
    initial begin s = 1; void'($value$plusargs("seed=%d", s)); s = s * 7 + ID; end
    always @(posedge clk) begin
        if (o_r !== o_n) begin
            errs <= errs + 1;
            if (errs < 5) $display("ERROR set %0d t=%0t: ref %h new %h", ID, $time, o_r, o_n);
        end
        // a request at most every few clocks, as the pair issues them, plus
        // random ones while busy (ignored by both outside STATE_NONE)
        wen <= 0; ren <= 0; sen <= 0; cen <= 0;
        case ($unsigned($random(s)) % 8)
            0: begin wen <= 1; reqs <= reqs + 1; end
            1: begin sen <= 1; reqs <= reqs + 1; end
            2: if ($unsigned($random(s)) % 4 == 0) begin cen <= 1; reqs <= reqs + 1; end
            3: if ($unsigned($random(s)) % 2 == 0) begin ren <= 1; reqs <= reqs + 1; end
            default: ;
        endcase
        bank <= $unsigned($random(s)); addr <= $unsigned($random(s)); din <= $unsigned($random(s)); cfg <= $unsigned($random(s));
        hb <= $unsigned($random(s)); lb <= $unsigned($random(s)); blen <= $unsigned($random(s)) % 12; rdq <= $unsigned($random(s));
        wt <= ($unsigned($random(s)) % 5) == 0;
    end
endmodule

module tb_pq_eq;
    reg clk = 0;
    always #5 clk = !clk;
    integer cycles = 200000; reg [31:0] seed = 1;
    wire [31:0] e0, e1, q0, q1;
    pq_pair #(.MHZ(100.541946), .WX(0), .ID(0)) p0 (.clk, .seed, .errs(e0), .reqs(q0));
    pq_pair #(.MHZ(48.0), .WX(2), .ID(1)) p1 (.clk, .seed, .errs(e1), .reqs(q1));
    initial begin
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("cycles=%d", cycles));
        repeat (cycles) @(posedge clk);
        #1;
        if (e0 == 0 && e1 == 0) $display("PASS: %0d clocks, %0d + %0d requests, 0 differences (seed %0d)", cycles, q0, q1, seed);
        else $display("FAIL: %0d / %0d clocks differ (seed %0d)", e0, e1, seed);
        $finish;
    end
endmodule
