// SPDX-License-Identifier: MIT
// The DS save's write-back on quit (docs/saves.md, "Write-back"): APF 0x0080
// "request read" for the save slot, then the Pocket reads the slot's bridge
// window one word at a time and keeps the PREVIOUS read's answer.
//
// Adapted from openfpga-PlayStation's psx_memcard_os_read.sv (released since 0.5.3):
// the same prefill-a-ring-then-acknowledge order. What
// differs: PSX's memory port is on the host clock and its card has a fixed
// size; here the ring is filled on clk_bus straight from the SDRAM arbiter, so
// the ring is a dual-clock RAM with the two pointers crossed by nds_bundle_cdc
// (each side sees the other's pointer late, which only holds it back), and
// the word count follows the save chip. No freeze is needed: the DS has stopped
// writing the save by the time the Pocket quits, and a word the game writes
// meanwhile is read either before or after, as on a flashcart.
//
// Bridge read of word a (window offset / 4): bridge_data = ring[a] when a is
// in the ring (a < the words filled) and not yet overwritten (a >= the
// furthest word read - BACK). The fill stays DEPTH - BACK words ahead of the
// furthest read at most, so the last BACK words read can be read again: the
// Pocket reads the slot in 1 KiB pieces, each followed by a dummy read of the
// next word, and then reads that word again as the next piece's first (#265:
// strict in-order serving answered those re-reads with 0, one zero word per
// KiB in every exported save). Reads at or past the save's end return 0 and
// count nothing; any other read returns 0 and counts in errors. A new 0x0080
// restarts from word 0 (a generation bit drops pointer updates from the run
// before).
`default_nettype none
module nds_save_read #(
    parameter [15:0] SLOT_ID = 16'd10,
    parameter [7:0] WIN = 8'h60,              // bridge window, address[31:24]
    parameter [23:0] BASE_W = 24'h04_0000,    // SDRAM word address of save byte 0
    parameter integer AW = 8,                 // ring of 2^AW words
    parameter integer BACK = 16,              // words behind the furthest read kept readable
    // TWO = 1: a second slot read the same way (the NDSDiag core's log, docs/diag.md): its ID, bridge window,
    // SDRAM base and size; the run serves whichever slot the 0x0080 asked for
    parameter bit TWO = 0,
    parameter [15:0] SLOT_ID2 = 16'd11,
    parameter [7:0] WIN2 = 8'h70,
    parameter [23:0] BASE_W2 = 24'h10_0000,
    parameter [18:0] WORDS2 = 19'h2_0000
) (
    // APF side
    input wire clk, reset,
    input wire rq, input wire [15:0] rq_id,   // core_bridge_cmd dataslot_requestread(_id), held until ack
    output wire rq_ack,
    input wire [18:0] words,                  // save size in words: static (the boot program's save type), so
                                              // both clocks read it directly (as core_top_ds's save facts)
    input wire bridge_rd,
    input wire [31:0] bridge_addr,
    output wire selected,                     // bridge_addr is in WIN
    output reg [31:0] bridge_data = 0,
    output reg [15:0] runs = 0, errors = 0,
    // SDRAM side
    input wire clk_bus, reset_bus,
    output wire m_valid,
    output wire [23:0] m_addr,
    input wire m_ready, m_rvalid,
    input wire [31:0] m_rdata
);
    localparam integer DEPTH = 1 << AW;
    (* ramstyle = "M10K" *) reg [31:0] ring [0:DEPTH-1];

    // ---------------- APF side ----------------
    reg gen = 0, acked = 0, rq_d = 0, rd_d = 0;
    reg sel2 = 0;                             // the run serves the second slot (TWO)
    wire is1 = rq_id == SLOT_ID, is2 = TWO && rq_id == SLOT_ID2;
    wire [18:0] words_r = sel2 ? WORDS2 : words;
    reg [18:0] rp = 0, wp74 = 0;              // furthest word read + 1, words in the ring (seen late)
    wire w_recv;
    wire [19:0] w_data;                       // {gen, filled}
    wire start = rq && (is1 || is2) && !rq_d;
    // core_bridge_cmd samples the ack from the clock it raises rq and sets rq_id,
    // so a clock with rq low must not acknowledge
    assign rq_ack = rq && (!(is1 || is2) || acked && rq_d);
    assign selected = bridge_addr[31:24] == (sel2 ? WIN2 : WIN);
    wire strobe = bridge_rd && !rd_d && selected;
    wire [18:0] a = bridge_addr[20:2];
    localparam [18:0] AHEAD = DEPTH - BACK;   // most words filled past the furthest read
    wire ready_all = wp74 >= (words_r < AHEAD ? words_r : AHEAD);
    reg [31:0] q = 0;
    reg serve = 0;
    always @(posedge clk) q <= ring[a[AW-1:0]];
    always @(posedge clk) begin
        rq_d <= rq && (is1 || is2); rd_d <= bridge_rd;
        serve <= 0;
        if (reset) begin
            gen <= 0; acked <= 0; rp <= 0; wp74 <= 0; runs <= 0; errors <= 0; bridge_data <= 0; sel2 <= 0;
        end else begin
            if (start) begin gen <= !gen; acked <= 0; rp <= 0; wp74 <= 0; runs <= runs + 1'b1; sel2 <= is2; end
            else if (w_recv && w_data[19] == gen) wp74 <= w_data[18:0];
            if (!start && rq_d && !acked && ready_all) acked <= 1;
            if (strobe && !start) begin
                if (a < wp74 && a + BACK[18:0] >= rp) begin
                    serve <= 1;
                    if (a >= rp) rp <= a + 1'b1;
                end
                else begin
                    bridge_data <= 0;
                    if (a < words_r) errors <= errors + 1'b1;
                end
            end
            // q is ring[a] read at the strobe (bridge_addr holds through the read)
            if (serve) bridge_data <= q;
        end
    end
    wire [20:0] cmd_b;
    nds_bundle_cdc #(.W(21)) x_cmd (.a_clk(clk), .a_send(1'b1), .a_data({sel2, gen, rp}), .a_busy(),
        .b_clk(clk_bus), .b_recv(), .b_data(cmd_b));

    // ---------------- SDRAM side ----------------
    // cmd_b = {second slot, gen, served}: a new gen restarts the fill at word 0
    reg gen_b = 0, busy = 0, sel2_b = 0;
    reg [18:0] wp = 0;
    wire [18:0] n_b = sel2_b ? WORDS2 : words, rp_b = cmd_b[18:0];
    wire room = wp - rp_b < AHEAD;
    assign m_valid = busy;
    assign m_addr = (sel2_b ? BASE_W2 : BASE_W) + {5'b0, wp};
    reg issued = 0;
    always @(posedge clk_bus) begin
        if (reset_bus) begin gen_b <= 0; busy <= 0; issued <= 0; wp <= 0; end
        else begin
            // a new run starts once no word of the old one is on its way
            if (cmd_b[19] != gen_b && !busy && !issued) begin gen_b <= cmd_b[19]; sel2_b <= TWO && cmd_b[20]; wp <= 0; end
            if (busy && m_ready) begin busy <= 0; issued <= 1; end
            else if (!busy && !issued && cmd_b[19] == gen_b && wp < n_b && room) busy <= 1;
            if (issued && m_rvalid) begin
                issued <= 0;
                ring[wp[AW-1:0]] <= m_rdata;
                wp <= wp + 1'b1;
            end
        end
    end
    nds_bundle_cdc #(.W(20)) x_fill (.a_clk(clk_bus), .a_send(1'b1), .a_data({gen_b, wp}), .a_busy(),
        .b_clk(clk), .b_recv(w_recv), .b_data(w_data));
endmodule
`default_nettype wire
