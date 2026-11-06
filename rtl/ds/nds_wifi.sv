// SPDX-License-Identifier: GPL-3.0-or-later
// The DS WiFi block (ARM7 0x04800000-0x0480FFFF) without radio traffic:
// written to behave as melonDS's Wifi.cpp (docs/wifi.md), not derived from
// its code. Games that start the wireless (HG/SS's main menu with Mystery
// Gift unlocked, ...) see a working transceiver that never hears anyone.
//
// Modelled: register storage with melonDS's write masks and read-only ports,
// W_ID, the MAC/BSSID reset values, W_ModeReset's defaults, the interrupt
// flags (W_IF/W_IE/W_IFSet, the ARM7's IRQ 24 on a 0 -> non-zero change of
// IF & IE), power (POWCNT2 bit 1 and W_PowerUS start the timers; W_PowerState,
// W_PowerForce, W_PowerDownCtrl, W_PowerTX, W_ModeWEP's power modes; IRQ11
// and the 2048 us power-up), the microsecond counter in 8 us steps with
// W_USCompare (IRQ14), the beacon counters (IRQ13/14), W_PreBeacon (IRQ15),
// W_ContentFree, W_CmdCount, W_Random, the baseband serial port (registers
// with melonDS's fixed values) and the type 2 RF serial port, and CMDStat's
// clear on read. Not modelled: transmit and receive (W_RXCnt, the TX slots
// and W_TXBufDataWrite store their values only; no frame is ever sent or
// received), RXBufDataRead's auto-increment.
//
// Area: one register file (512 x 16, one M10K) holds every register of
// 0x000-0x3FF that melonDS keeps in IOPORT, the microsecond counter and the
// beacon/listen counters included; flops hold only what logic needs every
// clock (IF/IE, the power bits, the prescaler, W_Random, W_CmdCount). One
// sequencer does the CPU's accesses and the timers' 8 us steps (melonDS's
// USTimer/MSTimer, in its order) with one 16-bit temporary and one adder;
// a step takes up to ~40 clocks of the 536 between steps. The WiFi RAM
// (0x4000-0x5FFF), registers 0x400-0xFFF and the baseband and RF register
// files live in SDRAM at byte 0x0F0000 through nds_vram's lowest-priority
// save port (wm_*). All of it is cleared after reset, as melonDS's Reset.
// The ARM7 waits for wf_ack, as for the DS's WiFi wait states.
`default_nettype none
module nds_wifi (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,           // 33.513982 MHz enable
    input  logic        power,          // POWCNT2 bit 1
    input  logic        id_lite,        // W_ID: 1 DS Lite (0xC340), 0 DS (0x1440)
    // the ARM7's accesses (nds_io D_WIFI): one per wf_req, answered by wf_ack
    input  logic        wf_req,
    input  logic        wf_we,
    input  logic [3:0]  wf_be,
    input  logic [23:2] wf_addr,
    input  logic [31:0] wf_wdata,
    output logic        wf_ack,
    output wire  [31:0] wf_rdata,       // valid with wf_ack, until the next wf_req
    output logic        irq,            // pulse: the ARM7's IF bit 24
    // memory (nds_vram's save port, VRAM-port word addresses)
    output logic        wm_req,
    output logic        wm_we,
    output logic [20:2] wm_addr,
    output logic [3:0]  wm_be,
    output logic [31:0] wm_wdata,
    input  logic        wm_ack,
    input  logic [31:0] wm_rdata
);
    // SDRAM layout (VRAM-port byte addresses)
    localparam logic [20:0] M_RAM = 21'h0F_0000;     // 8 KiB WiFi RAM
    localparam logic [20:0] M_IO  = 21'h0F_2000;     // registers 0x400-0xFFF (offset = register)
    localparam logic [20:0] M_BB  = 21'h0F_3000;     // 256 baseband registers, one byte each
    localparam logic [20:0] M_RF  = 21'h0F_3100;     // 32 RF registers, 18 bits in a word each
    localparam logic [20:0] M_END = 21'h0F_3180;

    // ---------------------------------------------------------------- flops
    logic [15:0] r_if, r_ie;
    logic        irq_q;
    logic        mode_reset;            // 0x004 bit 0
    logic [2:0]  mode_wep;              // 0x006 bits 2:0 (the power mode)
    logic        power_us0;             // 0x036 bit 0
    logic [1:0]  power_tx;              // 0x038
    logic [3:0]  ps_b;                  // W_PowerState bits 9, 8, 1, 0 (the others are always 0)
    logic [1:0]  pf_b;                  // W_PowerForce bits 15, 0
    logic [1:0]  pdc;                   // 0x048
    logic [1:0]  trx_power;             // 0x034
    logic [3:0]  rf_status;             // 0x214 (0x19C follows it)
    logic        us_cnt_en, us_cmp_en, cmd_cnt_en, block_b14;
    logic [11:0] until_on;              // us left until the transceiver is on (0 = none)
    logic [31:0] us_acc;                // 8 us prescaler: + 1e6 per tick, a step at 8 * 33,513,982
    logic        step_pend;
    logic [10:0] random;
    logic [15:0] cmd_q;                 // W_CmdCount's counter (melonDS: microseconds, val * 10)
    logic [3:0]  cmd_r;                 // as 10 * cmd_q + cmd_r: no divider for its (n + 9) / 10 read
    logic        pt_go, pe_go;          // power unit requests: timer (pt_arg 1 on, 2 off, 0) and engine (0)
    logic [1:0]  pt_arg;
    wire         power_on = power && !power_us0;
    wire  [15:0] power_state = {6'd0, ps_b[3:2], 6'd0, ps_b[1:0]};

    // ---------------------------------------------------------------- register file (0x000-0x3FF)
    (* ramstyle = "M10K" *) logic [15:0] rfile [0:511];
    logic        rf_we;
    logic [8:0]  rf_wa, rf_ra;
    logic [15:0] rf_wd, rf_q;
    always_ff @(posedge clk) begin
        if (rf_we) rfile[rf_wa] <= rf_wd;
        rf_q <= rfile[rf_ra];
    end

    // ---------------------------------------------------------------- helpers
    function automatic logic bb_ro(input logic [7:0] i);
        bb_ro = i == 8'h00 || (i >= 8'h0D && i <= 8'h12) || i == 8'h16 || i == 8'h17 || i == 8'h18 ||
                i == 8'h19 || i == 8'h1A || i == 8'h27 || i == 8'h4D || i == 8'h5D || i == 8'h5E ||
                i == 8'h5F || i == 8'h60 || i == 8'h61 || i == 8'h64 || i == 8'h66 || i >= 8'h69;
    endfunction
    function automatic logic [7:0] bb_fixed(input logic [7:0] i);
        bb_fixed = i == 8'h00 ? 8'h6D : i == 8'h5D ? 8'h01 : i == 8'h64 ? 8'hFF : 8'h00;
    endfunction
    function automatic logic read_only(input logic [11:0] i);
        case (i)
            12'h000, 12'h034, 12'h044, 12'h054, 12'h098, 12'h0B0, 12'h0B6, 12'h0B8, 12'h15C, 12'h15E,
            12'h180, 12'h19C, 12'h1A8, 12'h1AC, 12'h1C4, 12'h210, 12'h214, 12'h268: read_only = 1'b1;
            default: read_only = 1'b0;
        endcase
    endfunction
    // melonDS's write masks for stored registers
    function automatic logic [15:0] wmask(input logic [11:0] i, input logic [15:0] v);
        case (i)
            12'h004, 12'h0E8, 12'h0EA: wmask = v & 16'h0001;
            12'h006: wmask = v & 16'h007F;
            12'h028: wmask = v & 16'h000F;
            12'h02A: wmask = v & 16'h07FF;
            12'h030: wmask = v & 16'hFF0E;
            12'h036, 12'h038: wmask = v & 16'h0003;
            12'h040: wmask = v & 16'h8001;
            12'h058, 12'h062, 12'h068, 12'h074: wmask = v & 16'h1FFE;
            12'h056, 12'h05A, 12'h05C, 12'h064, 12'h06C, 12'h076: wmask = v & 16'h0FFF;
            12'h0B4: wmask = 16'h0000;
            12'h0F0: wmask = v & 16'hFC00;
            12'h184: wmask = v & 16'h413F;
            default: wmask = v;
        endcase
    endfunction
    function automatic logic [7:0] status_pins(input logic [3:0] s);
        case (s)
            4'd0, 4'd9: status_pins = 8'h04;
            4'd1, 4'd5: status_pins = 8'h84;
            4'd3, 4'd8: status_pins = 8'h46;
            4'd6:       status_pins = 8'h87;
            default:    status_pins = 8'h00;
        endcase
    endfunction
    // W_ModeReset's defaults (bit 14: 0-24 and 30; bit 13: 25-29), as (register, value)
    function automatic logic [27:0] def_entry(input logic [4:0] i);
        case (i)
            5'd0:  def_entry = {12'h008, 16'h0000};
            5'd1:  def_entry = {12'h00A, 16'h0000};
            5'd2:  def_entry = {12'h018, 16'h0000};
            5'd3:  def_entry = {12'h01A, 16'h0000};
            5'd4:  def_entry = {12'h01C, 16'h0000};
            5'd5:  def_entry = {12'h020, 16'h0000};
            5'd6:  def_entry = {12'h022, 16'h0000};
            5'd7:  def_entry = {12'h024, 16'h0000};
            5'd8:  def_entry = {12'h028, 16'h0000};
            5'd9:  def_entry = {12'h02A, 16'h0000};
            5'd10: def_entry = {12'h02C, 16'h0707};
            5'd11: def_entry = {12'h02E, 16'h0000};
            5'd12: def_entry = {12'h050, 16'h4000};
            5'd13: def_entry = {12'h052, 16'h4800};
            5'd14: def_entry = {12'h084, 16'h0000};
            5'd15: def_entry = {12'h0BC, 16'h0001};
            5'd16: def_entry = {12'h0D0, 16'h0401};
            5'd17: def_entry = {12'h0D4, 16'h0001};
            5'd18: def_entry = {12'h0E0, 16'h0008};
            5'd19: def_entry = {12'h0EC, 16'h3F03};
            5'd20: def_entry = {12'h194, 16'h0000};
            5'd21: def_entry = {12'h198, 16'h0000};
            5'd22: def_entry = {12'h1A2, 16'h0001};
            5'd23: def_entry = {12'h224, 16'h0003};
            5'd24: def_entry = {12'h230, 16'h0047};
            5'd25: def_entry = {12'h056, 16'h0000};
            5'd26: def_entry = {12'h0C0, 16'h0000};
            5'd27: def_entry = {12'h0C4, 16'h0000};
            5'd28: def_entry = {12'h1A4, 16'h0000};
            5'd29: def_entry = {12'h278, 16'h000F};
            default: def_entry = {12'h006, 16'h0000};       // 30: W_ModeWEP
        endcase
    endfunction
    // the register file's reset image: W_ID, MAC/BSSID 0xFFFF, W_PowerUS 1, else 0
    function automatic logic [15:0] init_val(input logic [8:0] i);
        if (i == 9'd0) init_val = id_lite ? 16'hC340 : 16'h1440;
        else if ((i >= 9'h00C && i <= 9'h00E) || (i >= 9'h010 && i <= 9'h012)) init_val = 16'hFFFF;
        else if (i == 9'h01B) init_val = 16'h0001;                       // 0x036
        else init_val = 16'h0000;
    endfunction

    // W_PowerState etc. after a change: melonDS UpdatePowerStatus (1 on, 0 no change, -1 off)
    typedef struct packed {
        logic [1:0]  trx;
        logic [3:0]  ps;
        logic [3:0]  st;
        logic [11:0] uo;
        logic        irq11;
    } pw_t;
    function automatic pw_t power_status(input logic on_in, input logic off_in);
        pw_t o;
        logic [1:0] cur, req;
        logic       on, off;
        o.trx = trx_power; o.ps = ps_b; o.st = rf_status; o.uo = until_on; o.irq11 = 1'b0;
        cur = {!ps_b[3], trx_power == 2'd1};
        req = cur; on = on_in; off = off_in;
        if (pf_b[1]) req = pf_b[0] ? 2'd0 : 2'd3;
        else if (!mode_reset) req = 2'd0;
        else begin
            if (!on_in && !off_in) begin
                if (ps_b[3] && ps_b[1]) on = 1'b1;                       // (ps & 0x0202) == 0x0202
                else if (!ps_b[3] && ps_b[0]) off = 1'b1;                // (ps & 0x0201) == 0x0001
            end
            if (off && pdc[0]) off = 1'b0;
            if (on) req = 2'd3;
            else if (off) req = pdc != 0 ? 2'd3 : 2'd0;
            else if (pdc[1]) req = 2'd3;
        end
        if (req != cur) begin
            if (req[0]) begin if (!cur[0]) begin o.trx = 2'd1; o.st = 4'd1; end end
            else begin o.trx = 2'd0; o.st = 4'd9; end
            if (req[1]) begin
                o.ps[2] = 1'b1;                                          // bit 8
                if (!cur[1] && until_on == 0) begin o.uo = 12'd2048; o.irq11 = 1'b1; end
            end else begin o.ps[0] = 1'b0; o.ps[2] = 1'b0; o.ps[3] = 1'b1; o.uo = 12'd0; end
        end
        return o;
    endfunction

    // ---------------------------------------------------------------- the sequencer
    typedef enum logic [5:0] {
        S_INIT_RF, S_INIT_MEM, S_INIT_REG, S_IDLE,
        // CPU accesses
        S_HALF, S_RFREAD, S_RFOUT, S_MEMWAIT, S_DEF, S_W2, S_RMW0, S_RMW1, S_BBW0, S_BBWR, S_BBRD, S_RFX, S_RFW0, S_RFW, S_NEXT,
        // the 8 us step
        S_T0, S_U0, S_U1, S_UC0, S_UC1, S_B0, S_B1, S_B2, S_B3, S_M0,
        S_C1, S_C2, S_C3,
        S_I0, S_I1, S_I2, S_I3, S_I4, S_I5, S_I6, S_I7, S_I8,
        S_BCR, S_BC0, S_BC1, S_BZR, S_BZ0, S_BZ1, S_BZ2, S_BZ3,
        S_D1R, S_D1W, S_D1, S_D0, S_E0, S_E1
    } st_t;
    st_t         st, i14_ret;           // (i14_ret: where SetIRQ14 returns to)
    logic        req_pend;              // a CPU access waits while a step runs
    logic        a_we;
    logic [3:0]  a_be;
    logic [23:2] a_addr;
    logic [31:0] a_wd, a_rd;
    logic        a_h;                   // the halfword being done (0 low, 1 high)
    logic [8:0]  init_i;
    logic [20:2] init_m;
    logic [4:0]  def_i;
    logic        def_13;
    logic [15:0] t;                     // the temporary
    logic [9:0]  usp;                   // the counter's low 10 bits after this step
    logic [1:0]  uc_k;                  // the counter word a carry goes into
    logic        cmp_eq;
    logic [1:0]  ck;                    // the compare's word
    logic        i14_src1;              // SetIRQ14 from the beacon count (1) or the compare / forced (0)
    logic        i14_reset_b1;          // source != 2: BeaconCount1 = BeaconInterval first
    logic [11:0] w2_ix;                 // a second register write (W_ModeReset's 0x27C)
    logic [15:0] w2_v;
    logic [1:0]  rmw_op;                // 0x0AC/0x0AE on W_TXReqRead: 1 clear, 2 set

    assign wf_rdata = a_rd;
    wire  [14:0] off    = {a_addr[14:2], a_h, 1'b0};  // the halfword's offset, & 0x7FFE as melonDS
    wire         in_ram = off >= 15'h4000 && off < 15'h6000;
    wire         in_ff  = off >= 15'h2000 && off < 15'h4000;
    wire         beyond = a_addr[23:16] != 8'h80;      // 0x04810000 and up
    wire  [11:0] ix     = off[11:0];
    wire  [1:0]  hbe    = a_h ? a_be[3:2] : a_be[1:0];
    wire  [15:0] wv     = a_h ? a_wd[31:16] : a_wd[15:0];

    wire act = |(r_if & r_ie);
    assign irq = act && !irq_q;

    // the register-file port, one access per clock: these set the read address and the write
    task automatic rd(input logic [11:0] r);
        rf_ra <= r[9:1];
    endtask
    task automatic wr(input logic [11:0] r, input logic [15:0] v);
        rf_we <= 1'b1; rf_wa <= r[9:1]; rf_wd <= v;
    endtask
    task automatic put(input logic [15:0] v);
        if (a_h) a_rd[31:16] <= v; else a_rd[15:0] <= v;
    endtask

    always_ff @(posedge clk) begin
        logic [15:0] nif;
        rf_we <= 1'b0;
        wf_ack <= 1'b0;
        irq_q <= act;
        nif = r_if;
        if (rst) begin
            st <= S_INIT_RF; init_i <= 9'd0; init_m <= M_RAM[20:2]; req_pend <= 1'b0;
            r_if <= 16'd0; r_ie <= 16'd0; mode_reset <= 1'b0; mode_wep <= 3'd0; power_us0 <= 1'b1;
            power_tx <= 2'd0; ps_b <= 4'd0; pf_b <= 2'd0; pdc <= 2'd0; trx_power <= 2'd0; rf_status <= 4'd0;
            us_cnt_en <= 1'b0; us_cmp_en <= 1'b0; cmd_cnt_en <= 1'b0; block_b14 <= 1'b0;
            until_on <= 12'd0; us_acc <= 32'd0; step_pend <= 1'b0; random <= 11'd1;
            cmd_q <= 16'd0; cmd_r <= 4'd0; pt_go <= 1'b0; pe_go <= 1'b0; pt_arg <= 2'd0;
            wm_req <= 1'b0; irq_q <= 1'b0;
        end else begin
            // ---- the prescaler: an 8 us step is due (the sequencer runs it next)
            if (power_on && tick) begin
                if (us_acc + 32'd1_000_000 >= 32'd268_111_856) begin
                    us_acc <= us_acc + 32'd1_000_000 - 32'd268_111_856; step_pend <= 1'b1;
                end else us_acc <= us_acc + 32'd1_000_000;
            end
            // ---- the power unit: one request at a time, the timer's first
            if (pt_go || pe_go) begin
                pw_t o;
                o = power_status(pt_go && pt_arg == 2'd1, pt_go && pt_arg == 2'd2);
                ps_b <= o.ps; trx_power <= o.trx; rf_status <= o.st; until_on <= o.uo;
                if (o.irq11) nif[11] = 1'b1;
                if (pt_go) pt_go <= 1'b0; else pe_go <= 1'b0;
            end
            // ---- a CPU access, latched until the sequencer takes it
            if (wf_req) begin
                req_pend <= 1'b1;
                a_we <= wf_we; a_be <= wf_be; a_addr <= wf_addr; a_wd <= wf_wdata;
            end

            case (st)
                // ---------------- reset: the register file's image, then SDRAM cleared
                S_INIT_RF: begin
                    rf_we <= 1'b1; rf_wa <= init_i; rf_wd <= init_val(init_i);
                    init_i <= init_i + 9'd1;
                    if (init_i == 9'd511) st <= S_INIT_MEM;
                end
                S_INIT_MEM: begin
                    wm_req <= 1'b1; wm_we <= 1'b1; wm_addr <= init_m; wm_be <= 4'hF; wm_wdata <= 32'd0;
                    st <= S_INIT_REG;
                end
                S_INIT_REG: if (wm_ack) begin
                    wm_req <= 1'b0;
                    init_m <= init_m + 19'd1;
                    st <= init_m + 19'd1 == M_END[20:2] ? S_IDLE : S_INIT_MEM;
                end
                S_IDLE: begin
                    if (step_pend) begin step_pend <= 1'b0; st <= S_T0; end
                    else if (req_pend) begin
                        req_pend <= 1'b0; a_rd <= 32'd0;
                        a_h <= a_be[1:0] == 2'b00;
                        st <= S_HALF;
                    end
                end

                // ---------------- CPU accesses, one halfword at a time
                S_HALF: begin
                    st <= S_NEXT;
                    rd(ix);
                    if (hbe == 2'b00 || beyond) ;
                    else if (in_ff) begin if (!a_we) put(16'hFFFF); end
                    else if (in_ram) begin
                        if (!a_we || hbe == 2'b11) begin                      // byte writes are ignored, as melonDS
                            wm_req <= 1'b1; wm_we <= a_we; wm_addr <= {M_RAM[20:13], off[12:2]};
                            wm_be <= off[1] ? 4'b1100 : 4'b0011; wm_wdata <= {wv, wv};
                            st <= S_MEMWAIT;
                        end
                    end else if (a_we) begin
                        if (hbe != 2'b11 || read_only(ix)) ;
                        else case (ix)
                            12'h060, 12'h070: ;     // RXBufDataRead / TXBufDataWrite: frames not modelled, nothing stored
                            12'h010: nif = nif & ~wv;
                            12'h012: begin r_ie <= wv; wr(ix, wv); end
                            12'h21C: nif = nif | (wv & 16'hFBFF);
                            12'h004: begin
                                mode_reset <= wv[0]; wr(ix, wmask(ix, wv)); def_13 <= wv[13];
                                if (wv[14]) begin mode_wep <= 3'd0; def_i <= 5'd0; end
                                else if (wv[13]) def_i <= 5'd25;
                                if (wv[0] != mode_reset) begin
                                    w2_ix <= 12'h27C; w2_v <= wv[0] ? 16'h0005 : 16'h000A; pe_go <= 1'b1; st <= S_W2;
                                end else if (wv[14] || wv[13]) st <= S_DEF;
                            end
                            12'h006: begin
                                mode_wep <= wv[2:0]; wr(ix, wmask(ix, wv));
                                if (power_tx[1]) begin
                                    pdc <= wv[2:0] == 3'd1 ? (pdc | 2'd2) : wv[2:0] == 3'd2 ? 2'd3 : pdc;
                                    if (wv[2:0] != 3'd3) ps_b[1:0] <= 2'd0;              // & 0x0300
                                    pe_go <= 1'b1;
                                end
                            end
                            12'h036: begin power_us0 <= wv[0]; wr(ix, wmask(ix, wv)); end
                            12'h038: begin
                                power_tx <= wv[1:0]; wr(ix, wmask(ix, wv));
                                if (wv[1]) begin
                                    pdc <= mode_wep == 3'd1 ? (pdc | 2'd2) : mode_wep == 3'd2 ? 2'd3 : pdc;
                                    pe_go <= 1'b1;
                                end
                            end
                            12'h03C: if (mode_wep == 3'd3) begin
                                logic [3:0] v;
                                v = {ps_b[3:2], wv[1:0]};
                                if (v[3:2] == 2'b10) v[0] = 1'b0; else v[1] = 1'b0;
                                if (!v[3]) v[2] = 1'b0;
                                ps_b <= v; pe_go <= 1'b1;
                            end
                            12'h040: begin pf_b <= {wv[15], wv[0]}; wr(ix, wmask(ix, wv)); pe_go <= 1'b1; end
                            12'h048: begin
                                logic [1:0] d;
                                d = wv[1:0];
                                if (power_tx[1]) d = mode_wep == 3'd1 ? (d | 2'd2) : mode_wep == 3'd2 ? 2'd3 : d;
                                pdc <= d; pe_go <= 1'b1;
                            end
                            12'h0E8: begin us_cnt_en <= wv[0]; wr(ix, wmask(ix, wv)); end
                            12'h0EA: begin
                                us_cmp_en <= wv[0]; wr(ix, wmask(ix, wv));
                                // bit 1: a forced IRQ14 (with the old enable, as melonDS)
                                if (wv[1] && us_cmp_en) begin i14_src1 <= 1'b0; i14_reset_b1 <= 1'b0; i14_ret <= S_NEXT; st <= S_I2; end
                            end
                            12'h0EE: begin cmd_cnt_en <= wv[0]; wr(ix, wv); end
                            12'h0F0: begin wr(ix, wmask(ix, wv)); if (wv[0]) block_b14 <= 1'b1; end
                            12'h0AC, 12'h0AE: begin rd(12'h0B0); rmw_op <= ix[1] ? 2'd2 : 2'd1; st <= S_RMW0; end
                            12'h118: begin cmd_q <= wv; cmd_r <= 4'd0; end
                            12'h158: begin
                                wr(ix, wv);
                                if (wv[15:12] == 4'h5 && !bb_ro(wv[7:0])) begin rd(12'h15A); st <= S_BBW0; end
                                else if (wv[15:12] == 4'h6) begin
                                    if (bb_ro(wv[7:0])) begin w2_ix <= 12'h15C; w2_v <= {8'd0, bb_fixed(wv[7:0])}; st <= S_W2; end
                                    else begin
                                        wm_req <= 1'b1; wm_we <= 1'b0; wm_addr <= {M_BB[20:8], wv[7:2]}; wm_be <= 4'hF;
                                        st <= S_BBRD;
                                    end
                                end else begin w2_ix <= 12'h15C; w2_v <= 16'd0; st <= S_W2; end   // W_BBRead reads 0
                            end
                            12'h17C: begin
                                wr(ix, wv);
                                if (wv[7]) begin
                                    wm_req <= 1'b1; wm_we <= 1'b0; wm_addr <= {M_RF[20:7], wv[6:2]}; wm_be <= 4'hF;
                                    st <= S_RFX;
                                end else begin rd(12'h17E); st <= S_RFW0; end
                            end
                            default: begin
                                if (ix < 12'h400) wr(ix, wmask(ix, wv));
                                else begin
                                    wm_req <= 1'b1; wm_we <= 1'b1; wm_addr <= {M_IO[20:12], ix[11:2]};
                                    wm_be <= ix[1] ? 4'b1100 : 4'b0011; wm_wdata <= {2{wmask(ix, wv)}};
                                    st <= S_MEMWAIT;
                                end
                            end
                        endcase
                    end else begin
                        // reads: from flops for what logic keeps, else the register file or SDRAM
                        case (ix)
                            12'h010: put(r_if);
                            12'h012: put(r_ie);
                            12'h034: put({14'd0, trx_power});
                            12'h03C: put(power_state);
                            12'h044: begin
                                logic [10:0] nr;
                                nr = {10'd0, random[0]} ^ {random[9:0], random[10]};
                                random <= nr; put({5'd0, nr});
                            end
                            12'h048: put({14'd0, pdc});
                            12'h118: put(cmd_q + {15'd0, cmd_r != 0});
                            12'h15E, 12'h180, 12'h21C: put(16'd0);
                            12'h19C: put({8'd0, status_pins(rf_status)});
                            12'h214: put({12'd0, rf_status});
                            default:
                                if (ix < 12'h400) st <= S_RFREAD;
                                else begin
                                    wm_req <= 1'b1; wm_we <= 1'b0; wm_addr <= {M_IO[20:12], ix[11:2]}; wm_be <= 4'hF;
                                    st <= S_MEMWAIT;
                                end
                        endcase
                    end
                end
                S_RFREAD: st <= S_RFOUT;                                  // the read address went in at S_HALF
                S_RFOUT: begin
                    logic [15:0] v;
                    v = rf_q;
                    if (ix == 12'h0BC) v = v & 16'h0003;                 // W_Preamble
                    if (ix == 12'h0B6) v = v & 16'h001F;                 // W_TXBusy
                    put(v);
                    if (ix >= 12'h1D0 && ix <= 12'h1DE) wr(ix, 16'd0);   // CMDStat: cleared by the read
                    st <= S_NEXT;
                end
                S_MEMWAIT: if (wm_ack) begin
                    wm_req <= 1'b0;
                    if (!wm_we) put(off[1] ? wm_rdata[31:16] : wm_rdata[15:0]);
                    st <= S_NEXT;
                end
                S_W2: begin                                               // a second register write
                    wr(w2_ix, w2_v);
                    st <= (a_we && ix == 12'h004 && (wv[14] || wv[13])) ? S_DEF : S_NEXT;
                end
                S_DEF: begin                                              // W_ModeReset's defaults, one a clock
                    logic [27:0] e;
                    e = def_entry(def_i);
                    wr(e[27:16], e[15:0]);
                    if (def_i == 5'd24) def_i <= 5'd30;
                    else if (def_i == 5'd30) begin if (def_13) def_i <= 5'd25; else st <= S_NEXT; end
                    else if (def_i == 5'd29) st <= S_NEXT;
                    else def_i <= def_i + 5'd1;
                end
                S_RMW0: st <= S_RMW1;                                     // W_TXReqRead comes back
                S_RMW1: begin wr(12'h0B0, rmw_op == 2'd1 ? rf_q & ~wv : rf_q | wv); st <= S_NEXT; end   // (TXReqSet's FireTX: not modelled)
                S_BBW0: st <= S_BBWR;                                     // (the register file's read takes a clock)
                S_BBWR: begin                                             // W_BBWrite came back: the register's byte
                    wm_req <= 1'b1; wm_we <= 1'b1; wm_addr <= {M_BB[20:8], wv[7:2]};
                    wm_be <= 4'b0001 << wv[1:0]; wm_wdata <= {4{rf_q[7:0]}};
                    wr(12'h15C, 16'd0);                                   // W_BBRead reads 0 unless the command is a read
                    st <= S_MEMWAIT;
                end
                S_BBRD: if (wm_ack) begin
                    wm_req <= 1'b0; w2_ix <= 12'h15C; w2_v <= {8'd0, wm_rdata[wv[1:0]*8 +: 8]}; st <= S_W2;
                end
                S_RFX: if (wm_ack) begin                                  // an RF read: back into W_RFData1/2
                    wm_req <= 1'b0;
                    wr(12'h17E, wm_rdata[15:0]);
                    w2_ix <= 12'h17C; w2_v <= {wv[15:2], wm_rdata[17:16]}; st <= S_W2;
                end
                S_RFW0: st <= S_RFW;
                S_RFW: begin                                              // an RF write: W_RFData1 came back
                    wm_req <= 1'b1; wm_we <= 1'b1; wm_addr <= {M_RF[20:7], wv[6:2]}; wm_be <= 4'hF;
                    wm_wdata <= {14'd0, wv[1:0], rf_q};
                    st <= S_MEMWAIT;
                end
                S_NEXT: begin
                    if (!a_h && a_be[3:2] != 0) begin a_h <= 1'b1; st <= S_HALF; end
                    else begin wf_ack <= 1'b1; st <= S_IDLE; end
                end

                // ---------------- the 8 us step (melonDS USTimer), in its order
                S_T0: begin
                    if (until_on != 0) begin
                        if (until_on <= 12'd8) begin
                            // W_PowerState = 0, status 1, then UpdatePowerStatus(0)
                            until_on <= 12'd0; ps_b <= 4'd0; rf_status <= 4'd1; pt_go <= 1'b1; pt_arg <= 2'd0;
                        end else until_on <= until_on - 12'd8;
                    end
                    if (us_cnt_en) begin rd(12'h0F8); st <= S_U0; end
                    else st <= S_D0;
                end
                S_U0: st <= S_U1;
                S_U1: begin                                               // the counter's low word + 8
                    logic [16:0] sum;
                    sum = {1'b0, rf_q} + 17'd8;
                    wr(12'h0F8, sum[15:0]); usp <= sum[9:0];
                    if (sum[16]) begin rd(12'h0FA); uc_k <= 2'd1; st <= S_UC0; end
                    else st <= S_B0;
                end
                S_UC0: st <= S_UC1;
                S_UC1: begin                                              // the carry into the next word
                    wr(12'h0F8 + {9'd0, uc_k, 1'b0}, rf_q + 16'd1);
                    if (rf_q == 16'hFFFF && uc_k != 2'd3) begin
                        rd(12'h0F8 + {9'd0, uc_k + 2'd1, 1'b0}); uc_k <= uc_k + 2'd1; st <= S_UC0;
                    end else st <= S_B0;
                end
                // W_PreBeacon: IRQ15 when ((BeaconCount1 << 10) | (0x3FF - us)) & ~7 == PreBeacon & ~7
                S_B0: if (us_cmp_en) begin rd(12'h11C); st <= S_B1; end else st <= S_M0;
                S_B1: begin rd(12'h110); st <= S_B2; end
                S_B2: begin t <= rf_q; st <= S_B3; end                    // BeaconCount1
                S_B3: begin                                               // rf_q: PreBeacon
                    if (t[15:6] == 10'd0 && t[5:0] == rf_q[15:10] && ((10'h3FF - usp) & ~10'd7) == (rf_q[9:0] & ~10'd7)) begin
                        nif[15] = 1'b1;
                        if (power_tx[0]) begin pt_go <= 1'b1; pt_arg <= 2'd1; end   // IRQ15's wake-up
                    end
                    st <= S_M0;
                end
                // the 1 ms timer (MSTimer) when the count lands on a multiple of 1024
                S_M0: begin
                    if (usp[9:3] != 7'd0) st <= S_D0;
                    else if (us_cmp_en) begin rd(12'h0F8); ck <= 2'd0; cmp_eq <= 1'b1; st <= S_C1; end
                    else st <= S_BCR;
                end
                // USCount[63:10] == USCompare[63:10], word by word (0x0F8/0x0F0 .. 0x0FE/0x0F6)
                S_C1: begin rd(12'h0F0 + {9'd0, ck, 1'b0}); st <= S_C2; end
                S_C2: begin t <= rf_q; st <= S_C3; end                    // the count's word
                S_C3: begin                                               // rf_q: the compare's word
                    logic eq;
                    eq = ck == 2'd0 ? t[15:10] == rf_q[15:10] : t == rf_q;
                    if (ck != 2'd3) begin
                        cmp_eq <= cmp_eq && eq; ck <= ck + 2'd1; rd(12'h0F8 + {9'd0, ck + 2'd1, 1'b0}); st <= S_C1;
                    end else if (cmp_eq && eq) begin
                        block_b14 <= 1'b0;
                        i14_src1 <= 1'b0; i14_reset_b1 <= 1'b1; i14_ret <= S_BCR; rd(12'h08C); st <= S_I0;
                    end else st <= S_BCR;
                end
                // SetIRQ14: BeaconCount1 = BeaconInterval (not the forced one); IRQ14 if allowed and enabled
                S_I0: st <= S_I1;
                S_I1: begin                                               // rf_q: BeaconInterval
                    if (i14_reset_b1) wr(12'h11C, rf_q);
                    if ((block_b14 && i14_src1) || !us_cmp_en) st <= i14_ret;
                    else st <= S_I2;
                end
                S_I2: begin nif[14] = 1'b1; wr(12'h134, 16'hFFFF); rd(12'h0B0); st <= S_I3; end
                S_I3: st <= S_I4;
                S_I4: begin wr(12'h0B0, rf_q & 16'hFFF2); rd(12'h088); st <= S_I5; end   // (the beacon slot is not sent)
                S_I5: st <= S_I6;
                S_I6: begin                                               // ListenCount: if 0, = ListenInterval; then - 1
                    if (rf_q == 0) begin rd(12'h08E); st <= S_I7; end
                    else begin wr(12'h088, rf_q - 16'd1); st <= i14_ret; end
                end
                S_I7: st <= S_I8;
                S_I8: begin wr(12'h088, rf_q - 16'd1); st <= i14_ret; end
                // BeaconCount1 - 1, IRQ14 when it reaches 0
                S_BCR: begin rd(12'h11C); st <= S_BC0; end
                S_BC0: st <= S_BC1;
                S_BC1: begin
                    if (rf_q != 0) begin
                        wr(12'h11C, rf_q - 16'd1);
                        if (rf_q == 16'd1) begin
                            i14_src1 <= 1'b1; i14_reset_b1 <= 1'b1; i14_ret <= S_BZR; rd(12'h08C); st <= S_I0;
                        end else st <= S_BZR;
                    end else st <= S_BZR;
                end
                // BeaconCount1 == 0: = BeaconInterval
                S_BZR: begin rd(12'h11C); st <= S_BZ0; end
                S_BZ0: st <= S_BZ1;
                S_BZ1: if (rf_q == 0) begin rd(12'h08C); st <= S_BZ2; end else st <= S_D1R;
                S_BZ2: st <= S_BZ3;
                S_BZ3: begin wr(12'h11C, rf_q); st <= S_D1R; end
                // BeaconCount2 - 1, IRQ13 when it reaches 0 (and a power-down in mode 0)
                S_D1R: begin rd(12'h134); st <= S_D1W; end
                S_D1W: st <= S_D1;
                S_D1: begin
                    if (rf_q != 0) begin
                        wr(12'h134, rf_q - 16'd1);
                        if (rf_q == 16'd1) begin
                            nif[13] = 1'b1;
                            if (mode_wep == 3'd0 && !power_tx[1]) begin pt_go <= 1'b1; pt_arg <= 2'd2; end
                        end
                    end
                    st <= S_D0;
                end
                // W_CmdCount (flops) and W_ContentFree
                S_D0: begin
                    if (cmd_cnt_en) begin
                        if (cmd_q == 0 && cmd_r < 4'd8) cmd_r <= 4'd0;
                        else if (cmd_r >= 4'd8) cmd_r <= cmd_r - 4'd8;
                        else begin cmd_r <= cmd_r + 4'd2; cmd_q <= cmd_q - 16'd1; end   // 10q + r - 8 = 10(q - 1) + r + 2
                    end
                    rd(12'h10C); st <= S_E0;
                end
                S_E0: st <= S_E1;
                S_E1: begin
                    if (rf_q != 0) wr(12'h10C, rf_q < 16'd8 ? 16'd0 : rf_q - 16'd8);
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
            r_if <= nif;
        end
    end
endmodule
`default_nettype wire
