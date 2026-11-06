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
    parameter bit CAP_CHAIN = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [71:0] vramcnt,        // VRAMCNT_A in [7:0] ... VRAMCNT_I in [71:64]
    // CPU port (fabric): request held until ack
    input  logic        c_req,
    input  logic        c_cpu,          // 0 ARM9 map, 1 ARM7 map
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
        r = '0;
        for (int b = 8; b >= 0; b--)
            if (bank_hit(b, vc[b*8 +: 8], v, o)) r = {1'b1, bank_base(b) | (o & bank_mask(b))};
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
    typedef enum logic [2:0] { S_IDLE, S_GBLK, S_GZERO, S_CAP, S_CPU, S_CPUR, S_GRES, S_CRES } st_t;
    st_t         st;
    logic [20:0] res_q;         // the resolver's answer for the request taken (S_GRES, S_CRES)
    logic [2:0]  beat;          // words received (block)
    logic [31:0] w0, w1;               // a beat's two words
    logic [31:0] r_q;                  // the CPU's or the save port's read word
    assign c_rdata = r_q; assign sv_rdata = r_q; assign g_rdata = {w1, w0};
    logic        cap_v;
    logic [17:0] cap_a;
    logic [15:0] cap_d;
    // Capture writes go in pairs: an even halfword is held until its odd
    // partner arrives, and the two leave as one 32-bit write (cap_w, the low
    // half in cap_lo). A line's 256 writes were each a request on the VRAM
    // port, 8 or more clocks apiece against the 3D ring's traffic: the
    // composite pass took 2,000-2,470 clocks instead of 526 and the line
    // went late (MKDS intro's dual-screen 3D, docs/2d-engine.md). An even
    // halfword whose partner does not follow within 4 clocks (a capture that
    // ends there, a changed address) is written alone.
    logic        cap_w, cap_p;
    logic [15:0] cap_lo, cap_pd;
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
    wire         g_go = g_req && bw_left <= 5'd8;

    // One resolver for both, registered: a request waits one clock in S_GRES or
    // S_CRES for its answer (known difference, docs/ds-rules.md). g_ack does not
    // depend on the answer, so the fabric's address and the block ports no longer
    // reach g_ack through the bank match (#1323 -1.01 ns to va, -0.46 to q_blk).
    // A block is taken with g_ack, so its source may change after that (nds_blk_arb).
    logic [20:0] res;
    assign res   = resolve(vramcnt, g_req ? g_view : c_view, g_req ? g_off : c_off);

    assign g_ack = st == S_IDLE && g_go;
    assign bw_acc = st == S_GBLK && vm_ack;
    wire cw_pair = CAP_CHAIN && cap_v && cap_w;
    assign cw_valid = cw_pair;
    assign cw_addr  = {7'd0, cap_a[17:16], cap_a[15:1]};
    assign cw_data  = {cap_d, cap_lo};
    assign cap_ready = !cap_v && (!cap_p || (cap_addr[0] && cap_addr[17:1] == cap_pa));

    always_ff @(posedge clk) begin
        g_rvalid <= 1'b0;
        c_ack <= 1'b0;
        sv_ack <= 1'b0;
        if (cap_we && cap_ready) begin
            if (!cap_addr[0]) begin cap_p <= 1'b1; cap_pa <= cap_addr[17:1]; cap_pd <= cap_data; cap_t <= 3'd0; end
            else begin
                cap_v <= 1'b1; cap_a <= cap_addr; cap_d <= cap_data;
                cap_w <= cap_p; cap_lo <= cap_pd; cap_p <= 1'b0;
            end
        end else if (cap_p) begin
            cap_t <= cap_t + 3'd1;
            if (cap_t == 3'd4 && !cap_v) begin
                cap_v <= 1'b1; cap_a <= {cap_pa, 1'b0}; cap_d <= cap_pd; cap_w <= 1'b0; cap_p <= 1'b0;
            end
        end
        if (cw_pair && cw_ack) cap_v <= 1'b0;
        // block words: pairs to the 2D engine
        bw_left <= bw_left + (bw_acc ? 5'd8 : 5'd0) - (vm_rvalid && bw_left != 5'd0 ? 5'd1 : 5'd0);
        if (vm_rvalid && bw_left != 5'd0) begin
            bw_odd <= !bw_odd;
            if (!bw_odd) w0 <= vm_rdata;
            else begin g_rvalid <= 1'b1; w1 <= vm_rdata; end
        end
        if (st == S_IDLE) res_q <= res;
        if (rst) begin
            st <= S_IDLE; cap_v <= 1'b0; cap_p <= 1'b0; bw_left <= 5'd0; bw_odd <= 1'b0;
        end else case (st)
            S_IDLE: begin
                beat <= 3'd0;
                if (g_req) begin
                    if (g_go) st <= S_GRES;
                end else if (bw_left != 5'd0) ;
                else if (cap_v && !cw_pair) begin
                    // capture writes go to banks A-D through their LCDC addresses
                    st <= S_CAP; va <= {cap_a[17:16], cap_a[15:1]}; vwe <= 1'b1; vblk <= 1'b0;
                    vbe <= cap_w ? 4'b1111 : cap_a[0] ? 4'b1100 : 4'b0011; vwd <= cap_w ? {cap_d, cap_lo} : {cap_d, cap_d};
                end else if (c_req && !c_ack) st <= S_CRES;
                else if (sv_req && !sv_ack) begin
                    st <= S_CPU; va <= sv_addr; vwe <= sv_we; vblk <= 1'b0; vbe <= sv_be; vwd <= sv_wdata;
                    vsv <= 1'b1;
                end
            end
            S_GRES:
                if (res_q[20]) begin
                    st <= S_GBLK; va <= res_q[19:2]; vwe <= 1'b0; vblk <= 1'b1;
                end else if (bw_left == 5'd0) st <= S_GZERO;     // (in order, after the blocks in flight)
            S_CRES:
                if (!res_q[20]) begin c_ack <= 1'b1; r_q <= 32'd0; st <= S_IDLE; end
                else begin
                    st <= S_CPU; va <= res_q[19:2]; vwe <= c_we; vblk <= 1'b0; vbe <= c_be; vwd <= c_wdata;
                    vsv <= 1'b0;
                end
            S_GBLK: if (vm_ack) st <= S_IDLE;     // the words follow (bw_left)
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
    end

    // the capture address is a halfword index in a 128 KiB bank: byte = {bank, idx, 0}
`ifndef ALTERA_RESERVED_QIS
    // the ports' contract a copy-free write would rely on: wdata/be unchanged
    // from the request until the write is taken (simulation check)
    always @(posedge clk)
        if (!rst && st == S_CPU && vwe && (vsv ? (sv_wdata != vwd || sv_be != vbe) : (c_wdata != vwd || c_be != vbe)))
            $display("nds_vram: ERROR: the %s port's write data changed before the write (%m) at %0t", vsv ? "save" : "CPU", $time);
`endif
    assign vm_req   = st == S_GBLK || st == S_CAP || st == S_CPU;
    assign vm_we    = vwe;
    assign vm_blk   = vblk;
    assign vm_addr  = va;
    // write data and lanes straight from their source, which holds them
    // until the write is taken: the capture registers, or the requesting
    // port (checked above in simulation; nds_cart's save port stalls its SPI
    // and sets its fields only before a request). vwd/vbe remain only for
    // that check (synthesis drops them).
    assign vm_be    = st == S_CAP ? (cap_w ? 4'b1111 : cap_a[0] ? 4'b1100 : 4'b0011) : vsv ? sv_be : c_be;
    assign vm_wdata = st == S_CAP ? (cap_w ? {cap_d, cap_lo} : {cap_d, cap_d}) : vsv ? sv_wdata : c_wdata;


    assign vramstat = {vramcnt[31] && vramcnt[26:24] == 3'd2, vramcnt[23] && vramcnt[18:16] == 3'd2};
endmodule
