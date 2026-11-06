// Bus fabric of the integrated DS system (docs/phase2-integration.md,
// "Bus fabric"). Everything the CPUs and DMA reach outside the ARM9's TCMs
// and caches and the ARM7's fast RAMs goes through here, one access at a
// time:
//   masters, highest priority first: DMA (both CPUs' channels, nds_sys),
//   the ARM9 bus (arm9_mem), the ARM7's slow path (nds_arm7_port), the
//   sound engine's sample fetches (ARM7 map, reads only)
//   targets, decoded per CPU map (melonDS NDS::ARM9Read32/ARM7Read32):
//     main RAM (external, through a 16-byte line buffer per master class),
//     shared WRAM, ARM7 WRAM, BIOS9, BIOS7, boot ROM (port B of their
//     RAMs), I/O (nds_io), palette and OAM (CPU copies here, writes also go
//     to the 2D engine), VRAM (nds_vram), the GBA slot (empty)
// Every master holds its request until ack; read data comes with ack.
// DMA halfwords: data in [15:0] both ways (sys_dma's convention).
//
// Main RAM: reads fetch the aligned 16 bytes into the requesting class's
// line buffer (ARM9, ARM7, DMA), so a cache-line fill (eight word reads) or
// sequential ARM7 fetches cost two or four external reads. Any write to
// main RAM invalidates the buffers holding its line.
module nds_fabric #(
    // 1: no OAM copy here: a CPU OAM read waits in S_GO for the 2D engine's OAM read port (oam_cre/oam_cgnt,
    // the word in oam_cq; nds_top OAM_SHARE); 0: the copy u_oamc
    parameter integer OAM_SHARE = 0,
    // 1: the boot ROM is in the external SRAM at byte 0x1E000 (loaded with the BIOS, nds_top BOOT_SRAM),
    // read-only like the BIOS; 0: the M10K boot ROM on port B (boot_q)
    parameter integer BOOT_SRAM = 0,
    parameter integer MR_BLOCK = 0,     // 1: the ARM9's 32-byte main-RAM blocks (a9_n8; docs/phase2-integration.md, burst path)
    parameter integer A7_FIRST = 1,     // 1: an ARM7 main-RAM request goes before an ARM9 one (DS, hwref run 30; ds-rules)
    // 1: an ARM7 request goes before an ARM9 DMA unit. On the DS the ARM7's I/O
    // is on the ARM7's own bus, which ARM9 DMA never holds, and on main RAM the
    // ARM7 side has priority over the ARM9 side (A7_FIRST, hwref run 30), where
    // ARM9 DMA is. Without this a long ARM9 DMA held the ARM7 off its registers
    // and main RAM for up to 300K clocks (gsdd-title). ARM7 DMA still goes
    // first, as it owns the ARM7's bus
    parameter integer A7_IO = 0,
    // 1: a DMA unit (dm_unit) reads main RAM and writes dm_dst in one grant,
    // one ack (docs/phase2-integration.md "DMA_UNIT")
    parameter integer DMA_FAST = 0,
    // 1 (with DMA_FAST): while a unit's write waits for its target, the next
    // source quad is read into a second DMA line on the idle main-RAM port, as
    // the sound side path does (docs/phase2-integration.md "DMA read-ahead")
    parameter integer DMA_RA = 0,
    // DMA units start no closer than the DS's measured rate for their route
    // (0: no floor). In eighths of a clk_sys: the GX FIFO 80 (5.00 system
    // cycles a word, hwref run 35), other I/O and the GX command ports 34
    // (2.07-2.08, run 35), VRAM 51 (3.15, run 4), palette and OAM 52 (3.2,
    // run 4). Any nonzero value turns the table on
    parameter integer DMA_B8 = 0,       // 1 (with DMA_RA, MR_BLOCK): DMA lines of 32 bytes read as one PSRAM burst (~38 clk, not 2 x ~33)
    parameter integer DMA_PACE = 0,
    // the GX FIFO route's floor in eighths of a clk_sys. The DS's cost is per FIFO entry (run 37, ds-rules
    // row 52): 2.08 system cycles a word with 0-1 entries, 5.00 with 4 packed; 80 (10 clk) is the 4-entry
    // case; 34 (4.25 clk, as the I/O route) the 0-1-entry case, 98% of MKDS's GX DMA words (2% have 2)
    parameter integer DMA_PACE_GX = 80,
    // 1 (with DMA_FAST): a unit's word to the GX FIFO or a command port
    // (0x04000400-0x040005FF) is posted straight to the geometry engine
    // (dx_valid) instead of through nds_io: the unit is done once the engine
    // takes it, and an ARM9 access to 0x04000320-0x04000FFF waits until the
    // engine has the word (docs/phase2-integration.md "DMA GX posting")
    parameter integer DMA_GX = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [1:0]  wramcnt,
    input  logic        pb_busy,        // the ARM7 data side has the RAMs' port B this cycle
    // DMA (nds_sys)
    input  logic        dm_req,
    input  logic        dm_we,
    input  logic        dm_cpu,
    input  logic        dm_size32,
    input  logic [31:0] dm_addr,
    input  logic        dm_unit,            // DMA_FAST: dm_addr (main RAM) is read and the word written to dm_dst
    input  logic        dm_more,            // DMA_RA: the run goes past this unit's quad
    input  logic [31:0] dm_dst,
    output logic        dx_valid,           // DMA_GX: io_addr/io_wdata to the geometry engine
    input  logic        dx_ready,
    input  logic        dx_idle,            // DMA_GX: no posted word waits in the engine's port
    input  logic [31:0] dm_wdata,
    output logic        dm_ack,
    output logic [31:0] dm_rdata,
    // ARM9 bus (arm9_mem)
    input  logic        a9_req,
    input  logic        a9_we,
    input  logic [31:0] a9_addr,
    input  logic [3:0]  a9_be,
    input  logic [3:0]  a9_tmr,             // the ARM9's request writes its timer n (one-hot, a register: cpu_domain b9_tmr)
    input  logic [31:0] a9_wdata,
    output logic        a9_ack,
    output logic [31:0] a9_rdata,
    // MR_BLOCK: a9_n8 asks for the 32-byte line of a9_addr. A read returns
    // words 0..7 on a9_rvalid (a9_ack with the last), from any target: main
    // RAM as one block, anything else (BIOS, WRAM, VRAM, ...: arm9_mem's
    // fills are n8 wherever the line is cached) as 8 single reads. A write
    // (main RAM only) takes a word per a9_wnext pulse (a9_wdata shows the
    // next one the cycle after) and acks with the eighth
    input  logic        a9_n8,
    output logic        a9_rvalid,
    output logic        a9_wnext,
    // ARM7 slow path (nds_arm7_port)
    input  logic        a7_req,
    input  logic        a7_we,
    input  logic [31:0] a7_addr,
    input  logic [3:0]  a7_be,
    input  logic [31:0] a7_wdata,
    output logic        a7_ack,
    output logic [31:0] a7_rdata,
    // sound sample fetches and capture writes (ARM7 map, words)
    input  logic        sn_req,
    input  logic        sn_we,
    input  logic [31:0] sn_addr,
    input  logic [31:0] sn_wdata,
    output logic        sn_ack,
    output logic [31:0] sn_rdata,
    // main RAM (external): request held until ack; reads return the four
    // words of the aligned 16 bytes on rvalid
    output logic        mr_req,
    output logic        mr_we,
    output logic [21:2] mr_addr,
    output logic [3:0]  mr_be,
    output logic [31:0] mr_wdata,
    input  logic        mr_ack,
    input  logic        mr_rvalid,
    input  logic [31:0] mr_rdata,
    // a 32-byte block (MR_BLOCK): a read returns its 8 words on rvalid; a
    // write takes mr_wdata on each mr_wnext pulse (8), then acks
    output logic        mr_n8,
    input  logic        mr_wnext,
    // shared WRAM, ARM7 WRAM, BIOS7, BIOS9 (0x1C000) in the external SRAM (nds_fr_arb; SRAM
    // byte addresses as nds_arm7_port lists them): request held until done
    output logic        fx_req,
    output logic        fx_we,
    output logic [17:2] fx_addr,
    output logic [3:0]  fx_be,
    output logic [31:0] fx_wdata,
    input  logic        fx_done,
    input  logic [31:0] fx_rdata,
    // RAM port B (address/write this cycle, data next cycle)
    output logic [10:0] boot_addr,
    input  logic [31:0] boot_q,
    output logic [31:0] ram_wdata,
    // I/O hub: one-cycle request, ack (with data) one or more cycles later
    output logic        io_req,
    output logic        io_pre,     // io_req without the GX hold: for what only reads (the timers' visit), off g_busy's path
    output logic        io_cpu,
    output logic        io_we,
    output logic [3:0]  io_be,
    output logic [23:2] io_addr,
    output logic [31:0] io_wdata,
    input  logic        io_ack,
    input  logic [31:0] io_rdata,
    // VRAM controller CPU port: request held until ack
    output logic        vr_req,
    output logic        vr_cpu,
    output logic        vr_we,
    output logic [23:2] vr_addr,
    output logic [3:0]  vr_be,
    output logic [31:0] vr_wdata,
    input  logic        vr_ack,
    input  logic [31:0] vr_rdata,
    // palette and OAM writes to the 2D engine (the OAM's CPU copy is kept
    // here; palette reads come from the 2D engine's copy 0, pal_cq: word
    // po_waddr, the clock after)
    input  logic [31:0] pal_cq,
    output logic        oam_cre,            // OAM_SHARE: the read of word po_waddr, held until oam_cgnt
    input  logic        oam_cgnt,
    input  logic [31:0] oam_cq,
    output logic        pal_we,
    output logic        oam_we,
    output logic [8:0]  po_waddr,
    output logic [31:0] po_wdata,
    output logic [3:0]  po_be,
    // write monitor (simulation traces): one pulse per completed write
    output logic        mon_we,
    output logic [1:0]  mon_master,     // 0 DMA, 1 ARM9, 2 ARM7, 3 sound
    output logic        mon_cpu,
    output logic [31:0] mon_addr,
    output logic [3:0]  mon_be,
    output logic [31:0] mon_wdata,
    // timer register writes, decoded on the grant edge from the request
    // being latched and so a register in the cycle the I/O request goes out
    // (S_GO): bit {cpu, index} for a write to 0x4000100 + 4 * index. The
    // same decode as nds_sys's (timing: #519, the address into the timers)
    output logic [7:0]  io_tmr_oh
);
    // ---------------------------------------------------------------- request
    typedef enum logic [3:0] {
        T_NONE, T_MAIN, T_SWRAM, T_WRAM7, T_BIOS9, T_BIOS7, T_BOOT, T_IO,
        T_PAL, T_OAM, T_VRAM, T_GBA
    } tgt_t;
    typedef enum logic [2:0] { S_IDLE, S_GO, S_RAM, S_MAIN, S_FILL, S_WAIT, S_DONE, S_FR } st_t;

    st_t         st;
    logic [1:0]  mst;           // master
    logic        cpu, we;
    logic [31:0] addr, wdata, rdata;
    logic [3:0]  be;
    tgt_t        tgt;
    logic [12:0] sw_a;          // shared WRAM word index for this map
    logic        sw_ok;

    // decode of the latched request
    always_comb begin
        tgt = T_NONE;
        sw_ok = 1'b1;
        sw_a = addr[14:2];
        // shared WRAM views (melonDS MapSharedWRAM)
        if (!cpu) case (wramcnt)
            2'd0: sw_a = addr[14:2];
            2'd1: sw_a = {1'b1, addr[13:2]};
            2'd2: sw_a = {1'b0, addr[13:2]};
            default: sw_ok = 1'b0;
        endcase else case (wramcnt)
            2'd0: sw_ok = 1'b0;
            2'd1: sw_a = {1'b0, addr[13:2]};
            2'd2: sw_a = {1'b1, addr[13:2]};
            default: sw_a = addr[14:2];
        endcase
        // (the BIOS's and the boot ROM's mirrors: the top bit or an all-zero region picks them, addr[15] which)
        if (!cpu) begin
            if (addr[31]) tgt = addr[15] ? T_BOOT : T_BIOS9;     // 0xFFFF0000, 0xFFFF8000-0xFFFF9FFF
            else case (addr[30:24])
                7'h02: tgt = T_MAIN;
                7'h03: tgt = sw_ok ? T_SWRAM : T_NONE;
                7'h04: tgt = T_IO;
                7'h05: tgt = T_PAL;
                7'h06: tgt = T_VRAM;
                7'h07: tgt = T_OAM;
                7'h08, 7'h09, 7'h0A: tgt = T_GBA;
                default: tgt = T_NONE;
            endcase
        end else begin
            case (addr[31:24])
                8'h00: tgt = addr[15] ? T_BOOT : T_BIOS7;        // 0x00000000-0x00003FFF, 0x00008000-0x00009FFF
                8'h02: tgt = T_MAIN;
                8'h03: tgt = (addr[23] || !sw_ok) ? T_WRAM7 : T_SWRAM;
                8'h04: tgt = T_IO;                         // 0x04800000 wifi: nds_io's D_WIFI
                8'h06: tgt = T_VRAM;
                8'h08, 8'h09, 8'h0A: tgt = T_GBA;
                default: tgt = T_NONE;
            endcase
        end
    end

    // byte writes by the ARM9 to palette, VRAM and OAM are ignored
    wire byte_w   = be == 4'b0001 || be == 4'b0010 || be == 4'b0100 || be == 4'b1000;
    wire drop_w9  = we && !cpu && mst != 2'd0 && byte_w && (tgt == T_PAL || tgt == T_OAM || tgt == T_VRAM);

    // ---------------------------------------------------------------- line buffers
    logic [1:0]   cls;           // 0 ARM9, 1 ARM7 and sound, 2 DMA (3: DMA_RA's second DMA line)
    logic         dsl;           // DMA_RA: the DMA's line is slot 3
    assign cls = mst == 2'd0 ? {1'b1, dsl} : mst == 2'd1 ? 2'd0 : 2'd1;
    logic [3:0]   lb_v;
    logic [21:4]  lb_tag [4];
    // each line's tag against the latched address: the hit and the write
    // invalidations share these compares
    logic [3:0]   t_eq5, t_eq;
    always_comb for (int c = 0; c < 4; c++) begin
        t_eq5[c] = lb_tag[c][21:5] == addr[21:5];
        t_eq[c]  = t_eq5[c] && ((DMA_B8 != 0 && c >= 2) || lb_tag[c][4] == addr[4]);
    end
    wire          lb_hit = lb_v[cls] && t_eq[cls];
    logic [2:0]   fw;            // fill word (blocks: 0..7)
    logic         blk;           // the access is an ARM9 32-byte block
    logic [2:0]   bk;            // block write: words taken
    logic         rv9;           // block read: a word to the ARM9 this cycle
    // the lines' words in an MLAB at {class, word}: read with the address
    // being granted (S_IDLE), so a hit's word is there in S_GO
    logic [DMA_B8 != 0 ? 4 : 3:0] lb_ra;
    logic [31:0]  lb_q;
    logic [1:0]   g_cls;
    logic [1:0]   g_w;
    logic         ra_fill;       // DMA_RA: a read-ahead's words arriving
    logic [2:0]   ra_fw;
    logic         ra_sl;         // its slot (2 + ra_sl)
    logic [21:4]  ra_q;          // its quad
    // DMA_B8: the two DMA lines hold 32 bytes each, words {1, slot, word}; the others keep 16 at {0, 0, class, word}
    generate if (DMA_B8 != 0) begin : g_lb8
        gpu2d_mlab #(.W(32), .AW(5), .STYLE("M10K")) u_lb (.clk, .we((st == S_FILL && mr_rvalid && !blk) || (ra_fill && mr_rvalid)),
            .waddr(ra_fill ? {1'b1, ra_sl, ra_fw} : cls[1] ? {1'b1, cls[0], fw} : {2'b00, cls[0], fw[1:0]}), .wdata(mr_rdata),
            .raddr(lb_ra), .rdata(lb_q));
    end else begin : g_lb4
        gpu2d_mlab #(.W(32), .AW(4), .STYLE("M10K")) u_lb (.clk, .we((st == S_FILL && mr_rvalid && !blk) || (ra_fill && mr_rvalid)),
            .waddr(ra_fill ? {1'b1, ra_sl, ra_fw[1:0]} : {cls, fw[1:0]}), .wdata(mr_rdata),
            .raddr(lb_ra), .rdata(lb_q));
    end endgenerate

    // ---------------------------------------------------------------- CPU palette/OAM copies
    logic [31:0] pal_q, oam_q;
    wire po_w = (st == S_GO) && we && !drop_w9;
    assign pal_q = pal_cq;
    assign oam_cre = OAM_SHARE != 0 && st == S_GO && tgt == T_OAM && !we;
    generate if (OAM_SHARE == 0) begin : g_oamc
        nds_sdp_ram #(.AW(9)) u_oamc (.clk, .we((po_w && tgt == T_OAM) ? be : 4'd0), .waddr(addr[10:2]),
            .wdata(wdata), .raddr(addr[10:2]), .rdata(oam_q));
    end else begin : g_oams
        assign oam_q = oam_cq;
    end endgenerate
    assign pal_we   = po_w && tgt == T_PAL;
    assign oam_we   = po_w && tgt == T_OAM;
    assign po_waddr = addr[10:2];
    assign po_wdata = wdata;
    assign po_be    = be;

    // ---------------------------------------------------------------- RAM ports
    assign boot_addr  = addr[12:2];
    assign ram_wdata  = wdata;
    // SRAM: the target and address as S_GO found them (BIOS7 is read-only)
    assign fx_req   = st == S_FR;
    assign fx_we    = we && tgt_q != T_BIOS7 && tgt_q != T_BIOS9 && tgt_q != T_BOOT;
    assign fx_addr  = tgt_q == T_WRAM7 ? {2'b00, addr[15:2]} : tgt_q == T_SWRAM ? {3'b010, sw_a} :
                      tgt_q == T_BIOS9 ? {6'b011100, addr[11:2]} :
                      BOOT_SRAM != 0 && tgt_q == T_BOOT ? {5'b01111, addr[12:2]} : {4'b0110, addr[13:2]};
    assign fx_be    = be;
    assign fx_wdata = wdata;

    // ---------------------------------------------------------------- state machine
    // DMA first; the CPUs and sound take turns (the last one served goes
    // behind the others), so a CPU running from slow memory can't starve
    // the other
    logic [3:0] grant;
    // DMA_RA: the DMA's request is in slot 3 (else slot 2: a hit there, or a fill)
    wire [21:4] dm_q = {dm_addr[21:5], DMA_B8 == 0 && dm_addr[4]};      // (DMA_B8: a DMA line's tag has bit 4 clear)
    wire d3 = DMA_RA != 0 && lb_v[3] && lb_tag[3] == dm_q;
    wire dm_hit = !dm_we && dm_addr[31:24] == 8'h02 && ((lb_v[2] && lb_tag[2] == dm_q) || d3);
    logic [1:0] last;
    logic sd_busy;              // the side path below is serving the sound engine
    logic ra_busy;              // DMA_RA: a read-ahead has main RAM
    // DMA_PACE: clocks since the last unit started (saturating), and the
    // whole clocks the next one waits for: DMA_PACE/8, plus one when the
    // eighths carried over (52: 6, 7, 6, 7 ...)
    logic [3:0] pg, plim;
    logic [2:0] pfr;
    wire  pc_hold = DMA_PACE != 0 && pg < plim;
    typedef enum logic [1:0] { SD_IDLE, SD_MAIN, SD_FILL, SD_ACK } sd_t;
    sd_t         sd_st;
    logic [1:0]  sd_fw;
    logic [31:0] sd_rdata;
    // DMA_PACE gap (dm_req held off by the pace): the DMA's own CPU stays out
    wire pc_gap = dm_req && pc_hold;
    wire a9_g = a9_req && !(pc_gap && !dm_cpu);
    wire a7_g = a7_req && !(pc_gap && dm_cpu);
    wire a7_first = A7_FIRST != 0 && a7_req && a9_req && a7_addr[31:24] == 8'h02 && a9_addr[31:24] == 8'h02;
    always_comb begin
        grant = 4'd0;
        if (sd_busy) ;
        // DMA_RA: during a read-ahead only a DMA read that hits a line goes
        // (it needs the line buffer, not the main-RAM port)
        else if (ra_busy) begin if (dm_req && dm_hit) grant[0] = !pc_hold; end
        else if (A7_IO != 0 && a7_req && !(dm_req && dm_cpu)) grant[2] = 1'b1;
        // DMA_PACE: the gap between units delays only the DMA and its own CPU
        // (which waits for the whole DMA on the DS, ds-rules); sound and the
        // other CPU are granted in it (#867's freezes: sound waits of 7K clk)
        else if (dm_req && !pc_hold) grant[0] = 1'b1;
        // on the DS the ARM7 has main RAM first: its back-to-back loads keep the
        // ARM9's line fills out for as long as they last (run 30: 2,887 against
        // 44.9 cycles a fill), and the ARM7 hardly slows (1 %)
        else if (a7_first && a7_g) grant[2] = 1'b1;
        else case (last)
            2'd1:    if (a7_g) grant[2] = 1'b1; else if (sn_req) grant[3] = 1'b1; else if (a9_g) grant[1] = 1'b1;
            2'd2:    if (sn_req) grant[3] = 1'b1; else if (a9_g) grant[1] = 1'b1; else if (a7_g) grant[2] = 1'b1;
            default: if (a9_g) grant[1] = 1'b1; else if (a7_g) grant[2] = 1'b1; else if (sn_req) grant[3] = 1'b1;
        endcase
    end
    always_comb begin
        g_cls = grant[0] ? {1'b1, d3} : grant[1] ? 2'd0 : 2'd1;
        g_w   = grant[0] ? dm_addr[3:2] : grant[1] ? a9_addr[3:2] : grant[2] ? a7_addr[3:2] : sn_addr[3:2];
        if (DMA_B8 != 0) lb_ra = st == S_IDLE ? (grant[0] ? {1'b1, d3, dm_addr[4:2]} : {2'b00, g_cls[0], g_w})
                                              : (cls[1] ? {1'b1, cls[0], addr[4:2]} : {2'b00, cls[0], addr[3:2]});
        else lb_ra = st == S_IDLE ? {g_cls, g_w} : {cls, addr[3:2]};
    end

    logic done;                 // pulse in S_DONE
    // DMA_FAST: the DMA unit in flight (its read first, then its write to
    // dm_dst: sys_dma holds it until the unit's ack, so it isn't copied)
    logic        u;
    logic        ura;           // DMA_RA: the unit's run continues past its quad
    wire         ugx = DMA_GX != 0 && dm_dst[27:24] == 4'h4 && dm_dst[12:9] == 4'd2;   // DMA_GX: the unit's destination is the GX FIFO or a command port
    logic        ugw;           // DMA_GX: S_GO is that unit's write (or, DMA_GX bit 1, the ARM9's)
    // DMA_GX bit 1: an ARM9 write to the GX FIFO or a command port (0x04000400-5FF) is posted the same way: S_GO hands
    // it to the engine's port (dx_valid) and the ARM9 is answered in S_DONE, without the I/O request and its io_ack
    // (#1591's kh-heavy: about 10 clocks a write before). Later ARM9 accesses to the 3D registers wait for it (gx_hold)
    wire         a9gx = (DMA_GX & 2) != 0 && a9_we && a9_addr[27:24] == 4'h4 && a9_addr[23:12] == 12'h000 && a9_addr[11:9] == 3'b010;
    wire         d_line = DMA_B8 != 0 && mst == 2'd0;                    // the access fills a 32-byte DMA line
    wire         f_this = d_line ? fw == addr[4:2] : fw[1:0] == addr[3:2];   // the fill's word is the access's
    wire [21:4]  uq_n = DMA_B8 != 0 ? {addr[21:5] + 17'd1, 1'b0} : addr[21:4] + 18'd1;   // the quad/line after this one
    logic        io_go2;        // the clock before was S_GO too, with this addr, be and wdata
    // (!u: a DMA_FAST unit's S_GO is its main RAM read, and a line-buffer hit reloads S_GO with the write's addr and
    // wdata; without it io_pre fired a clock after them, inside the SDC's 2-clock fabric multicycle)
    always_ff @(posedge clk) io_go2 <= st == S_GO && !u;
    // DMA_GX: an ARM9 access to the 3D registers waits while a posted word does
    wire gx_hold = DMA_GX != 0 && !dx_idle && !cpu && !addr[12] && (addr[11:10] != 2'd0 || addr[9:5] >= 5'h19);
    logic [21:4] uq;            // DMA_RA: the quad after the unit's source
    // DMA_RA: the read-ahead's state (its machine is below the sound side path)
    typedef enum logic [1:0] { RA_IDLE, RA_MAIN, RA_FILL } ra_t;
    ra_t ra_st;
    wire ra_has = (lb_v[{1'b1, dsl}] && lb_tag[{1'b1, dsl}] == uq) || (lb_v[{1'b1, !dsl}] && lb_tag[{1'b1, !dsl}] == uq);
    wire ra_start = DMA_RA != 0 && ra_st == RA_IDLE && sd_st == SD_IDLE && !(sn_req && sn_addr[31:24] == 8'h02)
                  && (st == S_WAIT || (st == S_GO && ugw && !dx_ready) || (st == S_IDLE && pc_gap && grant == 4'd0)) && mst == 2'd0 && ura && !ra_has;
    assign ra_busy = ra_st != RA_IDLE;
    assign ra_fill = ra_st == RA_FILL;
    logic io_sent;
    logic mr_sent;
    tgt_t tgt_q;
    // a block read outside main RAM: its words one by one, through S_DONE
    wire  bl_word = blk && !we && tgt_q != T_MAIN;
    wire  bl_more = bl_word && addr[4:2] != 3'd7;

    // the timer write the grant latches (as S_IDLE below): the ARM9 brings its
    // own one-hot (a9_tmr, decoded where its write buffer is pushed: only the
    // write buffer's drain writes I/O), so its address mux never reaches
    // io_tmr_oh (#618/#649/#681: arm9_mem st -> io_tmr_oh, -1.689 ns); the
    // other masters are decoded here from their request
    logic [31:0] g_addr;
    logic        g_we, g_cpu;
    always_comb begin
        if (grant[0]) begin
            g_we = dm_we; g_cpu = dm_cpu; g_addr = dm_size32 ? {dm_addr[31:2], 2'b00} : {dm_addr[31:1], 1'b0};
        end else if (grant[2]) begin
            g_we = a7_we; g_cpu = 1'b1; g_addr = a7_addr;
        end else begin
            g_we = sn_we; g_cpu = 1'b1; g_addr = {sn_addr[31:2], 2'b00};
        end
    end
    wire [7:0] g_tmr = grant[1] ? {4'd0, a9_tmr}
                     : (g_we && g_addr[31:12] == 20'h04000 && g_addr[11:4] == 8'h10) ? 8'd1 << {g_cpu, g_addr[3:2]} : 8'd0;

    logic [7:0] tmr_p;                 // (the grant's decode, a clock before the I/O request's clock)
    always_ff @(posedge clk) begin
        io_tmr_oh <= tmr_p;
        tmr_p <= 8'd0;
        if (rst) begin
            st <= S_IDLE;
            last <= 2'd0;
            lb_v <= 4'd0;
            io_sent <= 1'b0;
            u <= 1'b0;
            ugw <= 1'b0;
            dsl <= 1'b0;
            ura <= 1'b0;
        end else case (st)
            S_IDLE: if (|grant) begin
                st <= S_GO;
                tmr_p <= g_tmr;
                if (!grant[0]) last <= grant[1] ? 2'd1 : grant[2] ? 2'd2 : 2'd3;
                if (!grant[1]) blk <= 1'b0;
                u <= DMA_FAST != 0 && grant[0] && dm_unit; 
                if (grant[0]) begin dsl <= d3; ura <= DMA_RA != 0 && dm_unit && dm_more; end
                ugw <= 1'b0;
                if (grant[0]) begin
                    mst <= 2'd0; cpu <= dm_cpu; we <= dm_we;
                    addr <= dm_size32 ? {dm_addr[31:2], 2'b00} : {dm_addr[31:1], 1'b0};
                    be <= dm_size32 ? 4'hF : dm_addr[1] ? 4'b1100 : 4'b0011;
                    wdata <= dm_size32 ? dm_wdata : {dm_wdata[15:0], dm_wdata[15:0]};
                end else if (grant[1]) begin
                    mst <= 2'd1; cpu <= 1'b0; we <= a9_we; addr <= a9_addr; be <= a9_be; wdata <= a9_wdata;
                    ugw <= a9gx;
                    blk <= MR_BLOCK != 0 && a9_n8;
                    if (MR_BLOCK != 0 && a9_n8) begin addr[4:0] <= 5'd0; be <= 4'hF; end
                end else if (grant[2]) begin
                    mst <= 2'd2; cpu <= 1'b1; we <= a7_we; addr <= a7_addr; be <= a7_be; wdata <= a7_wdata;
                end else begin
                    mst <= 2'd3; cpu <= 1'b1; we <= sn_we; addr <= {sn_addr[31:2], 2'b00}; be <= 4'hF; wdata <= sn_wdata;
                end
            end
            S_GO: begin
                tgt_q <= tgt;   // (held while waiting for port B)
                unique case (tgt)
                    T_MAIN: begin
                        if (blk) begin
                            // both 16-byte halves leave the line buffers
                            if (we) for (int c = 0; c < 4; c++) if (t_eq5[c]) lb_v[c] <= 1'b0;
                            bk <= 3'd0;
                            st <= S_MAIN;
                        end else if (we) begin
                            for (int c = 0; c < 4; c++) if (t_eq[c]) lb_v[c] <= 1'b0;
                            st <= S_MAIN;
                        end else if (lb_hit) begin
                            rdata <= lb_q;
                            st <= S_DONE;
                            if (u) begin   // DMA_FAST: the unit's write, with the word just read
                                uq <= uq_n; addr <= dm_dst; we <= 1'b1; be <= 4'hF; ugw <= ugx; wdata <= lb_q; u <= 1'b0; st <= S_GO;
                            end
                        end else begin
                            lb_v[cls] <= 1'b0;
                            st <= S_MAIN;
                        end
                    end
                    T_SWRAM, T_WRAM7: st <= drop_w9 ? S_DONE : S_FR;
                    T_BIOS7, T_BIOS9: st <= we ? S_DONE : S_FR;
                    T_BOOT: if (BOOT_SRAM != 0) st <= we ? S_DONE : S_FR;
                            else if (!pb_busy) st <= S_RAM;
                    T_PAL: st <= S_RAM;
                    T_OAM: if (OAM_SHARE == 0 || we || oam_cgnt) st <= S_RAM;
                    T_IO: if (ugw) begin if (dx_ready) st <= S_DONE; end     // DMA_GX: posted
                          else if (!gx_hold && io_go2) st <= S_WAIT;
                    T_VRAM: st <= drop_w9 ? S_DONE : S_WAIT;
                    // the empty slot reads all ones, whichever CPU EXMEMCNT gives it (docs/ds-rules.md)
                    T_GBA: begin rdata <= 32'hFFFF_FFFF; st <= S_DONE; end
                    default: begin rdata <= 32'd0; st <= S_DONE; end
                endcase
            end
            S_RAM: begin
                unique case (tgt_q)
                    T_BOOT:  rdata <= boot_q;
                    T_PAL:   rdata <= pal_q;
                    default: rdata <= oam_q;
                endcase
                st <= S_DONE;
            end
            S_MAIN: begin
                if (blk && we && mr_wnext) bk <= bk + 3'd1;
                if (mr_ack) begin
                    if (we) st <= S_DONE;
                    else begin st <= S_FILL; fw <= 3'd0; end
                end
            end
            S_FILL: if (mr_rvalid && blk) begin
                rdata <= mr_rdata;
                fw <= fw + 3'd1;
                if (fw == 3'd7) st <= S_DONE;
            end else if (mr_rvalid) begin
                if (f_this) rdata <= mr_rdata;
                fw <= fw + 3'd1;
                if (d_line ? fw == 3'd7 : fw[1:0] == 2'd3) begin
                    lb_v[cls] <= 1'b1; lb_tag[cls] <= {addr[21:5], !d_line && addr[4]};
                    st <= S_DONE;
                    if (u) begin   // DMA_FAST: the unit's write (its word may be this beat)
                        uq <= uq_n; addr <= dm_dst; we <= 1'b1; be <= 4'hF; ugw <= ugx; u <= 1'b0; st <= S_GO;
                        wdata <= f_this ? mr_rdata : rdata;
                    end
                end
            end
            S_WAIT: begin
                if (tgt_q == T_IO) begin
                    if (io_ack) begin rdata <= io_rdata; st <= S_DONE; end
                end else if (vr_ack) begin rdata <= vr_rdata; st <= S_DONE; end
            end
            S_FR: if (fx_done) begin rdata <= fx_rdata; st <= S_DONE; end
            default:                         // S_DONE
                if (bl_more) begin addr[4:2] <= addr[4:2] + 3'd1; st <= S_GO; end
                else st <= S_IDLE;
        endcase
        // DMA_RA: the read-ahead's line is invalid while it fills, then valid
        if (ra_start) lb_v[{1'b1, !dsl}] <= 1'b0;
        if (ra_fill && mr_rvalid && ra_fw == (DMA_B8 != 0 ? 3'd7 : 3'd3)) begin lb_v[{1'b1, ra_sl}] <= 1'b1; lb_tag[{1'b1, ra_sl}] <= ra_q; end
        // the sound side path's writes leave no stale line behind: they drop
        // every line (sound writes main RAM only for capture; a dropped line
        // is refilled, so data is unchanged, and four tag compares go)
        if (sd_st == SD_MAIN && mr_ack && sn_we)
            for (int c = 0; c < 4; c++) if (lb_tag[c] == {sn_addr[21:5], !(DMA_B8 != 0 && c >= 2) && sn_addr[4]}) lb_v[c] <= 1'b0;
        // a write elsewhere to a line being filled leaves it invalid
        if (st == S_FILL && mr_rvalid && fw[1:0] == 2'd3) begin
            // (main RAM writes are serialised through this machine, so none
            // can land during a fill)
        end
    end

    // ---------------------------------------------------------------- sound side path
    // While the machine waits for an I/O or VRAM answer, the sound engine's
    // request to main RAM is served on the idle main-RAM port. (A CPU write
    // to VRAM can wait behind the 2D engine for hundreds of microseconds:
    // #107's log showed 457 late sound steps and a 300 us memory wait in
    // KH's movie, heard as an occasional buzz.) A CPU access to a
    // sound register waits for the engine, and the engine answers registers
    // only between channels, which can need its memory access: without this
    // the two waited for each other (NSMB in the SOUND build, frame 85).
    // Requests elsewhere (WRAM) still wait for the machine.
    // (also while a posted GX word waits for the geometry engine: DMA_GX's
    // backpressure held sound out for up to 6.9K clk in mkds-race)
    wire sd_start = sd_st == SD_IDLE && !ra_busy && (st == S_WAIT || (st == S_GO && ugw && !dx_ready))
                  && sn_req && sn_addr[31:24] == 8'h02;
    assign sd_busy = sd_st != SD_IDLE;
    always_ff @(posedge clk) begin
        if (rst) sd_st <= SD_IDLE;
        else case (sd_st)
            SD_IDLE: if (sd_start) sd_st <= SD_MAIN;
            SD_MAIN: if (mr_ack) begin
                if (sn_we) sd_st <= SD_ACK;
                else begin sd_st <= SD_FILL; sd_fw <= 2'd0; end
            end
            SD_FILL: if (mr_rvalid) begin
                if (sd_fw == sn_addr[3:2]) sd_rdata <= mr_rdata;
                sd_fw <= sd_fw + 2'd1;
                if (sd_fw == 2'd3) sd_st <= SD_ACK;
            end
            default: sd_st <= SD_IDLE;      // SD_ACK
        endcase
    end
    wire sd_on = sd_st == SD_MAIN || sd_st == SD_FILL;

    // ---------------------------------------------------------------- DMA read-ahead (DMA_RA)
    // While a DMA unit's write waits for its target (I/O, the GX FIFO, VRAM),
    // the next source quad is read into the DMA line the unit isn't using, on
    // the idle main-RAM port; the next unit then hits it. Grants wait while it
    // runs (as for the sound side path), so no main-RAM write can pass it; the
    // sound side path goes first and doesn't start during it.
    always_ff @(posedge clk) begin
        if (rst) ra_st <= RA_IDLE;
        else case (ra_st)
            RA_IDLE: if (ra_start) begin
                ra_st <= RA_MAIN; ra_sl <= !dsl; ra_q <= uq;   // (uq can move while it runs: DMA hits go on)
            end
            RA_MAIN: if (mr_ack) begin ra_st <= RA_FILL; ra_fw <= 3'd0; end
            default: if (mr_rvalid) begin           // RA_FILL
                ra_fw <= ra_fw + 3'd1;
                if (ra_fw == (DMA_B8 != 0 ? 3'd7 : 3'd3)) ra_st <= RA_IDLE;
            end
        endcase
    end
    wire ra_on = ra_st == RA_MAIN || ra_st == RA_FILL;

    // DMA_PACE: the floor between unit starts
    wire [6:0] pace = dm_dst[31:24] == 8'h04 ? (dm_dst[23:6] == 18'h00010 ? 7'(DMA_PACE_GX) : 7'd34)   // 0x04000400-43F: the GX FIFO
                    : dm_dst[31:24] == 8'h06 ? 7'd51 : 7'd52;
    always_ff @(posedge clk)
        if (rst || DMA_PACE == 0) begin pg <= 4'd15; plim <= 4'd0; pfr <= 3'd0; end
        else if (st == S_IDLE && grant[0] && dm_unit) begin
            pg <= 4'd1;
            pfr  <= pfr + 3'(pace & 7);
            plim <= 4'(pace >> 3) + 4'(({1'b0, pfr} + 4'(pace & 7)) >> 3);
        end else if (pg != 4'd15) pg <= pg + 4'd1;

    // I/O: one-cycle request on entry to S_WAIT
    // (pocket-now: the second clock of S_GO, so addr, be, wdata -> the I/O registers are 2-clock paths in the SDC;
    // #1322/#1323 addr -> sys_timers, rtc, powcnt1 -0.43 ns; known difference: an I/O access +1 clock)
    assign io_pre   = st == S_GO && tgt == T_IO && !ugw && io_go2;
`ifndef SYNTHESIS
    // the SDC's fabric multicycle (scripts/build_ds.sh): an I/O request a clock after addr, be, wdata, we or cpu changed
    logic [31:0] mc_addr, mc_wd;
    logic [3:0]  mc_be;
    logic        mc_we, mc_cpu;
    always_ff @(posedge clk) begin
        mc_addr <= addr; mc_wd <= wdata; mc_be <= be; mc_we <= we; mc_cpu <= cpu;
        if (!rst && io_pre && {mc_addr, mc_wd, mc_be, mc_we, mc_cpu} != {addr, wdata, be, we, cpu})
            $error("nds_fabric: io_pre a clock after its request changed (addr %08x was %08x, wdata %08x was %08x): the 2-clock fabric multicycle",
                   addr, mc_addr, wdata, mc_wd);
    end
`endif
    assign io_req   = io_pre && !gx_hold;
    assign dx_valid = st == S_GO && ugw && dx_ready;
    assign io_cpu   = cpu;
    assign io_we    = we;
    assign io_be    = be;
    assign io_addr  = addr[23:2];
    assign io_wdata = wdata;

    assign vr_req   = st == S_WAIT && tgt_q == T_VRAM;
    assign vr_cpu   = cpu;
    assign vr_we    = we;
    assign vr_addr  = addr[23:2];
    assign vr_be    = be;
    assign vr_wdata = wdata;

    assign mr_req   = st == S_MAIN || sd_st == SD_MAIN || ra_st == RA_MAIN;
    assign mr_we    = sd_on ? sn_we : !ra_on && we;
    assign mr_addr  = sd_on ? sn_addr[21:2] : ra_on ? {ra_q, 2'b00} : addr[21:2];
    assign mr_be    = sd_on || ra_on ? 4'hF : be;
    assign mr_wdata = sd_on ? sn_wdata : blk ? a9_wdata : wdata;
    assign mr_n8    = !sd_on && (DMA_B8 != 0 && ra_on || !ra_on && (blk || DMA_B8 != 0 && d_line && !we));
    assign a9_wnext = st == S_MAIN && blk && we && mr_wnext;
    always_ff @(posedge clk) rv9 <= st == S_FILL && blk && mr_rvalid;
    assign a9_rvalid = rv9 || (done && bl_word);

    // answers
    assign done     = st == S_DONE;
    wire [31:0] hw  = addr[1] ? {16'd0, rdata[31:16]} : {16'd0, rdata[15:0]};
    assign dm_ack   = done && mst == 2'd0;
    assign dm_rdata = be == 4'hF ? rdata : hw;
    assign a9_ack   = done && mst == 2'd1 && !bl_more;
    assign a9_rdata = rdata;
    assign a7_ack   = done && mst == 2'd2;
    assign a7_rdata = rdata;
    assign sn_ack   = (done && mst == 2'd3) || sd_st == SD_ACK;
    assign sn_rdata = sd_st == SD_ACK ? sd_rdata : rdata;

    wire   sd_mon     = sd_st == SD_ACK && sn_we;
    wire   bk_mon     = a9_wnext;                 // a block write's words, one by one
    assign mon_we     = (done && we && !blk) || sd_mon || bk_mon;
    assign mon_master = sd_mon ? 2'd3 : mst;
    assign mon_cpu    = sd_mon ? 1'b1 : cpu;
    assign mon_addr   = sd_mon ? {sn_addr[31:2], 2'b00} : bk_mon ? {addr[31:5], bk, 2'b00} : addr;
    assign mon_be     = sd_mon ? 4'hF : bk_mon ? 4'hF : be;
    assign mon_wdata  = sd_mon ? sn_wdata : bk_mon ? a9_wdata : wdata;
endmodule
