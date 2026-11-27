// arm9_core: the ARM9 (ARMv5TE) as a single-context pipeline that stalls on a
// refused memory access, as the ARM946E-S does (docs/arm9-stall.md). It takes
// the place of arm_core's ARM9 context (arm_cpu A9_CORE = 1; the ARM7 is
// arm7_ds) with the same ports, so arm9_mem is unchanged.
//
//   F   fetch request (the redirect target goes out in the redirecting cycle)
//   F2  arm9_mem's answer, into a three-entry queue (refused: fetched again)
//   D   halfword select, Thumb expansion, decode into uops (arm_core's rules),
//       register-file read addresses, interlocks, interrupt injection
//   E   operands (register file, or forwarded from M, W and the last write),
//       barrel shift and ALU in one clock, condition, CPSR writes, the data
//       request, redirects to known targets (branches, BX, exceptions)
//   M   the data answer. Refused: everything from M back holds (the stall)
//       while M sends the access again; a request E sent meanwhile is killed
//       (d_kill). Load alignment. Redirects to ALU results
//   W   register-file write, retire, loads into the PC, data aborts
//
// Uop timing follows the DS (hwref runs 22 and 30): one uop per clock, a
// load's result two clocks after it (three for bytes and halfwords), MUL/MLA
// two clocks, SMULL/UMULL three, a register-specified shift two.
module arm9_core import arm_pkg::*; #(
  parameter             RF_STYLE = "M10K"
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  run,                  // run[0]: the ARM9 (run[1] unused)
  input  logic [31:0] reset_pc0,
  input  logic [31:0] reset_pc1,
  input  logic [1:0]  hivecs,
  input  logic [1:0]  irq,
  input  logic [1:0]  fiq,
  input  logic [1:0]  halt_req,
  input  logic [1:0]  wake,

  output logic        i_req,
  output logic        i_tid,
  output logic        i_priv,
  output logic [31:0] i_addr,
  output logic [31:0] i_addr_s,         // i_addr's two candidates: the next sequential fetch and the redirect (arm9_mem's
  output logic [31:0] i_addr_r,         // ITCM match compares both before the late redirect select, i_rdr)
  output logic        i_rdr,
  input  logic [31:0] i_rdata,
  output logic        i_hsel,           // f1_pc[1]: the answer's halfword arm9_mem returns on i_rhw
  input  logic [15:0] i_rhw,            // i_rdata's halfword by i_hsel, with arm9_mem's way select last (#2566)
  input  logic [4:0]  i_rcls,
  input  logic [6:0]  i_rtop,           // thumb_top(i_rhw): u_thumb's kind and arm[31:28], decoded per way (RC13b)           // thumb_class(i_rhw), decoded per way in arm9_mem (#2570)
  input  logic        i_ok,
  input  logic        i_abort,

  output logic        d_req,
  output logic        d_tid,
  output logic        d_priv,
  output logic        d_we,
  output logic [1:0]  d_size,
  output logic [3:0]  d_be,
  output logic [31:0] d_addr,
  output logic [31:0] d_wdata,
  input  logic [31:0] d_rdata,
  input  logic [31:0] d_lw_it, d_lw_dt, d_lw_rs,   // d_rdata's sources (arm9_mem): d_ls_it ? it : d_ls_dt ? dt : rs
  input  logic        d_ls_it, d_ls_dt,
  input  logic        d_ok,
  input  logic        d_abort,
  input  logic [1:0]  d_wait,
  output logic        d_kill,
  output logic        cp_req,
  output logic        cp_we,
  output logic [15:0] cp_op,
  output logic [31:0] cp_wdata,

  output logic        dbg_wen,
  output logic [5:0]  dbg_wa,
  output logic [31:0] dbg_wd,
  output logic        dbg_retire,
  output logic        dbg_tid,
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_cpsr,
  output logic [1:0]  dbg_halt
);
  localparam logic [2:0] TK_ARM = 3'd0, TK_B = 3'd1, TK_BL1 = 3'd2, TK_BL2 = 3'd3,
                         TK_BLX2 = 3'd4, TK_UND = 3'd5;
  // (the uop classes C_* and thumb_class: arm_pkg, shared with arm9_mem's per-way Thumb class)
  localparam logic [2:0] CS_OLD = 3'd0, CS_R0 = 3'd1, CS_R31 = 3'd2, CS_X31 = 3'd3, CS_ZERO = 3'd4;

  // One uop (arm_core's uop_t without the barrel's fields, with this core's)
  typedef struct packed {
    logic        valid;
    logic [3:0]  cond;
    logic        last;
    logic        thumb;
    logic [31:0] pc;
    logic [31:0] pcv;       // r15 on ports A/B
    logic [31:0] pcv_c;     // r15 on port C (stored PC)
    logic [4:0]  ra, rb, rc;
    logic        a_pc, b_pc, c_pc;
    logic        a_zero;
    logic        b_imm;
    logic [31:0] imm;
    logic [2:0]  sh_type;
    logic        sh_reg;
    logic        amt_save;
    logic [7:0]  sh_amt;
    logic [4:0]  alu;
    logic        qdbl;
    logic [1:0]  flags;
    logic        wen;
    logic [4:0]  wa;
    logic [1:0]  wsrc;
    logic        wpc;
    logic [1:0]  rdr;
    logic        rdx;       // RD_ALU taken in E from operand B (BX, BLX, MOV pc, Rm)
    logic [1:0]  pct;
    logic [31:0] link;
    logic [1:0]  mem;
    logic [1:0]  msize;
    logic        msigned;
    logic        norot;
    logic [1:0]  maddr;
    logic [1:0]  taddr;
    logic        blk_pu, blk_u;
    logic        st_save, st_temp;
    logic        mul_start;
    logic [1:0]  mul_kind;
    logic        mul_signed, mul_xh, mul_yh;
    logic        mulw, mulhi, macc;
    logic        mlong;     // 64-bit accumulate (the hi uop reads RdHi)
    logic        mflag;     // MULS etc.: N, Z from the product in W
    logic        mq;        // SMLAxy/SMLAWy: Q from the accumulate in W
    logic        mbub;      // E is busy one more clock (the DS's MUL/MLA 2, long 3)
    logic        psr_spsr, msr;
    logic [3:0]  msr_mask;
    logic        restore;
    logic        exc;
    logic [4:0]  exc_mode;
    logic        exc_f;
    logic        set_thumb, clr_thumb;
    logic [15:0] cp_op;
    logic        wfi;
    logic        ldbh;      // byte/halfword load (use +2, the DS)
    logic        ua, ub;    // operand A / B is read (the interlocks)
    logic [3:0]  la, lb, lc, lw;   // ra/rb/rc/wa as logical numbers (the interlocks: the mode only changes with a flush)
  } uop9_t;

  // ---------------------------------------------------------------- state
  logic [12:0] cpsr_s;                 // NZCVQ, control byte
  logic [31:0] cpsr;
  assign cpsr = {cpsr_s[12:8], 19'h0, cpsr_s[7:0]};
  function automatic logic [12:0] psr13(input logic [31:0] p);
    return {p[31:27], p[7:0]};
  endfunction
  function automatic logic [31:0] psr32(input logic [12:0] p);
    return {p[12:8], 19'h0, p[7:0]};
  endfunction
  // The mode's register bank, kept as a class beside cpsr_s (mcl: the same writes) so decode's register mapping does
  // not decode cpsr_s[4:0] first (RC11 #2489 7asR: cpsr_s[4] -> the mode decode -> phys_reg -> u.rc -> fsel -> oh_c,
  // -0.532 ns). 0 none (USR, SYS, invalid), 1 FIQ, 2 IRQ, 3 SVC, 4 ABT, 5 UND; phys_regk(r, mclass(m)) == phys_reg(r, m)
  function automatic logic [2:0] mclass(input logic [4:0] m);
    case (m)
      M_FIQ: return 3'd1;
      M_IRQ: return 3'd2;
      M_SVC: return 3'd3;
      M_ABT: return 3'd4;
      M_UND: return 3'd5;
      default: return 3'd0;
    endcase
  endfunction
  function automatic logic [4:0] phys_regk(input logic [3:0] r, input logic [2:0] c);
    logic [4:0] p;
    p = {1'b0, r};
    if (r >= 4'd8 && r <= 4'd14 && c == 3'd1) p = 5'd16 + {1'b0, r} - 5'd8;
    else if (r == 4'd13 || r == 4'd14)
      case (c)
        3'd2: p = (r == 4'd13) ? 5'd23 : 5'd24;
        3'd3: p = (r == 4'd13) ? 5'd25 : 5'd26;
        3'd4: p = (r == 4'd13) ? 5'd27 : 5'd28;
        3'd5: p = (r == 4'd13) ? 5'd29 : 5'd30;
        default: ;
      endcase
    return p;
  endfunction
  logic [2:0]  mcl;
  logic        halted, irq_r, fiq_r;
  logic [4:0]  w_wa;
  logic        m_fw_r, m_prod_s31;
  uop9_t       eu;                     // the uop in E
  logic        e_exec, e_live;         // E's uop executes / commits this clock
  logic        m_mq;

  logic        stall;                  // M waits for its access: D, E, M, W hold
  logic        w_rdr, m_rdr, e_rdr;    // redirects (W oldest)
  logic [31:0] w_tgt, m_tgt, e_tgt;
  logic        w_newt, m_newt, e_newt;
  logic        flush;                  // any redirect: the queue, D's state
  assign flush = w_rdr || m_rdr || e_rdr;

  // ---------------------------------------------------------------- F / F2
  logic [31:0] fpc;
  logic        fth;
  logic        f1_v, f1_th, f1_ep;     // request sent last cycle
  logic [31:0] f1_pc;
  logic        ep;                     // redirect epoch: answers of older requests are dropped
  logic        i_one;                  // after a refused fetch: one at a time until one is taken
  logic [1:0]  q_n;                    // queue entries
  // Entry 0 (the head, read by D) is slot 0. Entries 1 and 2 are slots 1 and 2 as a ring: q_rp picks the slot that holds
  // entry 1. The answer goes into its slot from q_n and q_rp alone (registers), so the pop reaches only the head's
  // slot, q_rp and the count: ARM9 slack family A (#2749: d_ok -> stall -> pop -> the shift queue's write slot
  // n = q_n - pop -> the enables of entry 1, q_w[1] -7.71 / q_hw[1] -4.33 of its -15.8 deficit)
  logic        q_rp;
  logic [31:0] q_w  [0:2];
  logic [31:0] q_hpc;                   // the head's PC: the entries are consecutive from the last redirect
  logic        q_th [0:2];
  logic        q_ab [0:2];
  logic [15:0] q_hw [0:2];             // the Thumb halfword (offsets, the BL suffix)
  logic [4:0]  q_cls [0:2];
  logic [2:0]  q_kind [0:2];
  logic        q_pa [0:2];             // Thumb: r15 reads as (PC + 4) & ~3
  logic        f_ans, f_take, f_rew;
  assign f_ans  = f1_v && f1_ep == ep;
  assign f_take = f_ans && i_ok;
  assign f_rew  = f_ans && !i_ok;

  logic [31:0] r_tgt;                  // the redirect taken this cycle (oldest)
  logic        r_th;
  always_comb begin
    r_tgt = e_tgt; r_th = e_newt;
    if (m_rdr) begin r_tgt = m_tgt; r_th = m_newt; end
    if (w_rdr) begin r_tgt = w_tgt; r_th = w_newt; end
    r_tgt = r_th ? {r_tgt[31:1], 1'b0} : {r_tgt[31:2], 2'b00};
  end
  logic        fetch_en;
  logic [31:0] f_pc;
  logic        f_th;
  assign f_pc = flush ? r_tgt : fpc;
  assign f_th = flush ? r_th : fth;
  // queue room: entries plus the answer in flight (registered counts only); none behind a WFI
  assign fetch_en = run[0] && !halted && !rst && !(e_exec && eu.wfi) &&
                    (flush || (!(i_one && f1_v) && ({1'b0, q_n} + {2'b00, f1_v}) <= 3'd2));
  assign i_req  = fetch_en;
  assign i_tid  = 1'b0;
  assign i_priv = (cpsr[4:0] != M_USR);
  assign i_addr = {f_pc[31:2], 2'b00};
  assign i_addr_s = {fpc[31:2], 2'b00};
  assign i_addr_r = {r_tgt[31:2], 2'b00};
  assign i_rdr    = flush;

  // ---------------------------------------------------------------- D
  logic [31:0] h_w, h_pc;
  logic        h_th, h_ab, h_v;
  assign h_v  = q_n != 2'd0;
  assign h_w  = q_w[0];
  assign h_pc = q_hpc;
  assign h_th = q_th[0];
  assign h_ab = q_ab[0];

  // the answer's halfword select, Thumb expansion and class, into the queue (not in front of D's decode: #1872
  // q_pc -> u_thumb -> class -> decode -> hazard -> issue -> queue, -4.53 ns)
  logic [15:0] a_hw, f_hw;
  logic [31:0] tx_arm, tx_boff, a_ins;
  logic [2:0]  tx_kind;
  logic        tx_pcalign;
  logic [4:0]  a_cls;
  // the halfword from arm9_mem (i_rhw: selected by f1_pc[1] before the way, RC12c-ns #2566 I-tag -> way -> i_rdata
  // -> a_hw -> u_thumb -> q_w -0.506 ns); the same function as f1_pc[1] ? i_rdata[31:16] : i_rdata[15:0]
  assign i_hsel = f1_pc[1];
  assign a_hw = i_rhw;
  // synthesis translate_off
  always_ff @(posedge clk)
    if (!rst && i_rhw !== (f1_pc[1] ? i_rdata[31:16] : i_rdata[15:0]))
      $display("arm9_core: ERROR: i_rhw %h is not the answer's halfword %h at %0t", i_rhw,
               f1_pc[1] ? i_rdata[31:16] : i_rdata[15:0], $time);
  // synthesis translate_on
  arm_thumb u_thumb (.hw(a_hw), .v5(1'b1), .arm(tx_arm), .kind(tx_kind), .boff(tx_boff), .pcalign(tx_pcalign));
  // the condition field from arm9_mem's per-way decode (i_rtop), the rest from u_thumb (RC13b #2611 -0.510 ns)
  assign a_ins = f1_th ? {i_rtop[3:0], tx_arm[27:0]} : i_rdata;
  // synthesis translate_off
  always_ff @(posedge clk)
    if (!rst && f_take && f1_th && i_rtop !== {tx_kind, tx_arm[31:28]})   // (a refused answer reads 0)
      $display("arm9_core: ERROR: i_rtop %h is not u_thumb's kind / condition %h at %0t", i_rtop, {tx_kind, tx_arm[31:28]}, $time);
  // synthesis translate_on
  assign f_hw  = q_hw[0];

  function automatic logic [4:0] arm_class(input logic [31:0] ins);
    logic [4:0] cls;
    cls = C_UND;
    if (ins[31:28] == 4'hF) begin
      if (ins[27:25] == 3'b101)                  cls = C_BLXI;
      else if (ins[27:26] == 2'b01 && ins[24] && ins[22] && ins[21:20] == 2'b01)
                                                 cls = C_NOP;   // PLD
      else                                       cls = C_UND;
    end else begin
      case (ins[27:25])
        3'b000: begin
          if (ins[7] && ins[4]) begin
            if (ins[6:5] == 2'b00) begin
              if (ins[24:22] == 3'b000)                            cls = C_MUL;
              else if (ins[24:23] == 2'b01)                        cls = C_MULL;
              else if (ins[24:23] == 2'b10 && ins[21:20] == 2'b00) cls = C_SWP;
              else                                                 cls = C_UND;
            end else if (!ins[20] && ins[6] && ins[12])  cls = C_UND;
            else                                         cls = C_HW;
          end else if (ins[24:23] == 2'b10 && !ins[20]) begin
            if (ins[7:4] == 4'b0000)                              cls = ins[21] ? C_MSR : C_MRS;
            else if (ins[7:4] == 4'b0001 && ins[22:21] == 2'b01)  cls = C_BX;
            else if (ins[7:4] == 4'b0001 && ins[22:21] == 2'b11)  cls = C_CLZ;
            else if (ins[7:4] == 4'b0011 && ins[22:21] == 2'b01)  cls = C_BLXR;
            else if (ins[7:4] == 4'b0101)                         cls = C_QOP;
            else if (ins[7:4] == 4'b0111 && ins[22:21] == 2'b01)  cls = C_BKPT;
            else if (ins[7] && !ins[4])                           cls = C_SMUL;
            else                                                  cls = C_UND;
          end else
            cls = C_DP;
        end
        3'b001: begin
          if (ins[24:23] == 2'b10 && !ins[20]) cls = ins[21] ? C_MSR : C_UND;
          else                                 cls = C_DP;
        end
        3'b010: cls = C_SDT;
        3'b011: cls = ins[4] ? C_UND : C_SDT;
        3'b100: cls = C_BLK;
        3'b101: cls = C_B;
        3'b110: cls = C_UND;
        default: begin
          if (ins[24])                            cls = C_SWI;
          else if (ins[4] && ins[11:8] == 4'hF)   cls = C_CP;
          else                                    cls = C_UND;
        end
      endcase
    end
    return cls;
  endfunction


  function automatic logic [4:0] popcnt16(input logic [15:0] x);
    logic [4:0] n;
    n = 5'd0;
    for (int i = 0; i < 16; i++) n = n + {4'd0, x[i]};
    return n;
  endfunction
  function automatic logic [3:0] lowest16(input logic [15:0] x);
    logic [3:0] r;
    r = 4'd0;
    for (int i = 15; i >= 0; i--) if (x[i]) r = i[3:0];
    return r;
  endfunction

  // the Thumb class from arm9_mem (i_rcls: decoded from each way's halfword in parallel with the tag compare and
  // selected by the hits, RC12c-full #2570 7asR I-tag -> way -> i_rhw -> thumb_class -> q_cls -1.044 ns); the same
  // as thumb_class(a_hw), checked below
  assign a_cls = f1_th ? i_rcls : arm_class(i_rdata);
  // synthesis translate_off
  always_ff @(posedge clk)
    if (!rst && i_rcls !== thumb_class(a_hw))
      $display("arm9_core: ERROR: i_rcls %0d is not the halfword's Thumb class %0d at %0t", i_rcls, thumb_class(a_hw), $time);
  // synthesis translate_on

  // D's sequencer, the Thumb BL prefix, the instruction's class and target
  logic [1:0]  ustep;
  logic [15:0] rl_rem;
  logic [3:0]  rl_r;
  logic        bl_v;
  logic [31:0] bl_t;
  logic [31:0] c_ins, c_tgt;
  logic [4:0]  c_cls;
  logic [2:0]  c_kind;
  logic        c_bl2;                  // Thumb BL/BLX suffix right after its prefix: target known here
  logic [31:0] c_bl2t;
  always_comb begin
    logic [31:0] off;
    c_ins  = h_w;
    c_kind = q_kind[0];
    c_cls  = q_cls[0];
    if (h_th) begin                        // B (cond / not), the BL prefix's << 12 value
      if (f_hw[15:11] == 5'b11100)      off = {{20{f_hw[10]}}, f_hw[10:0], 1'b0};
      else if (f_hw[15:11] == 5'b11110) off = {{9{f_hw[10]}}, f_hw[10:0], 12'h000};
      else                              off = {{23{f_hw[7]}}, f_hw[7:0], 1'b0};
    end else
      off = {{6{h_w[23]}}, h_w[23:0], (h_w[31:25] == 7'b1111101) & h_w[24], 1'b0};
    c_tgt  = h_pc + (h_th ? 32'd4 : 32'd8) + off;
    c_bl2  = h_th && bl_v && (f_hw[15:11] == 5'b11111 || (f_hw[15:11] == 5'b11101 && !f_hw[0]));
    c_bl2t = (bl_t + {20'h0, f_hw[10:0], 1'b0}) & {30'h3FFFFFFF, f_hw[12], 1'b1};
  end

  // the uops in E, M, W (for the interlocks)
  logic        m_v, m_exec, m_ld, m_mulw, m_mflag, m_wen, m_wpc, m_ldbh, m_mem, m_mbub_x;
  logic [4:0]  m_wa;
  logic [3:0]  m_lw;
  logic        w_v, w_exec;

  logic        fresh, take_irq, take_fiq, inject, have, hold, d_go;
  assign fresh    = (ustep == 2'd0);
  assign take_fiq = fresh && !h_ab && fiq_r && !cpsr[6];
  assign take_irq = fresh && !h_ab && irq_r && !cpsr[7];
  assign inject   = h_v && (take_fiq || take_irq || h_ab);

  uop9_t       u, u0;
  logic        more;
  logic [1:0]  nstep;
  logic [15:0] nrl;
  logic [3:0]  nrl_r;
  assign nrl_r = (ustep == 2'd0) ? ((c_ins[15:0] == 16'h0) ? 4'd15 : lowest16(c_ins[15:0])) :
                 (rl_rem == 16'h8000) ? 4'd15 : lowest16(rl_rem & ~(16'h1 << rl_r));

  always_comb begin
    logic [31:0] ins;
    logic [3:0]  rn, rd, rs, rm;
    logic [31:0] pc8, link4;
    logic        is_load, is_store;
    logic [1:0]  lsize;
    logic        lsigned;
    logic [15:0] list, rl0;
    logic [4:0]  cnt, bmode, mode;
    logic [2:0]  bcl;
    logic        ubank, base_in, fwb, lastx, firstx;
    logic [3:0]  r;
    logic [4:0]  emode;
    logic [31:0] evec;
    logic        exc_any, pre, wb, acc;
    logic [4:0]  cls;

    pre = 1'b0; wb = 1'b0; acc = 1'b0;
    list = 16'h0; rl0 = 16'h0; cnt = 5'd0; bmode = M_USR; bcl = 3'd0;
    ubank = 1'b0; base_in = 1'b0; fwb = 1'b0; lastx = 1'b0; firstx = 1'b0; r = 4'd0;
    is_load = 1'b0; is_store = 1'b0; lsize = MS_W; lsigned = 1'b0;

    ins  = c_ins;
    cls  = c_cls;
    mode = cpsr[4:0];
    rn   = ins[19:16];
    rd   = ins[15:12];
    rs   = ins[11:8];
    rm   = ins[3:0];
    pc8  = h_pc + (h_th ? 32'd4 : 32'd8);
    link4 = h_pc + (h_th ? 32'd2 : 32'd4);

    u = '0;
    more = 1'b0;
    nstep = 2'd0;
    nrl = rl_rem;

    u.valid = h_v;
    u.cond  = ins[31:28];
    u.thumb = h_th;
    u.pc    = h_pc;
    u.pcv   = q_pa[0] ? {pc8[31:2], 2'b00} : pc8;
    u.pcv_c = h_pc + 32'd12;
    u.ra    = phys_regk(rn, mcl); u.la = rn;
    u.rb    = phys_regk(rm, mcl); u.lb = rm;
    u.rc    = phys_regk(rs, mcl); u.lc = rs;
    u.a_pc  = (rn == 4'hF);
    u.b_pc  = (rm == 4'hF);
    u.c_pc  = (rs == 4'hF);
    u.sh_type = SH_LSL;
    u.msize = MS_W;
    u.link  = link4;
    u.ua    = 1'b1;
    u.ub    = 1'b1;

    exc_any = 1'b0;
    emode = M_UND;
    evec = 32'h4;

    case (cls)
      C_DP: begin
        u.alu = {1'b0, ins[24:21]};
        u.ua = ins[24:21] != 4'hD && ins[24:21] != 4'hF;   // MOV/MVN read no Rn
        if (ins[25]) begin
          u.b_imm = 1'b1;
          u.imm = {24'h0, ins[7:0]};
          u.sh_type = SH_ROR;
          u.sh_amt = {3'b000, ins[11:8], 1'b0};
        end else if (ins[4]) begin
          // register-specified shift: Rs into temp_amt first (the DS: 2 cycles)
          u.sh_type = {1'b0, ins[6:5]};
          u.pcv = h_pc + 32'd12;
          if (ustep == 2'd0) begin
            u.amt_save = 1'b1;
            u.alu = AL_MOV;
            more = 1'b1; nstep = 2'd1;
          end else begin
            u.sh_reg = 1'b1;
          end
        end else begin
          u.sh_type = {1'b0, ins[6:5]};
          u.sh_amt = {3'b000, ins[11:7]};
          if (ins[6:5] != 2'b00 && ins[11:7] == 5'd0) begin
            if (ins[6:5] == 2'b11) u.sh_type = SH_RRX;
            else                   u.sh_amt = 8'd32;
          end
        end
        if (!u.amt_save) begin
          u.flags = ins[20] ? FL_DP : FL_NONE;
          if (ins[24:23] == 2'b10) begin
          end else if (rd == 4'hF) begin
            u.rdr = RD_ALU;
            u.pct = PT_KEEP;
            if (ins[20]) begin
              u.restore = 1'b1;
              u.flags = FL_NONE;
            end else if (ins[24:21] == 4'hD && !ins[25] && !ins[4] && ins[11:4] == 8'h00)
              u.rdx = 1'b1;                      // MOV pc, Rm: the target is operand B
          end else begin
            u.wen = 1'b1;
            u.wa = phys_regk(rd, mcl); u.lw = rd;
          end
        end
      end

      C_MRS: begin
        u.ua = 1'b0; u.ub = 1'b0;
        u.alu = AL_PSR;
        u.psr_spsr = ins[22];
        u.wen = (rd != 4'hF);
        u.wa = phys_regk(rd, mcl); u.lw = rd;
      end

      C_MSR: begin
        u.ua = 1'b0;
        u.alu = AL_MOV;
        u.msr = 1'b1;
        u.psr_spsr = ins[22];
        u.msr_mask = ins[19:16];
        u.rdr = RD_LINK;                         // flush: the mode may change
        if (ins[25]) begin
          u.b_imm = 1'b1;
          u.imm = {24'h0, ins[7:0]};
          u.sh_type = SH_ROR;
          u.sh_amt = {3'b000, ins[11:8], 1'b0};
        end
      end

      C_MUL: begin                                // MUL/MLA: one uop, E busy two clocks
        u.mul_start = 1'b1;
        u.mul_kind = MK_32;
        u.mulw = 1'b1; u.macc = ins[21]; u.mflag = ins[20]; u.mbub = 1'b1;
        u.ra = phys_regk(rm, mcl); u.la = rm;  u.a_pc = 1'b0;
        u.rb = phys_regk(rs, mcl); u.lb = rs;  u.b_pc = 1'b0;
        u.rc = phys_regk(rd, mcl); u.lc = rd;  u.c_pc = 1'b0;     // the accumulator (Rn, bits 15:12)
        u.wen = (rn != 4'hF);
        u.wa = phys_regk(rn, mcl); u.lw = rn;                      // Rd is bits 19:16
      end

      C_MULL: begin                               // UMULL/SMULL/UMLAL/SMLAL: RdLo, then RdHi; three clocks
        u.mulw = 1'b1; u.macc = ins[21];
        u.mul_signed = ins[22];
        if (ustep == 2'd0) begin
          u.mul_start = 1'b1;
          u.mul_kind = MK_32;
          u.mlong = 1'b1;
          u.ra = phys_regk(rm, mcl); u.la = rm;  u.a_pc = 1'b0;
          u.rb = phys_regk(rs, mcl); u.lb = rs;  u.b_pc = 1'b0;
          u.rc = phys_regk(rd, mcl); u.lc = rd;  u.c_pc = 1'b0;   // RdLo (accumulate)
          u.wen = (rd != 4'hF);
          u.wa = phys_regk(rd, mcl); u.lw = rd;
          more = 1'b1; nstep = 2'd1;
        end else begin
          u.ua = 1'b0; u.ub = 1'b0;
          u.mulhi = 1'b1; u.mlong = 1'b1;
          u.mflag = ins[20]; u.mbub = 1'b1;
          u.rc = phys_regk(rn, mcl); u.lc = rn;  u.c_pc = 1'b0;   // RdHi (accumulate)
          u.wen = (rn != 4'hF);
          u.wa = phys_regk(rn, mcl); u.lw = rn;
        end
      end

      C_SMUL: begin
        u.mulw = 1'b1;
        u.mul_signed = 1'b1;
        u.mul_kind = (ins[22:21] == 2'b01) ? MK_WY : MK_XY;
        u.mul_xh = ins[5];
        u.mul_yh = ins[6];
        if (ins[22:21] == 2'b10) begin            // SMLALxy: RdLo, then RdHi
          u.macc = 1'b1; u.mlong = 1'b1;
          if (ustep == 2'd0) begin
            u.mul_start = 1'b1;
            u.ra = phys_regk(rm, mcl); u.la = rm;  u.a_pc = 1'b0;
            u.rb = phys_regk(rs, mcl); u.lb = rs;  u.b_pc = 1'b0;
            u.rc = phys_regk(rd, mcl); u.lc = rd;  u.c_pc = 1'b0;
            u.wen = (rd != 4'hF);
            u.wa = phys_regk(rd, mcl); u.lw = rd;
            more = 1'b1; nstep = 2'd1;
          end else begin
            u.ua = 1'b0; u.ub = 1'b0;
            u.mulhi = 1'b1;
            u.rc = phys_regk(rn, mcl); u.lc = rn;  u.c_pc = 1'b0;
            u.wen = (rn != 4'hF);
            u.wa = phys_regk(rn, mcl); u.lw = rn;
          end
        end else begin
          // SMLAxy (00), SMLAWy (01, bit 5 = 0), SMULWy (01, bit 5 = 1), SMULxy (11)
          acc = (ins[22:21] == 2'b00) || (ins[22:21] == 2'b01 && !ins[5]);
          u.mul_start = 1'b1;
          u.macc = acc; u.mq = acc;
          u.ra = phys_regk(rm, mcl); u.la = rm;  u.a_pc = 1'b0;
          u.rb = phys_regk(rs, mcl); u.lb = rs;  u.b_pc = 1'b0;
          u.rc = phys_regk(rd, mcl); u.lc = rd;  u.c_pc = 1'b0;
          u.wen = (rn != 4'hF);
          u.wa = phys_regk(rn, mcl); u.lw = rn;
        end
      end

      C_SWP: begin
        u.ub = 1'b0;
        u.ua = (ustep == 2'd0);
        u.maddr = MA_A;
        u.msize = ins[22] ? MS_B : MS_W;
        if (ustep == 2'd0) begin
          u.mem = MO_LOAD;
          u.rc = phys_regk(rm, mcl); u.lc = rm;
          u.c_pc = (rm == 4'hF);
          u.st_save = 1'b1;
          u.wsrc = WS_MEM;
          u.ldbh = ins[22];
          u.wen = (rd != 4'hF);
          u.wa = phys_regk(rd, mcl); u.lw = rd;
          more = 1'b1; nstep = 2'd1;
        end else begin
          u.mem = MO_STORE;
          u.st_temp = 1'b1;
        end
      end

      C_HW, C_SDT: begin
        pre = ins[24];
        wb  = !pre || ins[21];
        u.alu = ins[23] ? AL_ADD : AL_SUB;
        if (cls == C_HW) begin
          if (ins[22]) begin
            u.b_imm = 1'b1;
            u.imm = {24'h0, ins[11:8], ins[3:0]};
          end
          if (ins[20]) begin
            is_load = 1'b1;
            lsize = (ins[6:5] == 2'b10) ? MS_B : MS_H;
            lsigned = ins[6];
          end else if (ins[6:5] == 2'b01) begin
            is_store = 1'b1;
            lsize = MS_H;
          end
        end else begin
          if (!ins[25]) begin
            u.b_imm = 1'b1;
            u.imm = {20'h0, ins[11:0]};
          end else begin
            u.sh_type = {1'b0, ins[6:5]};
            u.sh_amt = {3'b000, ins[11:7]};
            if (ins[6:5] != 2'b00 && ins[11:7] == 5'd0) begin
              if (ins[6:5] == 2'b11) u.sh_type = SH_RRX;
              else                   u.sh_amt = 8'd32;
            end
          end
          lsize = ins[22] ? MS_B : MS_W;
          is_load = ins[20];
          is_store = !ins[20];
        end

        if (is_load) begin
          if (!wb || ustep != 2'd0) begin
            u.mem = MO_LOAD;
            u.msize = lsize;
            u.msigned = lsigned;
            u.ldbh = (lsize != MS_W);
            u.maddr = wb ? MA_TADDR : MA_SUM;
            u.wsrc = WS_MEM;
            if (rd == 4'hF) begin
              u.wpc = 1'b1;
              u.pct = PT_DATA0;
            end else begin
              u.wen = 1'b1;
              u.wa = phys_regk(rd, mcl); u.lw = rd;
            end
          end else begin
            // base writeback first, so a load into the base register wins
            u.maddr = pre ? MA_SUM : MA_A;
            u.taddr = TA_ADDR;
            u.wen = (rn != 4'hF);
            u.wa = phys_regk(rn, mcl); u.lw = rn;
            more = 1'b1; nstep = 2'd1;
          end
        end else if (is_store) begin
          u.mem = MO_STORE;
          u.msize = lsize;
          u.maddr = pre ? MA_SUM : MA_A;
          u.rc = phys_regk(rd, mcl); u.lc = rd;
          u.c_pc = (rd == 4'hF);
          u.wen = wb && (rn != 4'hF);
          u.wa = phys_regk(rn, mcl); u.lw = rn;
        end else if (!ins[5]) begin
          // LDRD: address (+ writeback), Rd, Rd+1
          if (ustep == 2'd0) begin
            u.maddr = pre ? MA_SUM : MA_A;
            u.taddr = TA_ADDR;
            u.wen = wb && (rn != 4'hF);
            u.wa = phys_regk(rn, mcl); u.lw = rn;
            more = 1'b1; nstep = 2'd1;
          end else begin
            u.mem = MO_LOAD;
            u.maddr = MA_TADDR;
            u.taddr = TA_NEXT;
            u.norot = 1'b1;
            u.wsrc = WS_MEM;
            u.wen = 1'b1;
            u.wa = phys_reg((ustep == 2'd1) ? rd : {rd[3:1], 1'b1}, mode); u.lw = (ustep == 2'd1) ? rd : {rd[3:1], 1'b1};
            more = (ustep == 2'd1);
            nstep = 2'd2;
          end
        end else begin
          // STRD: Rd (+ writeback), Rd+1
          u.mem = MO_STORE;
          if (ustep == 2'd0) begin
            u.maddr = pre ? MA_SUM : MA_A;
            u.taddr = TA_NEXT;
            u.rc = phys_regk(rd, mcl); u.lc = rd;
            u.c_pc = 1'b0;
            u.wen = wb && (rn != 4'hF);
            u.wa = phys_regk(rn, mcl); u.lw = rn;
            more = 1'b1; nstep = 2'd1;
          end else begin
            u.maddr = MA_TADDR;
            u.rc = phys_regk({rd[3:1], 1'b1}, mcl); u.lc = {rd[3:1], 1'b1};
            u.c_pc = (rd[3:1] == 3'b111);
          end
        end
      end

      C_BLK: begin
        u.ub = 1'b0;
        u.ua = (ustep == 2'd0);
        // steps: 0 address, 1 transfers, 2 final base writeback (ARMv5 LDM
        // with the base in the list), 3 the PC load after that writeback
        rl0 = ins[15:0];
        list = rl0;
        cnt = (rl0 == 16'h0) ? 5'd16 : popcnt16(rl0);
        ubank = ins[22] && !(ins[20] && list[15]);
        bmode = ubank ? M_USR : mode;
        bcl = ubank ? 3'd0 : mcl;
        base_in = rl0[rn];
        fwb = ins[21] && base_in && ((rl0 == (16'h1 << rn)) || ((rl0 >> rn) > 16'h1));
        if (ustep == 2'd0) begin
          u.b_imm = 1'b1;
          u.imm = {25'h0, cnt, 2'b00};
          u.alu = ins[23] ? AL_ADD : AL_SUB;
          u.taddr = TA_BLOCK;
          u.blk_u = ins[23];
          u.blk_pu = (ins[24] == ins[23]);
          u.wa = phys_regk(rn, mcl); u.lw = rn;
          if (ins[20]) u.wen = ins[21] && !base_in;
          else         u.wen = ins[21] && (list == 16'h0);
          if (list != 16'h0) begin
            more = 1'b1; nstep = 2'd1; nrl = list;
          end
        end else if (ustep == 2'd2 || (ustep == 2'd1 && ins[20] && fwb && rl_rem == 16'h8000)) begin
          u.wen = 1'b1;
          u.wsrc = WS_TWB;
          u.wa = phys_regk(rn, mcl); u.lw = rn;
          more = (rl_rem == 16'h8000) && (ustep == 2'd1);
          nstep = 2'd3;
        end else begin
          r = rl_r;
          nrl = rl_rem & ~(16'h1 << r);
          lastx = (nrl == 16'h0);
          firstx = (rl_rem == list);
          u.maddr = MA_TADDR;
          u.taddr = TA_NEXT;
          u.norot = 1'b1;
          if (ins[20]) begin
            u.mem = MO_LOAD;
            u.wsrc = WS_MEM;
            if (r == 4'hF) begin
              u.wpc = 1'b1;
              u.restore = ins[22];
              u.pct = !ins[22] ? PT_DATA0 : PT_KEEP;
            end else begin
              u.wen = 1'b1;
              u.wa = phys_regk(r, bcl); u.lw = r;
            end
            more = !lastx || (fwb && ustep == 2'd1);
            nstep = lastx ? 2'd2 : 2'd1;
          end else begin
            u.mem = MO_STORE;
            u.rc = phys_regk(r, bcl); u.lc = r;
            u.c_pc = (r == 4'hF);
            u.wen = ins[21] && lastx;
            u.wsrc = WS_TWB;
            u.wa = phys_regk(rn, mcl); u.lw = rn;
            more = !lastx;
            nstep = 2'd1;
          end
        end
      end

      C_B, C_BLXI: begin
        u.ua = 1'b0; u.ub = 1'b0;
        u.imm = c_tgt;
        u.rdr = RD_IMM;
        if (cls == C_BLXI) begin
          u.cond = 4'hE;
          u.set_thumb = 1'b1;
        end
        if (ins[24] || cls == C_BLXI) begin
          u.wen = 1'b1;
          u.wsrc = WS_LINK;
          u.wa = phys_regk(4'hE, mcl); u.lw = 4'hE;
        end
      end

      C_TBR: begin
        u.ua = 1'b0; u.ub = 1'b0;
        case (c_kind)
          TK_B: begin
            u.imm = c_tgt;
            u.rdr = RD_IMM;
          end
          TK_BL1: begin
            u.wen = 1'b1;
            u.wsrc = WS_LINK;
            u.wa = phys_regk(4'hE, mcl); u.lw = 4'hE;
            u.link = c_tgt;
          end
          default: begin                       // BL / BLX suffix
            u.ra = phys_regk(4'hE, mcl); u.la = 4'hE;
            u.a_pc = 1'b0;
            u.ua = !c_bl2;
            u.b_imm = 1'b1;
            u.imm = {20'h0, ins[10:0], 1'b0};
            u.alu = AL_ADD;
            if (c_bl2) begin                   // right after its prefix: the target is known
              u.imm = c_bl2t;
              u.rdr = RD_IMM;
              u.clr_thumb = (c_kind == TK_BLX2);
            end else begin                     // on its own (an interrupt came between the halves): lr + offset
              u.rdr = RD_ALU;
              u.pct = (c_kind == TK_BLX2) ? PT_ARM : PT_KEEP;
              u.clr_thumb = (c_kind == TK_BLX2);   // the CPSR's T too, not only the fetch (White 2's import: the ARM
                                                   // routine behind it ran as Thumb from the next redirect on)
            end
            u.wen = 1'b1;
            u.wsrc = WS_LINK;
            u.wa = phys_regk(4'hE, mcl); u.lw = 4'hE;
            u.link = link4 | 32'h1;
          end
        endcase
      end

      C_BX, C_BLXR: begin
        u.ua = 1'b0;
        u.alu = AL_MOV;
        u.rdr = RD_ALU;
        u.rdx = 1'b1;
        u.pct = PT_DATA0;
        if (cls == C_BLXR) begin
          u.wen = 1'b1;
          u.wsrc = WS_LINK;
          u.wa = phys_regk(4'hE, mcl); u.lw = 4'hE;
          u.link = h_th ? (link4 | 32'h1) : link4;
        end
      end

      C_CLZ: begin
        u.ua = 1'b0;
        u.alu = AL_CLZ;
        u.wen = (rd != 4'hF);
        u.wa = phys_regk(rd, mcl); u.lw = rd;
      end

      C_QOP: begin
        u.alu = ins[21] ? AL_QSUB : AL_QADD;
        u.qdbl = ins[22];
        u.wen = (rd != 4'hF);
        u.wa = phys_regk(rd, mcl); u.lw = rd;
      end

      C_CP: begin
        u.ua = 1'b0; u.ub = 1'b0;
        u.mem = MO_CP;
        u.msigned = !ins[20];                  // MCR
        u.norot = 1'b1;
        u.cp_op = {2'b00, ins[23:21], ins[19:16], ins[3:0], ins[7:5]};
        u.rc = phys_regk(rd, mcl); u.lc = rd;
        u.c_pc = (rd == 4'hF);
        u.wsrc = WS_MEM;
        u.wen = ins[20] && (rd != 4'hF);
        u.wa = phys_regk(rd, mcl); u.lw = rd;
        if (!ins[20] && ins[19:16] == 4'd7 && ((ins[3:0] == 4'd0 && ins[7:5] == 3'd4) ||
                                               (ins[3:0] == 4'd8 && ins[7:5] == 3'd2))) begin
          u.wfi = 1'b1;
          u.rdr = RD_LINK;
        end
      end

      C_SWI: begin
        exc_any = 1'b1; emode = M_SVC; evec = 32'h08;
      end
      C_BKPT: begin
        exc_any = 1'b1; emode = M_ABT; evec = 32'h0C; u.link = h_pc + 32'd4; u.cond = 4'hE;
      end
      C_UND: begin
        exc_any = 1'b1; emode = M_UND; evec = 32'h04;
        if (c_kind == TK_UND || ins[31:28] == 4'hF) u.cond = 4'hE;
      end
      default: u.cond = 4'hF;                  // C_NOP: never
    endcase

    if (exc_any) begin
      u.exc = 1'b1;
      u.exc_mode = emode;
      u.wen = 1'b1;
      u.wsrc = WS_LINK;
      u.wa = phys_reg(4'hE, emode); u.lw = 4'hE;
      u.mem = MO_NONE;
      u.wpc = 1'b0;
      u.restore = 1'b0;
      u.flags = FL_NONE;
      u.rdr = RD_IMM;
      u.rdx = 1'b0;
      u.imm = (hivecs[0] ? 32'hFFFF0000 : 32'h0) + evec;
      more = 1'b0;
    end
    if (u.maddr == MA_TADDR || u.wsrc == WS_TWB) begin u.ua = 1'b0; u.ub = 1'b0; end
    if (exc_any) begin u.ua = 1'b0; u.ub = 1'b0; end
    u.last = !more;
    u0 = u;
    if (h_ab || take_fiq || take_irq) begin
      u = '0;
      emode = h_ab ? M_ABT : take_fiq ? M_FIQ : M_IRQ;
      evec  = h_ab ? 32'h0C : take_fiq ? 32'h1C : 32'h18;
      u.valid = h_v;
      u.thumb = h_th;
      u.pc = h_pc;
      u.exc_f = !h_ab && take_fiq;
      u.link = h_pc + 32'd4;
      u.cond = 4'hE;
      u.exc = 1'b1;
      u.exc_mode = emode;
      u.wen = 1'b1;
      u.wsrc = WS_LINK;
      u.wa = phys_reg(4'hE, emode); u.lw = 4'hE;
      u.rdr = RD_IMM;
      u.imm = (hivecs[0] ? 32'hFFFF0000 : 32'h0) + evec;
      u.last = 1'b1;
    end
  end

  // The instruction has more uops after this one: from the head's bits and D's registers only, not through the
  // decode (#1896-#1898: q_cls -> decode -> more -> pop -> the queue, -0.9 ns); the decode's more is checked
  logic mf;
  always_comb begin
    logic [31:0] i;
    logic [15:0] rl0, nrl_f;
    logic [3:0]  rn;
    logic        wb, fwb, lastx;
    i = c_ins; rl0 = i[15:0]; rn = i[19:16];
    wb = !i[24] || i[21];
    nrl_f = rl_rem & ~(16'h1 << rl_r);
    lastx = (nrl_f == 16'h0);
    fwb = i[21] && rl0[rn] && ((rl0 == (16'h1 << rn)) || ((rl0 >> rn) > 16'h1));
    mf = 1'b0;
    case (c_cls)
      C_DP:   mf = i[4] && !i[25] && ustep == 2'd0;
      C_MULL: mf = ustep == 2'd0;
      C_SMUL: mf = i[22:21] == 2'b10 && ustep == 2'd0;
      C_SWP:  mf = ustep == 2'd0;
      C_SDT:  mf = i[20] && wb && ustep == 2'd0;
      C_HW: begin
        if (i[20])                    mf = wb && ustep == 2'd0;            // LDRH/LDRSB/LDRSH
        else if (i[6:5] == 2'b01)     mf = 1'b0;                           // STRH
        else if (!i[5])               mf = ustep != 2'd2;                  // LDRD: address, Rd, Rd+1
        else                          mf = ustep == 2'd0;                  // STRD
      end
      C_BLK: begin
        if (ustep == 2'd0)
          mf = rl0 != 16'h0;
        else if (ustep == 2'd2 || (ustep == 2'd1 && i[20] && fwb && rl_rem == 16'h8000))
          mf = rl_rem == 16'h8000 && ustep == 2'd1;
        else if (i[20])
          mf = !lastx || (fwb && ustep == 2'd1);
        else
          mf = !lastx;
      end
      default: mf = 1'b0;
    endcase
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && h_v && !inject && mf !== more)
      $error("arm9_core: the head's uop count (%b) differs from the decode's (%b), pc %h", mf, more, h_pc);
`endif

  // The registers this uop reads, from the instruction's fields (flagged by class and step), not through the
  // decode's port mapping (#1906: decode -> u.la/u.lb -> compare -> have -> pop, -1.51 ns). A superset of the
  // decode's reads (rd_reg, checked in simulation), so it never misses a hazard.
  logic rN, rD, rS, rM, rL, rLR, rD1;  // Rn, Rd, Rs, Rm, the LDM/STM list register, LR, {Rd[3:1], 1}
  always_comb begin
    logic [31:0] i;
    logic        st;
    i = c_ins;
    rN = 1'b0; rD = 1'b0; rS = 1'b0; rM = 1'b0; rL = 1'b0; rLR = 1'b0; rD1 = 1'b0;
    case (c_cls)
      C_DP:   begin rN = i[24:21] != 4'hD && i[24:21] != 4'hF; rM = !i[25]; rS = !i[25] && i[4] && ustep == 2'd0; end
      C_MSR:  rM = !i[25];
      C_MUL:  begin rM = 1'b1; rS = 1'b1; rD = i[21]; end
      C_MULL: if (ustep == 2'd0) begin rM = 1'b1; rS = 1'b1; rD = i[21]; end else rN = i[21];
      C_SMUL: if (ustep == 2'd0) begin rM = 1'b1; rS = 1'b1; rD = 1'b1; end else rN = 1'b1;
      C_SWP:  if (ustep == 2'd0) begin rN = 1'b1; rM = 1'b1; end
      C_SDT:  if (ustep == 2'd0) begin rN = 1'b1; rM = i[25]; rD = !i[20]; end
      C_HW: begin
        st = !i[20] && i[6:5] == 2'b01;
        if (ustep == 2'd0) begin rN = 1'b1; rM = !i[22]; rD = st || (!i[20] && i[6:5] == 2'b11); end
        else if (!i[20] && i[6:5] == 2'b11) rD1 = 1'b1;                    // STRD's second word
      end
      C_BLK:  if (ustep == 2'd0) rN = 1'b1; else rL = !i[20];
      C_TBR:  rLR = (c_kind == TK_BL2 || c_kind == TK_BLX2) && !c_bl2;
      C_BX, C_BLXR, C_CLZ: rM = 1'b1;
      C_QOP:  begin rN = 1'b1; rM = 1'b1; end
      C_CP:   rD = !i[20];
      default: ;
    endcase
  end
  function automatic logic rd_f(input logic [3:0] r);
    return (rN && c_ins[19:16] == r) || (rD && c_ins[15:12] == r) || (rS && c_ins[11:8] == r) ||
           (rM && c_ins[3:0] == r) || (rL && rl_r == r) || (rLR && r == 4'hE) || (rD1 && {c_ins[15:13], 1'b1} == r);
  endfunction

  // Interlocks (D waits; E gets a bubble). Register reads of u.
  function automatic logic rd_reg(input uop9_t x, input logic [3:0] r);
    return (x.ua && r == x.la && !x.a_pc) ||
           (x.ub && r == x.lb && !x.b_pc && !x.b_imm) ||
           (r == x.lc && !x.c_pc && (x.amt_save || x.macc || x.mem == MO_STORE || (x.mem == MO_CP && x.msigned) || x.st_save));
  endfunction
`ifndef SYNTHESIS
  // A held store consumes temp_st, not the decode's unused port-C field.
  // Keep this semantic refinement in the checkers, outside the hardware.
  function automatic logic rd_checked(input uop9_t x, input logic [3:0] r);
    uop9_t live;
    live = x;
    if (x.mem == MO_STORE && x.st_temp) live.mem = MO_NONE;
    return rd_reg(live, r);
  endfunction
`endif
  function automatic logic psr_user(input uop9_t x);
    return x.cond != 4'hE || x.flags != FL_NONE || x.alu == AL_ADC || x.alu == AL_SBC || x.alu == AL_RSC ||
           x.alu == AL_PSR || x.sh_type == SH_RRX || x.exc || x.restore || x.msr || x.psr_spsr || x.mflag || x.mq ||
           x.alu == AL_QADD || x.alu == AL_QSUB || x.set_thumb || x.clr_thumb || x.rdx;
  endfunction
  logic e_ldx;                         // E's uop loads (its value is in W two clocks later)
  assign e_ldx = eu.valid && eu.wen && eu.wsrc == WS_MEM;
  always_comb begin
    logic h_ld, h_bh, h_mul, h_amt, h_mf, h_wpc, h_exc, h_bub, h_sl, psrw;
    // load-use: the value comes from W, so a reader waits while the load is in E (bytes/halfwords: also in M)
    h_ld  = e_ldx && rd_f(eu.lw);
    h_bh  = m_v && m_ld && m_wen && m_ldbh && rd_f(m_lw);
    // a product is written in W, read from the last-write bypass after it
    h_mul = (eu.valid && eu.mulw && eu.wen && rd_f(eu.lw)) || (m_v && m_mulw && m_wen && rd_f(m_lw));
    // the DS: a register-specified shift whose amount was written right before waits one clock
    h_amt = c_cls == C_DP && !c_ins[25] && c_ins[4] && ustep == 2'd0 && eu.valid && eu.wen && eu.lw == c_ins[11:8];
    // product flags are written in W
    h_mf  = ((eu.valid && (eu.mflag || eu.mq)) || (m_v && (m_mflag || m_mq))) && psr_user(u);
    // nothing issues behind a load into the PC (it redirects from W)
    h_wpc = (eu.valid && eu.wpc) || (m_v && m_wpc);
    // CPSR/SPSR writers wait until no memory access ahead of them can still abort
    psrw  = u.exc || u.msr || u.restore || u.set_thumb || u.clr_thumb || u.wfi;
    h_exc = psrw && ((eu.valid && eu.mem != MO_NONE) || (m_v && m_mem));
    // E busy a second clock (MUL/MLA, the long multiplies' last uop)
    h_bub = eu.valid && eu.mbub;
    // the DS: a load right behind a store waits one clock
    h_sl  = u.mem == MO_LOAD && eu.valid && eu.mem == MO_STORE;
    hold  = h_ld || h_bh || h_mul || h_amt || h_mf || h_wpc || h_exc || h_bub || h_sl;
  end
  assign have = h_v && !hold;
  assign d_go = have && !stall && !flush;

  // Register file: three read ports, one write port; the read address is
  // taken when D's uop moves into E (read-enable), the data is E's
  logic [31:0] rf_a, rf_b, rf_c;
  logic        rf_we;
  logic [4:0]  rf_wa;
  logic [31:0] rf_wd;
  logic        rf_we_ns;
  logic        rf_re;
  assign rf_re = !stall;
  // M10K: the read is registered in the block (data ~4 ns after the clock); MLAB: read in D (asynchronous, from
  // D's indices), the data registered in logic at D's end, so E starts from registers (a9stall #1934/#1935: the
  // MLAB read in E, rdaddr_reg -> rfm1 -> shifter -> adder -> temp_addr / w_rm / cpsr_s, -3.06 ns). Either way
  // the write at the same edge is not seen: the last-write bypass (fs_* 3, wq_d, held through a stall as the
  // data registers are; W writes nothing while stalled) gives it
  generate if (RF_STYLE == "MLAB") begin : g_rfm
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rfm0 [0:31];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rfm1 [0:31];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rfm2 [0:31];
    // the three reads as kept nets, so the operand registers rf_a / rf_b / rf_c stay fabric flip-flops the fitter can
    // place beside the shifter and adder and duplicate, not the MLABs' own output registers (rel15f block #2790: all
    // 46 failing m_wd endpoints from rfm1's dataout_reg[10] -> e_b -> rotator -> adder, +0.146 ns; forwarded flops on
    // the same cone are all above +1.0). The same values, the same cycles
    (* keep = 1 *) logic [31:0] rd_a, rd_b, rd_c;
    assign rd_a = rfm0[u.ra];
    assign rd_b = rfm1[u.rb];
    assign rd_c = rfm2[u.rc];
    always_ff @(posedge clk) begin
      if (rf_we) begin
        rfm0[rf_wa] <= rf_wd;
        rfm1[rf_wa] <= rf_wd;
        rfm2[rf_wa] <= rf_wd;
      end
      if (rf_re) begin
        rf_a <= rd_a;
        rf_b <= rd_b;
        rf_c <= rd_c;
      end
    end
  end else begin : g_rfk
    (* ramstyle = RF_STYLE *) logic [31:0] rfm0 [0:31];
    (* ramstyle = RF_STYLE *) logic [31:0] rfm1 [0:31];
    (* ramstyle = RF_STYLE *) logic [31:0] rfm2 [0:31];
    always_ff @(posedge clk) begin
      if (rf_we) begin
        rfm0[rf_wa] <= rf_wd;
        rfm1[rf_wa] <= rf_wd;
        rfm2[rf_wa] <= rf_wd;
      end
      if (rf_re) begin
        rf_a <= rfm0[u.ra];
        rf_b <= rfm1[u.rb];
        rf_c <= rfm2[u.rc];
      end
    end
  end endgenerate
  // the last write (the register file read at the same edge saw the old value)
  logic        wq_en;
  logic [4:0]  wq_a;
  logic [31:0] wq_d;

  // ---------------------------------------------------------------- E
  logic [31:0] temp_addr, temp_wb, temp_st;
  // temp_addr's +4 is added where it is used, from registers (a9stall #1935: register file -> shifter -> ALU ->
  // maddr + 4 -> temp_addr, -3.06 ns)
  logic [31:0] temp_base;
  logic        temp_inc;
  assign temp_addr = temp_base + {29'd0, temp_inc, 2'b00};
  logic [7:0]  temp_amt;
  logic [31:0] spsr_r;                 // the SPSR of the current mode
  logic [31:0] m_wd, m_res;            // M's write value / ALU result
  logic        m_fw;                   // M's write value is known (not a load or product)
  logic [31:0] w_wd;
  logic        w_fw;
  // Decode the condition with D's uop. The flags must still be live in E.
  logic [14:0] e_condition;
  wire e_n = cpsr[31], e_cc = cpsr[29], e_vflag = cpsr[28];
`ifdef ARM9_COND_STALE_Z_MUT
  logic delayed_z;
  always_ff @(posedge clk) delayed_z <= !rst && cpsr[30];
  wire e_eq_z = delayed_z;
`else
  wire e_eq_z = cpsr[30];
`endif
  wire e_hi = e_cc && !cpsr[30];
  wire e_ge = e_n == e_vflag;
  wire e_gt = e_ge && !cpsr[30];
  wire [14:0] e_predicates = {1'b1, !e_gt, e_gt, !e_ge, e_ge, !e_hi, e_hi,
                             !e_vflag, e_vflag, !e_n, e_n, !e_cc, e_cc, !e_eq_z, e_eq_z};
  assign e_exec = eu.valid && (|(e_condition & e_predicates)) && !m_rdr && !w_rdr;
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && eu.valid && !m_rdr && !w_rdr &&
        e_exec !== cond_pass(eu.cond, cpsr[31:28]))
      $error("arm9_core: live condition mismatch pc=%h cond=%h flags=%h redirect=%b fetch=%h",
             eu.pc, eu.cond, cpsr[31:28], e_rdr, i_addr);
`endif
  assign e_live = e_exec && !stall;

  function automatic logic [31:0] fwd(input logic [4:0] r, input logic [31:0] rf);
    if (m_fw && m_wa == r) return m_wd;
    if (w_fw && w_wa == r) return w_wd;
    if (wq_en && wq_a == r) return wq_d;
    return rf;
  endfunction
  logic [31:0] e_a, e_b, e_c;
  // The bypass selects are decided in D for the uop entering E (registered with it, #1886: eu.rb/w_wa ->
  // compare -> e_b -> address adder -> d_addr -> MPU match, -3.06 ns): as it enters, E's uop moves to M, M's
  // to W, and W's register write is the last write. 0 register file, 1 M, 2 W, 3 the last write.
  logic [1:0]  fs_a, fs_b, fs_c;
  function automatic logic [1:0] fsel(input logic [4:0] r);
    if (e_exec && eu.wen && eu.wsrc != WS_MEM && !eu.mulw && eu.wa == r) return 2'd1;
    if (m_v && m_exec && m_wen && !m_mulw && m_wa == r)                   return 2'd2;
    if (rf_we_ns && rf_wa == r)                                           return 2'd3;   // (only sampled under !stall: rf_we without its stall term)
    return 2'd0;
  endfunction
  function automatic logic [31:0] fpick(input logic [1:0] sel, input logic [31:0] rf);
    case (sel)
      2'd1: return m_wd;
      2'd2: return w_wd;
      2'd3: return wq_d;
      default: return rf;
    endcase
  endfunction
  // E's operands as an AND-OR of registered one-hot selects over registered sources (register file, M, W, the
  // last write, the uop's constant: no select decode in E; the block fits #1942-#1946: fs_b -> fpick -> e_b ->
  // shifter/adder, -1.1..-1.35 ns). {rf, M, W, last write, constant}
  logic [4:0]  oh_a, oh_b, oh_c;
  function automatic logic [4:0] onehot(input logic [1:0] sel, input logic konst);
    if (konst) return 5'b10000;
    case (sel)
      2'd1: return 5'b00010;
      2'd2: return 5'b00100;
      2'd3: return 5'b01000;
      default: return 5'b00001;
    endcase
  endfunction
  function automatic logic [31:0] ohpick(input logic [4:0] oh, input logic [31:0] rf, input logic [31:0] k);
    return ({32{oh[0]}} & rf) | ({32{oh[1]}} & m_wd) | ({32{oh[2]}} & w_wd) | ({32{oh[3]}} & wq_d) | ({32{oh[4]}} & k);
  endfunction
  logic        kb_imm;                  // port B's constant is the immediate (else the PC value)
  // port B's constant, chosen in D and registered with the uop (#2367: kb_imm -> e_b -> m_wd, -0.777 ns): E's
  // operand AND-OR takes it as one term, without kb_imm's select and its fanout
  logic [31:0] kconst;
  // the register file's word (the M10K's output, the latest source) enters at the last mux: the other sources are
  // picked beside it (RC6 #2096: register file -> two operand mux levels -> shifter -> address adder -> temp_base)
  logic [31:0] e_a_o, e_b_o, e_c_o;
  assign e_a_o = ohpick({oh_a[4:1], 1'b0}, 32'h0, eu.pcv);
  // port B's W term (the write-back value) from a register of its own, masked by its select, loaded at the same edge as
  // w_wd from w_wd's input (RC11 #2438 / #2450 7asR: w_wd -> e_b -> shifter -> a_off -> address adder -> the ITCM
  // address, -1.47 / -1.39 ns; w_wd's fanout and the select's AND leave the path). Checked against oh_b[2] & w_wd
  logic [31:0] e_bw;
  // e_bw is loaded unmasked and masked here by oh_b[2] (registered beside it): the select's compare left D's path
  // into e_bw's 32 enables (rc15f #2846 5asR: q_cls -> decode -> rb -> fsel -> e_bw's mask, -0.072 ns); e_b_o's
  // inputs are all registers, so the register file still enters e_b at the last level
`ifdef ARM9_EBWM_MUT
  assign e_b_o = ohpick({oh_b[4:3], 1'b0, oh_b[1], 1'b0}, 32'h0, kconst) | ({32{oh_b[1]}} & e_bw);   // (mutant: the M select)
`else
  assign e_b_o = ohpick({oh_b[4:3], 1'b0, oh_b[1], 1'b0}, 32'h0, kconst) | ({32{oh_b[2]}} & e_bw);
`endif
  assign e_c_o = ohpick({oh_c[4:1], 1'b0}, 32'h0, eu.pcv_c);
  assign e_a = oh_a[0] ? rf_a : e_a_o;
  assign e_b = oh_b[0] ? rf_b : e_b_o;
  assign e_c = oh_c[0] ? rf_c : e_c_o;
`ifndef SYNTHESIS
  // simulation: the mode class register follows cpsr_s's mode
  always_ff @(posedge clk)
    if (!rst && mcl !== mclass(cpsr_s[4:0]))
      $error("arm9_core: ERROR: mode class %0d, cpsr mode %h", mcl, cpsr_s[4:0]);
  // simulation: the selects are one-hot, so this is the AND-OR it replaces
  always_ff @(posedge clk)
    if (!rst && eu.valid && (e_a !== ohpick(oh_a, rf_a, eu.pcv) || e_b !== ohpick(oh_b, rf_b, kb_imm ? eu.imm : eu.pcv) ||
                             e_c !== ohpick(oh_c, rf_c, eu.pcv_c)))
      $error("arm9_core: operand mux differs from the one-hot AND-OR (selects %b %b %b, pc %h)", oh_a, oh_b, oh_c, eu.pc);
  always_ff @(posedge clk)
    if (!rst && oh_b[2] && e_bw !== w_wd)
      $error("arm9_core: port B's W register %h, w_wd %h (pc %h)", e_bw, w_wd, eu.pc);
  always_ff @(posedge clk)
    if (!rst && eu.valid && kconst !== (kb_imm ? eu.imm : eu.pcv))
      $error("arm9_core: kconst %h, port B's constant %h (pc %h)", kconst, kb_imm ? eu.imm : eu.pcv, eu.pc);
  always_ff @(posedge clk)
    if (!rst && eu.valid) begin
      logic [31:0] xo, yo;
      case (eu.alu)
        AL_SUB, AL_CMP, AL_SBC: begin xo = opa;  yo = ~sh_out; end
        AL_RSB, AL_RSC:         begin xo = sh_out; yo = ~opa; end
        AL_QADD:                begin xo = sh_out; yo = e_ad; end
        AL_QSUB:                begin xo = sh_out; yo = ~e_ad; end
        default:                begin xo = opa;  yo = sh_out; end
      endcase
      if (xo !== alu_x || yo !== alu_y)
        $error("arm9_core: adder operands %h %h, the case's %h %h (alu %0d, pc %h)", alu_x, alu_y, xo, yo, eu.alu, eu.pc);
    end
`endif
`ifndef SYNTHESIS
  // simulation: the registered selects give what the compares in E would
  always_ff @(posedge clk)
    if (!rst && eu.valid && (e_a !== (eu.a_pc ? eu.pcv : fwd(eu.ra, rf_a)) ||
                             e_b !== (eu.b_imm ? eu.imm : eu.b_pc ? eu.pcv : fwd(eu.rb, rf_b)) ||
                             e_c !== (eu.c_pc ? eu.pcv_c : fwd(eu.rc, rf_c))))
      $error("arm9_core: bypass select differs from the E compare (pc %h)", eu.pc);
`endif

  // Shifter controls, decoded ahead of E (#1896/#1898: eu.sh_amt/sh_reg/temp_amt -> this decode -> rotator ->
  // ALU -> CPSR / d_addr, -2.3 ns): in D for an immediate shift (registered with the uop), at the amount uop's
  // E for a register-specified one (registered with temp_amt). E picks one of the two.
  // {rot, keep, fasr, frrx, csel}: E computes x ror rot, keeps the bits in keep, fills the rest (ASR: x[31];
  // RRX: C into bit 31); csel picks the carry out
  typedef struct packed {
    logic [4:0]  rot;
    logic [31:0] keep;
    logic        fasr, frrx;
    logic [2:0]  csel;
  } shc_t;
  function automatic shc_t shctl(input logic [2:0] ty, input logic [7:0] n);
    shc_t c;
    logic [4:0] n5;
    n5 = n[4:0];
    c.rot = 5'd0; c.keep = 32'hFFFFFFFF; c.fasr = 1'b0; c.frrx = 1'b0; c.csel = CS_OLD;
    case (ty)
      SH_LSL: begin
        if (n == 8'd0) begin
        end else if (n < 8'd32) begin
          c.rot = 5'd0 - n5; c.keep = 32'hFFFFFFFF << n5; c.csel = CS_R0;
        end else if (n == 8'd32) begin
          c.keep = 32'h0; c.csel = CS_R0;
        end else begin
          c.keep = 32'h0; c.csel = CS_ZERO;
        end
      end
      SH_LSR, SH_ASR: begin
        if (n == 8'd0) begin
        end else if (n < 8'd32) begin
          c.rot = n5; c.keep = 32'hFFFFFFFF >> n5; c.csel = CS_R31; c.fasr = (ty == SH_ASR);
        end else if (n == 8'd32 || ty == SH_ASR) begin
          c.keep = 32'h0; c.csel = CS_X31; c.fasr = (ty == SH_ASR);
        end else begin
          c.keep = 32'h0; c.csel = CS_ZERO;
        end
      end
      SH_ROR: if (n != 8'd0) begin c.rot = n5; c.csel = CS_R31; end
      default: begin c.rot = 5'd1; c.keep = 32'h7FFFFFFF; c.frrx = 1'b1; c.csel = CS_R0; end   // RRX
    endcase
    return c;
  endfunction
  shc_t        e_shc, t_shc;           // the uop's (immediate) controls / temp_amt's
  logic        e_shn;                  // the uop's shift is the identity (LSL #0, not by register)
  shc_t        sc;
  logic [4:0]  sh_rot;
  logic [31:0] sh_keep;
  logic        sh_fasr, sh_frrx;
  logic [2:0]  sh_csel;
  assign sc      = eu.sh_reg ? t_shc : e_shc;
  assign sh_rot  = sc.rot;
  assign sh_keep = sc.keep;
  assign sh_fasr = sc.fasr;
  assign sh_frrx = sc.frrx;
  assign sh_csel = sc.csel;
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    // A failed condition skips preparation; its saved shift controls are unused.
    if (!rst && eu.valid && e_exec && sc !== shctl(eu.sh_type, eu.sh_reg ? temp_amt : eu.sh_amt))
      $error("arm9_core: shifter controls differ from E's decode (pc %h)", eu.pc);
`endif

  logic [31:0] x_rot, sh_out, e_ad;
  logic        sh_c, sh_cold, qsat_d;
  logic [31:0] x_rot4;                 // x_rot before its last stage (sh_rot[0]), for the address offset
  always_comb begin
    x_rot4 = e_b;
    if (sh_rot[4]) x_rot4 = {x_rot4[15:0], x_rot4[31:16]};
    if (sh_rot[3]) x_rot4 = {x_rot4[7:0],  x_rot4[31:8]};
    if (sh_rot[2]) x_rot4 = {x_rot4[3:0],  x_rot4[31:4]};
    if (sh_rot[1]) x_rot4 = {x_rot4[1:0],  x_rot4[31:2]};
    x_rot = sh_rot[0] ? {x_rot4[0], x_rot4[31:1]} : x_rot4;
    for (int i = 0; i < 32; i++)
      sh_out[i] = sh_keep[i] ? x_rot[i] : ((sh_fasr & e_b[31]) | (sh_frrx & cpsr[29] & (i == 31)));
    sh_cold = 1'b0;
    case (sh_csel)
      CS_R0:   sh_c = sh_frrx ? e_b[0] : x_rot[0];
      CS_R31:  sh_c = x_rot[31];
      CS_X31:  sh_c = e_b[31];
      CS_ZERO: sh_c = 1'b0;
      default: begin sh_c = 1'b0; sh_cold = 1'b1; end
    endcase
    qsat_d = 1'b0;
    e_ad = e_a;
    if (eu.qdbl) begin
      if (e_a[31] != e_a[30]) begin
        qsat_d = 1'b1;
        e_ad = e_a[31] ? 32'h80000000 : 32'h7FFFFFFF;
      end else begin
        e_ad = {e_a[30:0], 1'b0};
      end
    end
  end

  logic [31:0] opa, opp, res, lres, maddr, psr_val;
  logic [31:0] alu_x, alu_y;               // (simulation check)
  logic        e_swap, e_inv;              // the adder's operands (registered with the uop): swap S and P, invert y
  logic [31:0] res_o;                  // res when it is not the adder's sum (logic unit, CLZ, PSR, saturation)
  logic        res_s;                  // res is the adder's sum
  // m_res's own select: as res_s, but a saturating op takes the raw sum. m_res is read only as an ALU redirect's
  // target (m_tgt) and an MSR's value, and a QADD/QSUB is neither (Rd = PC: no write, no redirect), so its saturation
  // (res_s = !add_v, from the top of the carry chain, selecting all 32 bits) stays on m_wd alone. m_res's select is
  // then a function of the registered uop (RC9d #2335 3asR: oh_b -> shifter -> adder -> add_v -> res_s, fanout 35 ->
  // m_res -0.386; the same family in #2328, #2336)
  logic        res_ms;
  logic [31:0] res_m;
  logic [32:0] sum33;
  logic        add_c, add_v, alu_arith, shc_res;
  logic [2:0]  sidx;
  logic        spsr_ok;
  assign sidx    = spsr_idx(cpsr[4:0]);
  assign spsr_ok = (sidx != 3'd7);
  assign shc_res = sh_cold ? cpsr[29] : sh_c;
  always_comb begin
    logic [31:0] x, y;
    logic        ci;
    logic [5:0]  lz;
    logic [33:0] s34;
    opa = eu.a_zero ? 32'h0 : e_a;
    alu_arith = 1'b1;
    // x = swap ? S : P, y = inv ^ (swap ? P : S) (S the shifter's, P port A's: e_ad masked as opa): each bit a
    // function of four registered-select inputs, so it fits the adder's own LUTs (RC8p2 #2275: oh_b / the register
    // file -> shifter -> the operand select -> adder -> m_res, -0.69 / -0.60 ns)
    opp = eu.a_zero ? 32'h0 : e_ad;
    x = e_swap ? sh_out : opp;
    y = {32{e_inv}} ^ (e_swap ? opp : sh_out);
    case (eu.alu)
      AL_SUB, AL_CMP, AL_RSB, AL_QSUB: ci = 1'b1;
      AL_ADC, AL_SBC, AL_RSC:          ci = cpsr[29];
      AL_ADD, AL_CMN, AL_QADD:         ci = 1'b0;
      default: begin ci = 1'b0; alu_arith = 1'b0; end
    endcase
    s34 = {1'b0, x, 1'b1} + {1'b0, y, ci};
    alu_x = x; alu_y = y;
    sum33 = s34[33:1];
    add_c = sum33[32];
    add_v = (x[31] == y[31]) && (sum33[31] != x[31]);
    psr_val = cpsr;
    if (eu.psr_spsr && spsr_ok) psr_val = spsr_r;
    lz = 6'd32;
    // CLZ's Rm is port B unshifted (LSL #0): counted from e_b, not past the shifter (RC6 #2092: operand -> shifter ->
    // the count -> result mux -> m_res, -0.83 ns)
    for (int i = 0; i < 32; i++) if (e_b[i]) lz = 6'd31 - i[5:0];
    case (eu.alu)
      AL_AND, AL_TST: lres = opa & sh_out;
      AL_EOR, AL_TEQ: lres = opa ^ sh_out;
      AL_ORR:         lres = opa | sh_out;
      AL_BIC:         lres = opa & ~sh_out;
      AL_MVN:         lres = ~sh_out;
      default:        lres = sh_out;          // MOV
    endcase
    // the adder's sum enters at the last mux (res_s), everything else is selected beside the adder (RC6 #2091: bypass
    // -> shifter -> adder -> three result muxes -> m_wd, -1.21 ns). A saturating op overflowed (add_v) has the sign
    // opposite to x's, so its value needs only x[31]
    res_s = 1'b0;
    res_ms = 1'b0;
    case (eu.alu)
      AL_AND, AL_TST, AL_EOR, AL_TEQ, AL_ORR, AL_MOV, AL_BIC, AL_MVN: res_o = lres;   // (one logic unit, shared with N/Z)
      AL_CLZ:         res_o = {26'h0, lz};
      AL_PSR:         res_o = psr_val;
      AL_QADD, AL_QSUB: begin
        res_o = x[31] ? 32'h80000000 : 32'h7FFFFFFF;
        res_s = !add_v;
        res_ms = 1'b1;
      end
      default: begin  res_o = psr_val; res_s = 1'b1; res_ms = 1'b1; end
    endcase
    res = res_s ? sum33[31:0] : res_o;
    res_m = res_ms ? sum33[31:0] : res_o;
  end
  // the data address from its own adder: base +/- offset, the offset past the shifter only when the instruction
  // shifts it (#1871: register file -> forward -> shifter -> ALU adder -> d_addr -> arm9_mem's MPU match, -3.23 ns)
  logic        sh_none;
  logic [31:0] a_off, a_sum;
  assign sh_none = e_shn;
  // a_imm: B is the uop's immediate, unshifted (registered with it): the offset is eu.imm itself, not through the
  // operand mux and its kb_imm select (RC8 #2251: kb_imm -> e_b -> address adder -> the DTCM address, -0.10 ns)
  logic        a_imm;
  // the offset's rotated word enters at its last level, with the rotator's last stage, keep and the offset select in
  // one: a_rk (registers only) takes the rotator, a_ot is the other choice (rc15f #2847 7asR: register file -> e_b ->
  // rotator -> sh_out -> a_off -> address adder -> w_addr, -0.411 ns at 0 C). The same as a_imm ? imm : sh_none ? e_b
  // : sh_out
  logic [31:0] a_rk, a_ot;
  always_comb
    for (int i = 0; i < 32; i++) begin
      a_rk[i] = !a_imm && !sh_none && sh_keep[i];
`ifdef ARM9_AOFF_MUT
      a_ot[i] = a_imm ? eu.imm[i] : sh_none ? ((sh_fasr & e_b[31]) | (sh_frrx & cpsr[29] & (i == 31))) :
                ((sh_fasr & e_b[31]) | (sh_frrx & cpsr[29] & (i == 31)));   // (mutant: an unshifted register offset as the fill)
`else
      a_ot[i] = a_imm ? eu.imm[i] : sh_none ? e_b[i] : ((sh_fasr & e_b[31]) | (sh_frrx & cpsr[29] & (i == 31)));
`endif
      a_off[i] = a_rk[i] ? (sh_rot[0] ? x_rot4[(i + 1) % 32] : x_rot4[i]) : a_ot[i];
    end
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && eu.valid && !a_imm && a_off !== (sh_none ? e_b : sh_out))
      $error("arm9_core: register address offset %h, the operand mux's %h (pc %h)", a_off, sh_none ? e_b : sh_out, eu.pc);
  always_ff @(posedge clk)
    if (!rst && eu.valid && a_imm && a_off !== (sh_none ? e_b : sh_out))
      $error("arm9_core: immediate address offset %h, the operand mux's %h (pc %h)", a_off, sh_none ? e_b : sh_out, eu.pc);
`endif
  // One address carry chain for both signs. The extra low bit supplies
  // subtraction's +1 without a second arithmetic operation or result mux.
  wire         a_sub = (eu.alu == AL_SUB);
  wire [32:0]  a_addsub = {e_a, 1'b1} + {a_off ^ {32{a_sub}}, a_sub};
  assign a_sum = a_addsub[32:1];
  logic [31:0] maddr_o;                // maddr when it is not the address adder's sum
  assign maddr_o = (eu.maddr == MA_A) ? e_a : temp_addr;
  assign maddr = (eu.maddr == MA_SUM) ? a_sum : maddr_o;
  // temp_base's next value with the two adders' sums at its last mux (RC6 #2096: address adder -> maddr -> two
  // levels -> temp_base, -1.05 ns): tb_s picks a_sum, tb_y the ALU's sum, else tb_o
  logic        tb_s, tb_y;
  logic [31:0] tb_o, tb_n;
  always_comb begin
    tb_s = (eu.taddr == TA_NEXT || eu.taddr == TA_ADDR) && eu.maddr == MA_SUM;
    tb_y = eu.taddr == TA_BLOCK && !eu.blk_u;
    tb_o = (eu.taddr == TA_BLOCK) ? opa : maddr_o;
    tb_n = tb_s ? a_sum : tb_y ? sum33[31:0] : tb_o;
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && e_exec && eu.maddr == MA_SUM && (eu.mem != MO_NONE || eu.taddr == TA_ADDR) && a_sum !== sum33[31:0])
      $error("arm9_core: address adder %h, ALU %h", a_sum, sum33[31:0]);
`endif

  // E's data request (and M's request sent again: m_rq)
  logic        e_dreq, e_creq, m_rq;
  logic [31:0] e_wdata;
  logic [3:0]  e_be;
  logic [31:0] st_data;
  logic        m_pend, m_ans;          // M's access was refused / has an answer this cycle
  assign st_data = eu.st_temp ? temp_st : e_c;
  always_comb begin
    case (eu.msize)
      MS_B: begin e_wdata = {4{st_data[7:0]}};  e_be = 4'b0001 << maddr[1:0]; end
      MS_H: begin e_wdata = {2{st_data[15:0]}}; e_be = maddr[1] ? 4'b1100 : 4'b0011; end
      default: begin e_wdata = st_data; e_be = 4'b1111; end
    endcase
  end
  // (no request from E while M waits without an answer this cycle: it would only be killed)
  assign e_dreq = e_exec && (eu.mem == MO_LOAD || eu.mem == MO_STORE) && !(m_pend && !m_ans);
  assign e_creq = e_exec && eu.mem == MO_CP && !(m_pend && !m_ans);

  logic [31:0] m_da, m_dwd;
  logic        m_dwe, m_dpriv, m_cp, m_cwe;
  logic [3:0]  m_dbe;
  logic [1:0]  m_dsz;
  logic [15:0] m_cop;
  assign d_req    = m_rq ? (m_mem && !m_cp) : e_dreq;
  assign d_tid    = 1'b0;
  assign d_priv   = m_rq ? m_dpriv : (cpsr[4:0] != M_USR);
  assign d_we     = m_rq ? m_dwe : (eu.mem == MO_STORE);
  assign d_size   = m_rq ? m_dsz : eu.msize;
  assign d_be     = m_rq ? m_dbe : e_be;
  assign d_addr   = m_rq ? m_da : maddr;
  assign d_wdata  = m_rq ? m_dwd : e_wdata;
  assign cp_req   = m_rq ? m_cp : e_creq;
  assign cp_we    = m_rq ? m_cwe : eu.msigned;
  assign cp_op    = m_rq ? m_cop : eu.cp_op;
  assign cp_wdata = m_rq ? m_dwd : e_c;
  // the request E sent while M waited is not performed (arm9_mem: d_kill in its answer cycle)
  logic        kill_q;
  assign d_kill = kill_q || w_rdr;

  // E's CPSR write
  logic        e_aflags;                 // the ALU writes NZCV (FL_DP, no exception entry or SPSR restore)
  logic [3:0]  e_nzcv;
  logic        e_afl_ns;                 // e_aflags without stall
  assign e_afl_ns = e_exec && eu.flags == FL_DP && !eu.exc && !(eu.restore && !eu.wpc && spsr_ok);
  assign e_aflags = e_afl_ns && !stall;
  // Z of an add without the carry chain: x + y + ci is zero exactly when every bit's x^y equals the carry into it,
  // and that carry is (x|y) one bit down (ci at bit 0) (#1939 block fit: bypass -> shifter -> adder -> res -> zero
  // test -> CPSR Z, -1.26 ns)
  logic [31:0] z_x, z_y;
  logic        z_ci, z_add;
  always_comb begin
    case (eu.alu)
      AL_SUB, AL_CMP, AL_SBC: begin z_x = opa;    z_y = ~sh_out; end
      AL_RSB, AL_RSC:         begin z_x = sh_out; z_y = ~opa;    end
      default:                begin z_x = opa;    z_y = sh_out;  end
    endcase
    case (eu.alu)
      AL_SUB, AL_CMP, AL_RSB: z_ci = 1'b1;
      AL_ADC, AL_SBC, AL_RSC: z_ci = cpsr[29];
      default:                z_ci = 1'b0;
    endcase
    z_add = &(~((z_x ^ z_y) ^ {z_x[30:0] | z_y[30:0], z_ci}));
  end
  // m_wd when it is not the adder's sum: link, base write-back, or res_o
  logic [31:0] wd_o;
  assign wd_o = (eu.wsrc == WS_LINK) ? eu.link : (eu.wsrc == WS_TWB) ? temp_wb : res_o;
`ifndef SYNTHESIS
  // simulation: temp_base's next value as the case it replaces
  always_ff @(posedge clk)
    if (!rst && e_live && (eu.taddr == TA_NEXT || eu.taddr == TA_ADDR || eu.taddr == TA_BLOCK) &&
        tb_n !== ((eu.taddr == TA_BLOCK) ? (eu.blk_u ? opa : sum33[31:0]) : maddr))
      $error("arm9_core: temp_base next %h, the case's %h (pc %h)", tb_n, (eu.taddr == TA_BLOCK) ? (eu.blk_u ? opa : sum33[31:0]) : maddr, eu.pc);
`endif
`ifndef SYNTHESIS
  // simulation: CLZ's operand is the shifter's input unchanged
  always_ff @(posedge clk)
    if (!rst && eu.valid && e_exec && eu.alu == AL_CLZ && sh_out !== e_b) $error("arm9_core: CLZ operand %h past the shifter, %h before (pc %h)", sh_out, e_b, eu.pc);
`endif
`ifndef SYNTHESIS
  // simulation: res and m_wd's input as the one mux they replace
  always_ff @(posedge clk)
    if (!rst && eu.valid) begin
      logic [31:0] r0, w0, w1;
      case (eu.alu)
        AL_AND, AL_TST, AL_EOR, AL_TEQ, AL_ORR, AL_MOV, AL_BIC, AL_MVN: r0 = lres;
        AL_PSR:         r0 = psr_val;
        AL_QADD, AL_QSUB: r0 = add_v ? (sum33[31] ? 32'h7FFFFFFF : 32'h80000000) : sum33[31:0];
        default:        r0 = (eu.alu == AL_CLZ) ? res_o : sum33[31:0];
      endcase
      w0 = (eu.wsrc == WS_LINK) ? eu.link : (eu.wsrc == WS_TWB) ? temp_wb : r0;
      w1 = (eu.wsrc == WS_LINK || eu.wsrc == WS_TWB || !res_s) ? wd_o : sum33[31:0];
      if (res !== r0 || w1 !== w0) $error("arm9_core: result %h / %h, the one mux's %h / %h (pc %h)", res, w1, r0, w0, eu.pc);
      // m_res is res except a saturating op's, which nothing reads from m_res
      if (eu.alu != AL_QADD && eu.alu != AL_QSUB && res_m !== res) $error("arm9_core: m_res input %h, res %h (pc %h)", res_m, res, eu.pc);
      if ((eu.alu == AL_QADD || eu.alu == AL_QSUB) && (eu.rdr == RD_ALU || eu.msr)) $error("arm9_core: a saturating op redirects or writes a PSR (pc %h)", eu.pc);
    end
`endif
  // N and Z of a logical op from the logic result alone, not through res (whose mux also carries the adder: #1946
  // block fit, adder -> res -> zero test -> CPSR Z, -1.34 ns)
  assign e_nzcv   = {alu_arith ? sum33[31] : lres[31], alu_arith ? z_add : (lres == 32'h0),
                     alu_arith ? add_c : shc_res, alu_arith ? add_v : cpsr[28]};
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && eu.valid && eu.flags == FL_DP && (e_nzcv[3] != res[31] || e_nzcv[2] != (res == 32'h0)))
      $error("arm9_core: NZ %b%b, the result's %b%b (pc %h)", e_nzcv[3], e_nzcv[2], res[31], res == 32'h0, eu.pc);
`endif
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && eu.valid && eu.flags == FL_DP && alu_arith && z_add != (sum33[31:0] == 32'h0))
      $error("arm9_core: carry-free Z %b, the sum's %b (pc %h)", z_add, sum33[31:0] == 32'h0, eu.pc);
`endif
  logic [31:0] psr_mask;
  assign psr_mask = 32'hF80000FF;
  logic [31:0] e_cpsr_n;               // CPSR after E's uop
  always_comb begin
    logic [31:0] c;
    c = cpsr;
    if (e_exec) begin
      // (NZCV of FL_DP are not here: they go in through e_nzcv at the CPSR's last mux, so no path from the adder
      // runs through this logic: #1951/#1952 block fits, adder -> e_cpsr_n -> five muxes -> cpsr_s, -1.0..-1.2 ns)
      if ((eu.alu == AL_QADD || eu.alu == AL_QSUB) && (add_v || qsat_d)) c[27] = 1'b1;
      if (eu.exc) c = {cpsr[31:8], 1'b1, cpsr[6] | eu.exc_f, 1'b0, eu.exc_mode};
      else if (eu.restore && !eu.wpc && spsr_ok) c = spsr_r & psr_mask;
      if (e_rdr || eu.clr_thumb) c[5] = e_newt;   // (a lone BLX suffix redirects from M: its T is cleared here)
    end
    e_cpsr_n = c;
  end

  // E redirects: known targets (branches, exception vectors, flushes) and BX-like (operand B)
  always_comb begin
    logic t;
    e_rdr = 1'b0;
    e_tgt = eu.link;
    t = cpsr[5];
    // the target is chosen without the condition (it only reaches r_tgt, read under flush): the flags enter at
    // e_rdr alone (#2842 5asR: cpsr_s -> condition -> e_exec inside the target case -> r_tgt -> i_addr -> ITCM
    // address, -0.750 ns)
    case (eu.rdr)
      RD_IMM:  e_tgt = eu.imm;
      RD_ALU:  if (eu.rdx) e_tgt = e_b;
      default: ;
    endcase
    if (e_exec)                           // (while M stalls this repeats harmlessly: D cannot issue meanwhile)
      case (eu.rdr)
        RD_IMM, RD_LINK: e_rdr = 1'b1;
        RD_ALU:  e_rdr = eu.rdx;
        default: ;
      endcase
    if (eu.exc) t = 1'b0;
    if (eu.set_thumb) t = 1'b1;
    if (eu.clr_thumb) t = 1'b0;
    if (eu.rdx && eu.pct == PT_DATA0) t = e_b[0];
    if (eu.restore && !eu.wpc && spsr_ok) t = spsr_r[5];
    e_newt = t;
  end

  // SPSRs (per mode, MLAB): read for the current mode; written by E (exception entry, MSR) and W (abort)
  (* ramstyle = "MLAB, no_rw_check" *) logic [12:0] spsr_m [0:7];
  logic [7:0]  sp_vld;
  // synthesis translate_off
  initial for (int i = 0; i < 8; i++) spsr_m[i] = '1;
  // synthesis translate_on
  assign spsr_r = sp_vld[sidx] ? psr32(spsr_m[sidx]) : 32'h0;
  logic        sp_we;
  logic [2:0]  sp_wa;
  logic [12:0] sp_wd;

  // ---------------------------------------------------------------- multiplier
  // E (start): operands; M: four 17x17 partial products; W: their sum plus the
  // accumulator (32 or 64 bits), written by the lo uop; the hi uop takes the
  // registered high word a clock later
  logic [32:0] mq_a, mq_b;
  logic        mq_wy, mq_long;
  logic [31:0] mq_acc, mp_acc, mq_acch;
  logic        mp_wy, mp_long;
  logic signed [33:0] r_hh;
  logic signed [34:0] r_mid;
  logic        [31:0] r_ll;
  logic [63:0] m_prod, m_sum;
  logic [31:0] mh_q;
  logic        mzl_q;                 // the product's low word was zero (the hi uop's Z with mh_q == 0)
  wire         mz_q = mzl_q && mh_q == 32'h0;   // (RC6 #2099: the 64-bit sum -> its 64-bit zero test -> mz_q, -0.67 ns)
  logic [32:0] mul_a, mul_b;
  always_comb begin
    logic [15:0] ha, hb;
    ha = eu.mul_xh ? e_a[31:16] : e_a[15:0];
    hb = eu.mul_yh ? e_b[31:16] : e_b[15:0];
    case (eu.mul_kind)
      MK_XY:   begin mul_a = {{17{ha[15]}}, ha}; mul_b = {{17{hb[15]}}, hb}; end
      MK_WY:   begin mul_a = {e_a[31], e_a};     mul_b = {{17{hb[15]}}, hb}; end
      default: begin mul_a = {eu.mul_signed & e_a[31], e_a}; mul_b = {eu.mul_signed & e_b[31], e_b}; end
    endcase
  end
  always_ff @(posedge clk) begin
    logic signed [16:0] ah, bh;
    logic        [15:0] al, bl;
    logic signed [33:0] p_hl, p_lh;
    if (e_live && eu.mul_start) begin
      mq_a <= mul_a; mq_b <= mul_b;
      mq_wy <= eu.mul_kind == MK_WY;
      mq_long <= eu.mlong;
      mq_acc <= eu.macc ? e_c : 32'h0;
    end
    if (e_live && eu.mulhi) mq_acch <= eu.macc ? e_c : 32'h0;
    if (!stall) begin
      ah = mq_a[32:16]; al = mq_a[15:0]; bh = mq_b[32:16]; bl = mq_b[15:0];
      p_hl = ah * $signed({1'b0, bl});
      p_lh = $signed({1'b0, al}) * bh;
      r_hh  <= ah * bh;
      r_ll  <= al * bl;
      r_mid <= {p_hl[33], p_hl} + {p_lh[33], p_lh};
      mp_acc <= mq_acc; mp_wy <= mq_wy; mp_long <= mq_long;
    end
  end
  always_comb begin
    logic [63:0] p, ps, acc;
    p = {{30{r_hh[33]}}, r_hh} <<< 32;
    p = p + ({{29{r_mid[34]}}, r_mid} <<< 16) + {32'h0, r_ll};
    m_prod = p;
    ps  = mp_wy ? {{16{p[47]}}, p[63:16]} : p;   // SMULWy/SMLAWy: bits 47:16 (32 used)
    acc = {mp_long ? mq_acch : 32'h0, mp_acc};
    m_sum = ps + acc;
  end

  // ---------------------------------------------------------------- M
  logic        m_last, m_thumb, m_wsrc_mem, m_rdalu, m_restore, m_mulhi, m_msigned;
  logic [1:0]  m_pct, m_msize, m_alo;
  logic [31:0] m_pc;
  logic [12:0] m_cpsr;
  logic        m_go;                   // M's uop leaves to W this cycle
  logic        m_ok, m_abort;
  assign m_ok    = m_ans && d_ok;
  assign m_abort = m_v && m_exec && m_mem && m_ok && d_abort;
  assign stall   = m_v && m_exec && m_mem && !m_ok && !w_rdr;
  // (not gated by d_wait: a refused access sent again does nothing, and arm9_mem's d_wait -> this -> the request
  // mux -> its request registers was #1896/#1897's w_cpop/w_req/w_addr/tag path, -1.8 ns)
  assign m_rq    = m_v && m_exec && m_pend && !m_ans && !w_rdr;
  assign m_rdr   = m_v && m_exec && m_rdalu && !w_rdr;
  assign m_tgt   = m_res;
  assign m_newt  = (m_pct == PT_ARM) ? 1'b0 : cpsr[5];

  // MSR writes the CPSR (or SPSR) from M: it flushes everything behind it, so no younger uop is in E (#1880:
  // register file -> shifter -> result -> MSR's mode check -> CPSR, -3.34 ns)
  logic        m_msr, m_psr_spsr, m_msr_go;
  logic [3:0]  m_msr_mask;
  logic [31:0] m_msr_v;
  logic m_msr_ns;                        // m_msr_go without stall
  assign m_msr_ns = m_v && m_exec && m_msr && !w_rdr;
  assign m_msr_go = m_msr_ns && !stall;
  always_comb begin
    m_msr_v = cpsr;
    if (m_msr_mask[3]) m_msr_v[31:24] = m_res[31:24] & psr_mask[31:24];
    if (m_msr_mask[0] && cpsr[4:0] != M_USR && valid_mode(m_res[4:0]))
      m_msr_v[7:0] = {m_res[7:6], cpsr[5], m_res[4:0]};
  end

  // load alignment (into W's register): per output byte, the data byte E chose, a sign fill or zero; one mux level
  // after arm9_mem's answer (#1960-#1962 full chip: answer -> rotate -> byte/half/sign -> W, -0.4..-0.95 ns)
  logic [1:0]  m_lsrc [0:3];
  logic [1:0]  m_lmode [0:3];
  logic [1:0]  m_lsgn;
  logic [31:0] m_ldv, m_ldv_ref;
  // the load's per-byte selects (a byte, a sign or zero), decoded in M from m_alo, m_msize and m_msigned (registers,
  // early) instead of registered from E's address adder (RC11 #2506 1asR: operand B -> shifter -> address adder ->
  // maddr[1:0] + k -> m_lsrc -0.899 ns). m_alo is E's a (norot ? 0 : maddr[1:0]) for a byte or word and {a[1], 0} for
  // a halfword, whose selects use a[1] only
  always_comb begin
    logic [1:0] a;
    a = m_alo;
    for (int k = 0; k < 4; k++) begin m_lsrc[k] = 2'(a + k); m_lmode[k] = 2'd0; end
    m_lsgn = a;
    if (m_msize == MS_B) begin
      for (int k = 1; k < 4; k++) m_lmode[k] = m_msigned ? 2'd1 : 2'd2;
    end else if (m_msize == MS_H) begin
      m_lsrc[0] = {a[1], 1'b0}; m_lsrc[1] = {a[1], 1'b1};
`ifdef ARM9_LSRC_MUT
      m_lsgn = {a[1], 1'b0};                // (mutant: a halfword's sign from its low byte)
`else
      m_lsgn = {a[1], 1'b1};
`endif
      for (int k = 2; k < 4; k++) m_lmode[k] = m_msigned ? 2'd1 : 2'd2;
    end
  end
  // each source word is formatted, the TCM match selects last (rc15f #2844 5asR: w_ra -> rd_itcm -> the word's select
  // -> these lanes -> e_bw -0.784 ns); formatting d_rdata itself is the same function (checked below, m_ldv_ref)
  function automatic logic [31:0] lfmt(input logic [31:0] w, input logic [3:0][1:0] src, input logic [3:0][1:0] md,
                                       input logic [1:0] sgn);
    logic sg;
    logic [31:0] v;
    sg = w[{sgn, 3'd7}];
    for (int k = 0; k < 4; k++)
      v[k*8 +: 8] = md[k] == 2'd0 ? w[{src[k], 3'd0} +: 8] : md[k] == 2'd1 ? {8{sg}} : 8'h00;
    return v;
  endfunction
  logic [3:0][1:0] lsrc_p, lmode_p;
  always_comb for (int k = 0; k < 4; k++) begin lsrc_p[k] = m_lsrc[k]; lmode_p[k] = m_lmode[k]; end
  logic [31:0] lf_it, lf_dt, lf_rs;
  assign lf_it = lfmt(d_lw_it, lsrc_p, lmode_p, m_lsgn);
  assign lf_dt = lfmt(d_lw_dt, lsrc_p, lmode_p, m_lsgn);
  assign lf_rs = lfmt(d_lw_rs, lsrc_p, lmode_p, m_lsgn);
`ifdef ARM9_LFMT_MUT
  assign m_ldv = d_ls_it ? lf_dt : d_ls_dt ? lf_dt : lf_rs;   // (mutant: an ITCM load gets the DTCM word)
`else
  assign m_ldv = d_ls_it ? lf_it : d_ls_dt ? lf_dt : lf_rs;
`endif
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && m_v && m_exec && m_ld && m_ok && m_ldv !== m_ldv_ref)
      $error("arm9_core: load alignment %h, expected %h (alo %0d size %0d)", m_ldv, m_ldv_ref, m_alo, m_msize);
`endif
  always_comb begin
    logic [31:0] rt;
    logic [15:0] h;
    logic [7:0]  b;
    rt = (d_rdata >> {m_alo, 3'b000}) | (d_rdata << (6'd32 - {1'b0, m_alo, 3'b000}));
    if (m_alo == 2'd0) rt = d_rdata;
    h = m_alo[1] ? d_rdata[31:16] : d_rdata[15:0];
    b = rt[7:0];
    case (m_msize)
      MS_B: m_ldv_ref = m_msigned ? {{24{b[7]}}, b} : {24'h0, b};
      MS_H: m_ldv_ref = m_msigned ? {{16{h[15]}}, h} : {16'h0, h};
      default: m_ldv_ref = rt;
    endcase
  end

  // ---------------------------------------------------------------- W
  logic        w_last, w_wen, w_ld, w_mulw, w_mulhi, w_mflag, w_mq, w_wpc, w_restore, w_abort, w_thumb;
  logic [1:0]  w_pct;
  logic [31:0] w_pc;
  logic [12:0] w_cpsr;
  logic [12:0] cpsr_q;                 // the CPSR before E's last write (a data abort's SPSR)
  logic        w_go;
  assign w_go = w_v && !stall;
  logic [31:0] w_val;                  // the value W writes
  assign w_val = w_mulw ? (w_mulhi ? mh_q : m_sum[31:0]) : w_wd;
  assign w_fw  = w_v && w_exec && w_wen && !w_mulw;
  logic [2:0]  w_sidx;
  assign w_sidx = spsr_idx(cpsr[4:0]);
  assign w_rdr  = w_v && w_exec && (w_wpc || w_abort);
  assign w_tgt  = w_abort ? ((hivecs[0] ? 32'hFFFF0000 : 32'h0) + 32'h10) : w_wd;
  assign w_newt = w_abort ? 1'b0 : (w_pct == PT_DATA0) ? w_wd[0] :
                  (w_restore && w_sidx != 3'd7) ? spsr_r[5] : cpsr[5];

  // the CPSR W leaves (abort entry, LDM^ restore, T of a load into the PC, product flags), applied to the
  // architectural CPSR and, for the retire trace, to the CPSR the uop left E with
  logic        w_cw;
  function automatic logic [31:0] wpsr(input logic [31:0] base);
    logic [31:0] c;
    c = base;
    if (w_abort) c = {cpsr_q[12:8], 19'h0, 1'b1, cpsr_q[6], 1'b0, M_ABT};
    else if (w_wpc) begin
      if (w_restore && w_sidx != 3'd7) c = spsr_r & psr_mask;
      c[5] = w_newt;
    end
    if (w_mflag) begin
      c[31] = w_mulhi ? mh_q[31] : m_sum[31];
      c[30] = w_mulhi ? mz_q : (m_sum[31:0] == 32'h0);
    end
    if (w_mq && (m_sum[31] != mp_acc[31]) && (m_prod_s31 == mp_acc[31])) c[27] = 1'b1;
    return c;
  endfunction
  logic [31:0] w_cpsr_n, w_cpsr_t;
  assign w_cw     = w_v && w_exec && (w_abort || w_wpc || w_mflag || w_mq);
  assign w_cpsr_n = wpsr(cpsr);
  assign w_cpsr_t = w_exec ? wpsr(psr32(w_cpsr)) : psr32(w_cpsr);
  assign m_prod_s31 = mp_wy ? m_prod[47] : m_prod[31];

  assign rf_we = w_go && w_exec && (w_wen || w_abort);
  // fsel's W term: every fsel is registered under !stall, where this is rf_we; without stall, d_ok -> stall stays out
  // of D's operand selects (RC8p2 #2280: arm9_mem w_pg -> region -> d_ok -> stall -> rf_we -> fsel)
  assign rf_we_ns = w_v && w_exec && (w_wen || w_abort);
  assign rf_wa = w_abort ? 5'd28 : w_wa;
  assign rf_wd = w_abort ? (w_pc + 32'd8) : w_val;

  assign dbg_wen    = rf_we;
  assign dbg_wa     = {1'b0, rf_wa};
  assign dbg_wd     = rf_wd;
  assign dbg_retire = w_go && (w_last || (w_exec && w_abort));
  assign dbg_tid    = 1'b0;
  assign dbg_pc     = w_pc;
  assign dbg_cpsr   = w_cpsr_t;
  assign dbg_halt   = {1'b0, halted};

  // SPSR writes: W's abort entry, else E's exception entry or MSR
  always_comb begin
    sp_we = 1'b0; sp_wa = sidx; sp_wd = psr13(cpsr);
    if (w_go && w_exec && w_abort) begin
      sp_we = 1'b1; sp_wa = spsr_idx(M_ABT); sp_wd = cpsr_q;
    end else if (e_live && eu.exc) begin
      sp_we = 1'b1; sp_wa = spsr_idx(eu.exc_mode); sp_wd = psr13(cpsr);
    end else if (m_msr_go && m_psr_spsr && spsr_ok) begin
      sp_we = 1'b1; sp_wa = sidx;
      sp_wd = psr13(spsr_r);
      if (m_msr_mask[3]) sp_wd[12:8] = m_res[31:27];
      if (m_msr_mask[0]) sp_wd[7:0] = m_res[7:0];
    end
  end

  // ---------------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (sp_we) begin spsr_m[sp_wa] <= sp_wd; sp_vld[sp_wa] <= 1'b1; end
    if (rst) begin
      fpc <= reset_pc0; fth <= 1'b0;
      f1_v <= 1'b0; ep <= 1'b0; i_one <= 1'b0;
      q_n <= 2'd0; q_rp <= 1'b0;
      cpsr_s <= psr13({24'h0, 8'hD3});
      mcl <= mclass(5'h13);
      cpsr_q <= psr13({24'h0, 8'hD3});
      halted <= 1'b0; irq_r <= 1'b0; fiq_r <= 1'b0;
      ustep <= 2'd0; bl_v <= 1'b0;
      eu <= '0;
      e_condition <= '0;
      m_v <= 1'b0; m_pend <= 1'b0; m_ans <= 1'b0;
      w_v <= 1'b0;
      wq_en <= 1'b0;
      kill_q <= 1'b0;
      sp_vld <= 8'h0;
    end else begin
      irq_r <= irq[0];
      fiq_r <= fiq[0];
      if (wake[0] || fiq[0]) halted <= 1'b0;
      if (e_live && eu.wfi) halted <= 1'b1;

      // ---- F / F2
      f1_v  <= fetch_en;
      f1_pc <= f_pc;
      f1_th <= f_th;
      f1_ep <= flush ? !ep : ep;
      if (flush || f_rew) ep <= !ep;
      if (!flush && f_rew) begin fpc <= f1_pc; fth <= f1_th; end
      else begin
        fpc <= fetch_en ? f_pc + (f_th ? 32'd2 : 32'd4) : f_pc;
        fth <= f_th;
      end
      if (flush) i_one <= 1'b0;
      else if (f_rew) i_one <= 1'b1;
      else if (f_take) i_one <= 1'b0;
      // the queue: D takes the head when it issues an instruction's last uop
      begin
        logic pop;
        logic [1:0] rs;                     // the ring slot the answer goes into (1 or 2)
        pop = have && !stall && !inject && !mf;     // (not d_go: a flush clears the queue anyway)
        // (docs/arm9-fetch-queue.md, design B) the answer goes into the first free slot every clock, taken or not: an
        // answer not taken lies beyond the count and is overwritten. i_ok (f_take) reaches only q_n, no data register
        // (RC10 #2361: I-tag -> i_ok -> f_take -> the slot's enable -> q_w -0.588); the shift queue kept in
        // simulation (so_*) is checked against these entries every clock
        rs = (q_n == 2'd1) ? (q_rp ? 2'd2 : 2'd1) : (q_rp ? 2'd1 : 2'd2);
        if (q_n == 2'd1 || q_n == 2'd2) begin        // behind the head: entry q_n's ring slot
          q_w[rs]  <= a_ins; q_th[rs] <= f1_th; q_ab[rs] <= i_abort;
          q_hw[rs] <= a_hw; q_cls[rs] <= a_cls; q_kind[rs] <= f1_th ? i_rtop[6:4] : TK_ARM; q_pa[rs] <= f1_th && tx_pcalign;
        end
        if (pop && q_n >= 2'd2) begin               // the head takes entry 1 from the ring
          q_w[0] <= q_w[q_rp ? 2 : 1]; q_th[0] <= q_th[q_rp ? 2 : 1]; q_ab[0] <= q_ab[q_rp ? 2 : 1];
          q_hw[0] <= q_hw[q_rp ? 2 : 1]; q_cls[0] <= q_cls[q_rp ? 2 : 1]; q_kind[0] <= q_kind[q_rp ? 2 : 1];
          q_pa[0] <= q_pa[q_rp ? 2 : 1];
          q_rp <= !q_rp;
        end else if (q_n == 2'd0 || pop) begin        // an empty queue, or its last entry leaves: the answer is the head
          q_w[0]  <= a_ins; q_th[0] <= f1_th; q_ab[0] <= i_abort;
          q_hw[0] <= a_hw; q_cls[0] <= a_cls; q_kind[0] <= f1_th ? i_rtop[6:4] : TK_ARM; q_pa[0] <= f1_th && tx_pcalign;
        end
        if (pop) q_hpc <= q_hpc + (q_th[0] ? 32'd2 : 32'd4);
        if (q_n - {1'b0, pop} == 2'd0) q_hpc <= f1_pc;    // into an empty queue: the head's PC is the answer's
        q_n <= flush ? 2'd0 : q_n - {1'b0, pop} + {1'b0, f_take};
      end

      // ---- D
      if (flush) begin
        ustep <= 2'd0;
        bl_v <= 1'b0;
      end else if (d_go) begin
        if (!inject) begin
          ustep <= more ? nstep : 2'd0;
          rl_rem <= nrl;
          rl_r <= nrl_r;
          bl_v <= (c_kind == TK_BL1) && c_cls == C_TBR;
          if (c_kind == TK_BL1) bl_t <= c_tgt;
        end else
          bl_v <= 1'b0;
      end
      if (!stall) begin
        eu <= u;
        for (int c = 0; c < 15; c++) e_condition[c] <= u.cond == 4'(c);
        fs_a <= fsel(u.ra); fs_b <= fsel(u.rb); fs_c <= fsel(u.rc);
        oh_a <= onehot(fsel(u.ra), u.a_pc); oh_b <= onehot(fsel(u.rb), u.b_imm || u.b_pc); oh_c <= onehot(fsel(u.rc), u.c_pc);
`ifdef ARM9_EBW_MUT
        e_bw <= m_wd;
`else
        e_bw <= m_ld ? m_ldv : m_wd;          // (masked in E by oh_b[2])
`endif
        kb_imm <= u.b_imm;
`ifdef ARM9_KCONST_MUT
        kconst <= u.pcv;
`else
        kconst <= u.b_imm ? u.imm : u.pcv;
`endif
        e_swap <= u.alu == AL_RSB || u.alu == AL_RSC || u.alu == AL_QADD || u.alu == AL_QSUB;
        e_inv  <= u.alu == AL_SUB || u.alu == AL_CMP || u.alu == AL_SBC || u.alu == AL_RSB || u.alu == AL_RSC || u.alu == AL_QSUB;
        a_imm <= u.b_imm && u.sh_type == SH_LSL && !u.sh_reg && u.sh_amt == 8'd0;
        e_shc <= shctl(u.sh_type, u.sh_amt);
        e_shn <= u.sh_type == SH_LSL && !u.sh_reg && u.sh_amt == 8'd0;
        if (!d_go) eu.valid <= 1'b0;
      end
      if (m_rdr || w_rdr) eu.valid <= 1'b0;

      // ---- E
      if (e_live) begin
        case (eu.taddr)
          TA_NEXT:  begin temp_base <= tb_n; temp_inc <= 1'b1; end
          TA_BLOCK: begin
            temp_base <= tb_n; temp_inc <= eu.blk_pu;
            temp_wb <= sum33[31:0];
          end
          TA_ADDR:  begin temp_base <= tb_n; temp_inc <= 1'b0; end
          default: ;
        endcase
        if (eu.st_save) temp_st <= e_c;
        if (eu.amt_save) begin temp_amt <= e_c[7:0]; t_shc <= shctl(eu.sh_type, e_c[7:0]); end
      end
      if (!stall) cpsr_q <= cpsr_s;
      kill_q <= stall && (e_dreq || e_creq) && !m_rq;

      // ---- E -> M
      if (!stall) begin
        m_v      <= eu.valid && !m_rdr && !w_rdr;
        m_exec   <= e_exec;
        m_last   <= eu.last;
        m_pc     <= eu.pc;
        m_thumb  <= eu.thumb;
        m_wen    <= eu.wen;
        m_wa     <= eu.wa;
        m_lw     <= eu.lw;
        m_wsrc_mem <= eu.wsrc == WS_MEM;
        m_ld     <= eu.mem == MO_LOAD || (eu.mem == MO_CP && !eu.msigned);
        m_ldbh   <= eu.ldbh;
        m_mem    <= eu.mem != MO_NONE;
        m_cp     <= eu.mem == MO_CP;
        m_mulw   <= eu.mulw;
        m_mulhi  <= eu.mulhi;
        m_mflag  <= eu.mflag;
        m_mq     <= eu.mq;
        m_wpc    <= eu.wpc;
        m_pct    <= eu.pct;
        m_restore <= eu.restore;
        m_msr    <= eu.msr;
        m_psr_spsr <= eu.psr_spsr;
        m_msr_mask <= eu.msr_mask;
        m_rdalu  <= eu.rdr == RD_ALU && !eu.rdx;
        m_msize  <= eu.msize;
        m_msigned <= eu.msigned;
        m_alo    <= eu.norot ? 2'b00 : (eu.msize == MS_H) ? {maddr[1], 1'b0} : maddr[1:0];
        m_res    <= res_m;
        m_wd     <= (eu.wsrc == WS_LINK || eu.wsrc == WS_TWB || !res_s) ? wd_o : sum33[31:0];
        m_fw_r   <= e_exec && eu.wen && eu.wsrc != WS_MEM && !eu.mulw;
        m_cpsr   <= psr13(e_aflags ? {e_nzcv, e_cpsr_n[27:0]} : e_cpsr_n);
        m_da <= maddr; m_dwd <= e_wdata; m_dwe <= eu.mem == MO_STORE; m_dbe <= e_be; m_dsz <= eu.msize;
        m_dpriv <= cpsr[4:0] != M_USR;
        m_cwe <= eu.msigned; m_cop <= eu.cp_op;
        m_ans  <= e_dreq || e_creq;
        m_pend <= 1'b0;
      end else begin
        // M waits: an answer that was refused leaves it pending; it is sent again (m_rq)
        if (m_ans && !d_ok) m_pend <= 1'b1;
        m_ans <= m_rq;
      end
      if (w_rdr) m_v <= 1'b0;
      // w_go, m_msr_go and e_live all need !stall: the writer is chosen without stall, which gates it last
      // (#2843 7asR: arm9_mem's hit -> d_ok -> stall -> the priority muxes -> cpsr_s, -0.722 ns)
`ifdef ARM9_CPSR_STALL_MUT
      if (1'b1) begin
`else
      if (!stall) begin
`endif
        if (w_cw && w_v)                    cpsr_s <= psr13(w_cpsr_n);
        else if (m_msr_ns && !m_psr_spsr)   cpsr_s <= psr13(m_msr_v);
        else if (e_exec)                    cpsr_s <= psr13(e_cpsr_n);
        if (w_cw && w_v)                    mcl <= mclass(w_cpsr_n[4:0]);
`ifndef ARM9_MCL_MUT
        else if (m_msr_ns && !m_psr_spsr)   mcl <= mclass(m_msr_v[4:0]);
`endif
        else if (e_exec)                    mcl <= mclass(e_cpsr_n[4:0]);
        // the ALU's flags take a select of their own at the end (#1905: shifter -> adder -> V -> the CPSR's case
        // and priority muxes, -1.16 ns); e_cpsr_n's flag bits are the same, this only shortens the path
        if (!(w_cw && w_v) && !m_msr_ns && e_afl_ns) cpsr_s[12:9] <= e_nzcv;
      end

      // ---- M -> W
      if (!stall) begin
        w_v      <= m_v && !w_rdr;
        w_exec   <= m_exec;
        w_last   <= m_last;
        w_pc     <= m_pc;
        w_thumb  <= m_thumb;
        w_wen    <= m_wen;
        w_wa     <= m_wa;
        w_ld     <= m_ld;
        w_mulw   <= m_mulw;
        w_mulhi  <= m_mulhi;
        w_mflag  <= m_mflag;
        w_mq     <= m_mq;
        w_wpc    <= m_wpc;
        w_pct    <= m_pct;
        w_restore <= m_restore;
        w_abort  <= m_abort;
        w_wd     <= m_ld ? m_ldv : m_wd;
        w_cpsr   <= (m_exec && m_msr && !m_psr_spsr) ? psr13(m_msr_v) : m_cpsr;
      end
      if (w_rdr) w_v <= 1'b0;
      // the product's high word for the hi uop, a clock behind
      if (w_go && w_mulw && !w_mulhi) begin
        mh_q <= m_sum[63:32];
        mzl_q <= m_sum[31:0] == 32'h0;
      end

      // ---- W
      if (!stall) begin
        wq_en <= rf_we;
        wq_a  <= rf_wa;
        wq_d  <= rf_wd;
      end
    end
  end
  assign m_fw = m_v && m_fw_r;

`ifndef SYNTHESIS
`ifndef ALTERA_RESERVED_QIS
  // simulation (+a9irq): E, M, W and the data port while the BIOS IRQ handler (0xFFFF0270-0x2A0) is in E or M
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("a9irq") &&
        ((eu.valid && eu.pc[31:12] == 20'hFFFF0 && eu.pc[11:0] >= 12'h270 && eu.pc[11:0] < 12'h2A0) ||
         (m_v && m_pc[31:12] == 20'hFFFF0 && m_pc[11:0] >= 12'h270 && m_pc[11:0] < 12'h2A0)))
      $display("a9irq %0t E[v%0d pc=%08x ex%0d a=%08x b=%08x c=%08x ma=%08x] M[v%0d pc=%08x ex%0d ld%0d ans%0d pend%0d wa=%0d] stall%0d rq%0d | req%0d cp%0d we%0d a=%08x kill%0d | ok%0d rd=%08x ldv=%08x wait%0d cpsr=%03x",
               $time, eu.valid, eu.pc, e_exec, e_a, e_b, e_c, maddr, m_v, m_pc, m_exec, m_ld, m_ans, m_pend, m_wa, stall, m_rq,
               d_req, cp_req, d_we, d_addr, d_kill, d_ok, d_rdata, m_ldv, d_wait[0], cpsr_s);
  // simulation (+vecst): on a store to DTCM-range word 0xFFF of main RAM's 0x02 page (White 2's IRQ vector), the last 48
  // E-stage instructions with their operands, oldest first
  logic [159:0] vs_ring [0:47];
  logic [5:0]   vs_p = 6'd0;
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("vecst")) begin
      if (eu.valid) begin
        vs_ring[vs_p] <= {eu.pc, e_a, e_b, e_c, maddr};
        vs_p <= vs_p == 6'd47 ? 6'd0 : vs_p + 6'd1;
      end
      if (d_req && d_we && d_addr[31:24] == 8'h02 && d_addr[13:2] == 12'hFFF) begin
        $display("vecst %0t store a=%08x wd=%08x M pc=%08x", $time, d_addr, d_wdata, m_pc);
        for (int i = 0; i < 48; i++) begin
          logic [159:0] r;
          r = vs_ring[(int'(vs_p) + i) % 48];
          $display("vecst   E pc=%08x a=%08x b=%08x c=%08x ma=%08x", r[159:128], r[127:96], r[95:64], r[63:32], r[31:0]);
        end
      end
    end
  // simulation (+wtrace=T0 +wtrace_n=N): from time T0 (ps) on, every register write and retirement with W's PC and the
  // CPSR (N lines)
  longint wt_t0; int wt_n = -1;
  initial if (!$value$plusargs("wtrace=%d", wt_t0)) wt_t0 = -1; else if (!$value$plusargs("wtrace_n=%d", wt_n)) wt_n = 20000;
  always_ff @(posedge clk)
    if (!rst && wt_t0 >= 0 && $time >= wt_t0 && wt_n > 0 && (rf_we || dbg_retire)) begin
      wt_n <= wt_n - 1;
      $display("wt %0t pc=%08x ret%0d we%0d r%0d=%08x cpsr=%03x", $time, w_pc, dbg_retire, rf_we, rf_wa, rf_wd, cpsr_s);
    end
  // simulation (+a9dbg): the data port and the stall, per clock
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("a9dbg"))
      $display("a9 %0t E[v%0d pc=%08x ex%0d] M[v%0d pc=%08x mem%0d ans%0d pend%0d] stall%0d rq%0d | req%0d we%0d a=%08x wd=%08x kill%0d | ok%0d ab%0d rd=%08x wait%0d",
               $time, eu.valid, eu.pc, e_exec, m_v, m_pc, m_mem, m_ans, m_pend, stall, m_rq, d_req, d_we, d_addr, d_wdata, d_kill,
               d_ok, d_abort, d_rdata, d_wait[0]);
`endif
`ifndef ALTERA_RESERVED_QIS
  // simulation: the queue's entries are consecutive (a push into a non-empty queue lands at the head's PC plus the
  // entries before it)
  always_ff @(posedge clk)
    if (!rst && f_take && !flush && q_n != 2'd0 &&
        f1_pc != q_hpc + {29'h0, q_n} * (q_th[0] ? 32'd2 : 32'd4))
      $error("arm9_core: queue push at %h, the queue expects %h", f1_pc, q_hpc + {29'h0, q_n} * (q_th[0] ? 32'd2 : 32'd4));
  always_ff @(posedge clk)
    if (!rst && f_take && !flush && q_n == 2'd3) $error("arm9_core: an answer taken into a full queue");
  // simulation: the shift queue as it was (writes only on f_take), stepped beside it; every clock the valid entries,
  // the count and the head's PC are the same
  logic [1:0]  so_n;
  logic [31:0] so_hpc;
  logic [31:0] so_w [0:2]; logic so_th [0:2]; logic so_ab [0:2]; logic [15:0] so_hw [0:2];
  logic [4:0]  so_cls [0:2]; logic [2:0] so_kind [0:2]; logic so_pa [0:2];
  always_ff @(posedge clk) begin
    if (rst) so_n <= 2'd0;
    else begin
      logic pop;
      logic [1:0] n;
      pop = have && !stall && !inject && !mf;
      n = so_n;
      if (pop) begin
        for (int e = 0; e < 2; e++) begin
          so_w[e] <= so_w[e + 1]; so_th[e] <= so_th[e + 1]; so_ab[e] <= so_ab[e + 1];
          so_hw[e] <= so_hw[e + 1]; so_cls[e] <= so_cls[e + 1]; so_kind[e] <= so_kind[e + 1]; so_pa[e] <= so_pa[e + 1];
        end
        n = n - 2'd1;
        so_hpc <= so_hpc + (so_th[0] ? 32'd2 : 32'd4);
      end
      if (f_take && !flush) begin
        if (n == 2'd0) so_hpc <= f1_pc;
        so_w[n]  <= a_ins; so_th[n] <= f1_th; so_ab[n] <= i_abort;
        so_hw[n] <= a_hw; so_cls[n] <= a_cls; so_kind[n] <= f1_th ? tx_kind : TK_ARM; so_pa[n] <= f1_th && tx_pcalign;
        n = n + 2'd1;
      end
      so_n <= flush ? 2'd0 : n;
    end
  end
  always_ff @(posedge clk)
    if (!rst) begin
      if (so_n !== q_n) $error("arm9_core: queue count %0d, the shift queue's %0d", q_n, so_n);
      if (so_n != 2'd0 && so_hpc !== q_hpc) $error("arm9_core: queue head pc %h, the shift queue's %h", q_hpc, so_hpc);
      for (int i = 0; i < 3; i++) if (i < int'(so_n)) begin
        int k;
        k = i == 0 ? 0 : (i == 1) == !q_rp ? 1 : 2;     // entry i's slot: 0 the head, 1 and 2 the ring from q_rp
        if (q_w[k] !== so_w[i] || q_th[k] !== so_th[i] || q_ab[k] !== so_ab[i] || q_hw[k] !== so_hw[i] ||
            q_cls[k] !== so_cls[i] || q_kind[k] !== so_kind[i] || q_pa[k] !== so_pa[i])
          $error("arm9_core: queue entry %0d %h, the shift queue's %h", i, q_w[k], so_w[i]);
      end
    end
  // simulation: the field reads cover the decode's (a miss would be a missed hazard); +a9hz counts the holds the
  // field check adds over the decode's (time against the DS)
  longint hz_extra = 0, hz_all = 0;
  always_ff @(posedge clk)
    if (!rst && h_v && !inject) begin
      for (int r = 0; r < 15; r++)
        if (rd_checked(u, 4'(r)) && !rd_f(4'(r)))
          $error("arm9_core: field reads miss r%0d (pc %h, cls %0d, step %0d)", r, h_pc, c_cls, ustep);
      if (e_ldx) begin hz_all <= hz_all + 1; if (rd_f(eu.lw) && !rd_checked(u, eu.lw)) hz_extra <= hz_extra + 1; end
    end
  final if ($test$plusargs("a9hz")) $display("a9hz: load-use checks %0d, holds the field check adds %0d", hz_all, hz_extra);
`endif
  // simulation: a uop never sits in E while M's load result it reads is still in M (the interlock)
  always_ff @(posedge clk)
    if (!rst && eu.valid && m_v && m_exec && m_ld && m_wen && rd_checked(eu, m_lw) && !stall)
      $error("arm9_core: E reads r%0d while its load is in M", m_wa);
`endif
endmodule
