// DS card interface (docs/phase2-integration.md, "Cartridge"), after
// melonDS NDSCart (Interface::WriteROMCnt/ReadROMData, CartCommon in KEY2
// mode, CartRetail's save SPI) and GBATEK. The card starts in KEY2 data
// mode, as melonDS's direct boot leaves it (KEY2 itself is transparent to
// software, so it is not modelled):
//   0xB7 aaaaaaaa  data read; addresses below 0x8000 read 0x8000 + (a & 0x1FF)
//                  (not while BOOTCTL's raw bit is set, for the boot program)
//   0xB8           chip ID
//   other          zeros
// Registers (owned by the CPU EXMEMCNT bit 11 selects; the other CPU reads
// zeros and its writes are ignored):
//   0x1A0 AUXSPICNT, 0x1A2 AUXSPIDATA, 0x1A4 ROMCTRL, 0x1A8 command,
//   0x1B0 seeds (ignored), 0x4100010 data in
// Data words come from the ROM cache in 16-byte reads (cr_*), one at a time:
// a transfer's words become readable (DRQ, DMA trigger) as their 16 bytes
// arrive. The DMA trigger is ROMCTRL's DRQ bit as a level (melonDS: "the DMA
// trigger is level-sensitive"): a DMA still finishing the previous word
// ignores it, and takes the next word when it is done. melonDS's card bus delays are not modelled; the ROM cache and the
// SD card are slower than a real card anyway. Addresses step by 4 within a
// 4 KiB page (melonDS ROMRead32); word-aligned addresses only.
//
// Save chip on the AUX SPI, as melonDS's CartRetail (EEPROM 512 B, EEPROM
// 8-128 KiB, FLASH) with its memory in external RAM (sv_*), and the
// infrared pass-through byte of Pokemon HG/SS-style carts when `ir` is set.
// Differences from melonDS: FLASH erases fill with 0xFF and page program
// ANDs (as the chips; melonDS writes 0), and an erase runs in the background
// with the status register's busy bit set. An erase ends at the page's or the
// sector's last word, as the chips' aligned erases (melonDS: 256 bytes or 64 KiB
// from any address). ROMCTRL reads back only bits 31 and 23, and the data port
// shows a word only while bit 23 says so (docs/ds-rules.md).
module nds_cart (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,           // 33.51 MHz enable
    input  logic        owner7,         // EXMEMCNT bit 11: the ARM7 owns the slot
    input  logic        raw,            // boot program: no 0x8000 redirect
    input  logic        ir,             // infrared cart: SPI byte 0 is an IR command
    input  logic        dsi,            // DSi-enhanced/exclusive cart (header unit code bit 1): chip ID bit 30
    input  logic [2:0]  save_type,      // melonDS SaveMemType (0 none)
    input  logic [20:0] sv_loaded,      // bytes of the save file the shell loaded (static; docs/saves.md)
    input  logic [31:0] rom_size,
    // I/O
    input  logic        io_req,
    input  logic        io_cpu,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [2:0]  io_reg,         // 0 AUXSPI, 1 ROMCTRL, 2/3 command, 4 data, 5+ seeds
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        irq,            // transfer done, to the owner
    output logic        drq,            // level: a data word is readable (card DMA trigger)
    // ROM cache: 16-byte reads, request held until ack, four words on rvalid
    output logic        cr_req,
    output logic [31:4] cr_addr,
    input  logic        cr_ack,
    input  logic        cr_rvalid,
    input  logic [31:0] cr_rdata,
    // save memory (word address in the save region): request held until ack
    output logic        sv_req,
    output wire         sv_we,
    output logic [19:2] sv_addr,
    output wire  [3:0]  sv_be,
    output wire  [31:0] sv_wdata,
    input  logic        sv_ack,
    input  logic [31:0] sv_rdata
);
    logic [15:0] spicnt;
    logic [7:0]  spidata;
    logic        ro_start, ro_drq;  // ROMCTRL bits 31, 23
    logic [39:0] cmd;               // byte 0 (the command) in [7:0]
    wire  [28:0] rom_l = rom_size[28:0] - 29'd1;    // the last byte: its 4 KiB page is the check past the ROM's end

    // chip ID as melonDS, from the card's size (the next power of two of the file, m = 2^k - 1; only its bits from
    // 19 up matter). melonDS: 0x1 MiB-0x80 MiB: ((m + 1) >> 20) - 1, else 0x100 - ((m + 1) >> 28), in bits 15:8.
    // That is m[27:20] for 20 <= k <= 27, 0xFF, 0xFE for k = 28, 29, else 0x100 (all masks checked against the
    // formula, docs/saves.md "nds_cart area"). A read isn't wrapped at the card's size (docs/ds-rules.md).
    logic [28:19] m;
    always_comb begin
        m[28] = rom_l[28];
        for (int i = 27; i >= 19; i--) m[i] = m[i + 1] | rom_l[i];
    end
    // bit 30 (melonDS: unit code & 2): the DSi-enhanced cards' ID, which such a game stores at boot and checks
    // against later (a melonDS savestate of Pokémon White 2 holds 0x4000FEC2: without the bit the card counts
    // as pulled out and the ARM7 parks in its trap)
    wire [16:0] chip_id = m[19] && !m[27] ? {1'b0, m[27:20], 8'hC2} : m[27] ? {1'b0, 7'h7F, !m[28], 8'hC2} : 17'h1_00C2;

    wire mine = io_cpu == owner7;
    wire rd   = io_req && !io_we && mine;
    wire wr   = io_req && io_we && mine;

    logic [10:0] sp_cnt;            // busy, in 33.51 MHz cycles
    logic        sp_sel;            // chip select held
    logic [3:0]  sp_pos;            // bytes since select (saturates)
    logic [7:0]  sp_cmd, ir_cmd;
    logic [3:0]  sp_st;             // status register: [3:2] WP bits, [1] write enable
    logic [19:0] sp_a;              // address of the command
    logic [7:0]  pf;                // the byte a read returns next
    // an AUX SPI data write is taken in two clocks (timing: fabric address -> er_a/so_op): the
    // write's clock sets busy, sp_cnt, sp_sel and sp_pos; the next one (sb_go) answers the byte
    // sb_v at position sb_p (the SPI busy bit holds the next byte back for >= 64 ticks)
    logic        sb_go;
    logic [7:0]  sb_v;
    logic [3:0]  sb_p;
    // sb_so: the byte starts a save access (the block below sets so_v), from registers only: the erase
    // engine waits for it this clock, so the access still goes before the next erase word
    logic        sb_so;
    always_comb begin
        logic [3:0] sq;
        logic       pass, adr, rdc, wrc;
        sq   = ir ? sb_p - 4'd1 : sb_p;
        pass = !ir || (sb_p != 4'd0 && ir_cmd == 8'h00);
        adr  = sq <= {1'b0, sv_ab};
        rdc  = sp_cmd == 8'h03 || (sv_kind == 2'd1 && sp_cmd == 8'h0B) || (sv_kind == 2'd3 && sp_cmd == 8'h0B && sq != 4'd4);
        wrc  = sp_cmd == 8'h02 || (sv_kind != 2'd3 ? sv_kind == 2'd1 && sp_cmd == 8'h0A : sp_cmd == 8'h0A);
        sb_so = sb_go && pass && sv_kind != 2'd0 && sq != 4'd0 && sp_cmd != 8'h05 && !(sp_cmd == 8'h01 && sv_kind != 2'd3) &&
                sp_cmd != 8'h9F && ((rdc && (sq == {1'b0, sv_ab} || !adr)) || (wrc && !adr && sp_st[1]));
    end
    // save memory accesses: one SPI access (so_*) and the erase engine
    typedef enum logic [1:0] { O_RD, O_WR, O_PRG } op_t;
    logic        so_v, sv_er;
    op_t         so_op;             // (its address is sp_a, unmasked: the request masks it)
    logic [7:0]  so_d;
    wire  [19:0] sp_a1 = sp_a + 20'd1;
    logic [17:0] er_a;              // erase: next word
    logic [18:0] er_a1;             // (an adder in a DSP block, nds_dsp_add: the chip is short of LABs)
    nds_dsp_add #(.W(18)) u_er1 (.clk, .a(er_a), .b(18'd1), .s(er_a1));
    logic [1:0]  er_k;              //        to the end of 0 nothing, 1 the page, 2 the sector, 3 the chip
    logic [2:0]  st_q;              // save type the memory was blanked for
    // save type (melonDS SaveMemType 1-7): 1 EEPROM 512 B, 2-4 EEPROM 8/64/128 KiB,
    // 5-7 FLASH 256/512/1024 KiB
    logic [1:0]  sv_kind;           // 0 none, 1 small EEPROM, 2 EEPROM, 3 FLASH
    logic [2:0]  sv_ab;             // address bytes
    logic [19:0] sv_mask;
    wire  [17:0] sz_w = sv_mask[19:2];
    wire  [18:0] sv_lw = sv_loaded[20:2];           // loaded words (a save file is whole words)
    // the erase's last word: every bit its range covers set
    wire         er_last = &(er_a | ~(er_k == 2'd1 ? 18'h3F : er_k == 2'd2 ? 18'h3FFF : sz_w));
    always_comb begin
        case (save_type)
            3'd1: begin sv_kind = 2'd1; sv_ab = 3'd1; sv_mask = 20'h001FF; end
            3'd2: begin sv_kind = 2'd2; sv_ab = 3'd2; sv_mask = 20'h01FFF; end
            3'd3: begin sv_kind = 2'd2; sv_ab = 3'd2; sv_mask = 20'h0FFFF; end
            3'd4: begin sv_kind = 2'd2; sv_ab = 3'd3; sv_mask = 20'h1FFFF; end
            3'd5: begin sv_kind = 2'd3; sv_ab = 3'd3; sv_mask = 20'h3FFFF; end
            3'd6: begin sv_kind = 2'd3; sv_ab = 3'd3; sv_mask = 20'h7FFFF; end
            3'd7: begin sv_kind = 2'd3; sv_ab = 3'd3; sv_mask = 20'hFFFFF; end
            default: begin sv_kind = 2'd0; sv_ab = 3'd0; sv_mask = 20'h0; end
        endcase
    end
    // ---- ROM transfer
    typedef enum logic [2:0] { R_IDLE, R_FETCH, R_FILL, R_READY, R_END } r_t;
    r_t          rs;
    logic [28:0] raddr;             // next word's card address (DS ROMs are at most 512 MiB)
    logic [13:0] left;              // words left
    logic [1:0]  kind;              // 0 data, 1 chip ID, 2 zeros
    logic [12:0] ra4;               // (adders in DSP blocks, nds_dsp_add)
    logic [14:0] left_1;
    nds_dsp_add #(.W(12)) u_ra4 (.clk, .a(raddr[11:0]), .b(12'd4), .s(ra4));
    nds_dsp_add #(.W(14)) u_lf1 (.clk, .a(left), .b(14'h3FFF), .s(left_1));
    wire         r_past = raddr[28:12] > rom_l[28:12];   // past the file's last 4 KiB page
    // the 16-byte line, written as it arrives and read ahead combinationally
    // (MLAB: one write port, one asynchronous read)
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] q [4];
    logic [1:0]  fw;
    wire  [1:0]  ptr = raddr[3:2];
    always_ff @(posedge clk) if (!rst && rs == R_FILL && cr_rvalid) q[fw] <= cr_rdata;

    always_ff @(posedge clk) begin
        irq <= 1'b0;
        if (rst) begin
            rs <= R_IDLE; ro_start <= 1'b0; ro_drq <= 1'b0; spicnt <= 16'h8000; cmd <= 40'd0;
        end else begin
            // register writes
            if (wr) case (io_reg)
                3'd0: begin
                    logic [15:0] m, v;
                    m = {io_be[1] ? 8'hFF : 8'h00, io_be[0] ? 8'hFF : 8'h00};
                    v = io_wdata[15:0] & m;
                    spicnt <= (spicnt & (~m | 16'h0080)) | (v & 16'hE043);
                end
                3'd1: if (io_be[3]) begin
                    // a transfer starts on bit 31's rising edge with AUXSPICNT in ROM mode
                    ro_start <= io_wdata[31];
                    if (io_wdata[31] && !ro_start && spicnt[15] && !spicnt[13]) begin
                        logic [2:0]  ds;
                        logic [28:0] a;
                        logic [13:0] n;
                        ds = io_wdata[26:24];
                        n = ds == 3'd0 ? 14'd0 : ds == 3'd7 ? 14'd1 : (14'd64 << ds);
                        a = {cmd[12:8], cmd[23:16], cmd[31:24], cmd[39:32]};
                        if (!raw && a < 29'h8000) a = 29'h8000 | (a & 29'h1FF);
                        raddr <= {a[28:2], 2'b00};
                        left <= n;
                        kind <= cmd[7:0] == 8'hB7 ? 2'd0 : cmd[7:0] == 8'hB8 ? 2'd1 : 2'd2;
                        ro_drq <= 1'b0;
                        rs <= n == 14'd0 ? R_END : R_FETCH;
                    end
                end
                3'd2: for (int b = 0; b < 4; b++) if (io_be[b]) cmd[b*8 +: 8] <= io_wdata[b*8 +: 8];
                3'd3: if (io_be[0]) cmd[39:32] <= io_wdata[7:0];
                default: ;
            endcase

            case (rs)
                R_FETCH: begin
                    if (kind != 2'd0 || r_past) begin
                        ro_drq <= 1'b1; rs <= R_READY;
                    end else if (cr_ack) begin
                        fw <= 2'd0; rs <= R_FILL;
                    end
                end
                R_FILL: if (cr_rvalid) begin
                    fw <= fw + 2'd1;
                    if (fw == 2'd3) begin ro_drq <= 1'b1; rs <= R_READY; end
                end
                R_READY: if (rd && io_reg == 3'd4) begin
                    // the CPU (or DMA) took the word
                    raddr <= {raddr[28:12], ra4[11:0]};
                    left <= left_1[13:0];
                    if (left == 14'd1) begin ro_drq <= 1'b0; rs <= R_END; end
                    else if (kind != 2'd0 || ptr == 2'd3) begin ro_drq <= 1'b0; rs <= R_FETCH; end   // (the end of the ROM is checked per 16-byte line)
                end
                R_END: begin
                    ro_start <= 1'b0;
                    if (spicnt[14]) irq <= 1'b1;
                    rs <= R_IDLE;
                end
                default: ;
            endcase
        end
        // ---- save chip
        if (rst) begin
            sp_cnt <= 11'd0; sp_sel <= 1'b0; sp_pos <= 4'd0; spidata <= 8'd0; sp_st <= 4'd0;
            sp_cmd <= 8'd0; ir_cmd <= 8'd0; sp_a <= 20'd0;
            so_v <= 1'b0; sv_req <= 1'b0; er_k <= 2'd0; st_q <= 3'd0; sb_go <= 1'b0;
        end else begin
            if (tick && sp_cnt != 11'd0 && !(sp_cnt == 11'd1 && (so_v || (sv_req && !sv_er)))) begin
                sp_cnt <= sp_cnt - 11'd1;
                if (sp_cnt == 11'd1) spicnt[7] <= 1'b0;
            end
            // releasing chip select by clearing bit 13
            if (wr && io_reg == 3'd0 && io_be[1] && !io_wdata[13]) begin sp_sel <= 1'b0; sp_pos <= 4'd0; end
            // memory: one access at a time; SPI accesses first, then the erase
            if (sv_req) begin
                if (sv_ack) begin
                    sv_req <= 1'b0;
                    if (!sv_er) begin
                        logic [7:0] b;
                        b = sv_rdata[sp_a[1:0]*8 +: 8];
                        if (so_op == O_RD) begin pf <= b; so_v <= 1'b0; end
                        else if (so_op == O_PRG) begin so_op <= O_WR; so_d <= so_d & b; end
                        else begin so_v <= 1'b0; sp_a <= sp_a1; end   // written: the next byte's address
                    end
                end
            end else if (so_v) begin
                sv_req <= 1'b1; sv_er <= 1'b0; sv_addr <= sp_a[19:2] & sz_w;
            end else if (er_k != 2'd0 && !sb_so) begin   // (sb_so: the byte's access goes first, as so_v did a clock earlier)
                sv_req <= 1'b1; sv_er <= 1'b1; sv_addr <= er_a;
                // (er_a is always inside the chip: every load is masked or below the size)
                er_a <= er_a1[17:0] & sz_w;
                if (er_last) er_k <= 2'd0;
            end
            // a new save type: the chip starts blank (all 0xFF) after the bytes of
            // the loaded save file, as melonDS (a file shorter than the chip is
            // padded with 0xFF; none at all is a blank chip)
            if (save_type != st_q) begin
                st_q <= save_type;
                if (save_type != 3'd0) begin
                    if (|(sv_lw & ~{1'b0, sz_w})) er_k <= 2'd0;   // (sz_w is 2^k - 1)
                    else begin er_a <= sv_lw[17:0]; er_k <= 2'd3; end
                end
            end
            sb_go <= 1'b0;
            if (wr && io_reg == 3'd0 && io_be[2] && spicnt[15] && spicnt[13] && !spicnt[7]) begin
                logic [3:0]  p;
                p = sp_sel ? sp_pos : 4'd0;
                sb_go <= 1'b1; sb_v <= io_wdata[23:16]; sb_p <= p;
                spicnt[7] <= 1'b1;
                sp_cnt <= 11'd64 << spicnt[1:0];
                sp_sel <= spicnt[6];
                sp_pos <= spicnt[6] ? (p == 4'hF ? p : p + 4'd1) : 4'd0;
            end
            if (sb_go) begin
                logic [7:0]  v, r;
                logic [3:0]  p, sq;
                logic [19:0] a;
                logic        pass;
                v = sb_v;
                p = sb_p;
                r = 8'hFF;
                pass = 1'b1;
                sq = p;
                if (ir) begin
                    // byte 0: IR command, as melonDS's CartRetailIR: 0x00 passes the
                    // rest through to the save chip, 0x08 (ID) answers 0xAA; any
                    // other command (the IR transceiver itself, not emulated)
                    // never reaches the save chip and answers 0x00 (melonDS leaves
                    // that answer undefined; 0 reads as "nothing received")
                    sq = p - 4'd1;
                    if (p == 4'd0) begin ir_cmd <= v; r = 8'h00; pass = 1'b0; end
                    else if (ir_cmd != 8'h00) begin r = ir_cmd == 8'h08 ? 8'hAA : 8'h00; pass = 1'b0; end
                end
                if (pass) begin
                    a = sp_a;
                    if (sv_kind == 2'd0) r = 8'h00;              // no save chip
                    else if (sq == 4'd0) begin
                        if (v == 8'h04) begin sp_st[1] <= 1'b0; r = 8'h00; end
                        else if (v == 8'h06) begin sp_st[1] <= 1'b1; r = 8'h00; end
                        else begin sp_cmd <= v; sp_a <= 20'd0; end
                    end else begin
                        // address bytes, then data; reads return the byte fetched ahead
                        logic adr, rdc, wrc;
                        adr = sq <= {1'b0, sv_ab};
                        rdc = sp_cmd == 8'h03 || (sv_kind == 2'd1 && sp_cmd == 8'h0B) ||
                              (sv_kind == 2'd3 && sp_cmd == 8'h0B && sq != 4'd4);
                        wrc = sp_cmd == 8'h02 || (sv_kind != 2'd3 ? sv_kind == 2'd1 && sp_cmd == 8'h0A : sp_cmd == 8'h0A);
                        if (sp_cmd == 8'h05) r = {sv_kind == 2'd1 ? 4'hF : 4'h0, sp_st[3:1], er_k != 2'd0};
                        else if (sp_cmd == 8'h01 && sv_kind != 2'd3) begin
                            if (sq == 4'd1) sp_st[3:2] <= v[3:2];
                            r = 8'h00;
                        end else if (sp_cmd == 8'h9F) r = 8'hFF;
                        else if (rdc || wrc || (sv_kind == 2'd3 && (sp_cmd == 8'hD8 || sp_cmd == 8'hDB || sp_cmd == 8'h0B))) begin
                            r = 8'h00;
                            if (adr) begin
                                a = (sv_kind == 2'd1) ? {11'd0, sp_cmd[3], v} : {sp_a[11:0], v};
                                sp_a <= a;
                            end else if (sv_kind == 2'd3 && sp_cmd == 8'h0B && sq == 4'd4) ;   // dummy byte
                            else if (rdc) begin
                                r = pf;
                                a = sp_a1;
                                sp_a <= a;
                            end else if (wrc) begin
                                if (sp_st[1]) begin
                                    so_v <= 1'b1; so_op <= (sv_kind == 2'd3 && sp_cmd == 8'h02) ? O_PRG : O_WR;
                                    so_d <= v;
                                end
                            end
                            // fetch the next byte a read returns
                            if (rdc && (sq == {1'b0, sv_ab} || !adr)) begin
                                so_v <= 1'b1; so_op <= O_RD;
                            end
                            // erases: 64 KiB sector / 256-byte page from the address (filled with 0xFF)
                            if (sq == 4'd3 && sp_st[1] && (sp_cmd == 8'hD8 || sp_cmd == 8'hDB)) begin
                                er_a <= a[19:2] & sz_w;
                                er_k <= sp_cmd == 8'hD8 ? 2'd2 : 2'd1;
                            end
                        end else r = 8'hFF;
                    end
                end
                spidata <= r;
            end
        end
    end
    // the save request's data, byte enables and write: views of the access (an SPI access's so_op,
    // sp_a and so_d stay put until it is answered: the SPI busy bit holds the next byte back
    // until then; the address stays a register, as an erase command may move er_a meanwhile)
    assign sv_we    = sv_er || so_op == O_WR;
    assign sv_be    = sv_er ? 4'hF : 4'b0001 << sp_a[1:0];
    assign sv_wdata = sv_er ? 32'hFFFF_FFFF : {4{so_d}};
    assign drq     = ro_drq;
    assign cr_req  = rs == R_FETCH && kind == 2'd0 && !r_past;
    assign cr_addr = {3'd0, raddr[28:4]};

    // ---- reads
    always_ff @(posedge clk) begin
        logic [31:0] r;
        r = 32'd0;
        if (rd) case (io_reg)
            3'd0: r = {8'd0, (spicnt[15] && spicnt[13] && !spicnt[7]) ? spidata : 8'd0, spicnt};
            3'd1: r = {ro_start, 7'd0, ro_drq, 23'd0};
            3'd4: r = kind == 2'd0 ? (r_past ? 32'hFFFF_FFFF : q[ptr]) : kind == 2'd1 ? {1'b0, dsi, 13'd0, chip_id} : 32'd0;
            default: r = 32'd0;
        endcase
        io_rdata <= r;
    end
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation (+spitrace): every AUX SPI byte, the byte position in the
    // chip select, the byte written and the answer (two clocks after: sb_go)
    logic   tr_on = 1'b0, tr_v = 1'b0, tr_v0 = 1'b0;
    logic [7:0] tr_b = 8'd0;
    logic [3:0] tr_p = 4'd0;
    longint tr_cyc = 0;
    initial tr_on = $test$plusargs("spitrace");
    always_ff @(posedge clk) begin
        tr_cyc <= tr_cyc + 1;
        if (tr_cyc[19:0] == 20'd0) tr_on <= $test$plusargs("spitrace");
        tr_v <= tr_v0; tr_v0 <= 1'b0;
        if (!rst && wr && io_reg == 3'd0 && io_be[2] && spicnt[15] && spicnt[13] && !spicnt[7]) begin
            tr_v0 <= 1'b1; tr_b <= io_wdata[23:16]; tr_p <= sp_sel ? sp_pos : 4'd0;
        end
        if (tr_on && tr_v)
            $display("spi %0d: pos %0d out %h in %h hold %b ir %b ircmd %h cmd %h type %0d st %h",
                     tr_cyc, tr_p, tr_b, spidata, sp_sel, ir, ir_cmd, sp_cmd, save_type, sp_st);
    end
`endif
endmodule
