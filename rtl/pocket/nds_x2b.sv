// SPDX-License-Identifier: MIT
// Crossings between the DS core's clk_sys (67.03 MHz) and the memory clients'
// clk_bus (33.51 MHz) for the DS core (docs/phase2-integration.md, "Pocket
// shell"). Both clocks come from one PLL with aligned edges (sys = 2 x bus),
// so the crossings are synchronous: every path is timed by the fitter with
// one clk_sys period (14.9 ns), and no synchronisers are needed. A bus-domain
// pulse lasts two clk_sys cycles; clk_sys takes it only in the first
// (`take`, from nds_bus_phase).
`default_nettype none

// The bus phase seen from clk_sys: take is high in the clk_sys cycle whose
// end is the first clk_sys edge after a clk_bus edge.
module nds_bus_phase (
    input wire clk_bus, clk_sys,
    output wire take
);
    reg bt = 0, bs = 0;
    always @(posedge clk_bus) bt <= !bt;
    always @(posedge clk_sys) bs <= bt;
    assign take = bt != bs;
endmodule

// One memory port from clk_sys to a clk_bus client of nds_sdram's contract.
// clk_sys side: s_req held until s_ack (one clk_sys pulse, the request was
// taken); a read's words follow on s_rvalid (one clk_sys pulse each, s_rdata
// with it). s_req must drop the cycle after s_ack (the DS core's ports do).
// clk_bus side: c_valid held until c_ready, r_valid per word.
module nds_x2b #(parameter integer AW = 24) (
    input wire clk_sys, clk_bus, reset,      // reset on clk_bus
    input wire take,
    input wire s_req, s_we, s_quad,
    input wire [AW-1:0] s_addr,
    input wire [31:0] s_wdata,
    input wire [3:0] s_be,
    output wire s_ack, s_rvalid,
    output wire [31:0] s_rdata,
    output reg c_valid = 0,
    output reg c_write = 0, c_quad = 0,
    output reg [AW-1:0] c_addr = 0,
    output reg [31:0] c_wdata = 0,
    output reg [3:0] c_be = 0,
    input wire c_ready, r_valid,
    input wire [31:0] r_data
);
    reg ack_b = 0, wait_b = 0;
    always @(posedge clk_bus) begin
        ack_b <= 0;
        if (reset) begin c_valid <= 0; wait_b <= 0; end
        else if (wait_b) wait_b <= 0;               // s_req drops while the ack is taken
        else if (c_valid) begin
            if (c_ready) begin c_valid <= 0; ack_b <= 1; wait_b <= 1; end
        end else if (s_req) begin
            c_valid <= 1; c_write <= s_we; c_quad <= s_quad; c_addr <= s_addr; c_wdata <= s_wdata; c_be <= s_be;
        end
    end
    assign s_ack = ack_b && take;
    assign s_rvalid = r_valid && take;
    assign s_rdata = r_data;
endmodule

// Main RAM in PSRAM die 0, straight from clk_sys (docs/phase2-integration.md,
// "Memory plumbing redesign" 2): the DS core's main-RAM port (nds_x2b's
// clk_sys contract; single 32-bit writes with byte enables, 16-byte reads)
// onto psx_psram_pair on clk_mem. clk_mem = 1.5 x clk_sys from the same PLL
// with aligned edges: the request crosses as a held bundle and a toggle,
// the answer the same way back (the closest edge pair is 4.97 ns, timed;
// every crossing path is register to register but for one 4:1 word select).
// A read's four words follow on consecutive clk_sys cycles.
module nds_psram_port (
    input wire clk_sys, clk_mem, reset,     // reset on clk_sys
    // clk_sys: s_req held until s_ack (one pulse); s_req drops the cycle after
    input wire s_req, s_we,
    input wire [23:0] s_addr,               // word address (die 0)
    input wire [31:0] s_wdata,
    input wire [3:0] s_be,
    output reg s_ack = 0,
    output reg s_rvalid = 0,
    output reg [31:0] s_rdata = 0,
    // a 32-byte block (s_n8, nds_fabric MR_BLOCK): a read hands out 8 words
    // (two 16-byte pair reads); a write takes s_wdata on each s_wnext pulse
    // (two 16-byte pair writes of 4 words) and acks with the eighth word
    input wire s_n8,
    output reg s_wnext = 0,
    // psx_psram_pair (clk_mem)
    output reg req_valid = 0,
    output reg req_write = 0,
    input wire req_ready,
    // views of the sys side's held request (below)
    output wire [24:0] req_addr,
    output wire [3:0] req_halfwords,
    output wire [127:0] req_wdata,
    output wire [15:0] req_byte_en,
    input wire rsp_valid,
    // the pair's read data (its rsp_raw), held until its next read: the
    // next one starts only after the words are handed out (out_n gate)
    input wire [127:0] rsp_rdata
);
    // ---- sys side
    reg req_t = 0, busy = 0;
    reg b_write = 0;
    // The request's PSRAM fields, formed here at the request edge and held
    // until its answer is in (busy). The pair reads them as they are
    // (req_* below): it samples them on the clk_mem edge where it sees
    // req_valid, which the mem side raises on the first clk_mem edge after
    // req_t flips, so at least two clk_mem edges after these registers
    // change: a two-cycle path (build_ds.sh). Copying them on clk_mem was a
    // one-edge path (4.97 ns, #317/#326-#328 -0.004 to -0.123 ns). b_wdata
    // changes only with a write, as the copy did.
    reg [24:0] b_raddr = 0;
    reg [3:0] b_hw = 0;
    reg [127:0] b_wdata = 0;              // a block write's 4 words (single writes: word 0)
    reg blk = 0, half = 0;                 // a block access, and its second 16 bytes
    reg b_adv = 0;                         // block write: the second half starts a clock after the first's done
    reg [2:0] coll = 0;                    // block write: words still to take for this half
    reg [15:0] b_ben = 0;
    reg [2:0] out_n = 0;                     // words left to hand out
    reg [1:0] out_k = 0;
    reg done_t = 0, done_seen = 0;
    // the read data is the pair's own (rsp_rdata, final before the done_t
    // flip), read here from the clk_sys edge after the one that sees the
    // flip (out_n), a two-cycle path (build_ds.sh); no copy is kept
    always @(posedge clk_sys) begin
        s_ack <= 0; s_rvalid <= 0; s_wnext <= 0;
        if (reset) begin busy <= 0; out_n <= 0; done_seen <= done_t; blk <= 0; coll <= 0; b_adv <= 0; end
        else begin
            if (!busy && s_req && !s_ack && out_n == 0 && !blk && s_n8) begin
                // a block: reads start at once (acked now, as word reads are);
                // writes first take their first 4 words
                blk <= 1; half <= 0; b_write <= s_we;
                b_raddr <= {2'b00, 1'b0, s_addr[20:3], 3'b000, 1'b0};
                b_hw <= 4'd8; b_ben <= 16'hFFFF;
                if (s_we) begin coll <= 3'd4; s_wnext <= 1; end
                else begin busy <= 1; s_ack <= 1; req_t <= !req_t; end
            end else if (!busy && s_req && !s_ack && out_n == 0 && !blk) begin
                busy <= 1; s_ack <= 1; req_t <= !req_t;
                b_write <= s_we;
                if (s_we) b_wdata[31:0] <= s_wdata;
                // a write: one word, halfwords 2w and 2w+1; a read: 16 bytes
                // from the quad's first word
                b_raddr <= s_we ? {2'b00, 1'b0, s_addr[20:0], 1'b0} : {2'b00, 1'b0, s_addr[20:2], 2'b00, 1'b0};
                b_hw <= s_we ? 4'd2 : 4'd8;
                b_ben <= s_we ? {12'd0, s_be} : 16'hFFFF;
            end
            // block write: one word per s_wnext; after 4, that half goes out
            if (blk && coll != 0 && s_wnext) begin
                b_wdata[(3'd4 - coll) * 32 +: 32] <= s_wdata;
                coll <= coll - 1'b1;
                if (coll != 3'd1) s_wnext <= 1;
                else begin
                    busy <= 1; req_t <= !req_t;
                    if (half) s_ack <= 1;                    // the eighth word is taken
                end
            end
            if (busy && done_t != done_seen) begin
                done_seen <= done_t; busy <= 0;
                if (!b_write) begin out_n <= 3'd4; out_k <= 2'd0; end
                if (blk && b_write) begin
                    if (!half) begin
                        // (the second half starts on the next clock, b_adv: the
                        // first half's done_t crossing reaches only b_adv, not the
                        // 25-bit add, half and coll: #578/#591 done_t -> b_raddr
                        // -0.31/-1.65 ns, coll/half -0.28. A block write's second
                        // half is one clk_sys later; no client writes blocks yet)
                        b_adv <= 1;
                    end else blk <= 0;
                end
            end
            if (b_adv) begin half <= 1; b_raddr <= b_raddr + 25'd8; coll <= 3'd4; s_wnext <= 1; b_adv <= 0; end
            if (out_n != 0) begin
                s_rvalid <= 1; s_rdata <= rsp_rdata[out_k*32 +: 32];
                out_k <= out_k + 1'b1; out_n <= out_n - 1'b1;
                // block read: the second 16 bytes once the first are handed out
                if (out_n == 3'd1 && blk) begin
                    if (!half) begin half <= 1; b_raddr <= b_raddr + 25'd8; busy <= 1; req_t <= !req_t; end
                    else blk <= 0;
                end
            end
        end
    end

    assign req_addr = b_raddr;
    assign req_halfwords = b_hw;
    assign req_wdata = blk ? b_wdata : {96'd0, b_wdata[31:0]};
    assign req_byte_en = b_ben;

    // ---- mem side
    reg req_seen = 0, m_busy = 0;
    always @(posedge clk_mem) begin
        if (req_valid && req_ready) req_valid <= 0;
        // req_seen follows req_t while idle: the same value as loading it only
        // when they differ, but req_t reaches req_seen's D directly instead
        // of through the compare into its enable (#639 req_t -> req_seen
        // -0.104 ns on the clk_sys -> clk_mem edge pair, 4.97 ns)
        if (!m_busy) req_seen <= req_t;
        if (!m_busy && req_t != req_seen) begin
            m_busy <= 1; req_valid <= 1;
            req_write <= b_write;
        end
        if (m_busy && rsp_valid) begin
            m_busy <= 0; done_t <= !done_t;
        end
    end
endmodule
`default_nettype wire

// The DS core's VRAM port onto an nds_x2b: single words pass through; a
// 32-byte block read becomes two quad reads (acknowledged to the core with
// the first; its eight words follow in order).
module nds_vm_split #(
    parameter [23:0] BASE_W = 24'h0,
    parameter bit OCT = 0                    // the client reads 32 bytes per quad request (nds_sdram OCT)
) (
    input wire clk, reset,
    input wire vm_req, vm_we, vm_blk,
    input wire [20:2] vm_addr,
    input wire [3:0] vm_be,
    input wire [31:0] vm_wdata,
    output wire vm_ack, vm_rvalid,
    output wire [31:0] vm_rdata,
    output wire s_req, s_we, s_quad,
    output wire [23:0] s_addr,
    output wire [31:0] s_wdata,
    output wire [3:0] s_be,
    input wire s_ack, s_rvalid,
    input wire [31:0] s_rdata
);
    reg second = 0;                          // block: the second quad is being asked for
    always @(posedge clk)
        if (reset) second <= 0;
        else if (s_ack && vm_blk && !OCT) second <= !second;
    assign s_req   = vm_req || second;
    assign s_we    = vm_we && !vm_blk;
    assign s_quad  = vm_blk;
    assign s_addr  = BASE_W + (vm_blk ? {5'd0, vm_addr[20:5], second, 2'b00} : {5'd0, vm_addr});
    assign s_wdata = vm_wdata;
    assign s_be    = vm_be;
    assign vm_ack  = s_ack && !second;
    assign vm_rvalid = s_rvalid;
    assign vm_rdata  = s_rdata;
endmodule

// The DS core's boot-image port (word reads, answered with the data) onto
// an nds_x2b.
module nds_sr_port (
    input wire clk, reset,
    input wire sr_req,
    input wire [1:0] sr_sel,
    input wire [19:2] sr_addr,
    output wire sr_ack,
    output wire [31:0] sr_rdata,
    output wire s_req,
    output wire [23:0] s_addr,
    input wire s_ack, s_rvalid,
    input wire [31:0] s_rdata
);
    reg pend = 0;
    always @(posedge clk)
        if (reset) pend <= 0;
        else if (s_ack) pend <= 1;
        else if (s_rvalid) pend <= 0;
    assign s_req    = sr_req && !pend;
    // BIOS9, BIOS7, firmware at SDRAM bytes 0x0800000 + sel * 1 MiB (Phase 1 layout)
    assign s_addr   = 24'h20_0000 + {4'd0, sr_sel, sr_addr};
    assign sr_ack   = s_rvalid;
    assign sr_rdata = s_rdata;
endmodule

`ifndef ALTERA_RESERVED_QIS
// Simulation only: line-ring traffic (core_top_ds RING_GEN) to run the ring's
// SDRAM ports (block writes through the write chain, block reads on bus port
// 6) before the 3D line ring uses them. Random 32-byte block writes and
// read-backs over byte 0x200000-0x20BFFF (48 KiB, free SDRAM), each read
// word checked against the block's last written tag. A block is read only
// once wdrained has been seen high after its write (the write chain and the
// read port are separate paths): this also checks wdrained. A random gap
// (0..+ringgen_gap clocks) between blocks; +ringgen turns it on.
module nds_ring_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,                  // the DS running (go): the Pocket's boot clears memory before it
    input  wire        wdrained,            // every write so far has been taken by the SDRAM controller
    output reg         w_req = 0,
    output wire [23:0] w_addr,
    output wire [31:0] w_data,
    input  wire        w_ack,
    output reg         r_req = 0,
    output wire [23:0] r_addr,
    input  wire        r_ack,
    input  wire        r_valid,
    input  wire [31:0] r_data
);
    bit on = 0;
    int gap_max = 200, n_wr = 0, n_rd = 0, bad = 0, k = 0, gap = 100, st = 0;
    longint cyc = 0;
    reg [7:0] tag [0:1535];
    bit       landed [0:1535];              // written, and wdrained seen since
    bit       val [0:1535];
    reg [10:0] blk = 0;
    reg [7:0]  t = 0;
    function automatic [31:0] pat(input [10:0] b, input [7:0] tg, input integer w);
        pat = {b, tg, w[3:0], 9'h15A} ^ {tg, 2'b10, b, 11'h2C7};
    endfunction
    initial begin
        on = $test$plusargs("ringgen");
        void'($value$plusargs("ringgen_gap=%d", gap_max));
        for (int i = 0; i < 1536; i++) begin val[i] = 0; tag[i] = 0; landed[i] = 0; end
    end
    final if (on) $display("ringgen: %0d block writes, %0d block reads, %0d errors", n_wr, n_rd, bad);
    assign w_addr = 24'h08_0000 + {10'd0, blk, 3'd0} + k;      // word address (byte 0x200000 + blk * 32)
    assign w_data = pat(blk, t, k);
    assign r_addr = 24'h08_0000 + {10'd0, blk, 3'd0};
    always @(posedge clk) begin
        cyc = cyc + 1;
        // (wdrained lags the writes: a block counts as landed only once it reads
        // high after the block's last word went in)
        if (wdrained && st != 1) for (int i = 0; i < 1536; i++) if (val[i]) landed[i] = 1;
        if (rst || !on || (!en && st == 0)) begin w_req <= 0; r_req <= 0; st = 0; end
        else case (st)
            0: if (gap > 0) gap <= gap - 1;
               else begin
                   reg [10:0] b;
                   b = 11'($urandom % 1536);
                   blk <= b; k = 0;
                   if (!val[b] || !landed[b] || $urandom % 2) begin
                       t <= tag[b] + 8'd1; w_req <= 1; st = 1;
                   end else begin r_req <= 1; st = 2; end
               end
            1: if (w_ack) begin                              // a word taken
                   if (k == 7) begin
                       w_req <= 0; tag[blk] = t; val[blk] = 1; landed[blk] = 0; n_wr++;
                       st = 0; gap <= $urandom % (gap_max + 1);
                   end
                   k = k + 1;
               end
            2: if (r_ack) begin r_req <= 0; k = 0; st = 3; end
            default: if (r_valid) begin
                if (r_data !== pat(blk, tag[blk], k)) begin
                    bad++;
                    if (bad < 8) $display("ringgen: block %0d word %0d: %h, expected %h", blk, k, r_data, pat(blk, tag[blk], k));
                end
                k = k + 1;
                if (k == 8) begin n_rd++; st = 0; gap <= $urandom % (gap_max + 1); end
            end
        endcase
    end
endmodule
`endif
