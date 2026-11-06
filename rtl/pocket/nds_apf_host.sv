// SPDX-License-Identifier: MIT
// APF side of the Phase 1 shell, on clk_74a (docs/phase1-foundation.md).
//
// Data table: after all-complete, the ID/size pairs (slot k at words 2k, 2k+1,
// data.json order) are scanned once for the ROM (ID 1), BIOS9 (2), BIOS7 (3)
// and firmware (4), looked up by ID, not position. From then on the log slot's
// size is written into word 2*LOG_POS+1 so the Pocket saves the log on quit
// (as tools/sd-probe did on hardware).
//
// Start-up loads: the Pocket writes BIOS9, BIOS7 and the firmware (slots not
// deferred) to bridge 0x10000000, 0x10100000 and 0x10200000. Each word goes
// into the write FIFO for SDRAM byte 0x0800000 + region * 1 MiB + offset, and
// into a per-region CRC-32 (in arrival order; a write that does not follow
// the previous one of its region counts as a jump and voids that CRC).
//
// ROM tables (slot 5, the plugin's <game>.ndt, docs/pocket-plugin.md): bridge
// words at NDT_WIN + o go into the FIFO for SDRAM word NDT_BASE_W + o/4, so the
// file's 4 KiB header lands just below the ROM cache's table and the table
// on the table. At power-up one write of 0 to NDT_BASE_W (the magic) goes
// first through the FIFO, ahead of any slot data: a table from an earlier
// session is never taken for this one's (nds_cart_cache checks the magic).
//
// Save (docs/saves.md, SAVE_POS >= 0): the nonvolatile save slot (ID 10) at
// bridge SAVE_WIN + o (o < 1 MiB) goes into the FIFO for SDRAM word
// SAVE_BASE_W + o/4. The scan reads the loaded file's size (save_loaded, at
// most 1 MiB) and turns an exact chip size into a save type; the tables'
// header word 0x6C ({valid, type[2:0]}, from the plugin's database) is latched
// as it loads. save_info = {tables valid, tables type, size valid, size type}
// for the boot program. From then on the chip size of save_type (the type the
// boot program chose) is written into word 2*SAVE_POS+1, alternating with the
// log's, so the Pocket saves exactly the chip on quit (0 = none: no file).
//
// Cartridge fetches (from nds_cart_cache via nds_bundle_cdc): one APF
// target_dataslot_read of the ROM slot into the window FETCH_WIN. Bridge word
// at window offset o belongs to command block o/4096 and goes to SDRAM slot
// slot[o/4096] of the ROM cache. When the host reports done, a marker with
// the APF error code follows the data through the same FIFO, so the cache
// sees it only after every data word has been written.
//
// Pass A (PASS_A = 1, the Phase 1 test): before any fetch, the whole ROM is
// read in DIRECT_CHUNK commands
// into DIRECT_WIN, and every word is put into a CRC-32 (in file order) and
// the nds_sig signature at its file position. Bytes past the end of the file
// count as zero in the signature and not at all in the CRC. A command with an
// APF error is retried (up to 3 times) from a copy of the sums taken before it.
//
// Target commands: tgt_read is held from issue until done is seen low; done
// is trusted only after that (tools/sd-probe, "done trusted before it drops").
// The command's offset, bridge address and length are views, not registers
// (APF shell trim): of the fetch command as nds_bundle_cdc holds it (the ROM
// cache sends no new one before the last one's marker, which follows done),
// or of pass A's position. Both hold from tgt_read until done, so
// core_bridge_cmd_lean reads them directly.
`default_nettype none
module nds_apf_host #(
    parameter integer FC_RAM = 0,                   // 1: a block's slot from fc_slot (the ROM cache's MLAB), not fc_data
    parameter [31:0] FETCH_WIN = 32'h2000_0000,
    parameter [31:0] DIRECT_WIN = 32'h5000_0000,      // pass A (moved off slot 5's 0x30000000)
    parameter [31:0] NDT_WIN = 32'h3000_0000,         // slot 5, the ROM tables
    parameter [23:0] NDT_BASE_W = 24'h2F_FC00,        // = nds_cart_cache NDT_W (TABLE_W - 1024)
    parameter [31:0] DIRECT_CHUNK = 32'h0004_0000,
    parameter [23:0] CACHE_BASE_W = 24'h40_0000,     // SDRAM word address of slot 0
    parameter [23:0] SYS_BASE_W = 24'h20_0000,       // SDRAM word address of BIOS9
    parameter integer LOG_POS = 4,
    parameter integer SAVE_POS = -1,                // data.json position of the save slot; -1: none
    parameter [31:0] SAVE_WIN = 32'h6000_0000,
    parameter [23:0] SAVE_BASE_W = 24'h04_0000,     // SDRAM word address of save byte 0
    parameter [31:0] LOG_BYTES = 32'd256,
    parameter integer DIAG_POS = -1,                // data.json position of the NDSDiag log slot (docs/diag.md); -1: none
    parameter [31:0] DIAG_BYTES = 32'h0008_0000,
    parameter [31:0] MS_CLOCKS = 32'd74250,
    parameter integer PASS_A = 1                    // 0: no pass A (the DS core), fetches at once
) (
    input wire clk, reset,
    input wire allcomplete,
    input wire bridge_wr,
    input wire [31:0] bridge_addr, bridge_wr_data,
    // save
    input wire [2:0] save_type,                 // BOOTCTL[6:4], synchronised to clk
    output reg [20:0] save_loaded = 0,          // bytes of the loaded .sav (valid with sizes_valid)
    output wire [7:0] save_info,
    output reg [20:0] save_bytes = 0,           // the chip size of save_type (the size word's value)
    // APF data table, port A
    output wire [9:0] dt_addr,
    output wire dt_wren,
    output wire [31:0] dt_data,
    input wire [31:0] dt_q,
    // APF target command
    output reg tgt_read = 0,
    output wire [31:0] tgt_offset, tgt_bridge, tgt_length,
    input wire tgt_ack, tgt_done,
    input wire [2:0] tgt_err,
    // SDRAM write FIFO: {marker, word address, data}; a marker's data[2:0] is the APF error
    output reg f_wr = 0,
    output reg [56:0] f_data = 0,
    // fetch command from the cache: {length[14:0], offset[31:0], blocks[2:0], slot4..slot0[13:0]}
    input wire fc_recv,
    input wire [119:0] fc_data,
    input wire [13:0] fc_slot,                  // FC_RAM: the slot of block bridge_addr[14:12] (not fc_data's)
    // results
    output reg sizes_valid = 0,
    output reg [31:0] rom_size = 0, bios9_size = 0, bios7_size = 0, fw_size = 0,
    output reg [31:0] crc9 = 32'hFFFF_FFFF, crc7 = 32'hFFFF_FFFF, crcfw = 32'hFFFF_FFFF,  // running (not inverted)
    output reg [15:0] load_jumps = 0,
    output reg [31:0] load_words = 0,
    output reg [1:0] a_state = 0,               // 0 waiting, 1 running, 2 done, 3 failed
    output reg [31:0] a_crc = 32'hFFFF_FFFF,    // running (not inverted)
    output wire [63:0] a_sig,
    output reg [31:0] a_words = 0, a_ms = 0,
    output reg [15:0] a_cmds = 0, a_errors = 0, a_jumps = 0,
    output reg [15:0] f_cmds = 0, f_errors = 0,
    output reg [31:0] ms = 0                    // milliseconds since all-complete
);
    import nds_sig_pkg::*;

    // ---------------- millisecond clock ----------------
    reg [31:0] tick = 0;
    reg ticking = 0;
    always @(posedge clk) begin
        if (allcomplete) ticking <= 1;
        if (reset) begin tick <= 0; ms <= 0; ticking <= 0; end
        else if (ticking) begin
            if (tick == MS_CLOCKS - 1) begin tick <= 0; ms <= ms + 1'b1; end
            else tick <= tick + 1'b1;
        end
    end

    // ---------------- data table ----------------
    reg [4:0] dt_entry = 0;
    reg dt_size = 0, scanning = 0, scanned = 0;
    reg [1:0] dt_wait = 0;
    reg [4:0] dt_k = 0;                         // the entry's ID: 1, 2, 3, 4, 10
    reg [1:0] dt_ph = 0;                        // after the scan, in turn: 0 the log's size word, 1 the save's, 2 the diag log's
    always @(posedge clk) begin
        dt_ph <= dt_ph == 2'd0 ? (SAVE_POS >= 0 ? 2'd1 : DIAG_POS >= 0 ? 2'd2 : 2'd0) :
                 dt_ph == 2'd1 && DIAG_POS >= 0 ? 2'd2 : 2'd0;
        case (save_type)
            3'd1: save_bytes <= 21'h00200;
            3'd2: save_bytes <= 21'h02000;
            3'd3: save_bytes <= 21'h10000;
            3'd4: save_bytes <= 21'h20000;
            3'd5: save_bytes <= 21'h40000;
            3'd6: save_bytes <= 21'h80000;
            3'd7: save_bytes <= 21'h100000;
            default: save_bytes <= 0;
        endcase
    end
    assign dt_addr = scanning ? {4'b0, dt_entry, dt_size} : dt_ph == 2'd1 ? 10'(2 * SAVE_POS + 1) :
                     dt_ph == 2'd2 ? 10'(2 * DIAG_POS + 1) : 10'(2 * LOG_POS + 1);
    assign dt_wren = scanned;
    assign dt_data = dt_ph == 2'd1 ? {11'b0, save_bytes} : dt_ph == 2'd2 ? DIAG_BYTES : LOG_BYTES;
    reg [3:0] size_type = 0;                    // {valid, type} from the loaded file's size
    reg [3:0] ndt_type = 0;                     // {valid, type} from the tables' header word 0x6C
    assign save_info = {ndt_type, size_type};
    always @(posedge clk) begin
        if (reset) begin scanning <= 0; scanned <= 0; sizes_valid <= 0; save_loaded <= 0; size_type <= 0; end
        else if (!scanning && !scanned && allcomplete) begin
            scanning <= 1; dt_entry <= 0; dt_size <= 0; dt_wait <= 0;
        end else if (scanning) begin
            if (dt_wait != 2'd3) dt_wait <= dt_wait + 1'b1;
            else begin
                dt_wait <= 0;
                if (!dt_size) begin dt_k <= {dt_q[15:0] == 16'd10, dt_q[15:0] == 16'd4, dt_q[15:0] == 16'd3, dt_q[15:0] == 16'd2, dt_q[15:0] == 16'd1}; dt_size <= 1; end
                else begin
                    if (dt_k[0]) rom_size <= dt_q;
                    if (dt_k[1]) bios9_size <= dt_q;
                    if (dt_k[2]) bios7_size <= dt_q;
                    if (dt_k[3]) fw_size <= dt_q;
                    if (dt_k[4] && SAVE_POS >= 0) begin
                            save_loaded <= dt_q > 32'h10_0000 ? 21'h10_0000 : dt_q[20:0];
                            case (dt_q)
                                32'h0000_0200: size_type <= 4'h9;
                                32'h0000_2000: size_type <= 4'hA;
                                32'h0001_0000: size_type <= 4'hB;
                                32'h0002_0000: size_type <= 4'hC;
                                32'h0004_0000: size_type <= 4'hD;
                                32'h0008_0000: size_type <= 4'hE;
                                32'h0010_0000: size_type <= 4'hF;
                                default: size_type <= 0;
                            endcase
                    end
                    dt_size <= 0;
                    if (dt_entry == 5'd15) begin scanning <= 0; scanned <= 1; sizes_valid <= 1; end
                    else dt_entry <= dt_entry + 1'b1;
                end
            end
        end
    end

    // ---------------- target commands ----------------
    localparam [2:0] T_IDLE = 0, T_RUN = 1, T_MARK = 2, T_DONE = 3;
    reg [2:0] tst = T_IDLE;
    reg low_seen = 0, direct = 0;
    reg [2:0] err = 0;
    // pass A
    reg a_pending = 0;
    reg [31:0] a_off = 0, a_next = 0;
    reg [1:0] a_tries = 0;
    reg [31:0] a_crc_save = 0, a_next_save = 0, a_words_save = 0;
    reg [63:0] a_sig_save = 0;
    reg [31:0] a_t0 = 0;
    // fetch: fc_data as nds_bundle_cdc holds it until the next command
    reg fc_pending = 0;
    wire [119:0] fc = fc_data;
    // pass A's length is a register loaded at issue (as a view of a_off it made
    // a 15 ns path into T_DONE's end-of-file test, #285); without pass A it is
    // never loaded and drops out
    reg [31:0] a_len = 0;
    assign tgt_offset = direct ? a_off : fc[104:73];
    assign tgt_bridge = direct ? DIRECT_WIN : FETCH_WIN;
    assign tgt_length = direct ? a_len : {17'b0, fc[119:105]};
    wire [2:0] fc_blocks = fc[72:70];
    reg restore = 0;
    reg mark_wr = 0;
    wire [63:0] sig_now;
    always @(posedge clk) begin
        if (fc_recv) fc_pending <= 1;
        mark_wr <= 0;
        if (reset) begin
            tst <= T_IDLE; tgt_read <= 0; a_state <= 0; a_pending <= 0; fc_pending <= 0;
        end else case (tst)
            T_IDLE: begin
                if (sizes_valid && a_state == 0) begin
                    if (rom_size == 0) a_state <= 3;
                    else if (PASS_A == 0) a_state <= 2;
                    else begin a_state <= 1; a_off <= 0; a_tries <= 0; a_t0 <= ms; a_pending <= 1; end
                end else if (a_pending) begin
                    direct <= 1;
                    a_len <= rom_size - a_off > DIRECT_CHUNK ? DIRECT_CHUNK : rom_size - a_off;
                    a_crc_save <= a_crc; a_sig_save <= sig_now; a_next_save <= a_next; a_words_save <= a_words;
                    tgt_read <= 1; low_seen <= 0; tst <= T_RUN;
                end else if (fc_pending && a_state[1]) begin
                    direct <= 0; fc_pending <= 0;
                    tgt_read <= 1; low_seen <= 0; tst <= T_RUN;
                end
            end
            T_RUN: begin
                if (!tgt_done) begin low_seen <= 1; tgt_read <= 0; end
                if (low_seen && tgt_done) begin
                    err <= tgt_err;
                    tst <= direct ? T_DONE : T_MARK;
                end
            end
            T_MARK: if (!bridge_wr) begin
                // after the command's last data word (FIFO order), in a clock
                // with no bridge write to share the FIFO port with
                mark_wr <= 1;
                f_cmds <= f_cmds + 1'b1;
                if (err != 0) f_errors <= f_errors + 1'b1;
                tst <= T_IDLE;
            end
            T_DONE: begin
                a_cmds <= a_cmds + 1'b1;
                tst <= T_IDLE;
                if (err != 0) begin
                    a_errors <= a_errors + 1'b1;
                    restore <= 1;
                    if (a_tries == 2'd3) begin a_state <= 3; a_pending <= 0; end
                    a_tries <= a_tries + 1'b1;
                end else begin
                    a_tries <= 0;
                    if (a_off + tgt_length >= rom_size) begin a_pending <= 0; a_state <= 2; a_ms <= ms - a_t0; end
                    else a_off <= a_off + tgt_length;
                end
            end
            default: tst <= T_IDLE;
        endcase
        if (tst != T_DONE) restore <= 0;
    end

    // ---------------- bridge writes ----------------
    // (window 3, 0x10300000: the boot ROM image, ID 12, for nds_top BOOT_SRAM; no CRC)
    wire in_load = bridge_addr[31:22] == 10'b0001_0000_00;
    wire in_fetch = tst == T_RUN && !direct && bridge_addr[31:16] == FETCH_WIN[31:16]
                    && bridge_addr[15:0] < tgt_length[15:0] && bridge_addr[14:12] < fc_blocks;
    wire in_direct = tst == T_RUN && direct && bridge_addr[31:18] == DIRECT_WIN[31:18];
    reg [13:0] fslot_m;
    always @* case (bridge_addr[14:12])
        3'd0: fslot_m = fc[13:0];
        3'd1: fslot_m = fc[27:14];
        3'd2: fslot_m = fc[41:28];
        3'd3: fslot_m = fc[55:42];
        default: fslot_m = fc[69:56];
    endcase
    wire [13:0] fslot = FC_RAM != 0 ? fc_slot : fslot_m;
    (* ramstyle = "logic" *) reg [19:0] load_next [0:2];
    wire in_ndt = bridge_addr[31:20] == NDT_WIN[31:20];
    wire in_save = SAVE_POS >= 0 && bridge_addr[31:20] == SAVE_WIN[31:20];
    reg clr_pend = 1;                       // the power-up write of 0 to the tables' magic
    always @(posedge clk) begin
        f_wr <= 0;
        if (reset) clr_pend <= 1;
        else if (clr_pend && !bridge_wr && !mark_wr) begin
            clr_pend <= 0; f_wr <= 1; f_data <= {1'b0, NDT_BASE_W, 32'h0};
        end
        // explicit: on the Pocket the declarations' 0xFFFFFFFF did not apply (#55)
        if (reset) begin crc9 <= 32'hFFFF_FFFF; crc7 <= 32'hFFFF_FFFF; crcfw <= 32'hFFFF_FFFF; load_words <= 0; load_jumps <= 0; end
        if (mark_wr) begin f_wr <= 1; f_data <= {1'b1, 24'b0, 29'b0, err}; end
        if (bridge_wr && in_load) begin
            f_wr <= 1;
            f_data <= {1'b0, SYS_BASE_W + {2'b0, bridge_addr[21:20], 18'b0} + {4'b0, bridge_addr[19:2]}, bridge_wr_data};
            load_words <= load_words + 1'b1;
            if (bridge_addr[19:0] != load_next[bridge_addr[21:20]]) load_jumps <= load_jumps + 1'b1;
            load_next[bridge_addr[21:20]] <= bridge_addr[19:0] + 20'd4;
            case (bridge_addr[21:20])
                2'd0: crc9 <= crc32_word(crc9, bridge_wr_data, 3'd4);
                2'd1: crc7 <= crc32_word(crc7, bridge_wr_data, 3'd4);
                2'd2: crcfw <= crc32_word(crcfw, bridge_wr_data, 3'd4);
                default: ;
            endcase
        end
        if (bridge_wr && in_ndt) begin
            f_wr <= 1;
            f_data <= {1'b0, NDT_BASE_W + {6'b0, bridge_addr[19:2]}, bridge_wr_data};
        end
        if (reset) ndt_type <= 0;
        else if (bridge_wr && in_ndt && bridge_addr[19:0] == 20'h6C) ndt_type <= {bridge_wr_data[31], bridge_wr_data[2:0]};
        if (bridge_wr && in_save) begin
            f_wr <= 1;
            f_data <= {1'b0, SAVE_BASE_W + {6'b0, bridge_addr[19:2]}, bridge_wr_data};
        end
        if (bridge_wr && in_fetch) begin
            f_wr <= 1;
            f_data <= {1'b0, CACHE_BASE_W + {fslot, 10'b0} + {14'b0, bridge_addr[11:2]}, bridge_wr_data};
        end
    end

    // pass A sums: four stages per bridge word (the host's words are far
    // apart): window offset, file position, bytes left, then the CRC-32 (four
    // fixed-length trees, picked by the bytes in the file) and the signature.
    reg p0_v = 0, p1_v = 0, p2_v = 0;
    reg [17:0] p0_off = 0;
    reg [31:0] p0_d = 0, p1_d = 0, p2_d = 0, p1_pos = 0, p2_pos = 0, p2_left = 0;
    always @(posedge clk) begin
        p0_v <= bridge_wr && in_direct; p0_off <= bridge_addr[17:0]; p0_d <= bridge_wr_data;
        p1_v <= p0_v; p1_pos <= tgt_offset + {14'b0, p0_off}; p1_d <= p0_d;
        p2_v <= p1_v && p1_pos < rom_size; p2_pos <= p1_pos; p2_left <= rom_size - p1_pos; p2_d <= p1_d;
    end
    wire [31:0] a_pos = p2_pos;
    wire [2:0] a_bytes = p2_left >= 4 ? 3'd4 : p2_left[2:0];
    wire [31:0] a_mask = a_bytes == 3'd4 ? 32'hFFFF_FFFF : a_bytes == 3'd3 ? 32'h00FF_FFFF
                       : a_bytes == 3'd2 ? 32'h0000_FFFF : 32'h0000_00FF;
    wire a_take = p2_v;
    reg sig_v = 0;
    reg [31:0] sig_i = 0, sig_d = 0;
    always @(posedge clk) begin
        sig_v <= a_take;
        sig_i <= {2'b0, a_pos[31:2]};
        sig_d <= p2_d & a_mask;
        if (reset) begin
            a_crc <= 32'hFFFF_FFFF; a_next <= 0; a_words <= 0; a_jumps <= 0;
        end else if (restore) begin
            a_crc <= a_crc_save; a_next <= a_next_save; a_words <= a_words_save;
        end else if (a_take) begin
            a_words <= a_words + 1'b1;
            if (a_pos != a_next) a_jumps <= a_jumps + 1'b1;
            a_next <= a_pos + 32'd4;
            case (a_bytes)
                3'd4: a_crc <= crc32_word(a_crc, p2_d, 3'd4);
                3'd3: a_crc <= crc32_word(a_crc, p2_d, 3'd3);
                3'd2: a_crc <= crc32_word(a_crc, p2_d, 3'd2);
                default: a_crc <= crc32_word(a_crc, p2_d, 3'd1);
            endcase
        end
    end
    // signature with restore: sig_base holds the value to roll back to
    reg [63:0] sig_base = 0;
    wire [63:0] sig_acc;
    nds_sig sig_a (.clk(clk), .clear(reset || restore), .valid(sig_v), .index(sig_i), .data(sig_d), .sig(sig_acc));
    always @(posedge clk) if (reset) sig_base <= 0; else if (restore) sig_base <= a_sig_save;
    // sig_now = sig_base combined with the accumulator since the last restore
    assign sig_now = {sig_base[63:32] ^ sig_acc[63:32], sig_base[31:0] + sig_acc[31:0]};
    assign a_sig = sig_now;
endmodule
`default_nettype wire
