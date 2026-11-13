// VRAM bank controller (docs/phase2-integration.md, "VRAM"). The nine banks
// A-I live in one external physical space (656 KiB):
//   A 0x00000  B 0x20000  C 0x40000  D 0x60000  (128 KiB each)
//   E 0x80000 (64 KiB)  F 0x90000  G 0x94000 (16 KiB)  H 0x98000 (32 KiB)
//   I 0xA0000 (16 KiB)
// VRAMCNT A-I map them into the views (melonDS GPU::MapVRAM_*): engine A/B
// BG and OBJ, LCDC, ARM7, BG/OBJ extended palettes, 3D texture and texture
// palette. A view address hits bank b if b is enabled, its MST selects that
// view and its offset field covers the address; the bank address is the
// view address modulo the bank size. Where banks overlap, the first bank in
// A-I order serves the access (melonDS ORs reads and writes all; a
// documented difference). Unmapped reads give 0, unmapped writes are
// dropped.
//
// Clients: the 2D engine's 32-byte block reads (first priority, deadlines),
// display-capture halfword writes, then CPU/DMA word accesses from the
// fabric, then the cartridge's save memory. The 3D texture and palette
// caches (nds_gpu3d) share the block port through nds_blk_arb (spaces
// SP_TEX, SP_TPAL). One external access at a time.
module nds_vram
    import gpu2d_pkg::*;
#(
    // CAP_CHAIN: a captured word pair goes to the SDRAM write FIFO (cw_*, core_top_ds) instead of the
    // serial VRAM port: a line's 128 writes took ~26 clocks each there under the 3D's traffic and the
    // composite pass waited on them (MKDS intro, docs/2d-engine.md). A lone halfword still uses the port.
    parameter bit CAP_CHAIN = 0,
    // VR_POST (with CAP_CHAIN): a CPU or DMA word write also goes to the write FIFO, so it costs a few clocks
    // instead of an SDRAM write through the serial port (Golden Sun DD's title: its HBlank row and GX list took
    // 4 video frames a game frame). Reads and partial writes from this port wait until the FIFO has drained.
    parameter bit VR_POST = 0,
    // VR_RDB: this port's reads fill a line of 8 words, one block on the VRAM port, and hit it after that: the
    // same title's copy of a captured bank took 22 clocks a word through single reads. Any write empties the line.
    parameter bit VR_RDB = 0,
    // VR_PASS (with VR_POST): a 2D block read waits for the FIFO to drain only if its 8 words fall in the range of
    // the words posted since the FIFO was last empty (it waited for every posted word: each DMA word then went alone
    // and the next waited behind 2D, ~22 clocks a word for Golden Sun DD's HBlank DMA against the DS's 6.3). Posted
    // words now follow each other into the FIFO, whose controller writes them as one row chain, and a full-word
    // write is posted while 2D block words are still arriving (it doesn't use the VRAM port; the controller serves
    // a port's block before a chain write; a word for a line one of the last two blocks reads waits for them: the
    // testbench's ordering contract allows no port read of a word while a chain write to it is pending).
    parameter bit VR_PASS = 0,
    // VR_WB (with VR_PASS): a full-word write is acked as soon as a one-word buffer takes it; the buffer resolves
    // and posts it while the fabric runs the next unit (main->VRAM DMA: 4.10 system cycles a word here, the DS's
    // 3.15, unitmem). The buffer goes before this port's other CPU requests, so a later read waits for it.
    parameter bit VR_WB = 0,
    // VR_CWF (with VR_RDB): a line fill acks the read as its word arrives (critical word); the rest of the line
    // fills while the fabric goes on, and this port's next request waits for the fill's end.
    parameter bit VR_CWF = 0,
    // VR_HIT (with VR_RDB): a read of the line in rb is answered from S_IDLE, beside the state machine (it went
    // S_IDLE -> S_CRES -> ack); only while res is the CPU port's (no 2D request, no buffered write).
    parameter bit VR_HIT = 0,
    // VR_YIELD (with VR_PASS): a CPU access waiting in S_CRES (behind a block's line or the FIFO drain), S_WRES or
    // S_POST (FIFO full: it is shared with the 3D ring's writes) goes back to S_IDLE when the 2D engine asks for a
    // block, so the block starts (only S_IDLE starts one); the request stays pending and is resolved again.
    parameter bit VR_YIELD = 0,
    // VR_PDRAIN (with VR_PASS): post_p ends when the last posted word has left the shared FIFO (its pop count
    // passes the word's place, taken at the post from cw_pcnt + cw_fill), not when the whole FIFO is empty: the
    // 3D ring and the bottom screen keep it busy, so a 2D block in S_GRES behind pr_hit waited unbounded (gsdd 7 late lines).
    parameter bit VR_PDRAIN = 0,
    // VR_PF (with VR_RDB): the read line is two ways (one MLAB). A DMA read (c_dma) that hits or fills line L asks for
    // L+1 in the other way; the prefetch's block goes from S_IDLE when no 2D words are due and no posted word may
    // still be in the FIFO, and its words fill beside the state machine (as a 2D block's: S_PBLK returns to
    // S_IDLE), so the DMA's next reads hit the current way meanwhile (VRAM->main units: 6.46 system cycles a word,
    // the DS's 4.08, unitmem). Anything else that needs the port waits for the prefetch's words; any write
    // invalidates both ways and the prefetch in flight, as it did the line.
    parameter bit VR_PF = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [71:0] vramcnt,        // VRAMCNT_A in [7:0] ... VRAMCNT_I in [71:64]
    // CPU port (fabric): request held until ack
    input  logic        c_req,
    input  logic        c_cpu,          // 0 ARM9 map, 1 ARM7 map
    input  logic        c_dma,          // VR_PF: the request is a DMA's
    input  logic        c_we,
    input  logic [23:2] c_addr,         // offset in 0x06000000..0x06FFFFFF
    input  logic [3:0]  c_be,
    input  logic [31:0] c_wdata,
    output logic        c_ack,
    output logic [31:0] c_rdata,       // (c_rdata and sv_rdata are one register: each is read at its own ack)
    // 2D engine block port
    input  logic        g_req,
    input  blk_t        g_blk,
    output logic        g_ack,
    output logic        g_rvalid,
    output logic [63:0] g_rdata,       // {the beat's second word, w0}: w0 changes only after the beat is taken
    // display capture (bank << 16 | halfword index)
    input  logic        cap_we,
    input  logic [17:0] cap_addr,
    input  logic [15:0] cap_data,
    output logic        cap_ready,
    output logic        cw_valid,       // CAP_CHAIN: a word to write at VRAM word cw_addr, held until cw_ack
    output logic [23:0] cw_addr,
    output logic [31:0] cw_data,
    input  logic        cw_ack,
    input  logic        cw_drained,
    input  logic [6:0]  cw_fill,     // VR_PDRAIN: the FIFO's words written and not popped (lags)
    input  logic [6:0]  cw_pcnt,     // VR_PDRAIN: the FIFO's words popped, mod 128 (lags)
    // the cartridge's save memory (1 MiB at physical 0x100000) and the WiFi
    // block's memory (0x0F0000), lowest priority
    input  logic        sv_req,
    input  logic        sv_we,
    input  logic [20:2] sv_addr,        // full VRAM-port word address (nds_top adds the save's 0x100000)
    input  logic [3:0]  sv_be,
    input  logic [31:0] sv_wdata,
    output logic        sv_ack,
    output logic [31:0] sv_rdata,
    // external physical VRAM: request held until ack; reads return 1 or 8
    // words on rvalid
    output logic        vm_req,
    output logic        vm_we,
    output logic        vm_blk,
    output logic [20:2] vm_addr,
    output logic [3:0]  vm_be,
    output logic [31:0] vm_wdata,
    input  logic        vm_ack,
    input  logic        vm_rvalid,
    input  logic [31:0] vm_rdata,
    // ARM7 VRAMSTAT: bank C / D mapped to the ARM7
    output logic [1:0]  vramstat
);
    localparam logic [3:0] V_ABG = 4'd0, V_BBG = 4'd1, V_AOBJ = 4'd2, V_BOBJ = 4'd3, V_LCDC = 4'd4,
                           V_ARM7 = 4'd5, V_ABGX = 4'd6, V_BBGX = 4'd7, V_AOBJX = 4'd8, V_BOBJX = 4'd9,
                           V_TEX = 4'd10, V_TPAL = 4'd11, V_NONE = 4'd15;

    // physical base (bytes) and size (log2) per bank
    function automatic logic [19:0] bank_base(input int b);
        case (b)
            0: return 20'h00000; 1: return 20'h20000; 2: return 20'h40000; 3: return 20'h60000;
            4: return 20'h80000; 5: return 20'h90000; 6: return 20'h94000; 7: return 20'h98000;
            default: return 20'hA0000;
        endcase
    endfunction
    function automatic logic [19:0] bank_mask(input int b);
        case (b)
            0, 1, 2, 3: return 20'h1FFFF;
            4: return 20'h0FFFF;
            7: return 20'h07FFF;
            default: return 20'h03FFF;
        endcase
    endfunction

    // does bank b serve view v at offset o?
    function automatic logic bank_hit(input int b, input logic [7:0] cnt, input logic [3:0] v, input logic [19:0] o);
        logic [2:0] m;
        logic [1:0] f;
        m = cnt[2:0];
        f = cnt[4:3];
        if (!cnt[7]) return 1'b0;
        if (v == V_LCDC) begin
            // fixed LCDC layout, mapped while MST = 0
            if ((b == 0 || b == 1 || b == 7 || b == 8) ? m[1:0] != 2'd0 : m != 3'd0) return 1'b0;
            case (b)
                0: return o[19:17] == 3'd0;
                1: return o[19:17] == 3'd1;
                2: return o[19:17] == 3'd2;
                3: return o[19:17] == 3'd3;
                4: return o[19:16] == 4'h8;
                5: return o[19:14] == 6'h24;
                6: return o[19:14] == 6'h25;
                7: return o[19:15] == 5'h13;
                default: return o[19:14] == 6'h28;
            endcase
        end
        case (b)
            0, 1: case (m[1:0])                                  // A, B
                2'd1: return v == V_ABG  && o[18:17] == f;
                2'd2: return v == V_AOBJ && o[17] == f[0];
                2'd3: return v == V_TEX  && o[18:17] == f;
                default: return 1'b0;
            endcase
            2, 3: case (m)                                       // C, D
                3'd1: return v == V_ABG  && o[18:17] == f;
                3'd2: return v == V_ARM7 && o[17] == f[0];
                3'd3: return v == V_TEX  && o[18:17] == f;
                3'd4: return v == (b == 2 ? V_BBG : V_BOBJ);
                default: return 1'b0;
            endcase
            4: case (m)                                          // E
                3'd1: return v == V_ABG  && o[18:16] == 3'd0;
                3'd2: return v == V_AOBJ && o[17:16] == 2'd0;
                3'd3: return v == V_TPAL && o[16] == 1'b0;
                3'd4: return v == V_ABGX;
                default: return 1'b0;
            endcase
            5, 6: case (m)                                       // F, G
                3'd1: return v == V_ABG  && o[18:17] == 2'd0 && o[16] == f[1] && o[14] == f[0];
                3'd2: return v == V_AOBJ && o[17] == 1'b0 && o[16] == f[1] && o[14] == f[0];
                3'd3: return v == V_TPAL && o[16:14] == {f[1], 1'b0, f[0]};
                3'd4: return v == V_ABGX && o[14] == f[0];
                3'd5: return v == V_AOBJX;
                default: return 1'b0;
            endcase
            7: case (m[1:0])                                     // H
                2'd1: return v == V_BBG  && o[15] == 1'b0;
                2'd2: return v == V_BBGX;
                default: return 1'b0;
            endcase
            default: case (m[1:0])                               // I
                2'd1: return v == V_BBG  && o[15] == 1'b1;
                2'd2: return v == V_BOBJ;
                2'd3: return v == V_BOBJX;
                default: return 1'b0;
            endcase
        endcase
    endfunction

    // view offset -> physical byte address (first bank wins)
    function automatic logic [20:0] resolve(input logic [71:0] vc, input logic [3:0] v, input logic [19:0] o);
        logic [20:0] r;
        logic [19:0] pa;
        r = '0;
        pa = '0;
        for (int b = 8; b >= 0; b--)
            if (bank_hit(b, vc[b*8 +: 8], v, o)) begin
                pa = bank_base(b) | (o & bank_mask(b));
                r[20:14] = {1'b1, pa[19:14]};
            end
        // Every bank preserves these offset bits. Gate them with mapped-valid;
        // upper address bits still select the first matching bank.
        r[13:0] = r[20] ? (o[13:0] & 14'h3fff) : 14'd0;
        return r;
    endfunction

    // ---- CPU view
    logic [3:0]  c_view;
    logic [19:0] c_off;
    always_comb begin
        c_off = {c_addr[19:2], 2'b00};
        if (c_cpu) begin
            c_view = V_ARM7; c_off = {2'b00, c_addr[17:2], 2'b00};
        end else case (c_addr[23:21])
            3'd0: begin c_view = V_ABG;  c_off = {1'b0, c_addr[18:2], 2'b00}; end
            3'd1: begin c_view = V_BBG;  c_off = {3'b0, c_addr[16:2], 2'b00}; end
            3'd2: begin c_view = V_AOBJ; c_off = {2'b0, c_addr[17:2], 2'b00}; end
            3'd3: begin c_view = V_BOBJ; c_off = {3'b0, c_addr[16:2], 2'b00}; end
            default: begin c_view = V_LCDC; c_off = {c_addr[19:2], 2'b00}; end
        endcase
    end

    // ---- 2D view
    logic [3:0]  g_view;
    logic [19:0] g_off;
    always_comb begin
        logic [2:0] sp;
        logic       e;
        sp = g_blk[17:15];
        e  = g_blk[14];
        g_off = {1'b0, g_blk[13:0], 5'd0};
        case (sp)
            SP_BG:     begin g_view = e ? V_BBG : V_ABG;     if (e) g_off[19:17] = 3'd0; end
            SP_OBJ:    begin g_view = e ? V_BOBJ : V_AOBJ;   g_off[19:18] = 2'd0; if (e) g_off[17] = 1'b0; end
            SP_BGEXT:  begin g_view = e ? V_BBGX : V_ABGX;   g_off[19:15] = 5'd0; end
            SP_OBJEXT: begin g_view = e ? V_BOBJX : V_AOBJX; g_off[19:13] = 7'd0; end
            SP_LCDC:   begin g_view = V_LCDC;                g_off[19] = 1'b0; end
            SP_TEX:    begin g_view = V_TEX;                 g_off[19] = 1'b0; end
            SP_TPAL:   begin g_view = V_TPAL;                g_off[19:17] = 3'd0; end
            default:   g_view = V_NONE;
        endcase
    end

    // ---- state machine
    typedef enum logic [3:0] { S_IDLE, S_GBLK, S_GZERO, S_CAP, S_CPU, S_CPUR, S_GRES, S_CRES, S_POST, S_RBLK, S_RFIL, S_WRES, S_PBLK } st_t;
    st_t         st;
    logic [20:0] res_q;         // the resolver's answer for the request taken (S_GRES, S_CRES)
    logic [2:0]  beat;          // words received (block)
    logic [31:0] w0, w1;               // a beat's two words
    logic [31:0] r_q;                  // the CPU's or the save port's read word
    assign c_rdata = r_q; assign sv_rdata = r_q; assign g_rdata = {w1, w0};
    logic        cap_v;
    logic        cap_a0;        // the word's halfword: cap_pa is its word (a halfword index's bits 17:1)
    logic [15:0] cap_d;
    // Capture writes go in pairs: an even halfword is held until its odd
    // partner arrives, and the two leave as one 32-bit write (cap_w, the low
    // half in cap_pd: a new halfword is taken only with no word waiting, so the
    // held even one and a waiting word's low half are never both live). A line's 256 writes were each a request on the VRAM
    // port, 8 or more clocks apiece against the 3D ring's traffic: the
    // composite pass took 2,000-2,470 clocks instead of 526 and the line
    // went late (MKDS intro's dual-screen 3D, docs/2d-engine.md). An even
    // halfword whose partner does not follow within 4 clocks (a capture that
    // ends there, a changed address) is written alone.
    logic        cap_w, cap_p;
    logic [15:0] cap_pd;
    logic [16:0] cap_pa;
    logic [2:0]  cap_t;
    logic [20:2] va;
    logic        vwe, vblk;
    logic        vsv;           // the CPU states serve the save port
    logic [3:0]  vbe;
    logic [31:0] vwd;
    // up to two 2D blocks in flight: a block's request goes out while the
    // previous one's words still arrive (in order); CPU, capture and save
    // accesses and unmapped (zero) blocks wait until no block words are due
    logic [4:0]  bw_left;       // block words still to come
    logic        bw_odd;        // the next block word is the second of a pair
    logic        bw_acc;        // a block request was accepted this cycle
    logic        post_p, post_d; // VR_POST: a posted word may still be in the FIFO: nothing reads VRAM yet
    logic [3:0]  pf_left;       // VR_PF: prefetch words still to come (they come before any later block's)
    // (VR_PF: at most two blocks out; prefetch and block words are both due only with a whole block behind it)
    wire         g_go = g_req && (VR_PF && pf_left != 4'd0 ? bw_left == 5'd0 : bw_left <= 5'd8) && (VR_PASS || !post_p);
    logic [19:5] pr_lo, pr_hi;   // VR_PASS: the 8-word lines of the words posted while post_p is set
    wire         pr_hit = post_p && res_q[19:5] >= pr_lo && res_q[19:5] <= pr_hi;
    logic [19:5] bt0, bt1;       // VR_PASS: the lines of the last two 2D blocks (in flight while bw_left != 0)
    wire         bt_hit = bw_left != 5'd0 && (res_q[19:5] == bt0 || res_q[19:5] == bt1);
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rb [16];  // VR_RDB: the read line (MLAB: an M10K here was the 309th of 308 with MKDS's G3D_SL 9; read in S_IDLE, written in S_RBLK); {way, word}: one write site in every setting (a second, or an index wider than the array, built it from flip-flops: #2050, #2052)
    logic [19:5] lt [2];         // the ways' lines (VR_PF: way 1 too)
    logic        lv [2];         // a way is valid
    logic        rb_inv;         // a write came during the fill
    logic [2:0]  rb_w;
    logic        cur, fw, rd_dma; // VR_PF: the way the last read used, the way a fill writes, the fill is a DMA's
    logic        pf_req, pf_way, pf_inv;
    logic [2:0]  pf_w;
    function automatic logic [3:0] rbi(input logic wy, input logic [2:0] w);
        return {VR_PF && wy, w};
    endfunction
    wire  [1:0]  lhit = {VR_PF && lv[1] && lt[1] == res_q[19:5], lv[0] && lt[0] == res_q[19:5]};
    wire         lh = VR_PF && lhit[1];
    wire  [19:5] l_nx = res_q[19:5] + 15'd1;
    // VR_PF: L+1 for a DMA read of L into the other way w, unless it is there or asked for already. The request
    // takes w's tag at once (lv 0): the pending line is lt[pf_way]; none while prefetch words are due
    function automatic logic pf_want(input logic w);
        return pf_left == 4'd0 && (lt[w] != l_nx || (!lv[w] && !pf_req));
    endfunction
    wire         any_w;

    // One resolver for both, registered: a request waits one clock in S_GRES or
    // S_CRES for its answer (known difference, docs/ds-rules.md). g_ack does not
    // depend on the answer, so the fabric's address and the block ports no longer
    // reach g_ack through the bank match (#1323 -1.01 ns to va, -0.46 to q_blk).
    // A block is taken with g_ack, so its source may change after that (nds_blk_arb).
    logic [20:0] res;
    logic        wb_v, wb_p;     // VR_WB: the buffer holds a write; the post in S_POST is the buffer's
    logic [3:0]  wb_view;
    logic [19:2] wb_off;
    logic [31:0] wb_d;
    wire         c_full = VR_POST && c_req && c_we && c_be == 4'hF;
    wire         wb_take = VR_WB && c_full && !c_ack && !wb_v;
    assign res   = resolve(vramcnt, g_req ? g_view : VR_WB && wb_v ? wb_view : c_view,
                           g_req ? g_off : VR_WB && wb_v ? {wb_off, 2'b00} : c_off);
    wire         hit0 = VR_HIT && VR_RDB && st == S_IDLE && !g_req && !(VR_WB && wb_v) && c_req && !c_ack && !c_we
                        && !VR_PF && res[20] && lv[0] && lt[0] == res[19:5];

    assign g_ack = st == S_IDLE && g_go;
    assign bw_acc = st == S_GBLK && vm_ack;
    wire cw_pair = CAP_CHAIN && cap_v && cap_w;
    wire cw_post = VR_POST && st == S_POST && !cw_pair;
    assign cw_valid = cw_pair || cw_post;
    assign cw_addr  = cw_pair ? {7'd0, cap_pa} : {6'd0, res_q[19:2]};
    assign cw_data  = cw_pair ? {cap_d, cap_pd} : VR_WB && wb_p ? wb_d : c_wdata;
    assign cap_ready = !cap_v && (!cap_p || (cap_addr[0] && cap_addr[17:1] == cap_pa));

    always_ff @(posedge clk) begin
        g_rvalid <= 1'b0;
        c_ack <= 1'b0;
        sv_ack <= 1'b0;
        if (cap_we && cap_ready) begin
            if (!cap_addr[0]) begin cap_p <= 1'b1; cap_pa <= cap_addr[17:1]; cap_pd <= cap_data; cap_t <= 3'd0; end
            else begin
                cap_v <= 1'b1; cap_pa <= cap_addr[17:1]; cap_a0 <= 1'b1; cap_d <= cap_data;   // (cap_pa unchanged with a pair)
                cap_w <= cap_p; cap_p <= 1'b0;
            end
        end else if (cap_p) begin
            cap_t <= cap_t + 3'd1;
            if (cap_t == 3'd4 && !cap_v) begin
                cap_v <= 1'b1; cap_a0 <= 1'b0; cap_d <= cap_pd; cap_w <= 1'b0; cap_p <= 1'b0;
            end
        end
        if (cw_pair && cw_ack) cap_v <= 1'b0;
        // block words: pairs to the 2D engine
        bw_left <= bw_left + (bw_acc ? 5'd8 : 5'd0) - (vm_rvalid && bw_left != 5'd0 && pf_left == 4'd0 ? 5'd1 : 5'd0);
        if (VR_PF && vm_rvalid && pf_left != 4'd0) begin    // the prefetch's words (before any later block's)
            pf_w <= pf_w + 3'd1; pf_left <= pf_left - 4'd1;
            if (pf_left == 4'd1) lv[pf_way] <= !pf_inv;
        end
        if (vm_rvalid && bw_left != 5'd0 && pf_left == 4'd0) begin
            bw_odd <= !bw_odd;
            if (!bw_odd) w0 <= vm_rdata;
            else begin g_rvalid <= 1'b1; w1 <= vm_rdata; end
        end
        if (st == S_IDLE) res_q <= res;
        if (bw_acc) begin bt0 <= va[19:5]; bt1 <= bt0; end
        if (hit0) begin c_ack <= 1'b1; r_q <= rb[rbi(1'b0, res[4:2])]; end
        if (wb_take) begin wb_v <= 1'b1; wb_view <= c_view; wb_off <= c_off[19:2]; wb_d <= c_wdata; c_ack <= 1'b1; end
        if (rst) begin
            st <= S_IDLE; cap_v <= 1'b0; cap_p <= 1'b0; bw_left <= 5'd0; bw_odd <= 1'b0; wb_v <= 1'b0; wb_p <= 1'b0;
            pf_left <= 4'd0; pf_req <= 1'b0; cur <= 1'b0;
        end else case (st)
            S_IDLE: begin
                beat <= 3'd0;
                if (g_req) begin
                    if (g_go) st <= S_GRES;
                end else if (VR_WB && wb_v) st <= S_WRES;                // the buffer first (posted: no port use)
                else if (VR_WB && c_full) ;                               // waits for the buffer
                else if (VR_PASS && bw_left != 5'd0 && c_req && !c_ack && c_we && c_be == 4'hF) st <= S_CRES;   // posted: no port use
                else if (bw_left != 5'd0) ;
                else if (VR_PF && pf_left != 4'd0) begin if (c_req && !c_ack) st <= S_CRES; end   // (a hit, or it waits there)
                else if (cap_v && !cw_pair) begin
                    // capture writes go to banks A-D through their LCDC addresses
                    st <= S_CAP; va <= cap_pa; vwe <= 1'b1; vblk <= 1'b0;
                    vbe <= cap_w ? 4'b1111 : cap_a0 ? 4'b1100 : 4'b0011; vwd <= cap_w ? {cap_d, cap_pd} : {cap_d, cap_d};
                end else if (c_req && !c_ack && !hit0) st <= S_CRES;
                else if (VR_PF && pf_req && !post_p) begin
                    st <= S_PBLK; va <= {lt[pf_way], 3'd0}; vwe <= 1'b0; vblk <= 1'b1; vsv <= 1'b0; pf_inv <= 1'b0;
                end
                else if (sv_req && !sv_ack) begin
                    st <= S_CPU; va <= sv_addr; vwe <= sv_we; vblk <= 1'b0; vbe <= sv_be; vwd <= sv_wdata;
                    vsv <= 1'b1;
                end
            end
            S_GRES:
                if (VR_PASS && res_q[20] && pr_hit) ;      // its words may still be in the FIFO
                else if (res_q[20]) begin
                    st <= S_GBLK; va <= res_q[19:2]; vwe <= 1'b0; vblk <= 1'b1;
                end else if (bw_left == 5'd0) st <= S_GZERO;     // (in order, after the blocks in flight)
            S_CRES:
                if (!res_q[20]) begin c_ack <= 1'b1; r_q <= 32'd0; st <= S_IDLE; end
                else if (VR_POST && c_we && c_be == 4'hF) begin
                    if (!(VR_PASS && bt_hit)) st <= S_POST;   // not into a line a block still reads
                    else if (VR_YIELD && g_req) st <= S_IDLE;
                end
                else if (VR_RDB && !c_we && |lhit) begin
                    c_ack <= 1'b1; r_q <= rb[rbi(lh, res_q[4:2])]; st <= S_IDLE;
                    cur <= lh;
                    if (VR_PF && c_dma && pf_want(!lh)) begin pf_req <= 1'b1; lt[!lh] <= l_nx; lv[!lh] <= 1'b0; pf_way <= !lh; end
                end
                else if (VR_PF && pf_left != 4'd0) begin if (VR_YIELD && g_req) st <= S_IDLE; end   // the port's words are the prefetch's
                else if (post_p) begin if (VR_YIELD && g_req) st <= S_IDLE; end
                else if (VR_RDB && !c_we) begin
                    st <= S_RBLK; va <= {res_q[19:5], 3'd0}; vwe <= 1'b0; vblk <= 1'b1; vsv <= 1'b0; rb_w <= 3'd0; rb_inv <= 1'b0;
                    fw <= VR_PF && !cur; rd_dma <= c_dma; pf_req <= 1'b0;   // (asked again at the fill's end)
                end
                else begin
                    st <= S_CPU; va <= res_q[19:2]; vwe <= c_we; vblk <= 1'b0; vbe <= c_be; vwd <= c_wdata;
                    vsv <= 1'b0;
                end
            S_POST: if (cw_post && cw_ack) begin
                if (wb_p) begin wb_v <= 1'b0; wb_p <= 1'b0; end else c_ack <= 1'b1;
                st <= S_IDLE;
            end else if (VR_YIELD && g_req) begin wb_p <= 1'b0; st <= S_IDLE; end   // (wb_v stays: S_WRES again)
            S_WRES:                                                       // VR_WB: the buffer's word
                if (!res_q[20]) begin wb_v <= 1'b0; st <= S_IDLE; end    // unmapped: dropped
                else if (!bt_hit) begin wb_p <= 1'b1; st <= S_POST; end
                else if (VR_YIELD && g_req) st <= S_IDLE;
            S_RBLK: if (vm_ack) st <= S_RFIL;
            S_RFIL: if (vm_rvalid) begin
                rb_w <= rb_w + 3'd1;
                if (rb_w == res_q[4:2]) r_q <= vm_rdata;
                if (VR_CWF ? rb_w == res_q[4:2] : rb_w == 3'd7) c_ack <= 1'b1;
                if (rb_w == 3'd7) begin
                    lt[fw] <= res_q[19:5]; lv[fw] <= !rb_inv; st <= S_IDLE;
                    cur <= fw;
                    if (VR_PF && rd_dma && pf_want(!fw)) begin pf_req <= 1'b1; lt[!fw] <= l_nx; lv[!fw] <= 1'b0; pf_way <= !fw; end
                end
            end
            S_GBLK: if (vm_ack) st <= S_IDLE;     // the words follow (bw_left)
            S_PBLK: if (vm_ack) begin pf_left <= 4'd8; pf_w <= 3'd0; pf_req <= 1'b0; st <= S_IDLE; end   // VR_PF: they follow (pf_left)
            S_GZERO: begin
                g_rvalid <= 1'b1; w0 <= 32'd0; w1 <= 32'd0; beat <= beat + 3'd1;
                if (beat == 3'd3) st <= S_IDLE;
            end
            S_CAP: if (vm_ack) begin cap_v <= 1'b0; st <= S_IDLE; end
            S_CPU: if (vm_ack) begin
                if (vwe) begin
                    if (vsv) sv_ack <= 1'b1; else c_ack <= 1'b1;
                    st <= S_IDLE;
                end else st <= S_CPUR;
            end
            default: if (vm_rvalid) begin
                r_q <= vm_rdata;
                if (vsv) sv_ack <= 1'b1; else c_ack <= 1'b1;
                st <= S_IDLE;
            end
        endcase
        // VR_RDB: after the state machine, so a write wins over the line's end of fill
        if (rst || any_w) begin lv[0] <= 1'b0; lv[1] <= 1'b0; end
        if (any_w) begin rb_inv <= 1'b1; pf_inv <= 1'b1; end
    end

    assign any_w = (cw_valid && cw_ack) || (vm_req && vm_ack && vwe);
    // the line's one write port (MLAB): a fill's word (S_RFIL) or the prefetch's (VR_PF: never both, a fill
    // starts only with no prefetch words due); two write statements built it in registers (#2050: +554)
    wire        rb_pfw = VR_PF && vm_rvalid && pf_left != 4'd0;
    wire        rb_we  = rb_pfw || (st == S_RFIL && vm_rvalid);
    wire [3:0]  rb_wa  = rb_pfw ? rbi(pf_way, pf_w) : rbi(fw, rb_w);
    always_ff @(posedge clk) if (rb_we) rb[rb_wa] <= vm_rdata;
    logic [6:0]  pd_tgt;         // VR_PDRAIN: the pop count at which the last posted word has left
    // pops still due: 1..66 while the word waits (cw_fill reads up to 65: the read side pre-loads a word, and a
    // signed 7-bit test wrapped at 66 and ended the wait at once); 0, or 96 and up after pops overtook the target
    wire  [6:0]  pd_rem = pd_tgt - cw_pcnt;
    wire         pd_done = pd_rem == 7'd0 || pd_rem[6:5] == 2'b11;
    // VR_PDRAIN tracks every word nds_vram puts in the FIFO, capture pairs too (cw_addr is the word
    // address both ways): the whole-FIFO drain covered a capture word only while a post was pending
    wire         pd_w = VR_PDRAIN ? cw_valid && cw_ack : cw_post && cw_ack;
    wire  [19:5] pd_l = VR_PDRAIN ? cw_addr[17:3] : res_q[19:5];
    always_ff @(posedge clk) begin
        post_d <= cw_post && cw_ack;
        if (rst) post_p <= 1'b0;
        else if (pd_w) post_p <= 1'b1;
        else if (VR_PDRAIN ? pd_done : cw_drained && !post_d) post_p <= 1'b0;
        if (pd_w) pd_tgt <= cw_pcnt + cw_fill + 7'd1;
        if (pd_w) begin
            if (!post_p || pd_l < pr_lo) pr_lo <= pd_l;
            if (!post_p || pd_l > pr_hi) pr_hi <= pd_l;
        end
    end

    // the capture address is a halfword index in a 128 KiB bank: byte = {bank, idx, 0}
`ifndef ALTERA_RESERVED_QIS
    // the ports' contract a copy-free write would rely on: wdata/be unchanged
    // from the request until the write is taken (simulation check)
    always @(posedge clk)
        if (!rst && st == S_CPU && vwe && (vsv ? (sv_wdata != vwd || sv_be != vbe) : (c_wdata != vwd || c_be != vbe)))
            $display("nds_vram: ERROR: the %s port's write data changed before the write (%m) at %0t", vsv ? "save" : "CPU", $time);
`endif
    assign vm_req   = st == S_GBLK || st == S_CAP || st == S_CPU || st == S_RBLK || st == S_PBLK;
    assign vm_we    = vwe;
    assign vm_blk   = vblk;
    assign vm_addr  = va;
    // write data and lanes straight from their source, which holds them
    // until the write is taken: the capture registers, or the requesting
    // port (checked above in simulation; nds_cart's save port stalls its SPI
    // and sets its fields only before a request). vwd/vbe remain only for
    // that check (synthesis drops them).
    assign vm_be    = st == S_CAP ? (cap_w ? 4'b1111 : cap_a0 ? 4'b1100 : 4'b0011) : vsv ? sv_be : c_be;
    assign vm_wdata = st == S_CAP ? (cap_w ? {cap_d, cap_pd} : {cap_d, cap_d}) : vsv ? sv_wdata : c_wdata;


    assign vramstat = {vramcnt[31] && vramcnt[26:24] == 3'd2, vramcnt[23] && vramcnt[18:16] == 3'd2};
endmodule
