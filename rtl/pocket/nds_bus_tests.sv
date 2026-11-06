// SPDX-License-Identifier: MIT
// clk_bus blocks of the Phase 1 test core (docs/phase1-foundation.md):
//   nds_fifo_drain   bridge-write FIFO into SDRAM; markers to the ROM cache
//   nds_load_check   reads BIOS9/BIOS7/firmware back from SDRAM, CRC-32
//   nds_cart_test    pass B: the whole ROM through the cache, scrambled order
//   nds_sdram_test   pattern test of an SDRAM region, looping
// Each uses one nds_sdram client port (see nds_sdram.sv).
`default_nettype none

module nds_fifo_drain (
    input wire clk,
    input wire f_valid,
    input wire [56:0] f_data,               // {marker, word address, data}
    output wire f_rd,
    output reg mk_valid = 0,
    output reg [2:0] mk_err = 0,
    output wire m_valid,
    output wire [23:0] m_addr,
    output wire [31:0] m_wdata,
    input wire m_ready
);
    // the FIFO's head holds the request until it's taken (no copy of it here): pop a marker at once, a data word
    // when it's accepted
    assign m_valid = f_valid && !f_data[56];
    assign m_addr = f_data[55:32];
    assign m_wdata = f_data[31:0];
    assign f_rd = f_valid && (f_data[56] || m_ready);
    always @(posedge clk) begin
        mk_valid <= f_valid && f_data[56];
        if (f_valid && f_data[56]) mk_err <= f_data[2:0];
    end
endmodule

// CRC-32 of each loaded region read back from SDRAM, against the CRC the APF
// side computed while loading. state per region: 0 absent (size 0 or over
// 1 MiB), 1 checking, 2 equal, 3 different.
module nds_load_check #(parameter [23:0] SYS_BASE_W = 24'h20_0000) (
    input wire clk, reset,
    input wire start,
    input wire [31:0] size9, size7, sizefw,
    input wire [31:0] crc9, crc7, crcfw,    // load CRCs, running (not inverted)
    output reg [5:0] state = 0,             // {fw, bios7, bios9}
    output reg [31:0] rb9 = 0, rb7 = 0, rbfw = 0,
    output reg m_valid = 0,
    output reg [23:0] m_addr = 0,
    input wire m_ready,
    input wire m_rvalid,
    input wire [31:0] m_rdata
);
    import nds_sig_pkg::*;
    reg [1:0] region = 0;
    reg [31:0] pos = 0, crc = 0;
    reg running = 0, issued = 0;
    reg [1:0] got = 0;
    wire [31:0] size = region == 0 ? size9 : region == 1 ? size7 : sizefw;
    wire [31:0] want = region == 0 ? crc9 : region == 1 ? crc7 : crcfw;
    wire [31:0] rpos = pos + {28'b0, got, 2'b0};
    wire [31:0] rleft = size - rpos;
    wire [2:0] rbytes = rleft >= 4 ? 3'd4 : rleft[2:0];
    always @(posedge clk) begin
        if (m_ready) m_valid <= 0;
        if (reset) begin state <= 0; running <= 0; region <= 0; m_valid <= 0; issued <= 0; end
        else if (!running) begin
            if (start && state == 0 && region == 0) begin running <= 1; pos <= 0; crc <= 32'hFFFF_FFFF; got <= 0; end
        end else if (size == 0 || size > 32'h0010_0000) begin
            // absent: next region
            state[region*2 +: 2] <= 2'd0;
            pos <= 0; crc <= 32'hFFFF_FFFF;
            if (region == 2) running <= 0; else region <= region + 1'b1;
            if (region == 2) region <= 3;
        end else if (pos >= size) begin
            state[region*2 +: 2] <= crc == want ? 2'd2 : 2'd3;
            case (region)
                2'd0: rb9 <= ~crc;
                2'd1: rb7 <= ~crc;
                default: rbfw <= ~crc;
            endcase
            pos <= 0; crc <= 32'hFFFF_FFFF;
            if (region == 2) begin running <= 0; region <= 3; end else region <= region + 1'b1;
        end else begin
            state[region*2 +: 2] <= 2'd1;
            if (!issued) begin
                m_valid <= 1; m_addr <= SYS_BASE_W + {2'b0, region, 18'b0} + {4'b0, pos[21:2]};
                issued <= 1; got <= 0;
            end else if (m_rvalid) begin
                if (rpos < size) crc <= crc32_word(crc, m_rdata, rbytes);
                got <= got + 1'b1;
                if (got == 2'd3) begin issued <= 0; pos <= pos + 32'd16; end
            end
        end
    end
endmodule

// Pass B. 64 KiB groups are visited in the order g_i = (i * K) mod P for an
// odd K (P = the power of two at or above the group count; groups past the
// end are skipped); inside a group its 128 512-byte chunks go in bit-reversed
// order; each chunk is 32 quad reads. Every word inside the file goes into
// the signature at its position (bytes past the end as zero), as in pass A.
// After each group the header quad at 0x40 is read again and not summed: a
// hot block, as a game re-reading its FAT, so the replacement policy shows in
// which blocks get fetched again.
module nds_cart_test (
    input wire clk, reset,
    input wire start,
    input wire [31:0] rom_size,
    input wire tick_ms,                     // one pulse per millisecond
    output reg [1:0] state = 0,             // 0 waiting, 1 running, 2 done
    output wire [63:0] sig,
    output reg [31:0] words = 0, quads = 0,
    output reg [31:0] ms = 0,               // pass B time (#55's bus-clock count wrapped at 128 s)
    output reg [31:0] bytes_done = 0,
    output reg stat_clear = 0,
    output reg c_valid = 0,
    output reg [31:0] c_addr = 0,
    input wire c_ready,
    input wire r_valid,
    input wire [31:0] r_data
);
    localparam [31:0] K = 32'h9E37_79B1;
    reg [31:0] groups = 0, gmask = 0, gi = 0, g = 0, n = 0;
    reg [6:0] chunk = 0;
    reg [4:0] qd = 0;
    reg [1:0] w = 0;
    reg [2:0] s = 0;
    reg hot = 0;
    reg [31:0] qaddr = 0;
    wire [6:0] chunk_rev = {chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6]};
    wire [31:0] base = {g[15:0], chunk_rev, 9'b0};
    wire [31:0] wpos = qaddr + {28'b0, w, 2'b0};
    wire [31:0] wleft = rom_size - wpos;
    wire [31:0] wmask = wleft >= 4 ? 32'hFFFF_FFFF : (32'h1 << {wleft[1:0], 3'b0}) - 1'b1;
    nds_sig sig_b (.clk(clk), .clear(reset || stat_clear), .valid(r_valid && wpos < rom_size && state == 1 && !hot),
                   .index({2'b0, wpos[31:2]}), .data(r_data & wmask), .sig(sig));
    localparam [2:0] S_MASK = 0, S_GROUP = 1, S_CHUNK = 2, S_REQ = 3, S_DATA = 4, S_NEXT = 5, S_HOT = 6;
    always @(posedge clk) begin
        stat_clear <= 0;
        if (reset) begin state <= 0; c_valid <= 0; end
        else case (state)
            0: if (start) begin
                state <= 1; stat_clear <= 1; words <= 0; quads <= 0; ms <= 0; bytes_done <= 0;
                groups <= (rom_size + 32'hFFFF) >> 16; gmask <= 0; gi <= 0; g <= 0; n <= 0; s <= S_MASK;
            end
            1: begin
                if (tick_ms) ms <= ms + 1'b1;
                case (s)
                    S_MASK: if (gmask + 1'b1 < groups) gmask <= {gmask[30:0], 1'b1}; else s <= S_GROUP;
                    S_GROUP: begin
                        if (n > gmask) begin state <= 2; end
                        else if (g >= groups) begin n <= n + 1'b1; g <= (g + K) & gmask; end
                        else begin chunk <= 0; s <= S_CHUNK; end
                    end
                    S_CHUNK: begin
                        if (base >= rom_size) s <= S_NEXT;
                        else begin qaddr <= base; qd <= 0; s <= S_REQ; end
                    end
                    S_REQ: begin
                        if (qaddr >= rom_size) s <= S_NEXT;
                        else begin c_valid <= 1; c_addr <= qaddr; w <= 0; s <= S_DATA; end
                    end
                    S_DATA: begin
                        if (c_ready) c_valid <= 0;
                        if (r_valid && hot) begin
                            w <= w + 1'b1;
                            if (w == 2'd3) begin hot <= 0; s <= S_GROUP; end
                        end else if (r_valid) begin
                            if (wpos < rom_size) words <= words + 1'b1;
                            w <= w + 1'b1;
                            if (w == 2'd3) begin
                                quads <= quads + 1'b1; bytes_done <= bytes_done + 32'd16;
                                qaddr <= qaddr + 32'd16; qd <= qd + 1'b1;
                                s <= qd == 5'd31 ? S_NEXT : S_REQ;
                            end
                        end
                    end
                    S_NEXT: begin
                        if (chunk == 7'd127) begin
                            n <= n + 1'b1; g <= (g + K) & gmask;
                            hot <= 1; c_valid <= 1; c_addr <= 32'h40; w <= 0; s <= S_DATA;
                        end
                        else begin chunk <= chunk + 1'b1; s <= S_CHUNK; end
                    end
                    default: s <= S_MASK;
                endcase
            end
            default: ;
        endcase
    end
endmodule

// SDRAM pattern test over words [BASE, BASE+WORDS), looping. Each pass: write
// every word (pattern mix(address, pass)), read it all back as quads, then
// rewrite one byte (lane = address bits [11:10]) of every 1,024th word and read
// that word back alone. errors counts bad words; the first is kept.
// state: 0 waiting, 1 running (no error yet), 2 at least one pass and no
// error, 3 an error seen.
module nds_sdram_test #(parameter [23:0] BASE = 24'h0, parameter [23:0] WORDS = 24'h20_0000) (
    input wire clk, reset, start,
    output reg [1:0] state = 0,
    output reg [31:0] passes = 0, errors = 0,
    output reg [31:0] fail_addr = 0, fail_exp = 0, fail_act = 0,
    output reg [31:0] wr_cycles = 0, rd_cycles = 0,
    output reg m_valid = 0, m_write = 0, m_quad = 0,
    output reg [23:0] m_addr = 0,
    output reg [31:0] m_wdata = 0,
    output reg [3:0] m_be = 0,
    input wire m_ready,
    input wire m_rvalid,
    input wire [31:0] m_rdata
);
    import nds_sig_pkg::*;
    localparam [1:0] P_WRITE = 0, P_READ = 1, P_LANE = 2;
    reg [1:0] phase = P_WRITE;
    reg [23:0] a = 0;
    reg [1:0] got = 0;
    reg busy = 0, lane_rd = 0;
    reg [31:0] t = 0;
    wire [23:0] ra = a + got;
    wire [31:0] pat = mix({8'b0, ra}, passes);
    wire [1:0] lane = a[11:10];
    wire [31:0] lane_byte = {4{~pat[7:0]}};
    wire [31:0] lane_mask = 32'hFF << {lane, 3'b0};
    wire [31:0] lane_exp = (pat & ~lane_mask) | (lane_byte & lane_mask);
    task automatic bad(input [31:0] exp, input [31:0] act);
        if (errors == 0) begin fail_addr <= {8'b0, BASE + ra}; fail_exp <= exp; fail_act <= act; end
        errors <= errors + 1'b1; state <= 2'd3;
    endtask
    always @(posedge clk) begin
        if (m_ready) m_valid <= 0;
        if (reset) begin state <= 0; m_valid <= 0; busy <= 0; phase <= P_WRITE; a <= 0; end
        else if (state == 0) begin if (start) begin state <= 1; t <= 0; end end
        else begin
            t <= t + 1'b1;
            case (phase)
                P_WRITE: if (!busy) begin
                    m_valid <= 1; m_write <= 1; m_quad <= 0; m_addr <= BASE + a; m_wdata <= pat; m_be <= 4'hF;
                    busy <= 1; got <= 0;
                end else if (m_ready) begin
                    busy <= 0;
                    if (a == WORDS - 1) begin a <= 0; phase <= P_READ; wr_cycles <= t; t <= 0; end
                    else a <= a + 1'b1;
                end
                P_READ: if (!busy) begin
                    m_valid <= 1; m_write <= 0; m_quad <= 1; m_addr <= BASE + a; busy <= 1; got <= 0;
                end else if (m_rvalid) begin
                    if (m_rdata != pat) bad(pat, m_rdata);
                    got <= got + 1'b1;
                    if (got == 2'd3) begin
                        busy <= 0;
                        if (a + 4 >= WORDS) begin a <= 0; phase <= P_LANE; rd_cycles <= t; t <= 0; end
                        else a <= a + 24'd4;
                    end
                end
                P_LANE: if (!busy) begin
                    m_valid <= 1; m_quad <= 0; m_addr <= BASE + a; busy <= 1; got <= 0;
                    if (!lane_rd) begin m_write <= 1; m_wdata <= lane_byte; m_be <= 4'b0001 << lane; end
                    else m_write <= 0;
                end else if (!lane_rd && m_ready) begin
                    busy <= 0; lane_rd <= 1;
                end else if (lane_rd && m_rvalid) begin
                    if (m_rdata != lane_exp) bad(lane_exp, m_rdata);
                    busy <= 0; lane_rd <= 0;
                    if (a + 24'd1024 >= WORDS) begin
                        a <= 0; phase <= P_WRITE; passes <= passes + 1'b1;
                        if (state == 1) state <= 2;
                    end else a <= a + 24'd1024;
                end
                default: phase <= P_WRITE;
            endcase
        end
    end
endmodule
`default_nettype wire
