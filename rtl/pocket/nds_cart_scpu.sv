// SPDX-License-Identifier: MIT
// SDRAM ROM cache over APF target_dataslot_read with its policy in firmware
// (core_top_ds SHELL_CPU = 1; the same interface, SDRAM layout and policy as
// nds_cart_cache.sv, whose header documents them). Runs on clk_bus.
//
// Hardware keeps the client's path: a quad read looks its block up in the
// table (or reuses the last block), sets the slot's reference bit and reads
// the four words, as nds_cart_cache does, clock for clock on a hit. A block
// that is not cached raises `miss` and waits; the firmware fetches it and
// clears `miss`, and the lookup runs again.
//
// The firmware (sw/scpu/cache.c) runs on SERV (rtl/serv, ISC; bit-serial
// RV32I) and does everything else: the start-up (the plugin's table header,
// clearing the table, owners and reference bits), the miss run (read-ahead
// fields), CLOCK replacement, evictions, the APF commands with their retries,
// and the prefetch in the background, per stream (up to 4, woken by the new-block event, write 5 bit 29). SERV's code and data are
// SDRAM words FW_W + 0.. (nds_boot.bin past the boot ROM's 8 KiB, ID 12, so
// they arrive with the boot ROM before the cache starts), read and written
// through this module's SDRAM port; the client has priority on the port.
// SERV only runs while it has work: an idle firmware reads the wait register,
// whose acknowledge waits for an event (a miss, the client reaching a
// prefetch trigger, a fetch marker).
//
// SERV's addresses: 0x00000000 + o: SDRAM word FW_W + o/4 (code, data, stack;
// 16 KiB); 0x40000000 + 4w: SDRAM word w; 0x80000000 + 4r: register r:
//   write 2    the command: [2:0] blocks, [20:3] first block (fc_data); slots with write 8-12
//   write 3    the command: [14:0] length (fc_data); bit 31: send it (and forget the last marker), bit 30: a background prefetch
//   write 4    reference bit: [13:0] slot, [16] value, [17] write (the read of it follows)
//   write 5    [29] new-block mode: every table lookup that hits (the client moved to another cached block) sets
//              'trigger seen'; read 2's last block is that block (or a later one). (Until 2026-11-07 also a one-block
//              prefetch trigger, [17:0] block, [31] armed, [30] due on reaching it; the stream firmware never armed it)
//   write 6    [0] ready, [1] fail, [2] miss done, [3] forget the last block, [4] trigger seen done,
//              [6] release the client, [7] a prefetch is due, [8] the prefetch has started, [9] the background
//              prefetch is finished
//   write 7    the miss is fetched into slot [13:0]: read it from there as the last block (nds_cart_cache's
//              L_DONE: no table read, no reference bit); write 6 bit 2 instead looks the block up again
//   write 8-12 the command's slot k-8: [13:0] (an MLAB the host reads without a clock, fc_slot at fc_sel; held as fc_data is)
//   read 0     {miss, trigger seen, marker, marker error, fc_busy, ref bit, last valid, held, due, in flight, controls
//              frame, the controls' 3 bits, block}
// The client is held at its next idle clock (no read waiting) when a prefetch is due and none is in flight,
// or when the one in flight has its marker: nds_cart_cache's FSM does that work there before the next read,
// so the firmware, which takes longer, does it while the client waits, and both send the same commands.
//   read 1     rom_size
//   read 2     {SLOTS[13:0], the last block [17:0]}
//   read 3     the same as read 0, acknowledged once miss, trigger seen or marker is set, or a controls frame waits
// The controls (nds_controls FW = 1, docs/space-ctl.md; its header has the registers): writes 0-1 (ctl_we0/1,
// the data on m_wdata), read 4 (ctl_r0; it takes the frame, ctl_take), read 0 bits 21:18 ({ctl_pend, ctl_st}),
// read 2 bits 31:18 once ready (ctl_set); ctl_pend is an event of read 3
`default_nettype none
module nds_cart_scpu #(
    parameter [23:0] TABLE_W = 24'h30_0000,
    parameter [23:0] CACHE_W = 24'h40_0000,
    parameter [23:0] FW_W = 24'h2C_0800,    // SDRAM byte 0xB02000: nds_boot.bin offset 8 KiB
    parameter integer SLOTS = 12288
) (
    input wire clk, reset,
    input wire start,                       // rom_size valid; level
    input wire [31:0] rom_size,
    output reg ready = 0,
    output reg fail = 0,
    input wire c_valid,
    input wire [31:0] c_addr,
    output reg c_ready = 0,
    output wire r_valid,                    // (the SDRAM port's word, which it holds until the next)
    output wire [31:0] r_data,
    output reg fc_send = 0,
    output wire [119:0] fc_data,            // {length, offset, blocks, 70'b0}: the slots are fc_slot's
    input wire [2:0] fc_sel,                // (the host's clock)
    output wire [13:0] fc_slot,
    input wire fc_busy,
    input wire mk_valid,
    input wire [2:0] mk_err,
    output reg m_valid = 0,
    output reg m_write = 0,
    output reg m_quad = 0,
    output reg [23:0] m_addr = 0,
    output wire [31:0] m_wdata,             // (SERV's write data: it holds it until the acknowledge)
    output reg [3:0] m_be = 0,
    input wire m_ready,
    input wire m_rvalid,
    input wire [31:0] m_rdata,
    input wire stat_clear,
    input wire tick_ms,
    output reg [31:0] st_lookups = 0,
    output reg [31:0] st_cmds = 0,
    output reg [31:0] st_blocks = 0,
    output reg [31:0] st_wait = 0,
    output wire dg_wait,
    output wire dg_cmd,
    output wire ctl_we0, ctl_we1, ctl_take,
    input wire ctl_pend,
    input wire [31:0] ctl_r0,
    input wire [2:0] ctl_st,
    input wire [13:0] ctl_set
);
    localparam integer SB = $clog2(SLOTS);
    localparam [5:0] TB = TABLE_W[23:18];

    // ---------------- SERV ----------------
    wire [31:0] ib_adr, db_adr, db_dat, sv_rdt;
    wire ib_cyc, db_cyc, db_we;
    wire [3:0] db_sel;
    reg sv_ack = 0, io_ack = 0, sv_fly = 0, sv_hold = 0;
    wire io = db_cyc && db_adr[31];
    serv_rf_top #(.RESET_PC(32'd0), .WITH_CSR(0), .RESET_STRATEGY("MINI")) cpu (
        .clk(clk), .i_rst(reset || !start), .i_timer_irq(1'b0),
        .o_ibus_adr(ib_adr), .o_ibus_cyc(ib_cyc), .i_ibus_rdt(sv_rdt), .i_ibus_ack(sv_ack && ib_cyc),
        .o_dbus_adr(db_adr), .o_dbus_dat(db_dat), .o_dbus_sel(db_sel), .o_dbus_we(db_we), .o_dbus_cyc(db_cyc),
        .i_dbus_rdt(sv_rdt), .i_dbus_ack((sv_ack || io_ack) && db_cyc),
        .o_ext_rs1(), .o_ext_rs2(), .o_ext_funct3(), .i_ext_rd(32'd0), .i_ext_ready(1'b0), .o_mdu_valid());
    // SERV's SDRAM access (one at a time; SERV holds cyc until the acknowledge)
    wire [31:0] sv_a = db_cyc ? db_adr : ib_adr;
    wire sv_req = ((db_cyc && !io) || ib_cyc) && !sv_fly && !sv_hold && !sv_ack;
    wire [23:0] sv_w = sv_a[30] ? sv_a[25:2] : FW_W + {12'd0, sv_a[13:2]};
    assign m_wdata = db_dat;
    wire io_go = io && !io_ack && !sv_hold && (db_we || db_adr[3:2] != 2'd3 || event_v);
    assign r_valid = m_rvalid && m_quad;    // (a quad is always the client's)
    assign r_data = m_rdata;
    assign sv_rdt = !io_ack ? m_rdata : db_adr[4] ? ctl_r0 : db_adr[3:2] == 2'd1 ? rom_size :
                    db_adr[3:2] == 2'd2 ? {ready ? ctl_set : SLOTS[13:0], last_b} : status;
    // the command: length, first block, blocks in flops, the slots in an MLAB
    reg [14:0] fc_len = 0;
    reg [17:0] fc_lb = 0;
    reg [2:0] fc_n = 0;
    assign fc_data = {fc_len, 2'b00, fc_lb, 12'b0, fc_n, 70'd0};
    (* ramstyle = "MLAB, no_rw_check" *) reg [13:0] fc_slots [0:7];
    always @(posedge clk) if (io_go && db_we && db_adr[5]) fc_slots[db_adr[4:2]] <= db_dat[13:0];
    assign fc_slot = fc_slots[fc_sel];
    assign ctl_we0 = io_go && db_we && db_adr[5:2] == 4'd0;
    assign ctl_we1 = io_go && db_we && db_adr[5:2] == 4'd1;
    assign ctl_take = io_go && !db_we && db_adr[4:2] == 3'd4;

    // ---------------- reference bits ----------------
    reg refmem [0:SLOTS-1];
    reg ref_q = 0, ref_we = 0, ref_wd = 0;
    reg [SB-1:0] ref_waddr = 0;             // (the firmware reads and writes a bit only while the client can't)
    always @(posedge clk) begin
        ref_q <= refmem[ref_waddr];
        if (ref_we) refmem[ref_waddr] <= ref_wd;
    end

    // ---------------- the client ----------------
    localparam [2:0] H_IDLE = 0, H_LOOK = 1, H_ENTRY = 2, H_READ = 3, H_DATA = 4, H_MISS = 5;
    reg [2:0] st = H_IDLE;
    reg mem_busy = 0, mem_sv = 0;
    reg [1:0] mem_n = 0;
    reg [31:0] qaddr = 0;
    reg [SB-1:0] last_slot = 0;
    reg [17:0] last_b = 0;
    reg last_v = 0;
    reg miss = 0, pf_seen = 0, mk_v = 0, mk_e = 0, hold = 0, pf_due = 0, pf_fly = 0, fast = 0, pf_any = 0;
    wire [17:0] cb = qaddr[29:12];
    wire c_pend = ctl_pend && ready;         // (no controls frame before the start-up is done)
    wire event_v = miss || pf_seen || hold || c_pend;
    wire [31:0] status = {miss, pf_seen, mk_v, mk_e, fc_busy, ref_q, last_v, hold, pf_due, pf_fly, c_pend, ctl_st, cb};
    function automatic [13:0] pad14(input [SB-1:0] x);
        pad14 = x;
    endfunction

    assign dg_wait = st == H_MISS;
    assign dg_cmd = fc_send;
    always @(posedge clk) begin
        c_ready <= 0; fc_send <= 0; ref_we <= 0; sv_ack <= 0; io_ack <= 0;
        sv_hold <= sv_ack || io_ack;
        if (m_ready) m_valid <= 0;
        if (stat_clear) begin st_lookups <= 0; st_cmds <= 0; st_blocks <= 0; st_wait <= 0; end
        if (dg_wait && tick_ms) st_wait <= st_wait + 1'b1;
        if (mk_valid) begin mk_v <= 1; mk_e <= mk_err != 0; end
        // SDRAM results
        if (mem_busy) begin
            if (m_write && m_ready) begin
                mem_busy <= 0;
                if (mem_sv) begin sv_ack <= 1; sv_fly <= 0; end
            end
            if (m_rvalid) begin
                mem_n <= mem_n + 1'b1;
                if (!m_quad || mem_n == 2'd3) mem_busy <= 0;
                if (mem_sv) begin sv_ack <= 1; sv_fly <= 0; end
            end
        end
        // registers
        // (the firmware writes reference bits only while the client is held or waits for a miss: no clash with a hit's)
        if (io_go) begin
            io_ack <= 1;
            if (db_we) case (db_adr[5:2])
                4'd2: begin fc_n <= db_dat[2:0]; fc_lb <= db_dat[20:3]; end
                4'd3: begin
                    fc_len <= db_dat[14:0];
                    if (db_dat[31]) begin
                        fc_send <= 1; mk_v <= 0; if (db_dat[30]) pf_fly <= 1;
                        st_cmds <= st_cmds + 1'b1; st_blocks <= st_blocks + fc_n;   // run_n
                    end
                end
                4'd4: begin ref_waddr <= db_dat[SB-1:0]; ref_wd <= db_dat[16]; ref_we <= db_dat[17]; end
                4'd7: begin last_slot <= db_dat[SB-1:0]; last_b <= cb; last_v <= 1; fast <= 1; miss <= 0; end
                4'd5: pf_any <= db_dat[29];
                4'd6: begin
                    if (db_dat[0]) ready <= 1;
                    if (db_dat[1]) fail <= 1;
                    if (db_dat[2]) miss <= 0;
                    if (db_dat[3]) last_v <= 0;
                    if (db_dat[4]) pf_seen <= 0;
                    if (db_dat[6]) hold <= 0;
                    if (db_dat[7]) pf_due <= 1;
                    if (db_dat[8]) pf_due <= 0;
                    if (db_dat[9]) pf_fly <= 0;
                end
            endcase
        end

        if (reset || !start) begin
            st <= H_IDLE; m_valid <= 0; mem_busy <= 0; mem_sv <= 0; sv_fly <= 0;
            ready <= 0; fail <= 0; miss <= 0; last_v <= 0; pf_seen <= 0; mk_v <= 0; hold <= 0; pf_due <= 0; pf_fly <= 0; pf_any <= 0;
        end else if (!mem_busy) begin
            case (st)
                H_IDLE: if (ready && c_valid && !hold) begin
                    c_ready <= 1; qaddr <= {c_addr[31:4], 4'b0}; st <= H_LOOK;
                end else if (ready && !hold && ((pf_due && !pf_fly) || (pf_fly && mk_v))) hold <= 1;
                H_LOOK: begin
                    st_lookups <= st_lookups + 1'b1;
                    if (last_v && last_b == cb) st <= H_READ;
                    else begin
                        m_valid <= 1; m_write <= 0; m_quad <= 0; m_addr <= {TB, cb}; m_be <= 4'b0000;
                        mem_busy <= 1; mem_sv <= 0; mem_n <= 0; st <= H_ENTRY;
                    end
                end
                H_ENTRY: if (m_rdata[16]) begin
                    last_b <= cb; last_slot <= m_rdata[SB-1:0]; last_v <= 1;
                    ref_we <= 1; ref_waddr <= m_rdata[SB-1:0]; ref_wd <= 1;
                    if (pf_any) pf_seen <= 1;
                    st <= H_READ;
                end else begin miss <= 1; st <= H_MISS; end
                H_MISS: if (!miss) begin st <= fast ? H_READ : H_LOOK; fast <= 0; end
                H_READ: begin
                    m_valid <= 1; m_write <= 0; m_quad <= 1; m_addr <= {CACHE_W[23:10] + pad14(last_slot), qaddr[11:2]}; m_be <= 4'b0000;
                    mem_busy <= 1; mem_sv <= 0; mem_n <= 0; st <= H_DATA;
                end
                H_DATA: st <= H_IDLE;
                default: st <= H_IDLE;
            endcase
            // SERV's access when the client does not need the port this clock
            if (sv_req && st != H_LOOK && st != H_ENTRY && st != H_READ && !(st == H_IDLE && ready && c_valid && !hold)) begin
                m_valid <= 1; m_write <= db_cyc && db_we; m_quad <= 0; m_addr <= sv_w;
                m_be <= db_cyc && db_we ? db_sel : 4'b0000;
                mem_busy <= 1; mem_sv <= 1; mem_n <= 0; sv_fly <= 1;
            end
        end
    end
endmodule
`default_nettype wire
