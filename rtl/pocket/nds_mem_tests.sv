// SPDX-License-Identifier: MIT
// clk_mem tests of the Phase 1 core (docs/phase1-foundation.md):
//   nds_psram_test  pattern test through psx_psram_pair (PocketQuake recipe)
//   nds_sram_test   which access lengths the Pocket's async SRAM passes
// Both loop forever; results are static between passes.
`default_nettype none

// psx_psram_pair packet port: halfword address {die, word, 0}, 1..8 halfwords;
// WORDS <= 2M per die (the pair takes word addresses below 2M of each die).
// Each pass over WORDS words of each die: four-word writes, four-word reads
// (compared), then a single-halfword write of the low byte of every 1,024th
// word and a one-word read of it. Times in clk_mem clocks: whole write and
// read phases, and the longest single read packet (request to response).
module nds_psram_test #(parameter [21:0] WORDS = 22'h20_0000) (
    input wire clk, reset, start,
    output reg [1:0] state = 0,             // 0 waiting, 1 running, 2 passing, 3 error seen
    output reg [31:0] passes = 0, errors = 0,
    output reg [31:0] fail_addr = 0, fail_exp = 0, fail_act = 0,
    output reg [31:0] wr_cycles = 0, rd_cycles = 0,
    output reg [15:0] rd_max = 0, rd_min = 16'hFFFF,   // both reset explicitly
    output reg req_valid = 0, req_write = 0,
    input wire req_ready,
    output reg [24:0] req_addr = 0,
    output reg [3:0] req_halfwords = 0,
    output reg [127:0] req_wdata = 0,
    output reg [15:0] req_byte_en = 0,
    input wire rsp_valid,
    input wire [127:0] rsp_rdata,
    input wire rsp_error
);
    localparam [1:0] P_WRITE = 0, P_READ = 1, P_LANE = 2;
    reg [1:0] phase = P_WRITE;
    reg die = 0, busy = 0, lane_rd = 0;
    reg [21:0] w = 0;
    reg [31:0] t = 0;
    reg [15:0] lat = 0;
    // a different word at every address (die and word in the low 22 bits),
    // every bit inverted from one pass to the next; XORs only (100 MHz)
    function automatic [31:0] pat(input d, input [20:0] word, input [31:0] p);
        pat = {word[15:0], d, word[20:6]} ^ {p[15:0], p[31:16]} ^ {32{p[0]}};
    endfunction
    // w is a multiple of 4 wherever quads are used
    wire [127:0] quad = {pat(die, {w[20:2], 2'd3}, passes), pat(die, {w[20:2], 2'd2}, passes),
                         pat(die, {w[20:2], 2'd1}, passes), pat(die, w[20:0], passes)};
    wire [31:0] p0 = pat(die, w[20:0], passes);
    wire [31:0] lane_exp = {p0[31:8], ~p0[7:0]};
    task automatic bad(input [21:0] word, input [31:0] exp, input [31:0] act);
        if (errors == 0) begin fail_addr <= {9'b0, die, word}; fail_exp <= exp; fail_act <= act; end
        errors <= errors + 1'b1; state <= 2'd3;
    endtask
    always @(posedge clk) begin
        if (req_valid && req_ready) req_valid <= 0;
        if (reset) begin
            state <= 0; req_valid <= 0; busy <= 0; phase <= P_WRITE; die <= 0; w <= 0; t <= 0;
            rd_max <= 0; rd_min <= 16'hFFFF; errors <= 0; passes <= 0;
        end
        else if (state == 0) begin if (start) state <= 1; end
        else begin
            t <= t + 1'b1;
            lat <= lat + 1'b1;
            if (!busy) begin
                busy <= 1; req_valid <= 1; lat <= 0;
                req_addr <= {1'b0, die, 1'b0, w[20:0], 1'b0};
                case (phase)
                    P_WRITE: begin req_write <= 1; req_halfwords <= 4'd8; req_wdata <= quad; req_byte_en <= 16'hFFFF; end
                    P_READ: begin req_write <= 0; req_halfwords <= 4'd8; end
                    default: if (!lane_rd) begin
                        req_write <= 1; req_halfwords <= 4'd1; req_wdata <= {120'b0, ~p0[7:0]};
                        req_byte_en <= 16'h0001;
                    end else begin req_write <= 0; req_halfwords <= 4'd2; end
                endcase
            end else if (rsp_valid) begin
                busy <= 0;
                if (rsp_error) bad(w, 32'hE0E0_E0E0, 32'h0);
                case (phase)
                    P_WRITE: begin
                        if (w + 22'd4 >= WORDS) begin
                            w <= 0;
                            if (die) begin die <= 0; phase <= P_READ; wr_cycles <= t; t <= 0; end
                            else die <= 1;
                        end else w <= w + 22'd4;
                    end
                    P_READ: begin
                        if (lat > rd_max) rd_max <= lat;
                        if (lat < rd_min) rd_min <= lat;
                        if (rsp_rdata[31:0] != quad[31:0]) bad(w, quad[31:0], rsp_rdata[31:0]);
                        else if (rsp_rdata[63:32] != quad[63:32]) bad(w + 22'd1, quad[63:32], rsp_rdata[63:32]);
                        else if (rsp_rdata[95:64] != quad[95:64]) bad(w + 22'd2, quad[95:64], rsp_rdata[95:64]);
                        else if (rsp_rdata[127:96] != quad[127:96]) bad(w + 22'd3, quad[127:96], rsp_rdata[127:96]);
                        if (w + 22'd4 >= WORDS) begin
                            w <= 0;
                            if (die) begin die <= 0; phase <= P_LANE; rd_cycles <= t; t <= 0; end
                            else die <= 1;
                        end else w <= w + 22'd4;
                    end
                    default: if (!lane_rd) lane_rd <= 1;
                    else begin
                        lane_rd <= 0;
                        if (rsp_rdata[31:0] != lane_exp) bad(w, lane_exp, rsp_rdata[31:0]);
                        if (w + 22'd1024 >= WORDS) begin
                            w <= 0;
                            if (die) begin
                                die <= 0; phase <= P_WRITE; passes <= passes + 1'b1;
                                if (state == 1) state <= 2;
                            end else die <= 1;
                        end else w <= w + 22'd1024;
                    end
                endcase
            end
        end
    end
endmodule

// Async SRAM (128K x 16, addresses 0..LAST). For each access length L = 1..15
// clocks in turn, one pass writes every halfword (pattern per L and round) and
// reads it back. A write sets address and data with WE# high, drops WE# for L
// clocks, raises it with the data still driven for one more clock (as
// PocketQuake's sram_controller); a read drives the address and OE# low and
// samples the pins' input register L clocks later. ok[L] is set when a whole
// pass at L had no error, bad[L] when one did; both are kept over all rounds,
// with every register reset explicitly (#55: Quartus turned the set-only
// ok/bad bits into constants). err_l holds each length's errors over all
// rounds (saturating), ffff_reads the bad reads that came back as 0xFFFF
// (nothing driving the bus).
module nds_sram_test #(parameter [16:0] LAST = 17'h1_FFFF) (
    input wire clk, reset, start,
    output reg [15:0] ok = 0, bad = 0,
    output reg [15:0] rounds = 0,
    output reg [31:0] errors = 0,
    output reg [31:0] ffff_reads = 0,
    output wire [255:0] err_l,              // 16 bits per L, L in [16L +: 16]
    output reg [31:0] fail_info = 0,        // first error: {L, address}
    output reg [31:0] fail_data = 0,        // {expected, actual}
    (* useioff = 1 *) output reg [16:0] sram_a = 0,
    (* useioff = 1 *) output reg [15:0] dq_out = 0,
    (* useioff = 1 *) output reg dq_oe = 0,
    input wire [15:0] dq_pin,
    (* useioff = 1 *) output reg oe_n = 1,
    (* useioff = 1 *) output reg we_n = 1,
    output wire ub_n, lb_n
);
    assign ub_n = 1'b0, lb_n = 1'b0;
    (* useioff = 1 *) reg [15:0] dq_in = 0;
    always @(posedge clk) dq_in <= dq_pin;
    reg [3:0] len = 1;
    reg [16:0] a = 0;
    reg rd = 0, running = 0, pass_bad = 0;
    reg [4:0] c = 0;
    (* ramstyle = "logic" *) reg [15:0] errs [0:15];
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : err_out
        assign err_l[g*16 +: 16] = errs[g];
    end endgenerate
    // a different halfword at every address, changing with L and the round
    wire [15:0] pat = {a[7:0], a[15:8]} ^ {len, rounds[11:0]} ^ {16{a[16]}};
    wire wrong = dq_in != pat;
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            running <= 0; oe_n <= 1; we_n <= 1; dq_oe <= 0; len <= 1; a <= 0; c <= 0; rd <= 0; pass_bad <= 0;
            ok <= 0; bad <= 0; rounds <= 0; errors <= 0; ffff_reads <= 0; fail_info <= 0; fail_data <= 0;
            for (i = 0; i < 16; i = i + 1) errs[i] <= 0;
        end else if (!running) begin if (start) begin running <= 1; c <= 0; end end
        else begin
            c <= c + 1'b1;
            if (!rd) begin
                // write: address+data at 0 (WE# high), WE# low 1..L, WE# high at L+1, bus released at L+2
                if (c == 0) begin sram_a <= a; dq_out <= pat; dq_oe <= 1; we_n <= 1; oe_n <= 1; end
                else if (c == 1) we_n <= 0;
                else if (c == len + 1) we_n <= 1;
                else if (c == len + 2) begin
                    dq_oe <= 0; c <= 0;
                    if (a == LAST) begin a <= 0; rd <= 1; end else a <= a + 1'b1;
                end
            end else begin
                // read: address and OE# at 0; the input register holds the pins of clock L at L+1
                if (c == 0) begin sram_a <= a; oe_n <= 0; we_n <= 1; end
                else if (c == len + 1) begin
                    oe_n <= 1; c <= 0;
                    if (wrong) begin
                        if (errors == 0) begin fail_info <= {11'b0, len, a}; fail_data <= {pat, dq_in}; end
                        errors <= errors + 1'b1; pass_bad <= 1;
                        if (errs[len] != 16'hFFFF) errs[len] <= errs[len] + 1'b1;
                        if (dq_in == 16'hFFFF) ffff_reads <= ffff_reads + 1'b1;
                    end
                    if (a == LAST) begin
                        a <= 0; rd <= 0;
                        if (pass_bad || wrong) bad[len] <= 1; else ok[len] <= 1;
                        pass_bad <= 0;
                        if (len == 4'd15) begin len <= 1; rounds <= rounds + 1'b1; end
                        else len <= len + 1'b1;
                    end else a <= a + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
