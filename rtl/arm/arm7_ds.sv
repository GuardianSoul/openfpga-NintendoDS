// arm7_ds: a compact ARMv4T core, the DS's ARM7TDMI, laid out as the real one: F, D and E shift together, every
// instruction runs in E, and E reads its operands itself. One ARM7 cycle = two clocks (ph 0, 1):
//   ph 0: the register file (one MLAB, read without a clock) gives Rm or a store's data; rotator -> sho
//   ph 1: it gives Rn; adder and logic -> the register file, the flags, pc_f or addr, at the end of ph 1
// So there are no operand registers and no bypass: a read in either phase sees every earlier write. r15 is pc_f, E's
// PC + 8 (+ 4): nothing leaves E unless the word behind it was fetched, as the real core's bus stalls everything.
// Index 15 of the register file is spare: it holds what the real core's r15 has after E's first cycle (PC + 12), and
// a SWP's loaded word.
//
// Ports as arm_cpu's ARM7 side: a request is answered (data, ok) at the next clock edge; ok = 0 asks for it again.
// Halt: an accepted store of 0x80 to HALTCNT (0x04000301) stops it until wake or fiq.
module arm7_ds import arm_pkg::*; (
  input  logic        clk,
  input  logic        rst,
  input  logic        run,
  input  logic [31:0] reset_pc,
  input  logic        hivecs,
  input  logic        irq,
  input  logic        fiq,
  input  logic        wake,
  output logic        i_req,
  output logic [31:0] i_addr,
  input  logic [31:0] i_rdata,
  input  logic        i_ok,
  output logic        d_req,
  output logic        d_we,
  output logic [3:0]  d_be,
  output logic [31:0] d_addr,
  output logic [31:0] d_wdata,
  input  logic [31:0] d_rdata,
  input  logic        d_ok,
  output logic        dbg_wen,
  output logic [4:0]  dbg_wa,
  output logic [31:0] dbg_wd,
  output logic        dbg_retire,
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_cpsr,
  output logic        dbg_halted
);
  localparam logic [2:0] TK_ARM = 3'd0, TK_B = 3'd1, TK_BL1 = 3'd2, TK_BL2 = 3'd3;
  localparam logic [3:0] K_DP = 4'd0, K_MRS = 4'd1, K_MSR = 4'd2, K_MUL = 4'd3, K_MULL = 4'd4,
                         K_SWP = 4'd5, K_HW = 4'd6, K_BX = 4'd7, K_SDT = 4'd8, K_BLK = 4'd9,
                         K_B = 4'd10, K_SWI = 4'd11, K_UND = 4'd12, K_NOP = 4'd13,
                         K_TB = 4'd14, K_TBL = 4'd15;
  // E's steps: 0 is every instruction's first cycle, LAST the last of a longer one (REFILL after a load into r15)
  localparam logic [2:0] ES_0 = 3'd0, ES_MEM = 3'd1, ES_LAST = 3'd2, ES_REFILL = 3'd3, ES_BLK0 = 3'd4,
                         ES_WAIT = 3'd5, ES_LO = 3'd6, ES_SWPW = 3'd7;

  // ---------------------------------------------------------------- state
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rf [0:31];   // physical registers (arm_pkg::phys_reg)
  (* ramstyle = "MLAB, no_rw_check" *) logic [12:0] spsr [0:4];  // (not reset: only an SPSR read before any write can tell)
  logic [31:1] pc_f;                       // the fetch address; r15 as E reads it
  logic [12:0] cpsr;                       // psr13: N Z C V Q I F T mode
  logic        ph;
  logic        halted;
  logic        d_v, e_v;
  logic [31:0] d_ins, ins;                 // ARM encoding (Thumb expanded; a Thumb branch has its offset in [21:0])
  logic [2:0]  d_tk, tk;                   // Thumb branch kind
  logic        d_pcal, tpcal;              // Thumb: r15 reads as (PC+4) & ~3
  logic [3:0]  k;                          // E's kind
  logic        e_mem, e_blk, e_mul, e_mull, e_swp, e_sr, e_rs0, b_usr;   // (registered: k's most used decodes)
  logic [2:0]  es;                         // E's step
  logic [31:0] sho;                        // the rotator's result
  logic        shc;
  logic [31:0] opc;                        // Rs: a shift amount or the multiplier's operand
  logic [31:0] addr;                       // memory address / block cursor
  logic [15:0] rl;                         // block: registers left
  logic        first;
  logic [2:0]  wcnt;                       // multiply: wait cycles left
  logic        mc;                         // long multiply: the low word's carry
  logic [63:0] prod_q;
  logic [31:0] rf_wd;                      // the last result, for Z
  logic        z_en, z_lo, zq;             // Z lands a clock after the result (a long multiply's from both words)
  logic        x, x_f;                     // an interrupt's entry cycle, and FIQ

  wire  [4:0]  mode = cpsr[4:0];
  wire         tbit = cpsr[5];
  wire  [3:0]  nzcv = cpsr[12:9];
  wire  [2:0]  sidx = spsr_idx(mode);
  wire         has_spsr = (sidx != 3'd7);
  wire  [12:0] spsr_m = spsr[has_spsr ? sidx : 3'd0];
  wire  [31:0] r15 = {pc_f, 1'b0};
  wire         z_d = rf_wd == 32'h0 && zq;
  wire         z_now = z_en ? z_d : cpsr[11];      // (for an MRS, read in the ph 0 that Z lands in)

  function automatic logic [31:0] psr32(input logic [12:0] p);
    return {p[12:8], 19'h0, p[7:0]};
  endfunction

  // ---------------------------------------------------------------- Thumb
  logic [31:0] f_arm, f_boff;
  logic [2:0]  f_kind;
  logic        f_pcal;
  arm_thumb u_thumb (.hw(pc_f[1] ? i_rdata[31:16] : i_rdata[15:0]), .v5(1'b0), .arm(f_arm),
                     .kind(f_kind), .boff(f_boff), .pcalign(f_pcal));

  // ---------------------------------------------------------------- decode
  function automatic logic [3:0] kdec(input logic [31:0] ins, input logic [2:0] tk);
    logic [3:0] k;
    k = K_UND;
    if (tk != TK_ARM) k = (tk == TK_B) ? K_TB : (tk == TK_BL1 || tk == TK_BL2) ? K_TBL : K_UND;
    else if (ins[31:28] == 4'hF) k = K_NOP;
    else case (ins[27:25])
      3'b000: begin
        if (ins[7] && ins[4]) begin
          if (ins[6:5] == 2'b00) begin
            if (ins[24:22] == 3'b000)                            k = K_MUL;
            else if (ins[24:23] == 2'b01)                        k = K_MULL;
            else if (ins[24:23] == 2'b10 && ins[21:20] == 2'b00) k = K_SWP;
            else                                                 k = K_UND;
          end else if (!ins[20] && ins[6]) k = K_UND;           // LDRD/STRD: ARMv5
          else                             k = K_HW;
        end else if (ins[24:23] == 2'b10 && !ins[20]) begin
          if (ins[7:4] == 4'b0000)                             k = ins[21] ? K_MSR : K_MRS;
          else if (ins[7:4] == 4'b0001 && ins[22:21] == 2'b01) k = K_BX;
          else                                                 k = K_UND;
        end else k = K_DP;
      end
      3'b001: k = (ins[24:23] == 2'b10 && !ins[20]) ? (ins[21] ? K_MSR : K_UND) : K_DP;
      3'b010: k = K_SDT;
      3'b011: k = ins[4] ? K_UND : K_SDT;
      3'b100: k = K_BLK;
      3'b101: k = K_B;
      3'b110: k = K_UND;
      default: k = ins[24] ? K_SWI : K_UND;
    endcase
    return k;
  endfunction
  wire [3:0] dk = kdec(d_ins, d_tk);

  wire [3:0] rn = ins[19:16], rd = ins[15:12], rs = ins[11:8], rm = ins[3:0];
  wire       is_load = ins[20];
  wire       e_ok    = cond_pass(ins[31:28], nzcv);            // (E's first cycle; a later one has passed)
  wire       e_bimm  = k == K_B || k == K_TB || (k == K_TBL && tk == TK_BL1);
  wire       alu_wr  = (ins[24:23] != 2'b10);                   // not TST TEQ CMP CMN

  // block transfer
  wire        bempty = ins[15:0] == 16'h0;                       // ARMv4: an empty list moves r15
  wire [15:0] blist = {ins[15] || bempty, ins[14:0]};
  logic [4:0] bcnt;
  always_comb begin
    bcnt = 5'd0;
    for (int i = 0; i < 16; i++) bcnt = bcnt + {4'h0, blist[i]};
    if (bempty) bcnt = 5'd16;
  end
  function automatic logic [3:0] lowest(input logic [15:0] x);
    for (int i = 0; i < 16; i++) if (x[i]) return 4'(i);
    return 4'd0;
  endfunction
  logic [3:0]  br;                                              // the lowest of rl
  wire  [15:0] rl_n = rl & ~(16'h1 << br);                      // the registers left after this one
  wire  [15:0] rl_d = es == ES_0 ? blist : rl_n;
  wire  [4:0]  bmode = (b_usr && es == ES_MEM) ? M_USR : mode;  // S bit: user bank (not LDM with r15)

  // ---------------------------------------------------------------- the register file's one read
  // ph 0: Rm, or the data of a store; Rs before a shift or multiply (then Rm is ph 1's)
  // ph 1: Rn or an accumulator, decided in ph 0 (E's registers have not changed since the last ph 1)
  logic [3:0]  r1_d;
  logic [4:0]  ra1_q;
  wire         e_rs = e_rs0 && es == ES_0;
  always_comb begin
    r1_d = rn;
    if (k == K_TBL) r1_d = 4'd14;
    if ((e_mul || e_mull) && es == ES_0) r1_d = rm;
    else if (e_mul) r1_d = rd;                                  // (MUL: Rd is [19:16], the accumulator [15:12])
    else if (e_mull && es != ES_LAST) r1_d = rd;                // RdLo, then [19:16] RdHi
    else if (e_swp && es == ES_LAST) r1_d = 4'hF;
  end
  always_ff @(posedge clk) ra1_q <= phys_reg(r1_d, mode);
  // ph 0's numbers from registers, taken with the instruction (a mode change flushes D, so it is E's mode): only the
  // choice and a block's next register are left in front of the RAM (es -> r0_n -> phys_reg -> RAM -> rotator -> sho, #1486/#1489)
  logic [4:0]  ra_rm, ra_rs, ra_rd;
  wire  [4:0]  ra0 = e_rs ? ra_rs : (es == ES_MEM && !is_load) ? (e_blk ? phys_reg(br, bmode) : e_mem ? ra_rd : ra_rm) : ra_rm;
  wire [31:0] rq = rf[ph ? ra1_q : ra0];

  // ---------------------------------------------------------------- rotator (ph 0)
  logic [31:0] immv;
  logic        s_imm, s_pass;
  always_comb begin
    s_pass = 1'b0;                                              // through unrotated
    s_imm  = 1'b0;
    immv   = 32'h0;
    case (k)
      K_DP, K_MSR: if (ins[25]) begin s_imm = 1'b1; immv = {24'h0, ins[7:0]}; end else if (k == K_MSR) s_pass = 1'b1;
      K_SDT: if (!ins[25]) begin s_imm = 1'b1; s_pass = 1'b1; immv = {20'h0, ins[11:0]}; end
      K_HW: begin s_pass = 1'b1; if (ins[22]) begin s_imm = 1'b1; immv = {24'h0, ins[11:8], ins[3:0]}; end end
      K_BLK: begin s_imm = 1'b1; s_pass = 1'b1; immv = {25'h0, bcnt, 2'b00}; end
      K_B: begin s_imm = 1'b1; s_pass = 1'b1; immv = {{6{ins[23]}}, ins[23:0], 2'b00}; end
      K_TB, K_TBL: begin s_imm = 1'b1; s_pass = 1'b1; immv = {{9{ins[21]}}, ins[21:0], 1'b0}; end
      K_MRS: begin s_imm = 1'b1; s_pass = 1'b1; immv = ins[22] ? (has_spsr ? psr32(spsr_m) : 32'h0) : psr32({cpsr[12], z_now, cpsr[10:0]}); end
      K_SWP: begin s_imm = 1'b1; s_pass = 1'b1; end
      K_BX, K_MUL, K_MULL: s_pass = 1'b1;
      default: ;
    endcase
  end
  wire        i_rot = (k == K_DP || k == K_MSR) && ins[25];      // the rotated immediate
  wire [31:0] shv = s_imm ? immv : (es == ES_0 && rm == 4'hF) ? r15 : rq;
  wire [1:0]  sht = s_pass ? 2'b00 : i_rot ? 2'b11 : ins[6:5];
  wire [7:0]  shn = s_pass ? 8'd0 : i_rot ? {3'b000, ins[11:8], 1'b0} : e_sr ? opc[7:0] : {3'b000, ins[11:7]};
  wire        shr = s_pass || i_rot || e_sr;                     // not the immediate-shift encodings' #0 = #32, RRX
  logic [31:0] sho_u;
  logic        shc_u;
  always_comb begin
    // one right-rotator: LSL n = ROR (32-n) keeping the high bits, LSR/ASR n = ROR n keeping the low bits (ASR fills
    // with the sign); the carry is the last bit out (bit 0 of the rotation for LSL, bit 31 otherwise)
    logic [4:0]  rot;
    logic [31:0] rv, keep;
    logic        big, zero, fill, rrx;
    zero = (shn == 8'd0);
    big  = (shn >= 8'd32) || (!shr && zero && (sht == 2'b01 || sht == 2'b10));   // #0 = #32
    rrx  = sht == 2'b11 && !shr && zero;                                         // RRX: ROR 1, the carry in at the top
    rot  = rrx ? 5'd1 : (sht == 2'b00) ? 5'd0 - shn[4:0] : shn[4:0];
    rv   = shv;
    if (rot[4]) rv = {rv[15:0], rv[31:16]};
    if (rot[3]) rv = {rv[7:0],  rv[31:8]};
    if (rot[2]) rv = {rv[3:0],  rv[31:4]};
    if (rot[1]) rv = {rv[1:0],  rv[31:2]};
    if (rot[0]) rv = {rv[0],    rv[31:1]};
    fill = (sht == 2'b10) && shv[31];
    // every case but RRX is the rotation, its kept bits and the fill: ROR keeps all, a shift of 32 or more none
    for (int i = 0; i < 32; i++)
      keep[i] = (sht == 2'b11) || (!big && ((sht == 2'b00) ? 5'(i) >= shn[4:0] : 5'(31 - i) >= shn[4:0]));
    sho_u = (rv & keep) | ({32{fill}} & ~keep);
    if (rrx) sho_u[31] = nzcv[1];
    shc_u = nzcv[1];
    if (i_rot) shc_u = (ins[11:8] == 4'h0) ? nzcv[1] : sho_u[31];  // the rotated immediate: bit 31 unless the rotation is 0
    else if (sht == 2'b11) begin                                   // ROR, RRX
      if (rrx) shc_u = shv[0];
      else if (!zero) shc_u = rv[31];
    end else if (zero && !big) ;                                   // LSL #0, or by register 0
    else if (big) begin
      shc_u = (shn == 8'd32 || (!shr && zero)) ? ((sht == 2'b00) ? shv[0] : shv[31])
                                               : ((sht == 2'b10) && shv[31]);
    end else shc_u = (sht == 2'b00) ? rv[0] : rv[31];
  end
  // a multiply's and a block's operand, and a store's offset for its base's write, stay for E's later cycles
  wire sho_en = es == ES_0 ? !ph || e_mul || e_mull : !ph && es == ES_LAST && (e_sr || e_swp);
  always_ff @(posedge clk) if (sho_en) begin sho <= sho_u; shc <= shc_u; end

  // ---------------------------------------------------------------- the adder (ph 1)
  logic [31:0] a, b, alu;
  logic [32:0] s33;
  logic        inva, invb, cin, arith, a_pc, a_zero, alu_c, alu_v;
  wire  [31:0] sum = s33[31:0];
  always_comb begin
    a_pc   = e_bimm || (es == ES_0 && rn == 4'hF && k != K_TBL);
    a_zero = k == K_MRS || k == K_BX || ((e_mul || e_mull) && !ins[21]);
    a = a_zero ? 32'h0 : a_pc ? r15 : rq;
    if (tpcal) a[1] = 1'b0;
    b = (e_mul || es == ES_LO) ? prod_q[31:0] : e_mull ? prod_q[63:32] : sho;
    inva = 1'b0; invb = 1'b0; cin = 1'b0; arith = 1'b0;
    case (k)
      K_DP: case (ins[24:21])
        4'h2, 4'hA: begin invb = 1'b1; cin = 1'b1; arith = 1'b1; end      // SUB CMP
        4'h3:       begin inva = 1'b1; cin = 1'b1; arith = 1'b1; end      // RSB
        4'h4, 4'hB: arith = 1'b1;                                         // ADD CMN
        4'h5:       begin cin = nzcv[1]; arith = 1'b1; end                // ADC
        4'h6:       begin invb = 1'b1; cin = nzcv[1]; arith = 1'b1; end   // SBC
        4'h7:       begin inva = 1'b1; cin = nzcv[1]; arith = 1'b1; end   // RSC
        default: ;
      endcase
      K_SDT, K_HW, K_BLK: begin invb = !ins[23]; cin = !ins[23]; end
      K_MULL: cin = es == ES_LAST && mc;
      default: ;
    endcase
    s33 = {1'b0, a ^ {32{inva}}} + {1'b0, b ^ {32{invb}}} + {32'h0, cin};
    alu_c = arith ? s33[32] : shc;
    alu_v = ((a[31] ^ inva) == (b[31] ^ invb)) && (sum[31] != (a[31] ^ inva));
    alu = sum;
    if (k == K_DP) case (ins[24:21])
      4'h0, 4'h8: alu = a & sho;
      4'h1, 4'h9: alu = a ^ sho;
      4'hC: alu = a | sho;
      4'hD: alu = sho;
      4'hE: alu = a & ~sho;
      4'hF: alu = ~sho;
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- multiplier (DSP)
  // one signed 33-bit multiplier: an operand's top bit is its sign only for SMULL/SMLAL. Its operands are in place at
  // the end of E's first cycle, prod_q a clock later, for the next cycle's ph 1
  wire         mul_s = e_mull && ins[22];
  wire signed [32:0] mul_a = {mul_s && sho[31], sho}, mul_b = {mul_s && opc[31], opc};
  always_ff @(posedge clk) begin
    prod_q <= 64'(mul_a * mul_b);
    if (!ph && es == ES_0) opc <= rq;
  end
  // Rs, in opc from E's first ph 0: UMULL/UMLAL end early only on zeros
  wire         m_ones = !(e_mull && !ins[22]);
  wire [2:0]   mterm = (opc[31:8] == 24'h0 || (m_ones && opc[31:8] == 24'hFFFFFF)) ? 3'd1 :
                       (opc[31:16] == 16'h0 || (m_ones && opc[31:16] == 16'hFFFF)) ? 3'd2 :
                       (opc[31:24] == 8'h0 || (m_ones && opc[31:24] == 8'hFF)) ? 3'd3 : 3'd4;
  // the wait cycles: m - 1, one more to accumulate
  wire [2:0]   mwait = mterm - 3'd1 + {2'b00, ins[21]};

  // ---------------------------------------------------------------- loads and stores
  logic [1:0]  msz;
  logic        msg;
  always_comb begin
    msz = MS_W; msg = 1'b0;
    case (k)
      K_SDT, K_SWP: msz = ins[22] ? MS_B : MS_W;
      K_HW: begin msz = (ins[6:5] == 2'b10) ? MS_B : MS_H; msg = ins[6]; end
      default: ;
    endcase
  end
  // the one aligner: rotate by the address, then byte / halfword; ARMv4 odd
  // halfwords: LDRSH gives the signed byte, LDRH the halfword at a-1 rotated by 8
  logic [31:0] ldv;
  always_comb begin
    logic [31:0] r;
    logic [1:0]  al;
    al = e_blk ? 2'b00 : addr[1:0];
    r = d_rdata;
    if (al[1]) r = {r[15:0], r[31:16]};
    if (al[0]) r = {r[7:0], r[31:8]};
    case (msz)
      MS_B: ldv = msg ? {{24{r[7]}}, r[7:0]} : {24'h0, r[7:0]};
      MS_H: begin
        if (al[0] && msg) ldv = {{24{r[7]}}, r[7:0]};
        else if (al[0])   ldv = {r[31:24], 16'h0, r[7:0]};
        else              ldv = msg ? {{16{r[15]}}, r[15:0]} : {16'h0, r[15:0]};
      end
      default: ldv = r;
    endcase
  end
  wire e_ldst = es == ES_MEM || es == ES_SWPW;                    // a data cycle: asked in ph 0, answered in ph 1
  assign i_req  = ph == 1'b0 && run && !halted && !x && !rst;   // (rst: the port may be out of reset already, its boot ROM not loaded)
  assign i_addr = {pc_f[31:2], 2'b00};
  assign d_req  = ph == 1'b0 && e_v && e_ldst;
  assign d_we   = es == ES_SWPW || (es == ES_MEM && !is_load && !e_swp);
  assign d_addr = e_blk ? {addr[31:2], 2'b00} : addr;
  always_comb begin
    d_be = 4'hF;
    d_wdata = rq;
    if (!e_blk) case (msz)
      MS_B: begin d_be = 4'b0001 << addr[1:0]; d_wdata = {4{rq[7:0]}}; end
      MS_H: begin d_be = addr[1] ? 4'b1100 : 4'b0011; d_wdata = {2{rq[15:0]}}; end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------- E's control (the end of ph 1)
  wire        pe      = ph && run && !halted;                     // the phase everything commits in
  wire        e_pass  = e_v && es == ES_0 && e_ok;
  wire        e_end   = e_v && (es != ES_0 || e_ok);              // (E's last cycle) it did not fail its condition
  wire        e_long  = e_mem || e_blk || e_mul || e_mull || e_swp || e_sr;
  wire        e_ldpc  = e_mem && is_load && rd == 4'hF;           // LDR into r15: one more cycle before the refill
  wire        e_busy  = e_v && (es == ES_0 ? e_ok && e_long : es == ES_LAST ? e_ldpc : es != ES_REFILL);
  wire        adv     = pe && !x && !e_busy && i_ok;              // E's last cycle ends, the pipeline moves
  wire        step    = pe && !x && e_busy;                       // or one of its earlier cycles does

  wire        dp_pc   = e_end && k == K_DP && rd == 4'hF && alu_wr;      // MOV pc, ... / ADD pc, ...: a branch
  wire        psr_rt  = e_end && k == K_DP && rd == 4'hF && ins[20] && has_spsr;  // MOVS pc, ...; "TSTP": CPSR <= SPSR
  wire        msr     = (e_pass && k == K_MSR) || (e_end && k == K_DP && rd == 4'hF && ins[20] && !alu_wr);   // (also "TSTP") refetch the rest
  wire        brt     = dp_pc || (e_pass && (k == K_B || k == K_TB || k == K_BX || (k == K_TBL && tk == TK_BL2)));
  wire        exc     = e_pass && (k == K_SWI || k == K_UND);
  wire        irq_f   = fiq && !cpsr[6];
  wire        irq_take = irq_f || (irq && !cpsr[7]);
  wire        link    = e_pass && ((k == K_B && ins[24]) || (k == K_TBL && tk == TK_BL2));
  wire        ld_pc_a = es == ES_MEM && d_ok && (e_ldpc || (e_blk && is_load && br == 4'hF));   // the loaded word is the target
  wire        w_t15   = es == ES_0 && (e_sr || ((e_mem || e_blk) && !is_load));    // PC + 12 to index 15

  // the fetch adder: the next fetch; the instruction after E (a link, or where an interrupt or MSR continues); an interrupt's LR
  wire        pa_back = link || exc || msr || (!e_busy && irq_take);
  wire [31:1] pa      = pc_f + (x ? 31'd2 : pa_back ? (tbit ? 31'h7FFF_FFFF : 31'h7FFF_FFFE) : (tbit ? 31'd1 : 31'd2));
  // the result: what the register file gets and what a branch loads
  wire        w_pa    = link || exc || x || w_t15;
  wire [31:0] w_ld    = (es == ES_MEM && (is_load || e_swp)) ? ldv : alu;
  wire [31:0] wd_d    = w_pa ? {pa, (k == K_TBL) && !x} : w_ld;
  wire        new_t   = (ld_pc_a ? (e_blk && ins[22] && has_spsr) : psr_rt) ? spsr_m[5] : (k == K_BX) ? sho[0] : tbit;
  wire [31:0] tgt     = new_t ? {w_ld[31:1], 1'b0} : {w_ld[31:2], 2'b00};
  wire [4:0]  w_exc   = x ? (x_f ? M_FIQ : M_IRQ) : (k == K_SWI) ? M_SVC : M_UND;

  // the register file's one write, at the end of ph 1
  logic       rf_we;
  logic [3:0] wn;
  always_comb begin
    rf_we = 1'b0;
    if (x) rf_we = pe;
    else if (e_v && pe) case (es)
      ES_0: if (e_ok) case (k)
        K_DP:  rf_we = e_sr || (alu_wr && rd != 4'hF && i_ok);
        K_MRS, K_TBL, K_SWI, K_UND: rf_we = i_ok;
        K_B:   rf_we = ins[24] && i_ok;
        K_SDT, K_HW, K_BLK: rf_we = !is_load || (ins[21] && (!e_blk || !blist[rn])) || (!e_blk && !ins[24]);   // a load's base first; a store's r15
        default: ;
      endcase
      ES_MEM: if (d_ok) begin
        if (e_blk) rf_we = is_load ? br != 4'hF : first && ins[21];   // ARMv4 STM: the base after the first store
        else if (e_swp) rf_we = 1'b1;
        else rf_we = is_load ? rd != 4'hF : ins[21] || !ins[24];      // a store's base after its data
      end
      ES_LO: rf_we = 1'b1;
      ES_LAST: if (e_mul || e_mull || e_swp) rf_we = i_ok; else if (e_sr) rf_we = alu_wr && rd != 4'hF && i_ok;
      default: ;
    endcase
    wn = rd;
    if (x) wn = 4'd14;
    else case (es)
      ES_0: case (k)
        K_DP:  if (e_sr) wn = 4'hF;
        K_B, K_TBL, K_SWI, K_UND: wn = 4'd14;
        K_SDT, K_HW, K_BLK: wn = is_load ? rn : 4'hF;         // (a store's r15 goes to index 15)
        default: ;
      endcase
      ES_MEM: wn = e_blk ? (is_load ? br : rn) : e_swp ? 4'hF : is_load ? rd : rn;
      ES_LAST: if (e_mul || e_mull) wn = rn;
      default: ;
    endcase
  end
  // its number is known in ph 0: only the enable waits for ph 1's condition and answers
  logic [4:0] rf_wa;
  always_ff @(posedge clk) begin
    rf_wa <= phys_reg(wn, (x || (es == ES_0 && (k == K_SWI || k == K_UND))) ? w_exc : bmode);
    if (rf_we) rf[rf_wa] <= wd_d;
    rf_wd <= wd_d;
  end

  // the SPSRs: one RAM write, an exception's CPSR or an MSR's fields
  wire x_go   = x && pe;
  wire exc_go = exc && adv;
  wire sp_msr = msr && k == K_MSR && adv && ins[22] && has_spsr;
  always_ff @(posedge clk)
    if (x_go || exc_go || sp_msr)
      spsr[(x_go || exc_go) ? spsr_idx(w_exc) : sidx] <= (x_go || exc_go) ? cpsr :
        {ins[19] ? sho[31:28] : spsr_m[12:9], spsr_m[8], ins[16] ? sho[7:0] : spsr_m[7:0]};

  always_ff @(posedge clk) begin
    dbg_retire <= 1'b0;
    z_en <= 1'b0; z_lo <= 1'b0;
    if (z_en) begin cpsr[11] <= z_d; zq <= 1'b1; end
    if (z_lo) zq <= rf_wd == 32'h0;
    if (rst) begin
      ph <= 1'b0; d_v <= 1'b0; e_v <= 1'b0; es <= ES_0; x <= 1'b0; zq <= 1'b1;
      cpsr <= {5'h0, 8'hD3};
      pc_f <= reset_pc[31:1];
    end else if (run && !halted) begin
      ph <= ~ph;
      if (x && ph) begin
        // the entry: LR = the next instruction + 4
        cpsr[4:0] <= w_exc;
        cpsr[5] <= 1'b0; cpsr[7] <= 1'b1;
        if (x_f) cpsr[6] <= 1'b1;
        pc_f <= {hivecs ? 16'hFFFF : 16'h0, 11'h0, x_f ? 4'hE : 4'hC};
        x <= 1'b0;
        dbg_retire <= 1'b1;
      end else if (step) begin
        // ---- a longer instruction's cycles (F's word waits)
        case (es)
          ES_0: begin
            if (e_mem || e_swp) addr <= (e_swp || !ins[24]) ? a : sum;
            if (e_blk) begin addr <= ins[23] ? a : sum; first <= 1'b1; end
            if (e_sr) es <= ES_LAST;
            else if (e_mul || e_mull) begin
              wcnt <= mwait - 3'd1;
              es <= mwait != 3'd0 ? ES_WAIT : e_mull ? ES_LO : ES_LAST;
            end else es <= (e_blk && ins[24] == ins[23]) ? ES_BLK0 : ES_MEM;
          end
          ES_BLK0: begin addr <= addr + 32'd4; es <= ES_MEM; end
          ES_WAIT: if (wcnt == 3'd0) es <= e_mull ? ES_LO : ES_LAST; else wcnt <= wcnt - 3'd1;
          ES_LO: begin mc <= s33[32]; z_lo <= ins[20]; es <= ES_LAST; end
          ES_MEM: if (d_ok) begin
            if (e_blk) begin
              addr <= addr + 32'd4; first <= 1'b0;
              if (rl_n == 16'h0) es <= ES_LAST;
            end else es <= e_swp ? ES_SWPW : ES_LAST;
            if (ld_pc_a) begin
              pc_f <= tgt[31:1]; d_v <= 1'b0;
              if (e_blk && ins[22] && has_spsr) cpsr <= spsr_m;
            end
          end
          ES_SWPW: if (d_ok) es <= ES_LAST;
          ES_LAST: es <= ES_REFILL;                         // a load into r15: its internal cycle
          default: ;
        endcase
      end else if (adv) begin
        // ---- E's last cycle
        dbg_retire <= e_v;
        es <= ES_0;
        if (e_end) begin
          if (k == K_DP) begin
            if (ins[20] && rd == 4'hF) begin
              if (has_spsr) cpsr <= spsr_m;
            end else if (ins[20]) begin
              cpsr[12] <= alu[31];
              z_en <= 1'b1;
              cpsr[10] <= alu_c;
              if (arith) cpsr[9] <= alu_v;
            end
          end
          if ((e_mul || e_mull) && ins[20]) begin cpsr[12] <= alu[31]; z_en <= 1'b1; end
          if (k == K_BX) cpsr[5] <= sho[0];
          if (k == K_MSR && !ins[22]) begin
            if (ins[19]) cpsr[12:9] <= sho[31:28];
            if (ins[16] && mode != M_USR && valid_mode(sho[4:0])) begin
              cpsr[7:6] <= sho[7:6]; cpsr[4:0] <= sho[4:0];
            end
          end
          if (exc) begin
            cpsr[4:0] <= w_exc; cpsr[5] <= 1'b0; cpsr[7] <= 1'b1;
          end
        end
        if (exc) begin
          pc_f <= {hivecs ? 16'hFFFF : 16'h0, 11'h0, (k == K_SWI) ? 4'h4 : 4'h2};
          d_v <= 1'b0; e_v <= 1'b0;
        end else if (irq_take) begin
          // E is done; the entry next cycle, from where the program continues
          x_f <= irq_f;
          x <= 1'b1; d_v <= 1'b0; e_v <= 1'b0;
          if (brt) pc_f <= tgt[31:1];
          else if (d_v) pc_f <= pa;
        end else if (brt) begin
          pc_f <= tgt[31:1]; d_v <= 1'b0; e_v <= 1'b0;
        end else if (msr) begin
          pc_f <= pa; d_v <= 1'b0; e_v <= 1'b0;
        end else begin
          // D -> E, F -> D
          e_v <= d_v;
          ins <= d_ins; k <= dk; tk <= d_tk; tpcal <= d_pcal;
          e_mem <= dk == K_SDT || dk == K_HW; e_blk <= dk == K_BLK; e_mul <= dk == K_MUL; e_mull <= dk == K_MULL;
          e_swp <= dk == K_SWP; e_sr <= dk == K_DP && !d_ins[25] && d_ins[4];   // shift by register: Rs first
          e_rs0 <= dk == K_MUL || dk == K_MULL || (dk == K_DP && !d_ins[25] && d_ins[4]);
          b_usr <= dk == K_BLK && d_ins[22] && !(d_ins[20] && d_ins[15]);
          ra_rm <= phys_reg(d_ins[3:0], mode); ra_rs <= phys_reg(d_ins[11:8], mode); ra_rd <= phys_reg(d_ins[15:12], mode);
          d_v <= 1'b1;
          d_ins <= !tbit ? i_rdata : f_kind != TK_ARM ? {f_arm[31:28], 6'h0, f_boff[22:1]} : f_arm;
          d_tk <= tbit ? f_kind : TK_ARM;
          d_pcal <= tbit && f_pcal;
          pc_f <= pa;
        end
      end
    end else ph <= 1'b0;
  end

  // the block cursor's registers: from E's first cycle (the list) and each answered step
  always_ff @(posedge clk)
    if (step && (es == ES_0 || (es == ES_MEM && d_ok))) begin rl <= rl_d; br <= lowest(rl_d); end

  // halt: a store of 0x80 to HALTCNT, accepted (d_ok) the cycle after
  logic haltst;
  always_ff @(posedge clk) begin
    haltst <= d_req && d_we && d_addr[31:2] == 30'h010000C0 && d_be[1] && d_wdata[15:8] == 8'h80;
    if (rst) halted <= 1'b0;
    else if (haltst && d_ok) halted <= 1'b1;
    else if (wake || fiq) halted <= 1'b0;
  end

  assign dbg_cpsr = psr32(cpsr);
  assign dbg_halted = halted;
`ifndef ALTERA_RESERVED_QIS
  // what tb_arm and the lockstep see: each register write a clock later, and the PC of what retired
  logic [31:0] pc_e, dpc_q;
  always_ff @(posedge clk) begin
    dbg_wen <= rf_we && rf_wa != 5'd15;
    dbg_wa <= rf_wa;
    dbg_wd <= wd_d;
    if (adv) pc_e <= r15 - (tbit ? 32'd2 : 32'd4);
    dpc_q <= (x && ph) ? r15 : pc_e;
  end
  assign dbg_pc = dpc_q;
`else
  assign dbg_wen = 1'b0;
  assign dbg_wa = 5'd0;
  assign dbg_wd = 32'h0;
  assign dbg_pc = 32'h0;
`endif
endmodule
