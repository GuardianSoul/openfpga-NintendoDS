// SPDX-License-Identifier: GPL-3.0-or-later
// The DS WiFi block as nds_wifi.sv (same ports, same behaviour, docs/wifi.md),
// with its sequencer replaced by a small microcoded engine: what nds_wifi.sv
// spends on per-register decode, write masks, the defaults, the timer states
// and the power logic is a ROM and a dispatch table here, both in M10K, and
// microcode (sim/ds/wifi_mc_asm.py assembles it and writes the generated
// sections of this file).
//
// The engine runs one instruction a clock: a 16-bit accumulator T with one
// adder (T op (source & mask)), branches on conditions or T's bits, one
// return address, and the register file (RD sets the read address, its value
// is in Q two clocks later, RDL waits for it into T; WR writes in the same
// clock). The register file holds, besides the registers, the state
// nds_wifi.sv keeps in flops for the power logic and W_CmdCount (in slots the
// CPU cannot write, wifi_mc_asm.py); flops hold only what logic needs every
// clock or for a condition: IF/IE, W_Random, the prescaler, W_PowerUS bit 0,
// the IRQ14 block, the counter's bits 9:3, the prescaler's tick count (its
// residual is in the register file: the step's microcode decides the next
// interval, 268 or 269 ticks). A CPU halfword starts at its
// dispatch entry (the table for registers 0x000-0x3FE, logic for the rest);
// a timer step at T_STEP. MEM waits for the SDRAM.
//
// wf_we/wf_be/wf_addr/wf_wdata must stay as they were at wf_req until wf_ack
// (nds_fabric holds its request until the answer), so they are not copied.
`default_nettype none
module nds_wifi_mc (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,           // 33.513982 MHz enable
    input  logic        power,          // POWCNT2 bit 1
    input  logic        id_lite,        // W_ID: 1 DS Lite (0xC340), 0 DS (0x1440)
    input  logic        wf_req,
    input  logic        wf_we,
    input  logic [3:0]  wf_be,
    input  logic [23:2] wf_addr,
    input  logic [31:0] wf_wdata,
    output logic        wf_ack,
    output wire  [31:0] wf_rdata,       // valid with wf_ack, until the next wf_req
    output logic        irq,            // pulse: the ARM7's IF bit 24
    output logic        wm_req,
    output logic        wm_we,
    output logic [20:2] wm_addr,
    output logic [3:0]  wm_be,
    output logic [31:0] wm_wdata,
    input  logic        wm_ack,
    input  logic [31:0] wm_rdata
);
// ---- BEGIN GENERATED PARAMS (sim/ds/wifi_mc_asm.py)
// 377 instructions; encoding {op[4:0], nx, c[4:0], ax, a[8:0], imm[15:0]}
localparam logic [4:0] O_NOP = 5'd0; localparam logic [4:0] O_RD = 5'd1; localparam logic [4:0] O_RDL = 5'd2; localparam logic [4:0] O_WR = 5'd3; localparam logic [4:0] O_LD = 5'd4; localparam logic [4:0] O_LDP = 5'd5; localparam logic [4:0] O_ADD = 5'd6; localparam logic [4:0] O_AND = 5'd7; localparam logic [4:0] O_OR = 5'd8; localparam logic [4:0] O_XOR = 5'd9; localparam logic [4:0] O_ANDN = 5'd10; localparam logic [4:0] O_BR = 5'd11; localparam logic [4:0] O_BT = 5'd12; localparam logic [4:0] O_BF = 5'd13; localparam logic [4:0] O_CALL = 5'd14; localparam logic [4:0] O_RET = 5'd15; localparam logic [4:0] O_MEM = 5'd16; localparam logic [4:0] O_SPC = 5'd17;
localparam logic [4:0] S_IMM = 5'd0; localparam logic [4:0] S_Q = 5'd1; localparam logic [4:0] S_W = 5'd2; localparam logic [4:0] S_T = 5'd3; localparam logic [4:0] S_IF = 5'd4; localparam logic [4:0] S_IE = 5'd5; localparam logic [4:0] S_RND = 5'd6; localparam logic [4:0] S_BBFIX = 5'd7;
localparam logic [4:0] C_ALWAYS = 5'd0; localparam logic [4:0] C_Z = 5'd1; localparam logic [4:0] C_NZ = 5'd2; localparam logic [4:0] C_C = 5'd3; localparam logic [4:0] C_NC = 5'd4; localparam logic [4:0] C_QZ = 5'd5; localparam logic [4:0] C_NOTMS = 5'd6; localparam logic [4:0] C_BLOCK = 5'd7; localparam logic [4:0] C_BBW = 5'd8; localparam logic [4:0] C_BBR = 5'd9; localparam logic [4:0] C_BBRO = 5'd10; localparam logic [4:0] C_NOTPB = 5'd11;
localparam logic [8:0] X_IFOR = 9'd0; localparam logic [8:0] X_IFANDN = 9'd1; localparam logic [8:0] X_IE = 9'd2; localparam logic [8:0] X_PWUS = 9'd3; localparam logic [8:0] X_BLOCK_SET_W = 9'd4; localparam logic [8:0] X_BLOCK_CLR = 9'd5; localparam logic [8:0] X_USP = 9'd6; localparam logic [8:0] X_K268 = 9'd7;
localparam logic [4:0] M_CPU = 5'd0; localparam logic [4:0] M_BBW = 5'd1; localparam logic [4:0] M_BBR = 5'd2; localparam logic [4:0] M_RFWL = 5'd3; localparam logic [4:0] M_RFWH = 5'd4; localparam logic [4:0] M_RFRL = 5'd5; localparam logic [4:0] M_RFRH = 5'd6;
localparam logic [8:0] E_H_NEXT = 9'd1; localparam logic [8:0] E_H_FF = 9'd2; localparam logic [8:0] E_H_MEM = 9'd3; localparam logic [8:0] E_H_RD = 9'd6; localparam logic [8:0] E_H_WR = 9'd21; localparam logic [8:0] E_T_STEP = 9'd189; localparam logic [8:0] E_H_M0000 = 9'd23; localparam logic [8:0] E_H_M0001 = 9'd25; localparam logic [8:0] E_H_M000F = 9'd27; localparam logic [8:0] E_H_M07FF = 9'd29; localparam logic [8:0] E_H_M0FFF = 9'd31; localparam logic [8:0] E_H_M1FFE = 9'd33; localparam logic [8:0] E_H_M413F = 9'd35; localparam logic [8:0] E_H_MFF0E = 9'd37; localparam logic [8:0] E_H_RCMD = 9'd14; localparam logic [8:0] E_H_RDB6 = 9'd8; localparam logic [8:0] E_H_RDBC = 9'd7; localparam logic [8:0] E_H_RDCS = 9'd9; localparam logic [8:0] E_H_RIE = 9'd12; localparam logic [8:0] E_H_RIF = 9'd11; localparam logic [8:0] E_H_RRND = 9'd13; localparam logic [8:0] E_H_RZERO = 9'd20; localparam logic [8:0] E_H_W004 = 9'd118; localparam logic [8:0] E_H_W006 = 9'd78; localparam logic [8:0] E_H_W010 = 9'd39; localparam logic [8:0] E_H_W012 = 9'd41; localparam logic [8:0] E_H_W036 = 9'd44; localparam logic [8:0] E_H_W038 = 9'd88; localparam logic [8:0] E_H_W03C = 9'd63; localparam logic [8:0] E_H_W040 = 9'd47; localparam logic [8:0] E_H_W048 = 9'd92; localparam logic [8:0] E_H_W0AC = 9'd57; localparam logic [8:0] E_H_W0AE = 9'd60; localparam logic [8:0] E_H_W0EA = 9'd108; localparam logic [8:0] E_H_W0F0 = 9'd54; localparam logic [8:0] E_H_W118 = 9'd51; localparam logic [8:0] E_H_W158 = 9'd163; localparam logic [8:0] E_H_W17C = 9'd176; localparam logic [8:0] E_H_W21C = 9'd40; localparam logic [8:0] E_H_ZERO = 9'd0;
// ---- END GENERATED PARAMS

    // SDRAM layout (VRAM-port byte addresses 0x0F0000 + these offsets)
    //   0x0000 WiFi RAM (8 KiB), 0x2000 registers 0x400-0xFFF (offset = register),
    //   0x3000 the 256 baseband registers (a halfword each), 0x3200 the 32 RF registers (18 bits in a word)
    localparam logic [6:0]  M_HI   = 7'h3C;              // VRAM-port word address [20:14] of 0x0F0000
    localparam logic [11:0] M_WEND = 12'hCA0;            // 0x3280 / 4: the words cleared after reset

    // ---------------------------------------------------------------- flops
    logic [15:0] r_if, r_ie;
    logic        irq_q;
    logic        power_us0;             // 0x036 bit 0
    logic        block_b14;
    logic [8:0]  pcnt;                  // 8 us prescaler: ticks to the next step
    logic        k268;                  // the interval after it: 268 ticks, else 269 (the microcode sets it)
    logic        step_pend;
    logic [10:0] random;
    logic [9:3]  usp;                   // the counter's bits 9:3 after this step
    wire         power_on = power && !power_us0;

    // ---------------------------------------------------------------- the engine's state
    typedef enum logic [3:0] { E_INIT_RF, E_INIT_MEM, E_INIT_REG, E_IDLE, E_D0, E_D1, E_RUN, E_MEMW, E_W1, E_W2 } est_t;
    est_t        est;
    logic [8:0]  pc, pc_n, ret;
    (* romstyle = "M10K" *) logic [36:0] ins;
    logic [8:0]  dt_q;
    logic [9:0]  dt_a;
    logic [15:0] t;
    logic        c_flag;
    logic        in_step, req_pend, a_h;
    logic [31:0] a_rd;
    logic [11:0] init_c;                // the register file's, then SDRAM's words cleared

    wire  [4:0]  op  = ins[36:32];
    wire         nx  = ins[31];
    wire  [4:0]  c   = ins[30:26];
    wire         ax  = ins[25];
    wire  [8:0]  ia  = ins[24:16];
    wire  [15:0] imm = ins[15:0];

    // the access (held by the requester)
    assign wf_rdata = a_rd;
    wire  [14:0] off    = {wf_addr[14:2], a_h, 1'b0};
    wire         in_ram = off >= 15'h4000 && off < 15'h6000;
    wire         in_ff  = off >= 15'h2000 && off < 15'h4000;
    wire         beyond = wf_addr[23:16] != 8'h80;
    wire  [11:0] ix     = off[11:0];
    wire  [1:0]  hbe    = a_h ? wf_be[3:2] : wf_be[1:0];
    wire  [15:0] wv     = a_h ? wf_wdata[31:16] : wf_wdata[15:0];
    assign dt_a = {wf_we, ix[9:1]};

    wire act = |(r_if & r_ie);
    assign irq = act && !irq_q;

    // ---------------------------------------------------------------- helpers
    function automatic logic bb_ro(input logic [7:0] i);
        bb_ro = i == 8'h00 || (i >= 8'h0D && i <= 8'h12) || i == 8'h16 || i == 8'h17 || i == 8'h18 ||
                i == 8'h19 || i == 8'h1A || i == 8'h27 || i == 8'h4D || i == 8'h5D || i == 8'h5E ||
                i == 8'h5F || i == 8'h60 || i == 8'h61 || i == 8'h64 || i == 8'h66 || i >= 8'h69;
    endfunction
    function automatic logic [7:0] bb_fixed(input logic [7:0] i);
        bb_fixed = i == 8'h00 ? 8'h6D : i == 8'h5D ? 8'h01 : i == 8'h64 ? 8'hFF : 8'h00;
    endfunction
    // the register file's reset image: W_ID, MAC/BSSID 0xFFFF, W_PowerUS 1, else 0
    function automatic logic [15:0] init_val(input logic [8:0] i);
        if (i == 9'd0) init_val = id_lite ? 16'hC340 : 16'h1440;
        else if ((i >= 9'h00C && i <= 9'h00E) || (i >= 9'h010 && i <= 9'h012)) init_val = 16'hFFFF;
        else if (i == 9'h01B) init_val = 16'h0001;
        else if (i == 9'h0C0) init_val = 16'hD8D5;                       // 0x180: the residual after the 2nd step, 55,509
        else init_val = 16'h0000;
    endfunction

    // ---------------------------------------------------------------- operands
    logic [15:0] rf_q;
    wire  [10:0] rnd_n = {10'd0, random[0]} ^ {random[9:0], random[10]};
    logic [15:0] src;
    always_comb begin
        case (c)
            S_Q:     src = rf_q;
            S_W:     src = wv;
            S_T:     src = t;
            S_IF:    src = r_if;
            S_IE:    src = r_ie;
            S_RND:   src = {5'd0, rnd_n};
            S_BBFIX: src = {8'd0, bb_fixed(wv[7:0])};
            default: src = 16'hFFFF;                        // S_IMM
        endcase
    end
    wire [15:0] b = src & imm;
    logic cond;
    always_comb begin
        case (op)
            O_BT:    cond = t[c[3:0]];
            O_BF:    cond = !t[c[3:0]];
            default: case (c)
                C_Z:     cond = t == 16'd0;
                C_NZ:    cond = t != 16'd0;
                C_C:     cond = c_flag;
                C_NC:    cond = !c_flag;
                C_QZ:    cond = rf_q == 16'd0;
                C_NOTMS: cond = usp != 7'd0;
                C_BLOCK: cond = block_b14;
                C_BBW:   cond = wv[15:12] == 4'h5 && !bb_ro(wv[7:0]);
                C_BBR:   cond = wv[15:12] == 4'h6;
                C_BBRO:  cond = bb_ro(wv[7:0]);
                // W_PreBeacon: ((BeaconCount1 << 10) | (0x3FF - us)) & ~7 != PreBeacon & ~7 (T, Q)
                C_NOTPB: cond = !(t[15:6] == 10'd0 && t[5:0] == rf_q[15:10] && ~usp == rf_q[9:3]);
                default: cond = 1'b1;                       // C_ALWAYS
            endcase
        endcase
    end

    // ---------------------------------------------------------------- register file (0x000-0x3FF)
    (* ramstyle = "M10K" *) logic [15:0] rfile [0:511];
    logic [8:0]  rf_ra;
    wire         run    = est == E_RUN;
    wire  [8:0]  ra_sel = ax ? ix[9:1] : ia;
    wire         rf_we  = est == E_INIT_RF || (run && op == O_WR);
    wire  [8:0]  rf_wa  = est == E_INIT_RF ? init_c[8:0] : ra_sel;
    wire  [15:0] rf_wd  = est == E_INIT_RF ? init_val(init_c[8:0]) : b;
    always_ff @(posedge clk) begin
        if (rf_we) rfile[rf_wa] <= rf_wd;
        rf_q <= rfile[rf_ra];
    end

    // the dispatch: registers from the table, the rest by logic
    logic [8:0] entry;
    always_comb begin
        if (hbe == 2'b00 || beyond) entry = E_H_NEXT;
        else if (in_ff) entry = wf_we ? E_H_NEXT : E_H_FF;
        else if (wf_we && hbe != 2'b11) entry = E_H_NEXT;  // byte writes are ignored, as melonDS
        else if (in_ram || ix[11:10] != 2'd0) entry = E_H_MEM;
        else if (dt_q == 9'd0) entry = wf_we ? E_H_WR : E_H_RD;     // the table's default
        else entry = dt_q;
    end

    always_comb begin
        pc_n = pc + 9'd1;
        case (est)
            E_IDLE: pc_n = E_T_STEP;
            E_D1:   pc_n = entry;
            E_RUN:  case (op)
                        O_BR, O_BT, O_BF: if (cond) pc_n = ia;
                        O_CALL: pc_n = ia;
                        O_RET:  pc_n = ret;
                        O_MEM, O_RDL: pc_n = pc;
                        default: ;
                    endcase
            E_W2:   ;                                       // RDL: the next instruction is fetched as T loads
            E_MEMW: if (!wm_ack) pc_n = pc;
            default: pc_n = pc;
        endcase
    end

    // memory: the request as the MEM instruction (or the reset clear) describes it; data {T, T}
    logic        m_hi;                  // the halfword: write enables, and which half a read loads
    always_comb begin
        logic [11:0] w;
        wm_we = 1'b0; m_hi = 1'b0;
        case (c)
            M_CPU:  begin wm_we = wf_we; m_hi = off[1]; w = in_ram ? {1'b0, off[12:2]} : {2'b10, ix[11:2]}; end
            M_BBW:  begin wm_we = 1'b1; m_hi = wv[0]; w = {5'b11000, wv[7:1]}; end
            M_BBR:  begin m_hi = wv[0]; w = {5'b11000, wv[7:1]}; end
            M_RFWL: begin wm_we = 1'b1; w = {7'b1100100, wv[6:2]}; end
            M_RFWH: begin wm_we = 1'b1; m_hi = 1'b1; w = {7'b1100100, wv[6:2]}; end
            M_RFRL: w = {7'b1100100, wv[6:2]};
            default: begin m_hi = 1'b1; w = {7'b1100100, wv[6:2]}; end      // M_RFRH
        endcase
        wm_wdata = {t, t};
        if (est != E_MEMW) begin wm_we = 1'b1; w = init_c; wm_wdata = 32'd0; end
        wm_addr = {M_HI, w};
        wm_be = !wm_we || est != E_MEMW ? 4'hF : m_hi ? 4'b1100 : 4'b0011;
    end

    task automatic put(input logic [15:0] v);
        if (a_h) a_rd[31:16] <= v; else a_rd[15:0] <= v;
    endtask

    always_ff @(posedge clk) begin
        logic [15:0] nif;
        wf_ack <= 1'b0;
        irq_q <= act;
        nif = r_if;
        pc <= pc_n;
        if (rst) begin
            est <= E_INIT_RF; init_c <= 12'd0; req_pend <= 1'b0;
            r_if <= 16'd0; r_ie <= 16'd0; power_us0 <= 1'b1; block_b14 <= 1'b0;
            pcnt <= 9'd269; k268 <= 1'b1; step_pend <= 1'b0; random <= 11'd1;
            wm_req <= 1'b0; irq_q <= 1'b0;
        end else begin
            // ---- the prescaler: an 8 us step is due (the engine runs it next)
            if (power_on && tick) begin
                if (pcnt == 9'd1) begin pcnt <= k268 ? 9'd268 : 9'd269; step_pend <= 1'b1; end
                else pcnt <= pcnt - 9'd1;
            end
            if (wf_req) req_pend <= 1'b1;

            case (est)
                // ---------------- reset: the register file's image, then SDRAM cleared
                E_INIT_RF: begin
                    init_c <= init_c[8:0] == 9'd511 ? 12'd0 : init_c + 12'd1;
                    if (init_c[8:0] == 9'd511) est <= E_INIT_MEM;
                end
                E_INIT_MEM: begin wm_req <= 1'b1; est <= E_INIT_REG; end
                E_INIT_REG: if (wm_ack) begin
                    wm_req <= 1'b0;
                    init_c <= init_c + 12'd1;
                    est <= init_c + 12'd1 == M_WEND ? E_IDLE : E_INIT_MEM;
                end
                E_IDLE: begin
                    if (step_pend) begin step_pend <= 1'b0; in_step <= 1'b1; est <= E_RUN; end
                    else if (req_pend) begin
                        req_pend <= 1'b0; in_step <= 1'b0; a_rd <= 32'd0;
                        a_h <= wf_be[1:0] == 2'b00;
                        est <= E_D0;
                    end
                end
                E_D0: begin rf_ra <= ix[9:1]; est <= E_D1; end     // the dispatch table and the register come back
                E_D1: est <= E_RUN;
                E_W1: est <= E_W2;                                  // RDL: the register comes back
                E_W2: begin t <= rf_q & imm; est <= E_RUN; end
                E_MEMW: if (wm_ack) begin
                    wm_req <= 1'b0;
                    if (!wm_we) t <= m_hi ? wm_rdata[31:16] : wm_rdata[15:0];
                    est <= E_RUN;
                end
                E_RUN: begin
                    case (op)
                        O_RD:   rf_ra <= ra_sel;
                        O_RDL:  begin rf_ra <= ra_sel; est <= E_W1; end
                        O_LD:   t <= b;
                        O_LDP:  begin t <= b; put(b); end
                        O_ADD:  {c_flag, t} <= {1'b0, t} + {1'b0, b};
                        O_AND:  t <= t & b;
                        O_OR:   t <= t | b;
                        O_XOR:  t <= t ^ b;
                        O_ANDN: t <= t & ~b;
                        O_CALL: ret <= pc + 9'd1;
                        O_MEM:  begin wm_req <= 1'b1; est <= E_MEMW; end
                        O_SPC: case (ia)
                            X_IFOR:        nif = nif | b;
                            X_IFANDN:      nif = nif & ~b;
                            X_IE:          r_ie <= b;
                            X_PWUS:        power_us0 <= wv[0];
                            X_BLOCK_SET_W: if (wv[0]) block_b14 <= 1'b1;
                            X_BLOCK_CLR:   block_b14 <= 1'b0;
                            X_USP:         usp <= t[9:3];
                            default:       k268 <= c_flag;          // X_K268
                        endcase
                        default: ;
                    endcase
                    if ((op == O_LD || op == O_LDP) && c == S_RND) random <= rnd_n;
                    if (nx) begin
                        if (in_step) est <= E_IDLE;
                        else if (!a_h && wf_be[3:2] != 0) begin a_h <= 1'b1; est <= E_D0; end
                        else begin wf_ack <= 1'b1; est <= E_IDLE; end
                    end
                end
                default: est <= E_IDLE;
            endcase
            r_if <= nif;
        end
    end

`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
    // simulation (+wifimctrace): every access (start and answer), and an access or SDRAM
    // request that has waited 100,000 clocks
    logic   tr_on = 1'b0, tr_busy = 1'b0;
    longint tr_cyc = 0, tr_since = 0;
    initial tr_on = $test$plusargs("wifimctrace");
    always_ff @(posedge clk) begin
        tr_cyc <= tr_cyc + 1;
        if (tr_cyc[19:0] == 20'd0) tr_on <= $test$plusargs("wifimctrace");
        if (wf_req) begin tr_since <= tr_cyc; tr_busy <= 1'b1; end
        if (wf_ack) tr_busy <= 1'b0;
        if (tr_on && wf_req) $display("wifimc %0d: req %s %h be %h wdata %h est %0d pc %0d", tr_cyc,
                                      wf_we ? "W" : "R", {wf_addr, 2'b00}, wf_be, wf_wdata, est, pc);
        if (tr_on && wf_ack) $display("wifimc %0d: ack %h", tr_cyc, a_rd);
        if (tr_busy && tr_cyc - tr_since == 100000)
            $display("wifimc %0d: STUCK est %0d pc %0d op %0d wm_req %b wm_addr %h", tr_cyc, est, pc, op, wm_req, {wm_addr, 2'b00});
    end
`endif

// ---- BEGIN GENERATED ROMS (sim/ds/wifi_mc_asm.py)
    always_ff @(posedge clk) begin
        case (pc_n)
            9'd0: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd1: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd2: ins <= {5'd5, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // LDP IMM 0xFFFF !
            9'd3: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd4: ins <= {5'd16, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // MEM CPU
            9'd5: ins <= {5'd5, 1'b1, 5'd3, 1'b0, 9'h000, 16'hFFFF};   // LDP T !
            9'd6: ins <= {5'd5, 1'b1, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LDP Q !
            9'd7: ins <= {5'd5, 1'b1, 5'd1, 1'b0, 9'h000, 16'h0003};   // LDP Q 0x0003 !
            9'd8: ins <= {5'd5, 1'b1, 5'd1, 1'b0, 9'h000, 16'h001F};   // LDP Q 0x001F !
            9'd9: ins <= {5'd5, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LDP Q
            9'd10: ins <= {5'd3, 1'b1, 5'd0, 1'b1, 9'h000, 16'h0000};   // WR IX IMM 0 !
            9'd11: ins <= {5'd5, 1'b1, 5'd4, 1'b0, 9'h000, 16'hFFFF};   // LDP IF !
            9'd12: ins <= {5'd5, 1'b1, 5'd5, 1'b0, 9'h000, 16'hFFFF};   // LDP IE !
            9'd13: ins <= {5'd5, 1'b1, 5'd6, 1'b0, 9'h000, 16'hFFFF};   // LDP RND !
            9'd14: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd15: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h10E, 16'hFFFF};   // RD 0x21C
            9'd16: ins <= {5'd0, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP
            9'd17: ins <= {5'd11, 1'b0, 5'd5, 1'b0, 9'h013, 16'hFFFF};   // BR QZ RCMD_P
            9'd18: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0001};   // ADD IMM 0x0001
            9'd19: ins <= {5'd5, 1'b1, 5'd3, 1'b0, 9'h000, 16'hFFFF};   // LDP T !
            9'd20: ins <= {5'd5, 1'b1, 5'd0, 1'b0, 9'h000, 16'h0000};   // LDP IMM 0 !
            9'd21: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd22: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd23: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0000};   // LD W 0x0000
            9'd24: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd25: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // LD W 0x0001
            9'd26: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd27: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h000F};   // LD W 0x000F
            9'd28: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd29: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h07FF};   // LD W 0x07FF
            9'd30: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd31: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0FFF};   // LD W 0x0FFF
            9'd32: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd33: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h1FFE};   // LD W 0x1FFE
            9'd34: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd35: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h413F};   // LD W 0x413F
            9'd36: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd37: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFF0E};   // LD W 0xFF0E
            9'd38: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd39: ins <= {5'd17, 1'b1, 5'd2, 1'b0, 9'h001, 16'hFFFF};   // SPC IFANDN W !
            9'd40: ins <= {5'd17, 1'b1, 5'd2, 1'b0, 9'h000, 16'hFBFF};   // SPC IFOR W 0xFBFF !
            9'd41: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd42: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd43: ins <= {5'd17, 1'b1, 5'd2, 1'b0, 9'h002, 16'hFFFF};   // SPC IE W !
            9'd44: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0003};   // LD W 0x0003
            9'd45: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd46: ins <= {5'd17, 1'b1, 5'd0, 1'b0, 9'h003, 16'hFFFF};   // SPC PWUS !
            9'd47: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h8001};   // LD W 0x8001
            9'd48: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd49: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h146, 16'hFFFF};   // CALL POW0
            9'd50: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd51: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd52: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd53: ins <= {5'd3, 1'b1, 5'd0, 1'b0, 9'h10E, 16'h0000};   // WR 0x21C IMM 0 !
            9'd54: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFC00};   // LD W 0xFC00
            9'd55: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd56: ins <= {5'd17, 1'b1, 5'd0, 1'b0, 9'h004, 16'hFFFF};   // SPC BLOCK_SET_W !
            9'd57: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h058, 16'hFFFF};   // RDL 0x0B0
            9'd58: ins <= {5'd10, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // ANDN W
            9'd59: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h058, 16'hFFFF};   // WR 0x0B0 !
            9'd60: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h058, 16'hFFFF};   // RDL 0x0B0
            9'd61: ins <= {5'd8, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // OR W
            9'd62: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h058, 16'hFFFF};   // WR 0x0B0 !
            9'd63: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h003, 16'h0007};   // RDL 0x006 0x0007
            9'd64: ins <= {5'd9, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0003};   // XOR IMM 0x0003
            9'd65: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h001, 16'hFFFF};   // BR NZ H_NEXT
            9'd66: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'h0300};   // RDL 0x03C 0x0300
            9'd67: ins <= {5'd8, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0003};   // OR W 0x0003
            9'd68: ins <= {5'd13, 1'b0, 5'd9, 1'b0, 9'h04A, 16'hFFFF};   // BF 9 W03C_N9
            9'd69: ins <= {5'd12, 1'b0, 5'd8, 1'b0, 9'h048, 16'hFFFF};   // BT 8 W03C_A
            9'd70: ins <= {5'd7, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFE};   // AND IMM 0xFFFE
            9'd71: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h04B, 16'hFFFF};   // BR ALWAYS W03C_W
            9'd72: ins <= {5'd7, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFD};   // AND IMM 0xFFFD
            9'd73: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h04B, 16'hFFFF};   // BR ALWAYS W03C_W
            9'd74: ins <= {5'd7, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFEFD};   // AND IMM 0xFEFD
            9'd75: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h01E, 16'hFFFF};   // WR 0x03C
            9'd76: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h146, 16'hFFFF};   // CALL POW0
            9'd77: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd78: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h007F};   // LD W 0x007F
            9'd79: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd80: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01C, 16'hFFFF};   // RDL 0x038
            9'd81: ins <= {5'd13, 1'b0, 5'd1, 1'b0, 9'h001, 16'hFFFF};   // BF 1 H_NEXT
            9'd82: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0007};   // LD W 0x0007
            9'd83: ins <= {5'd9, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0003};   // XOR IMM 0x0003
            9'd84: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h060, 16'hFFFF};   // BR Z PDCM
            9'd85: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'h0300};   // RDL 0x03C 0x0300
            9'd86: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h01E, 16'hFFFF};   // WR 0x03C
            9'd87: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h060, 16'hFFFF};   // BR ALWAYS PDCM
            9'd88: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0003};   // LD W 0x0003
            9'd89: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd90: ins <= {5'd13, 1'b0, 5'd1, 1'b0, 9'h001, 16'hFFFF};   // BF 1 H_NEXT
            9'd91: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h060, 16'hFFFF};   // BR ALWAYS PDCM
            9'd92: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0003};   // LD W 0x0003
            9'd93: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd94: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01C, 16'hFFFF};   // RDL 0x038
            9'd95: ins <= {5'd13, 1'b0, 5'd1, 1'b0, 9'h06A, 16'hFFFF};   // BF 1 PDCP
            9'd96: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h003, 16'h0007};   // RDL 0x006 0x0007
            9'd97: ins <= {5'd9, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0001};   // XOR IMM 0x0001
            9'd98: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h067, 16'hFFFF};   // BR NZ PDCM2
            9'd99: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h024, 16'hFFFF};   // RDL 0x048
            9'd100: ins <= {5'd8, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0002};   // OR IMM 0x0002
            9'd101: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h024, 16'hFFFF};   // WR 0x048
            9'd102: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h06A, 16'hFFFF};   // BR ALWAYS PDCP
            9'd103: ins <= {5'd9, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0003};   // XOR IMM 0x0003
            9'd104: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h06A, 16'hFFFF};   // BR NZ PDCP
            9'd105: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h024, 16'h0003};   // WR 0x048 IMM 0x0003
            9'd106: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h146, 16'hFFFF};   // CALL POW0
            9'd107: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd108: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd109: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h074, 16'hFFFF};   // BF 0 W0EA_N
            9'd110: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd111: ins <= {5'd13, 1'b0, 5'd1, 1'b0, 9'h074, 16'hFFFF};   // BF 1 W0EA_N
            9'd112: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // LD W 0x0001
            9'd113: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd114: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h138, 16'hFFFF};   // CALL I14_BODY
            9'd115: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd116: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // LD W 0x0001
            9'd117: ins <= {5'd3, 1'b1, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX !
            9'd118: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd119: ins <= {5'd9, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // XOR W 0x0001
            9'd120: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h07F, 16'hFFFF};   // BR Z W004_D
            9'd121: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // LD W 0x0001
            9'd122: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd123: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h13E, 16'h000A};   // WR 0x27C IMM 0x000A
            9'd124: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h07E, 16'hFFFF};   // BF 0 W004_P
            9'd125: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h13E, 16'h0005};   // WR 0x27C IMM 0x0005
            9'd126: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h146, 16'hFFFF};   // CALL POW0
            9'd127: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0001};   // LD W 0x0001
            9'd128: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd129: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd130: ins <= {5'd13, 1'b0, 5'd14, 1'b0, 9'h09D, 16'hFFFF};   // BF 14 W004_13
            9'd131: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h004, 16'h0000};   // WR 0x008 IMM 0x0000
            9'd132: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h005, 16'h0000};   // WR 0x00A IMM 0x0000
            9'd133: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h00C, 16'h0000};   // WR 0x018 IMM 0x0000
            9'd134: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h00D, 16'h0000};   // WR 0x01A IMM 0x0000
            9'd135: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h00E, 16'h0000};   // WR 0x01C IMM 0x0000
            9'd136: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h010, 16'h0000};   // WR 0x020 IMM 0x0000
            9'd137: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h011, 16'h0000};   // WR 0x022 IMM 0x0000
            9'd138: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h012, 16'h0000};   // WR 0x024 IMM 0x0000
            9'd139: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h014, 16'h0000};   // WR 0x028 IMM 0x0000
            9'd140: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h015, 16'h0000};   // WR 0x02A IMM 0x0000
            9'd141: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h016, 16'h0707};   // WR 0x02C IMM 0x0707
            9'd142: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h017, 16'h0000};   // WR 0x02E IMM 0x0000
            9'd143: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h028, 16'h4000};   // WR 0x050 IMM 0x4000
            9'd144: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h029, 16'h4800};   // WR 0x052 IMM 0x4800
            9'd145: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h042, 16'h0000};   // WR 0x084 IMM 0x0000
            9'd146: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h05E, 16'h0001};   // WR 0x0BC IMM 0x0001
            9'd147: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h068, 16'h0401};   // WR 0x0D0 IMM 0x0401
            9'd148: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h06A, 16'h0001};   // WR 0x0D4 IMM 0x0001
            9'd149: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h070, 16'h0008};   // WR 0x0E0 IMM 0x0008
            9'd150: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h076, 16'h3F03};   // WR 0x0EC IMM 0x3F03
            9'd151: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0CA, 16'h0000};   // WR 0x194 IMM 0x0000
            9'd152: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0CC, 16'h0000};   // WR 0x198 IMM 0x0000
            9'd153: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0D1, 16'h0001};   // WR 0x1A2 IMM 0x0001
            9'd154: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h112, 16'h0003};   // WR 0x224 IMM 0x0003
            9'd155: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h118, 16'h0047};   // WR 0x230 IMM 0x0047
            9'd156: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h003, 16'h0000};   // WR 0x006 IMM 0x0000
            9'd157: ins <= {5'd13, 1'b0, 5'd13, 1'b0, 9'h001, 16'hFFFF};   // BF 13 H_NEXT
            9'd158: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h02B, 16'h0000};   // WR 0x056 IMM 0x0000
            9'd159: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h060, 16'h0000};   // WR 0x0C0 IMM 0x0000
            9'd160: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h062, 16'h0000};   // WR 0x0C4 IMM 0x0000
            9'd161: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0D2, 16'h0000};   // WR 0x1A4 IMM 0x0000
            9'd162: ins <= {5'd3, 1'b1, 5'd0, 1'b0, 9'h13C, 16'h000F};   // WR 0x278 IMM 0x000F !
            9'd163: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd164: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd165: ins <= {5'd11, 1'b0, 5'd8, 1'b0, 9'h0A8, 16'hFFFF};   // BR BBW W158_W
            9'd166: ins <= {5'd11, 1'b0, 5'd9, 1'b0, 9'h0AB, 16'hFFFF};   // BR BBR W158_R
            9'd167: ins <= {5'd3, 1'b1, 5'd0, 1'b0, 9'h0AE, 16'h0000};   // WR 0x15C IMM 0 !
            9'd168: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h0AD, 16'h00FF};   // RDL 0x15A 0x00FF
            9'd169: ins <= {5'd16, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // MEM BBW
            9'd170: ins <= {5'd3, 1'b1, 5'd0, 1'b0, 9'h0AE, 16'h0000};   // WR 0x15C IMM 0 !
            9'd171: ins <= {5'd11, 1'b0, 5'd10, 1'b0, 9'h0AE, 16'hFFFF};   // BR BBRO W158_F
            9'd172: ins <= {5'd16, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // MEM BBR
            9'd173: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h0AE, 16'hFFFF};   // WR 0x15C !
            9'd174: ins <= {5'd4, 1'b0, 5'd7, 1'b0, 9'h000, 16'hFFFF};   // LD BBFIX
            9'd175: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h0AE, 16'hFFFF};   // WR 0x15C !
            9'd176: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFF};   // LD W
            9'd177: ins <= {5'd3, 1'b0, 5'd3, 1'b1, 9'h000, 16'hFFFF};   // WR IX
            9'd178: ins <= {5'd12, 1'b0, 5'd7, 1'b0, 9'h0B8, 16'hFFFF};   // BT 7 W17C_R
            9'd179: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h0BF, 16'hFFFF};   // RDL 0x17E
            9'd180: ins <= {5'd16, 1'b0, 5'd3, 1'b0, 9'h000, 16'hFFFF};   // MEM RFWL
            9'd181: ins <= {5'd4, 1'b0, 5'd2, 1'b0, 9'h000, 16'h0003};   // LD W 0x0003
            9'd182: ins <= {5'd16, 1'b0, 5'd4, 1'b0, 9'h000, 16'hFFFF};   // MEM RFWH
            9'd183: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd184: ins <= {5'd16, 1'b0, 5'd5, 1'b0, 9'h000, 16'hFFFF};   // MEM RFRL
            9'd185: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h0BF, 16'hFFFF};   // WR 0x17E
            9'd186: ins <= {5'd16, 1'b0, 5'd6, 1'b0, 9'h000, 16'hFFFF};   // MEM RFRH
            9'd187: ins <= {5'd8, 1'b0, 5'd2, 1'b0, 9'h000, 16'hFFFC};   // OR W 0xFFFC
            9'd188: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h0BE, 16'hFFFF};   // WR 0x17C !
            9'd189: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h0C0, 16'hFFFF};   // RDL 0x180
            9'd190: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hE4B1};   // ADD IMM 0xE4B1
            9'd191: ins <= {5'd11, 1'b0, 5'd3, 1'b0, 9'h0C1, 16'hFFFF};   // BR C T_K
            9'd192: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hF424};   // ADD IMM 0xF424
            9'd193: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h0C0, 16'hFFFF};   // WR 0x180
            9'd194: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hE4B1};   // ADD IMM 0xE4B1
            9'd195: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h007, 16'hFFFF};   // SPC K268
            9'd196: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h0AF, 16'hFFFF};   // RDL 0x15E
            9'd197: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h0CD, 16'hFFFF};   // BR Z T_U
            9'd198: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // ADD IMM 0xFFFF
            9'd199: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h0AF, 16'hFFFF};   // WR 0x15E
            9'd200: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h0CD, 16'hFFFF};   // BR NZ T_U
            9'd201: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h01E, 16'h0000};   // WR 0x03C IMM 0
            9'd202: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h10A, 16'h0001};   // WR 0x214 IMM 1
            9'd203: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0CE, 16'h0084};   // WR 0x19C IMM 0x0084
            9'd204: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h146, 16'hFFFF};   // CALL POW0
            9'd205: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h074, 16'hFFFF};   // RDL 0x0E8
            9'd206: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h117, 16'hFFFF};   // BF 0 T_D0
            9'd207: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h07C, 16'hFFFF};   // RDL 0x0F8
            9'd208: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0008};   // ADD IMM 0x0008
            9'd209: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h07C, 16'hFFFF};   // WR 0x0F8
            9'd210: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h006, 16'hFFFF};   // SPC USP
            9'd211: ins <= {5'd11, 1'b0, 5'd4, 1'b0, 9'h0DF, 16'hFFFF};   // BR NC T_B0
            9'd212: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h07D, 16'hFFFF};   // RDL 0x0FA
            9'd213: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0001};   // ADD IMM 0x0001
            9'd214: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h07D, 16'hFFFF};   // WR 0x0FA
            9'd215: ins <= {5'd11, 1'b0, 5'd4, 1'b0, 9'h0DF, 16'hFFFF};   // BR NC T_B0
            9'd216: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h07E, 16'hFFFF};   // RDL 0x0FC
            9'd217: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0001};   // ADD IMM 0x0001
            9'd218: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h07E, 16'hFFFF};   // WR 0x0FC
            9'd219: ins <= {5'd11, 1'b0, 5'd4, 1'b0, 9'h0DF, 16'hFFFF};   // BR NC T_B0
            9'd220: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h07F, 16'hFFFF};   // RDL 0x0FE
            9'd221: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0001};   // ADD IMM 0x0001
            9'd222: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h07F, 16'hFFFF};   // WR 0x0FE
            9'd223: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h075, 16'hFFFF};   // RDL 0x0EA
            9'd224: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h0E9, 16'hFFFF};   // BF 0 T_M0
            9'd225: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h08E, 16'hFFFF};   // RD 0x11C
            9'd226: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h088, 16'hFFFF};   // RD 0x110
            9'd227: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd228: ins <= {5'd11, 1'b0, 5'd11, 1'b0, 9'h0E9, 16'hFFFF};   // BR NOTPB T_M0
            9'd229: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h000, 16'h8000};   // SPC IFOR IMM 0x8000
            9'd230: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01C, 16'hFFFF};   // RDL 0x038
            9'd231: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h0E9, 16'hFFFF};   // BF 0 T_M0
            9'd232: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h142, 16'hFFFF};   // CALL POW_ON
            9'd233: ins <= {5'd11, 1'b0, 5'd6, 1'b0, 9'h117, 16'hFFFF};   // BR NOTMS T_D0
            9'd234: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h075, 16'hFFFF};   // RDL 0x0EA
            9'd235: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h102, 16'hFFFF};   // BF 0 T_BCR
            9'd236: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07C, 16'hFFFF};   // RD 0x0F8
            9'd237: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h078, 16'hFFFF};   // RD 0x0F0
            9'd238: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFC00};   // LD Q 0xFC00
            9'd239: ins <= {5'd9, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFC00};   // XOR Q 0xFC00
            9'd240: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h102, 16'hFFFF};   // BR NZ T_BCR
            9'd241: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07D, 16'hFFFF};   // RD 0x0FA
            9'd242: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h079, 16'hFFFF};   // RD 0x0F2
            9'd243: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd244: ins <= {5'd9, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // XOR Q
            9'd245: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h102, 16'hFFFF};   // BR NZ T_BCR
            9'd246: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07E, 16'hFFFF};   // RD 0x0FC
            9'd247: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07A, 16'hFFFF};   // RD 0x0F4
            9'd248: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd249: ins <= {5'd9, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // XOR Q
            9'd250: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h102, 16'hFFFF};   // BR NZ T_BCR
            9'd251: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07F, 16'hFFFF};   // RD 0x0FE
            9'd252: ins <= {5'd1, 1'b0, 5'd0, 1'b0, 9'h07B, 16'hFFFF};   // RD 0x0F6
            9'd253: ins <= {5'd4, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // LD Q
            9'd254: ins <= {5'd9, 1'b0, 5'd1, 1'b0, 9'h000, 16'hFFFF};   // XOR Q
            9'd255: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h102, 16'hFFFF};   // BR NZ T_BCR
            9'd256: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h005, 16'hFFFF};   // SPC BLOCK_CLR
            9'd257: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h134, 16'hFFFF};   // CALL I14R
            9'd258: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h08E, 16'hFFFF};   // RDL 0x11C
            9'd259: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h108, 16'hFFFF};   // BR Z T_BZR
            9'd260: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // ADD IMM 0xFFFF
            9'd261: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h08E, 16'hFFFF};   // WR 0x11C
            9'd262: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h108, 16'hFFFF};   // BR NZ T_BZR
            9'd263: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h12E, 16'hFFFF};   // CALL I14B
            9'd264: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h08E, 16'hFFFF};   // RDL 0x11C
            9'd265: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h10C, 16'hFFFF};   // BR NZ T_D1
            9'd266: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h046, 16'hFFFF};   // RDL 0x08C
            9'd267: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h08E, 16'hFFFF};   // WR 0x11C
            9'd268: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h09A, 16'hFFFF};   // RDL 0x134
            9'd269: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h117, 16'hFFFF};   // BR Z T_D0
            9'd270: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // ADD IMM 0xFFFF
            9'd271: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h09A, 16'hFFFF};   // WR 0x134
            9'd272: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h117, 16'hFFFF};   // BR NZ T_D0
            9'd273: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h000, 16'h2000};   // SPC IFOR IMM 0x2000
            9'd274: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h003, 16'h0007};   // RDL 0x006 0x0007
            9'd275: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h117, 16'hFFFF};   // BR NZ T_D0
            9'd276: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01C, 16'hFFFF};   // RDL 0x038
            9'd277: ins <= {5'd12, 1'b0, 5'd1, 1'b0, 9'h117, 16'hFFFF};   // BT 1 T_D0
            9'd278: ins <= {5'd14, 1'b0, 5'd0, 1'b0, 9'h144, 16'hFFFF};   // CALL POW_OFF
            9'd279: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h077, 16'hFFFF};   // RDL 0x0EE
            9'd280: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h127, 16'hFFFF};   // BF 0 T_CF
            9'd281: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h10E, 16'hFFFF};   // RDL 0x21C
            9'd282: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFF8};   // ADD IMM 0xFFF8
            9'd283: ins <= {5'd11, 1'b0, 5'd3, 1'b0, 9'h124, 16'hFFFF};   // BR C T_CR
            9'd284: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h08C, 16'hFFFF};   // RDL 0x118
            9'd285: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h126, 16'hFFFF};   // BR Z T_CZ
            9'd286: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // ADD IMM 0xFFFF
            9'd287: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h08C, 16'hFFFF};   // WR 0x118
            9'd288: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h10E, 16'hFFFF};   // RDL 0x21C
            9'd289: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0002};   // ADD IMM 0x0002
            9'd290: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h10E, 16'hFFFF};   // WR 0x21C
            9'd291: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h127, 16'hFFFF};   // BR ALWAYS T_CF
            9'd292: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h10E, 16'hFFFF};   // WR 0x21C
            9'd293: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h127, 16'hFFFF};   // BR ALWAYS T_CF
            9'd294: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h10E, 16'h0000};   // WR 0x21C IMM 0
            9'd295: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h086, 16'hFFFF};   // RDL 0x10C
            9'd296: ins <= {5'd11, 1'b0, 5'd1, 1'b0, 9'h12D, 16'hFFFF};   // BR Z T_END
            9'd297: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFF8};   // ADD IMM 0xFFF8
            9'd298: ins <= {5'd11, 1'b0, 5'd4, 1'b0, 9'h12C, 16'hFFFF};   // BR NC T_CF0
            9'd299: ins <= {5'd3, 1'b1, 5'd3, 1'b0, 9'h086, 16'hFFFF};   // WR 0x10C !
            9'd300: ins <= {5'd3, 1'b1, 5'd0, 1'b0, 9'h086, 16'h0000};   // WR 0x10C IMM 0 !
            9'd301: ins <= {5'd0, 1'b1, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // NOP !
            9'd302: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h046, 16'hFFFF};   // RDL 0x08C
            9'd303: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h08E, 16'hFFFF};   // WR 0x11C
            9'd304: ins <= {5'd11, 1'b0, 5'd7, 1'b0, 9'h141, 16'hFFFF};   // BR BLOCK I14_RET
            9'd305: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h075, 16'hFFFF};   // RDL 0x0EA
            9'd306: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h141, 16'hFFFF};   // BF 0 I14_RET
            9'd307: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h138, 16'hFFFF};   // BR ALWAYS I14_BODY
            9'd308: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h046, 16'hFFFF};   // RDL 0x08C
            9'd309: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h08E, 16'hFFFF};   // WR 0x11C
            9'd310: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h075, 16'hFFFF};   // RDL 0x0EA
            9'd311: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h141, 16'hFFFF};   // BF 0 I14_RET
            9'd312: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h000, 16'h4000};   // SPC IFOR IMM 0x4000
            9'd313: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h09A, 16'hFFFF};   // WR 0x134 IMM 0xFFFF
            9'd314: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h058, 16'hFFF2};   // RDL 0x0B0 0xFFF2
            9'd315: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h058, 16'hFFFF};   // WR 0x0B0
            9'd316: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h044, 16'hFFFF};   // RDL 0x088
            9'd317: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h13F, 16'hFFFF};   // BR NZ I14_L
            9'd318: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h047, 16'hFFFF};   // RDL 0x08E
            9'd319: ins <= {5'd6, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // ADD IMM 0xFFFF
            9'd320: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h044, 16'hFFFF};   // WR 0x088
            9'd321: ins <= {5'd15, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // RET
            9'd322: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h022, 16'h0001};   // WR 0x044 IMM 1
            9'd323: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h147, 16'hFFFF};   // BR ALWAYS POW
            9'd324: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h022, 16'h0002};   // WR 0x044 IMM 2
            9'd325: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h147, 16'hFFFF};   // BR ALWAYS POW
            9'd326: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h022, 16'h0000};   // WR 0x044 IMM 0
            9'd327: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h020, 16'hFFFF};   // RDL 0x040
            9'd328: ins <= {5'd13, 1'b0, 5'd15, 1'b0, 9'h14B, 16'hFFFF};   // BF 15 P_NF
            9'd329: ins <= {5'd12, 1'b0, 5'd0, 1'b0, 9'h16D, 16'hFFFF};   // BT 0 P_REQ0
            9'd330: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h15C, 16'hFFFF};   // BR ALWAYS P_REQ3
            9'd331: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h002, 16'hFFFF};   // RDL 0x004
            9'd332: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h16D, 16'hFFFF};   // BF 0 P_REQ0
            9'd333: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h022, 16'hFFFF};   // RDL 0x044
            9'd334: ins <= {5'd12, 1'b0, 5'd0, 1'b0, 9'h15C, 16'hFFFF};   // BT 0 P_REQ3
            9'd335: ins <= {5'd12, 1'b0, 5'd1, 1'b0, 9'h158, 16'hFFFF};   // BT 1 P_OFF
            9'd336: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'hFFFF};   // RDL 0x03C
            9'd337: ins <= {5'd13, 1'b0, 5'd9, 1'b0, 9'h154, 16'hFFFF};   // BF 9 P_N9
            9'd338: ins <= {5'd12, 1'b0, 5'd1, 1'b0, 9'h15C, 16'hFFFF};   // BT 1 P_REQ3
            9'd339: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h155, 16'hFFFF};   // BR ALWAYS P_NONE
            9'd340: ins <= {5'd12, 1'b0, 5'd0, 1'b0, 9'h158, 16'hFFFF};   // BT 0 P_OFF
            9'd341: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h024, 16'hFFFF};   // RDL 0x048
            9'd342: ins <= {5'd12, 1'b0, 5'd1, 1'b0, 9'h15C, 16'hFFFF};   // BT 1 P_REQ3
            9'd343: ins <= {5'd15, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // RET
            9'd344: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h024, 16'hFFFF};   // RDL 0x048
            9'd345: ins <= {5'd12, 1'b0, 5'd1, 1'b0, 9'h15C, 16'hFFFF};   // BT 1 P_REQ3
            9'd346: ins <= {5'd12, 1'b0, 5'd0, 1'b0, 9'h178, 16'hFFFF};   // BT 0 P_RET
            9'd347: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h16D, 16'hFFFF};   // BR ALWAYS P_REQ0
            9'd348: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01A, 16'hFFFF};   // RDL 0x034
            9'd349: ins <= {5'd13, 1'b0, 5'd0, 1'b0, 9'h161, 16'hFFFF};   // BF 0 P3_C0
            9'd350: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'hFFFF};   // RDL 0x03C
            9'd351: ins <= {5'd13, 1'b0, 5'd9, 1'b0, 9'h178, 16'hFFFF};   // BF 9 P_RET
            9'd352: ins <= {5'd11, 1'b0, 5'd0, 1'b0, 9'h164, 16'hFFFF};   // BR ALWAYS P3_HI
            9'd353: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h01A, 16'h0001};   // WR 0x034 IMM 1
            9'd354: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h10A, 16'h0001};   // WR 0x214 IMM 1
            9'd355: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0CE, 16'h0084};   // WR 0x19C IMM 0x0084
            9'd356: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'hFFFF};   // RDL 0x03C
            9'd357: ins <= {5'd8, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0100};   // OR IMM 0x0100
            9'd358: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h01E, 16'hFFFF};   // WR 0x03C
            9'd359: ins <= {5'd13, 1'b0, 5'd9, 1'b0, 9'h178, 16'hFFFF};   // BF 9 P_RET
            9'd360: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h0AF, 16'hFFFF};   // RDL 0x15E
            9'd361: ins <= {5'd11, 1'b0, 5'd2, 1'b0, 9'h178, 16'hFFFF};   // BR NZ P_RET
            9'd362: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0AF, 16'h0100};   // WR 0x15E IMM 256
            9'd363: ins <= {5'd17, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0800};   // SPC IFOR IMM 0x0800
            9'd364: ins <= {5'd15, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // RET
            9'd365: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01A, 16'hFFFF};   // RDL 0x034
            9'd366: ins <= {5'd12, 1'b0, 5'd0, 1'b0, 9'h171, 16'hFFFF};   // BT 0 P0_GO
            9'd367: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'hFFFF};   // RDL 0x03C
            9'd368: ins <= {5'd12, 1'b0, 5'd9, 1'b0, 9'h178, 16'hFFFF};   // BT 9 P_RET
            9'd369: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h01A, 16'h0000};   // WR 0x034 IMM 0
            9'd370: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h10A, 16'h0009};   // WR 0x214 IMM 9
            9'd371: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0CE, 16'h0004};   // WR 0x19C IMM 0x0004
            9'd372: ins <= {5'd2, 1'b0, 5'd0, 1'b0, 9'h01E, 16'h0202};   // RDL 0x03C 0x0202
            9'd373: ins <= {5'd8, 1'b0, 5'd0, 1'b0, 9'h000, 16'h0200};   // OR IMM 0x0200
            9'd374: ins <= {5'd3, 1'b0, 5'd3, 1'b0, 9'h01E, 16'hFFFF};   // WR 0x03C
            9'd375: ins <= {5'd3, 1'b0, 5'd0, 1'b0, 9'h0AF, 16'h0000};   // WR 0x15E IMM 0
            9'd376: ins <= {5'd15, 1'b0, 5'd0, 1'b0, 9'h000, 16'hFFFF};   // RET
            default: ins <= 37'd0;
        endcase
    end

    (* romstyle = "M10K" *) logic [8:0] dtab [0:1023];
    initial begin
        for (int i = 0; i < 1024; i++) dtab[i] = 9'd0;            // H_RD / H_WR
        dtab[10'h008] = 9'd11;   // R 010 H_RIF
        dtab[10'h009] = 9'd12;   // R 012 H_RIE
        dtab[10'h022] = 9'd13;   // R 044 H_RRND
        dtab[10'h05B] = 9'd8;   // R 0B6 H_RDB6
        dtab[10'h05E] = 9'd7;   // R 0BC H_RDBC
        dtab[10'h08C] = 9'd14;   // R 118 H_RCMD
        dtab[10'h0AF] = 9'd20;   // R 15E H_RZERO
        dtab[10'h0C0] = 9'd20;   // R 180 H_RZERO
        dtab[10'h0E8] = 9'd9;   // R 1D0 H_RDCS
        dtab[10'h0E9] = 9'd9;   // R 1D2 H_RDCS
        dtab[10'h0EA] = 9'd9;   // R 1D4 H_RDCS
        dtab[10'h0EB] = 9'd9;   // R 1D6 H_RDCS
        dtab[10'h0EC] = 9'd9;   // R 1D8 H_RDCS
        dtab[10'h0ED] = 9'd9;   // R 1DA H_RDCS
        dtab[10'h0EE] = 9'd9;   // R 1DC H_RDCS
        dtab[10'h0EF] = 9'd9;   // R 1DE H_RDCS
        dtab[10'h10E] = 9'd20;   // R 21C H_RZERO
        dtab[10'h200] = 9'd1;   // W 000 H_NEXT
        dtab[10'h202] = 9'd118;   // W 004 H_W004
        dtab[10'h203] = 9'd78;   // W 006 H_W006
        dtab[10'h208] = 9'd39;   // W 010 H_W010
        dtab[10'h209] = 9'd41;   // W 012 H_W012
        dtab[10'h214] = 9'd27;   // W 028 H_M000F
        dtab[10'h215] = 9'd29;   // W 02A H_M07FF
        dtab[10'h218] = 9'd37;   // W 030 H_MFF0E
        dtab[10'h21A] = 9'd1;   // W 034 H_NEXT
        dtab[10'h21B] = 9'd44;   // W 036 H_W036
        dtab[10'h21C] = 9'd88;   // W 038 H_W038
        dtab[10'h21E] = 9'd63;   // W 03C H_W03C
        dtab[10'h220] = 9'd47;   // W 040 H_W040
        dtab[10'h222] = 9'd1;   // W 044 H_NEXT
        dtab[10'h224] = 9'd92;   // W 048 H_W048
        dtab[10'h22A] = 9'd1;   // W 054 H_NEXT
        dtab[10'h22B] = 9'd31;   // W 056 H_M0FFF
        dtab[10'h22C] = 9'd33;   // W 058 H_M1FFE
        dtab[10'h22D] = 9'd31;   // W 05A H_M0FFF
        dtab[10'h22E] = 9'd31;   // W 05C H_M0FFF
        dtab[10'h230] = 9'd1;   // W 060 H_NEXT
        dtab[10'h231] = 9'd33;   // W 062 H_M1FFE
        dtab[10'h232] = 9'd31;   // W 064 H_M0FFF
        dtab[10'h234] = 9'd33;   // W 068 H_M1FFE
        dtab[10'h236] = 9'd31;   // W 06C H_M0FFF
        dtab[10'h238] = 9'd1;   // W 070 H_NEXT
        dtab[10'h23A] = 9'd33;   // W 074 H_M1FFE
        dtab[10'h23B] = 9'd31;   // W 076 H_M0FFF
        dtab[10'h24C] = 9'd1;   // W 098 H_NEXT
        dtab[10'h256] = 9'd57;   // W 0AC H_W0AC
        dtab[10'h257] = 9'd60;   // W 0AE H_W0AE
        dtab[10'h258] = 9'd1;   // W 0B0 H_NEXT
        dtab[10'h25A] = 9'd23;   // W 0B4 H_M0000
        dtab[10'h25B] = 9'd1;   // W 0B6 H_NEXT
        dtab[10'h25C] = 9'd1;   // W 0B8 H_NEXT
        dtab[10'h274] = 9'd25;   // W 0E8 H_M0001
        dtab[10'h275] = 9'd108;   // W 0EA H_W0EA
        dtab[10'h278] = 9'd54;   // W 0F0 H_W0F0
        dtab[10'h28C] = 9'd51;   // W 118 H_W118
        dtab[10'h2AC] = 9'd163;   // W 158 H_W158
        dtab[10'h2AE] = 9'd1;   // W 15C H_NEXT
        dtab[10'h2AF] = 9'd1;   // W 15E H_NEXT
        dtab[10'h2BE] = 9'd176;   // W 17C H_W17C
        dtab[10'h2C0] = 9'd1;   // W 180 H_NEXT
        dtab[10'h2C2] = 9'd35;   // W 184 H_M413F
        dtab[10'h2CE] = 9'd1;   // W 19C H_NEXT
        dtab[10'h2D4] = 9'd1;   // W 1A8 H_NEXT
        dtab[10'h2D6] = 9'd1;   // W 1AC H_NEXT
        dtab[10'h2E2] = 9'd1;   // W 1C4 H_NEXT
        dtab[10'h308] = 9'd1;   // W 210 H_NEXT
        dtab[10'h30A] = 9'd1;   // W 214 H_NEXT
        dtab[10'h30E] = 9'd40;   // W 21C H_W21C
        dtab[10'h334] = 9'd1;   // W 268 H_NEXT
    end
    always_ff @(posedge clk) dt_q <= dtab[dt_a];
// ---- END GENERATED ROMS
endmodule
`default_nettype wire
