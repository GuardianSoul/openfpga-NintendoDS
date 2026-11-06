// Two-context ARM pipeline: ARM9 (ARMv5TE) and ARM7 (ARMv4T) share one
// integer pipeline and alternate cycles (docs/arm-pipeline.md).
//
//   F    fetch request
//   F2   instruction memory answers (on-chip RAM, tag check); a "not ready"
//        answer rewinds the fetch
//   PD   predecode: Thumb expansion, class, branch target; unconditional and
//        backward conditional branches redirect fetch here
//   D    uop sequencing, register-bank mapping, register-file read addresses,
//        load-use interlock, interrupt and prefetch-abort injection
//   E1   register-file data, shifter controls, bypass selects
//   E2   bypass of the context's two previous uops, barrel shifter,
//        multiplier operands
//   E3   condition check, ALU, memory request, CPSR control writes,
//        redirects for branches to known targets, exceptions and flushes
//   WB   memory answer (data, ready, abort) registered, flags, redirects to
//        ALU results
//   WB2  load alignment, register write; redirects for loads into the PC,
//        replays (memory not ready) and data aborts
//
// Even stages (F, PD, E1, E3, WB2) work for context `te`, odd stages (F2, D,
// E2, WB) for the other, `to`; the two swap every cycle. A context's
// consecutive uops are therefore two cycles apart in every stage. Per-context
// state lives in rotating register pairs: slot 0 always belongs to `te` and
// slot 1 to `to`, so no state read needs a context mux (an even stage reads
// slot 0 and writes slot 1, an odd stage the reverse, because the roles swap
// at the clock edge).
//
// Replay: a memory that is not ready answers "not ready" in WB (or F2 for
// fetches). The answer is only registered there; in WB2 (PD for fetches) the
// uop and everything younger of that context is dropped, fetch restarts at
// its instruction and D resumes at the uop's step, so earlier uops of the
// instruction are not repeated. The other context runs on.
module arm_core import arm_pkg::*; #(
  parameter logic [1:0] V5       = 2'b01,   // context 0 = ARM9 (v5TE), 1 = ARM7 (v4T)
  parameter             RF_STYLE = "M10K",
  // 1: solo mode (docs/arm-pipeline.md "A9_SOLO"): while the ARM7 is halted or
  // not running and has left the pipeline, both rotating slots carry the ARM9,
  // which then issues every cycle (interlocks where the barrel's spacing hid a
  // hazard)
  parameter bit         A9_SOLO  = 1'b0,
  parameter bit         SOLO_ONLY = 1'b0,    // the ARM7 is a separate core (arm7_ds): this one is always solo (needs A9_SOLO)
  parameter int         A9_OPT   = 0,        // ARM9 speed options (bit 0: exact load-use check)
  // 1: the CPUs run at clk_sys (67 MHz, the 3D build): structures that only
  // served 89-100 MHz take their smaller forms (same cycles; docs/arm-pipeline.md
  // "SLOW")
  parameter bit         SLOW     = 1'b0,
  parameter bit         ROT_DSP  = 1'b0   // SLOW's rotator in a DSP multiplier (#403); off: e2_sb -> e3_x fails in the chain build (#648 -1.163 ns)
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [1:0]  run,                  // context enables
  input  logic [31:0] reset_pc0,
  input  logic [31:0] reset_pc1,
  input  logic [1:0]  hivecs,               // exception vectors at 0xFFFF0000
  input  logic [1:0]  irq,
  input  logic [1:0]  fiq,
  // halt (pulse: the context stops issuing, like the ARM7's HALTCNT) and the
  // condition that ends a halt or a CP15 wait-for-interrupt (level)
  input  logic [1:0]  halt_req,
  input  logic [1:0]  wake,

  // Instruction port: request in F (word address), answer in F2
  output logic        i_req,
  output logic        i_tid,
  output logic        i_priv,               // not User mode
  output logic [31:0] i_addr,
  input  logic [31:0] i_rdata,
  input  logic        i_ok,                 // 0: not ready, fetch again
  input  logic        i_abort,              // prefetch abort (with i_ok)

  // Data and CP15 port: request in E3, answer in WB
  output logic        d_req,
  output logic        d_tid,
  output logic        d_priv,
  output logic        d_we,
  output logic [1:0]  d_size,
  output logic [3:0]  d_be,
  output logic [31:0] d_addr,
  output logic [31:0] d_wdata,
  input  logic [31:0] d_rdata,
  input  logic        d_ok,                 // 0: not ready, replay (store not done)
  input  logic        d_abort,              // data abort (with d_ok)
  input  logic [1:0]  d_wait,               // per context: hold fetch, a replay is pending
  output logic        d_kill,               // MEM1: the uop now in WB is squashed (a redirect out of WB2): memory must not act on it
  output logic        cp_req,               // MCR/MRC p15 (ARMv5 context)
  output logic        cp_we,
  output logic [15:0] cp_op,
  output logic [31:0] cp_wdata,           // MRC data comes back on d_rdata

  // Trace: register-file writes and retired instructions (WB2)
  output logic        dbg_wen,
  output logic [5:0]  dbg_wa,
  output logic [31:0] dbg_wd,
  output logic        dbg_retire,
  output logic        dbg_tid,
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_cpsr,
  output logic [1:0]  dbg_halt               // {ARM7, ARM9} halted (WFI / HALTCNT), for the diagnostics
);

  // ---------------------------------------------------------------- state
  logic        tid;                    // te: context in the even stages
  logic        te, to;
  assign te = tid;
  assign to = ~tid;
  // the CPU each slot belongs to (c0: te's, c1: to's); both the ARM9 in solo
  logic        solo_r;
  logic        solo;                   // both slots carry the ARM9
  assign solo = SOLO_ONLY || solo_r;   // SOLO_ONLY: the ARM7 is not in this core (arm7_ds): always solo, the park machinery is constant
  logic        c0, c1;
  assign c0 = !solo && te;
  assign c1 = !solo && to;
  // BURST (A9_OPT bit 9): the ARM7 is also parked while it is not halted, in windows: BR clk of barrel (ARM7 and
  // ARM9 alternate), then the ARM7 stops fetching (park_req), drains, and the ARM9 runs alone (solo) for BS clk or
  // until an ARM7 interrupt/wake; ARM7 average speed is the barrel's share of the time, bursts are the ARM9's
  localparam bit BURST = A9_SOLO && (A9_OPT & 512) != 0;
  localparam int BR = 128, BS = 256;
  logic [8:0]  r_cnt, s_cnt;
  logic        pk_burst;
  logic        park_req;
  logic        solo_e;                 // entry: the cycle after the ARM7 was found drained (the ARM9 is te)
  logic        solo_x;                 // leaving: no more fetches, the pipeline drains
  assign park_req = BURST && !solo && !solo_e && r_cnt >= 9'(BR) && run[1] && !irq[1] && !fiq[1];
  logic [31:0] pk_pc;                  // the parked ARM7: next fetch, Thumb, CPSR, halted
  logic        pk_thumb, pk_halt;
  logic [12:0] pk_cpsr;
  // solo instruction buffer: four entries (both contexts' MLAB words) in
  // order p = 0..3 at {p[1], p[0] ^ ib4_x}, head ib4_h, count ib4_n
  logic [1:0]  ib4_h;
  logic [2:0]  ib4_n;
  logic        ib4_x;
  function automatic logic [1:0] ib4a(input logic [1:0] q, input logic x);
    return {q[1], q[0] ^ x};
  endfunction

  logic [31:0] fetch_pc    [0:1];
  logic        fetch_thumb [0:1];
  // PSRs are stored as their 13 bits that exist (NZCVQ, control byte); the
  // 32-bit views below have the other bits zero
  logic [12:0] cpsr_s      [0:1];
  logic [31:0] cpsr        [0:1];
  function automatic logic [12:0] psr13(input logic [31:0] p);
    return {p[31:27], p[7:0]};
  endfunction
  function automatic logic [31:0] psr32(input logic [12:0] p);
    return {p[12:8], 19'h0, p[7:0]};
  endfunction
  always_comb
    for (int c = 0; c < 2; c++) cpsr[c] = psr32(cpsr_s[c]);

  // SPSRs: MLABs at {context, bank}, flags and control byte in separate
  // lanes (MSR writes either), each read twice (E3 and WB2, both te). The
  // one write port works for to: MSR in WB as before; an exception entry
  // (E3) and a data abort (WB2) are written a cycle later, when their
  // context has moved to the odd stages. Both redirect, so nothing reads
  // the SPSR in between. An entry reads 0 until written.
  (* ramstyle = "MLAB, no_rw_check" *) logic [4:0] spf_e [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] spc_e [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [4:0] spf_x [0:15];
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] spc_x [0:15];
  logic [15:0] sp_vld = 16'h0;
  // simulation: unwritten MLAB words as all ones (their power-up value is
  // not defined), so a read that missed the valid bit would show
  // synthesis translate_off
  initial for (int i = 0; i < 16; i++) begin
    spf_e[i] = '1; spc_e[i] = '1; spf_x[i] = '1; spc_x[i] = '1;
  end
  // synthesis translate_on
  logic        se_v, sa_v;               // exception entry / abort write pending
  logic [2:0]  se_b;
  logic [12:0] se_d, sa_d;
  logic        sp_wf, sp_wc;             // write flags / control lane
  logic [3:0]  sp_wa;
  logic [12:0] sp_wd;
  logic [31:0] spsr_e3, spsr_x2;         // the SPSR of the mode in E3 / WB2
  logic        halted      [0:1];      // WFI until an interrupt line rises
  logic        irq_r       [0:1];
  logic        rh          [0:1];      // a replay is pending: no IRQ/FIQ before it re-issues
  logic        fiq_r       [0:1];
  logic        dwait_r     [0:1];

  // Instruction buffer between PD and D, two predecoded instructions per
  // context: D works on entry 0 until it has issued the last uop, then entry
  // 1 moves up.
  typedef struct packed {
    logic [31:0] ins;
    logic [2:0]  kind;
    logic [4:0]  cls;
    logic [31:0] tgt;
    logic        pred;
    logic [1:0]  ctr;      // direction counter (conditional branches)
    logic        bwd;      // backward branch
    logic        pcalign;
    logic        thumb;
    logic        pabt;
    logic [31:0] pc;
  } ibe_t;
  // The two entries of each context live in an MLAB at {context, slot}:
  // entry 0 (the one D works on) is slot ib_h, entry 1 the other. Only PD
  // writes it (for te) and only D reads it (for to), so a read never meets
  // a write of the same context in one cycle.
  // SOLO_ONLY: the decode fields also have a head register (ib_hq, no MLAB read in front of D's hazard/uop
  // decode: ib4_h -> rl_rem, #1307 -1.39, #1308 -1.96 ns); their MLAB is read at the entry after the head.
  // tgt and pc stay MLAB reads of the head.
  typedef struct packed {
    logic [31:0] ins;
    logic [2:0]  kind;
    logic [4:0]  cls;
    logic        pred;
    logic [1:0]  ctr;
    logic        bwd;
    logic        pcalign;
    logic        thumb;
    logic        pabt;
  } ibh_t;
  (* ramstyle = "MLAB, no_rw_check" *) ibh_t ibh [0:3];
  (* ramstyle = "MLAB, no_rw_check" *) logic [63:0] ibc [0:3];   // {tgt, pc}
  ibh_t        ib_hq;
  logic        ib_h        [0:1];      // slot of entry 0
  logic        ib_v        [0:1];      // entry 0 valid
  logic        ib1_v       [0:1];      // entry 1 valid
  ibe_t        ib_d;                   // entry 0 of the context in D

  // D sequencer and load-use interlock, per context
  logic [1:0]  ustep       [0:1];
  logic [15:0] rl_rem      [0:1];
  logic [3:0]  rl_r        [0:1];      // lowest register left in rl_rem
  logic        ll_v        [0:1];      // previous uop loads into register ll_r
  logic [3:0]  ll_r        [0:1];

  // Temporaries, per context
  logic [31:0] temp_addr   [0:1];      // written in WB, read in E3
  logic [31:0] temp_wb     [0:1];      // written in WB, read in E3
  logic        temp_c      [0:1];      // written in WB, read in E3
  logic        temp_lz     [0:1];      // WB
  logic [31:0] temp_st     [0:1];      // E3 (SWP store data)
  logic [7:0]  temp_amt    [0:1];      // written in E2, read in E1
  // Thumb BL: the prefix's LR value, kept in PD while the next instruction
  // through PD is its suffix (cleared by anything else and by any redirect)
  logic        bl_v        [0:1];
  logic [31:0] bl_t        [0:1];

  localparam logic [2:0] TK_ARM = 3'd0, TK_B = 3'd1, TK_BL1 = 3'd2, TK_BL2 = 3'd3,
                         TK_BLX2 = 3'd4, TK_UND = 3'd5;

  localparam logic [4:0] C_DP = 5'd0, C_MRS = 5'd1, C_MSR = 5'd2, C_MUL = 5'd3, C_MULL = 5'd4,
                         C_SWP = 5'd5, C_HW = 5'd6, C_BX = 5'd7, C_BLXR = 5'd8, C_CLZ = 5'd9,
                         C_QOP = 5'd10, C_SMUL = 5'd11, C_BKPT = 5'd12, C_SDT = 5'd13,
                         C_BLK = 5'd14, C_B = 5'd15, C_BLXI = 5'd16, C_SWI = 5'd17, C_CP = 5'd18,
                         C_UND = 5'd19, C_NOP = 5'd20, C_TBR = 5'd21;

  // ARM instruction class
  function automatic logic [4:0] arm_class(input logic [31:0] ins, input logic v5c);
    logic [4:0] cls;
    cls = C_UND;
    if (ins[31:28] == 4'hF) begin
      if (!v5c)                                  cls = C_NOP;   // ARMv4: "never"
      else if (ins[27:25] == 3'b101)             cls = C_BLXI;
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
            end else if (!ins[20] && ins[6] && !v5c) cls = C_UND;   // LDRD/STRD
            else if (!ins[20] && ins[6] && ins[12])  cls = C_UND;
            else                                     cls = C_HW;
          end else if (ins[24:23] == 2'b10 && !ins[20]) begin
            if (ins[7:4] == 4'b0000)                                    cls = ins[21] ? C_MSR : C_MRS;
            else if (ins[7:4] == 4'b0001 && ins[22:21] == 2'b01)        cls = C_BX;
            else if (ins[7:4] == 4'b0001 && ins[22:21] == 2'b11 && v5c) cls = C_CLZ;
            else if (ins[7:4] == 4'b0011 && ins[22:21] == 2'b01 && v5c) cls = C_BLXR;
            else if (ins[7:4] == 4'b0101 && v5c)                        cls = C_QOP;
            else if (ins[7:4] == 4'b0111 && ins[22:21] == 2'b01 && v5c) cls = C_BKPT;
            else if (ins[7] && !ins[4] && v5c)                          cls = C_SMUL;
            else                                                        cls = C_UND;
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
          if (ins[24])                                  cls = C_SWI;
          else if (ins[4] && v5c && ins[11:8] == 4'hF)  cls = C_CP;
          else                                          cls = C_UND;
        end
      endcase
    end
    return cls;
  endfunction

  // Thumb instruction class, straight from the halfword (same answer as
  // arm_class on the expansion, without waiting for it)
  function automatic logic [4:0] thumb_class(input logic [15:0] hw, input logic v5c);
    logic [4:0] cls;
    cls = C_DP;
    case (hw[15:13])
      3'b000, 3'b001: cls = C_DP;
      3'b010: begin
        if (hw[12:10] == 3'b000)      cls = (hw[9:6] == 4'hD) ? C_MUL : C_DP;
        else if (hw[12:10] == 3'b001) cls = (hw[9:8] != 2'b11) ? C_DP : ((hw[7] && v5c) ? C_BLXR : C_BX);
        else if (hw[12:11] == 2'b01)  cls = C_SDT;
        else                          cls = hw[9] ? C_HW : C_SDT;
      end
      3'b011: cls = C_SDT;
      3'b100: cls = hw[12] ? C_SDT : C_HW;
      3'b101: begin
        if (!hw[12])                           cls = C_DP;
        else if (hw[11:8] == 4'b0000)          cls = C_DP;
        else if (hw[10:9] == 2'b10)            cls = C_BLK;
        else if (hw[11:8] == 4'b1110 && v5c)   cls = C_BKPT;
        else                                   cls = C_UND;
      end
      3'b110: begin
        if (!hw[12])                 cls = C_BLK;
        else if (hw[11:8] == 4'hF)   cls = C_SWI;
        else if (hw[11:8] == 4'hE)   cls = C_UND;
        else                         cls = C_TBR;
      end
      default: begin
        if (hw[12:11] == 2'b01) cls = (v5c && !hw[0]) ? C_TBR : C_UND;
        else                    cls = C_TBR;
      end
    endcase
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

  // Pipeline registers
  uop_t        e1;                     // D  -> E1
  uop_t        e2;                     // E1 -> E2
  uop_t        e3;                     // E2 -> E3

  logic        e3_exec;                // E3: uop alive and condition passed

  // Redirects and kills (computed further down)
  logic        e3_rdr;                 // E3 redirect (te)
  logic [31:0] e3_tgt;
  logic        e3_newt;
  logic        x2_rdr;                 // WB2 redirect (te): load into the PC, replay, abort
  logic [31:0] x2_tgt;
  logic        x2_newt;
  logic        wb_kill;                // WB redirect to an ALU result (to)
  logic [31:0] wb_tgt;
  logic        wb_newt;
  logic        kill_e;                 // even stages of te are being flushed
  logic        pd_rew;                 // PD: the fetch was not answered, fetch again
  assign kill_e = e3_rdr || x2_rdr;

  // ---------------------------------------------------------------- F (te)
  logic        f2_v;                   // F -> F2
  logic [31:0] f2_pc;
  logic        f2_thumb;
  logic        p_v;                    // F2 -> PD
  logic [31:0] p_pc, p_word;
  logic        p_thumb, p_pabt, p_ok;
  logic        fetch_en;

  // At most two instructions per context in the buffer and in flight: the
  // fetch now in PD lands this cycle, a fetch issued now lands two later.
  // (solo: four buffer entries, the fetches in F2 and PD count too)
  // SOLO_ONLY, after a refused fetch: one fetch at a time until PD takes one. Otherwise a refused fetch's rewind repeats
  // with a 3-clock period and an uncached read that takes a multiple of 3 clocks always starts for a fetch that gets
  // squashed: the fetch word buffer never holds the head and the ARM9 livelocks (import stub, ARM7 polling in its ROM).
  logic        i_one;
  assign fetch_en = run[c0] && !halted[0] && !(i_one && (f2_v || p_v)) && (!dwait_r[0] || (A9_OPT & 2) != 0) && !(BURST && park_req && c0 && !rh[0]) &&
                    (solo ? !solo_x && ({1'b0, ib4_n} + {3'd0, p_v} + {3'd0, f2_v}) <= 4'd3
                          : (({1'b0, ib_v[0]} + {1'b0, ib1_v[0]} + {1'b0, p_v}) <= 2'd1));
  assign i_req    = fetch_en;
  assign i_tid    = c0;
  assign i_priv   = (cpsr[0][4:0] != M_USR);
  assign i_addr   = {fetch_pc[0][31:2], 2'b00};

  // Branch direction predictor: 2-bit counters indexed by context and
  // pc[8:1], read with the fetch, used in PD, written in WB when a
  // conditional branch resolves. Stored XOR the static rule (backward
  // taken), so a counter never written predicts as before.
  (* ramstyle = "M10K" *) logic [1:0] bp_ram [0:511];
  logic [1:0]  bp_q, p_ctr;
  logic        bp_we;
  logic [8:0]  bp_wa;
  logic [1:0]  bp_wd;
  // synthesis translate_off
  initial for (int i = 0; i < 512; i++) bp_ram[i] = 2'b00;
  // synthesis translate_on
  always_ff @(posedge clk) begin
    bp_q <= bp_ram[{c0, fetch_pc[0][8:1]}];
    if (bp_we) bp_ram[bp_wa] <= bp_wd;
  end

  // ---------------------------------------------------------------- F2 (to)
  // the answer is registered into PD; a fetch not answered is redone there

  // ---------------------------------------------------------------- PD (te)
  logic [15:0] f_hw;
  logic [31:0] tx_arm, tx_boff;
  logic [2:0]  tx_kind;
  logic        tx_pcalign;

  assign f_hw = p_pc[1] ? p_word[31:16] : p_word[15:0];

  arm_thumb u_thumb (
    .hw(f_hw), .v5(V5[c0]),
    .arm(tx_arm), .kind(tx_kind), .boff(tx_boff), .pcalign(tx_pcalign)
  );

  logic [31:0] pd_ins, pd_tgt, pd_off;
  logic [2:0]  pd_kind;
  logic [4:0]  pd_cls;
  logic        pd_go, pd_br, pd_pred, pd_blxi, pd_newt;
  always_ff @(posedge clk)
    if (rst) i_one <= 1'b0;
    else if (pd_rew) i_one <= SOLO_ONLY;
    else if (pd_go) i_one <= 1'b0;
  logic        pd_bl1, pd_bl2;         // Thumb BL prefix / suffix (BL or BLX) seen in PD
  logic [1:0]  pd_ctr;
  ibe_t        pd_e;

  // Thumb branch decode for one halfword, from the raw bits: is a B (cond or
  // not), is unconditional, and the offset (B, or the BL prefix's <<12 value)
  function automatic logic [33:0] tbr(input logic [15:0] hw);
    logic isb, unc;
    logic [31:0] off;
    unc = (hw[15:11] == 5'b11100);
    isb = unc || (hw[15:12] == 4'b1101 && hw[11:9] != 3'b111);
    if (unc)                           off = {{20{hw[10]}}, hw[10:0], 1'b0};
    else if (hw[15:11] == 5'b11110)    off = {{9{hw[10]}}, hw[10:0], 12'h000};
    else                               off = {{23{hw[7]}}, hw[7:0], 1'b0};
    return {isb, unc, off};
  endfunction

  always_comb begin
    logic is_br, uncond;
    logic [33:0] tb_lo, tb_hi, tb;
    logic        a_isb, a_unc;
    pd_ins  = p_thumb ? tx_arm : p_word;
    pd_kind = p_thumb ? tx_kind : TK_ARM;
    pd_cls  = p_thumb ? thumb_class(f_hw, V5[c0]) : arm_class(p_word, V5[c0]);
    // BLX(imm) from the raw bits, not from the class decode (shorter path)
    pd_blxi = !p_thumb && V5[c0] && (p_word[31:25] == 7'b1111101);
    // B/BL/BLX(imm) and Thumb B redirect here when unconditional, or when
    // conditional and backward (predicted taken); E3 corrects mispredictions.
    // Decoded from the raw word, both halfwords in parallel, so the
    // halfword select is the last step before the redirect.
    tb_lo = tbr(p_word[15:0]);
    tb_hi = tbr(p_word[31:16]);
    tb    = p_pc[1] ? tb_hi : tb_lo;
    a_isb = (p_word[27:25] == 3'b101) && (p_word[31:28] != 4'hF || V5[c0]);
    a_unc = (p_word[31:28] == 4'hE) || (p_word[31:28] == 4'hF);
    if (p_thumb) pd_off = tb[31:0];
    else         pd_off = {{6{p_word[23]}}, p_word[23:0], pd_blxi & p_word[24], 1'b0};
    // Thumb BL pair: the suffix right after its prefix branches here, to the
    // prefix's LR value plus its own offset (BLX: word-aligned, to ARM)
    pd_bl1 = p_thumb && f_hw[15:11] == 5'b11110;
    pd_bl2 = p_thumb && bl_v[0] &&
             (f_hw[15:11] == 5'b11111 || (V5[c0] && f_hw[15:11] == 5'b11101 && !f_hw[0]));
    if (pd_bl2) pd_tgt = (bl_t[0] + {20'h0, f_hw[10:0], 1'b0}) & {30'h3FFFFFFF, f_hw[12], 1'b1};
    else        pd_tgt = p_pc + (p_thumb ? 32'd4 : 32'd8) + pd_off;
    pd_newt = pd_bl2 ? f_hw[12] : (p_thumb | pd_blxi);
    is_br  = p_thumb ? tb[33] : a_isb;
    uncond = p_thumb ? tb[32] : a_unc;
    pd_ctr = p_ctr ^ {pd_off[31], !pd_off[31]};
    pd_pred = (is_br && !uncond && pd_ctr[1]) || pd_bl2;
    pd_rew = p_v && !p_ok && !kill_e && !(solo && wb_kill);
    pd_go  = p_v && p_ok && !kill_e && !(solo && wb_kill);
    pd_br  = pd_go && !p_pabt && ((is_br && (uncond || pd_pred)) || pd_bl2);
    pd_e.ins = pd_ins;
    pd_e.kind = pd_kind;
    pd_e.cls = pd_cls;
    pd_e.tgt = pd_tgt;
    pd_e.pred = pd_pred;
    pd_e.ctr = pd_ctr;
    pd_e.bwd = pd_off[31];
    pd_e.pcalign = p_thumb && tx_pcalign;
    pd_e.thumb = p_thumb;
    pd_e.pabt = p_pabt;
    pd_e.pc = p_pc;
  end

  ibh_t pd_h;
  always_comb begin
    pd_h.ins = pd_e.ins; pd_h.kind = pd_e.kind; pd_h.cls = pd_e.cls; pd_h.pred = pd_e.pred; pd_h.ctr = pd_e.ctr;
    pd_h.bwd = pd_e.bwd; pd_h.pcalign = pd_e.pcalign; pd_h.thumb = pd_e.thumb; pd_h.pabt = pd_e.pabt;
  end
  // PD's entry: slot ib_h if entry 0 is free, else the other one
  always_ff @(posedge clk)
    if (pd_go) begin
      ibh[solo ? ib4a(ib4_h + ib4_n[1:0], ib4_x) : {c0, ib_h[0] ^ ib_v[0]}] <= pd_h;
      ibc[solo ? ib4a(ib4_h + ib4_n[1:0], ib4_x) : {c0, ib_h[0] ^ ib_v[0]}] <= {pd_e.tgt, pd_e.pc};
    end

  // ---------------------------------------------------------------- D (to)
  logic        have, fresh, hazard, inject, take_fiq, take_irq;
  logic [31:0] c_ins, c_tgt, c_pc;
  logic [2:0]  c_kind;
  logic [4:0]  c_cls;
  logic        c_pcalign, c_thumb, c_pred, c_pabt;
  logic [1:0]  c_step;
  logic [15:0] c_rl;
  logic        v5c;
  logic [4:0]  mode1;

  wire [1:0] ib_ra  = solo ? ib4a(ib4_h, ib4_x) : {c1, ib_h[1]};
  wire [1:0] ibh_ra = SOLO_ONLY ? ib4a(ib4_h + 2'd1, ib4_x) : ib_ra;
  ibh_t ibh_r;
  logic [63:0] ibc_r;
  assign ibh_r = ibh[ibh_ra];
  assign ibc_r = ibc[ib_ra];
  ibh_t ib_h_d;
  assign ib_h_d = SOLO_ONLY ? ib_hq : ibh_r;
  always_comb begin
    ib_d.ins = ib_h_d.ins; ib_d.kind = ib_h_d.kind; ib_d.cls = ib_h_d.cls; ib_d.pred = ib_h_d.pred; ib_d.ctr = ib_h_d.ctr;
    ib_d.bwd = ib_h_d.bwd; ib_d.pcalign = ib_h_d.pcalign; ib_d.thumb = ib_h_d.thumb; ib_d.pabt = ib_h_d.pabt;
    ib_d.tgt = ibc_r[63:32]; ib_d.pc = ibc_r[31:0];
  end
  assign c_ins     = ib_d.ins;
  assign c_kind    = ib_d.kind;
  assign c_cls     = ib_d.cls;
  assign c_tgt     = ib_d.tgt;
  assign c_pred    = ib_d.pred;
  assign c_pcalign = ib_d.pcalign;
  assign c_thumb   = ib_d.thumb;
  assign c_pabt    = ib_d.pabt;
  assign c_pc      = ib_d.pc;
  assign c_step    = ustep[1];
  assign c_rl      = rl_rem[1];
  assign v5c       = V5[c1];
  assign mode1     = cpsr[1][4:0];

  localparam bit MEM1  = A9_SOLO && SLOW && (A9_OPT & 524288) != 0;  // bit 19: memory accesses back to back (arm9_mem MEM1: the store's write merges into the next read)
  assign fresh = (c_step == 2'd0);
  // A uop that reads the register the previous uop loads waits one slot.
  // Conservative: any register field of the instruction (and the list of
  // a block transfer) counts as a read.
  // A9_OPT[0]: exact for the common classes: only the fields the instruction reads (a data-processing
  // immediate's imm4 and rotate, MOV/MVN's Rn, a load's Rd, a shift-by-immediate's Rs are not reads)
  function automatic logic true_read(input logic [4:0] cls, input logic [31:0] i, input logic [3:0] r);
    case (cls)
      C_DP:    return (i[19:16] == r && i[24:21] != 4'hD && i[24:21] != 4'hF) ||
                      (!i[25] && i[3:0] == r) || (!i[25] && i[4] && i[11:8] == r);
      C_SDT:   return i[19:16] == r || (!i[20] && i[15:12] == r) || (i[25] && i[3:0] == r);
      C_HW:    return i[19:16] == r || (!i[20] && i[15:12] == r) || (!i[22] && i[3:0] == r);
      C_BLK:   if (MEM1) return i[19:16] == r || (!i[20] && i[r]);        // (MEM1: an LDM's list is written, not read)
               else return i[19:16] == r || i[3:0] == r || i[11:8] == r || i[15:12] == r;
      default: return i[19:16] == r || i[3:0] == r || i[11:8] == r || i[15:12] == r;
    endcase
  endfunction
  logic hz_old, hz_new;
  assign hz_old = fresh && ll_v[1] &&
                  (c_ins[19:16] == ll_r[1] || c_ins[3:0] == ll_r[1] ||
                   c_ins[11:8] == ll_r[1] || c_ins[15:12] == ll_r[1] ||
                   (c_cls == C_BLK && c_ins[ll_r[1]]) ||
                   (c_kind != TK_ARM && ll_r[1] == 4'hE));
  assign hz_new = fresh && ll_v[1] &&
                  (true_read(c_cls, c_ins, ll_r[1]) ||
                   (c_cls == C_BLK && c_ins[ll_r[1]] && !(MEM1 && c_ins[20])) ||
                   (c_kind != TK_ARM && ll_r[1] == 4'hE));
  assign hazard = ((A9_OPT & 1) != 0 && c_kind == TK_ARM && (!to || (MEM1 && solo))) ? hz_new : hz_old;   // (the ARM9 only: the ARM7 keeps its timing; MEM1: also in the solo ARM9's odd slots)
  // solo: issue every cycle unless the barrel's two-cycle spacing hid a
  // hazard with the uops just issued (docs/arm-pipeline.md "A9_SOLO")
  logic        sbub;
  // A9_OPT[1]: the fetch goes on during a D fill (the replayed access is fetched early); a memory uop waits in D
  // until the fill is done, so it is not refused a second time
  logic        c_ismem, dw_hold;
  assign c_ismem = c_cls == C_SDT || c_cls == C_HW || c_cls == C_BLK || c_cls == C_SWP || c_cls == C_CP;
  assign dw_hold = (A9_OPT & 2) != 0 && dwait_r[1] && c_ismem;
  assign have = (solo ? ib4_n != 3'd0 : ib_v[1]) && !wb_kill && !hazard && !sbub && !(solo && kill_e) && !dw_hold;
  // irq/fiq come through the rotating slots (one cycle later, no context mux)
  // An instruction whose memory access was refused (replayed) re-issues before
  // any interrupt is taken: the memory may already have performed a read with
  // a side effect (I/O FIFOs, the card data port) and holds its word for the
  // replay; an exception in between would read it a second time.
  assign take_fiq = fresh && !c_pabt && fiq_r[1] && !cpsr[1][6] && !rh[1];
  assign take_irq = fresh && !c_pabt && irq_r[1] && !cpsr[1][7] && !rh[1];
  assign inject = have && (take_fiq || take_irq || c_pabt);

  uop_t        u, u0;
  logic        more;
  logic [1:0]  nstep;
  logic [15:0] nrl;
  logic        u_ld;                   // uop loads into register u_ldr
  logic [3:0]  u_ldr;
  wire ibh_load = ib4_n == 3'd0 || (have && !inject && !more);       // (ib4_n counted down as at the solo block)
  always_ff @(posedge clk)
    if (SOLO_ONLY && ibh_load) ib_hq <= (ib4_n >= 3'd2) ? ibh_r : pd_h;
  // synthesis translate_off
  always_ff @(posedge clk)
    if (SOLO_ONLY && !rst && ib4_n != 3'd0 && ib_hq !== ibh[ib_ra]) $error("arm_core: ib_hq differs from the head entry");
  // an injected exception holds through u.exc (the issue rules have no inject term)
  always_ff @(posedge clk)
    if (!rst && inject && !u.exc) $error("arm_core: inject without u.exc");
  // synthesis translate_on
  // next register of a block transfer, straight from the list (not from
  // the decode result): the list itself at the address uop, else rl_rem
  // without its lowest register
  logic [3:0]  nrl_r;
  // (an empty ARMv4 list transfers r15; a list down to r15 stays there,
  // which covers the base writeback that comes before a PC load)
  assign nrl_r = (c_step == 2'd0) ? ((c_ins[15:0] == 16'h0) ? 4'd15 : lowest16(c_ins[15:0])) :
                 (c_rl == 16'h8000) ? 4'd15 : lowest16(c_rl & ~(16'h1 << rl_r[1]));

  always_comb begin
    logic [31:0] ins;
    logic [3:0]  rn, rd, rs, rm;
    logic [31:0] pc8, link4;
    logic        is_load, is_store;
    logic [1:0]  lsize;
    logic        lsigned;
    logic [15:0] list, rl0;
    logic [4:0]  cnt, bmode;
    logic        ubank, base_in, fwb, lastx, firstx;
    logic [3:0]  r;
    logic [4:0]  emode;
    logic [31:0] evec;
    logic        exc_any;
    logic        pre, wb, acc;
    logic [4:0]  cls;
    uop_t        ud;

    pre = 1'b0; wb = 1'b0; acc = 1'b0;
    list = 16'h0; rl0 = 16'h0; cnt = 5'd0; bmode = M_USR;
    ubank = 1'b0; base_in = 1'b0; fwb = 1'b0; lastx = 1'b0; firstx = 1'b0; r = 4'd0;
    is_load = 1'b0; is_store = 1'b0; lsize = MS_W; lsigned = 1'b0;

    ins  = c_ins;
    cls  = c_cls;
    rn   = ins[19:16];
    rd   = ins[15:12];
    rs   = ins[11:8];
    rm   = ins[3:0];
    pc8  = c_pc + (c_thumb ? 32'd4 : 32'd8);
    link4 = c_pc + (c_thumb ? 32'd2 : 32'd4);

    u = '0;
    more = 1'b0;
    nstep = 2'd0;
    nrl = c_rl;
    u_ld = 1'b0;
    u_ldr = 4'd0;

    u.valid = have;
    u.cond  = ins[31:28];
    u.thumb = c_thumb;
    u.pc    = c_pc;
    u.pcv   = c_pcalign ? {pc8[31:2], 2'b00} : pc8;
    u.pcv_c = c_pc + 32'd12;
    u.ra    = phys_reg(rn, mode1);
    u.rb    = phys_reg(rm, mode1);
    u.rc    = phys_reg(rs, mode1);
    u.a_pc  = (rn == 4'hF);
    u.b_pc  = (rm == 4'hF);
    u.c_pc  = (rs == 4'hF);
    u.sh_type = SH_LSL;
    u.msize = MS_W;
    u.link  = link4;
    u.step  = c_step;
    u.rl    = c_rl;
    u.rr    = rl_r[1];

    exc_any = 1'b0;
    emode = M_UND;
    evec = 32'h4;

    ud = u;
    begin
      case (cls)
        C_DP: begin
          u.alu = {1'b0, ins[24:21]};
          if (ins[25]) begin
            u.b_imm = 1'b1;
            u.imm = {24'h0, ins[7:0]};
            u.sh_type = SH_ROR;
            u.sh_amt = {3'b000, ins[11:8], 1'b0};
          end else if (ins[4]) begin
            // register-specified shift: read Rs into temp_amt first
            u.sh_type = {1'b0, ins[6:5]};
            u.pcv = c_pc + 32'd12;
            if (c_step == 2'd0) begin
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
              // TST/TEQ/CMP/CMN: flags only. ARM7TDMI legacy "TSTP": with Rd=15
              // they copy the SPSR to the CPSR instead (gba-tests arm 234).
              if (rd == 4'hF && !v5c) begin
                u.restore = 1'b1;
                u.flags = FL_NONE;
                u.rdr = RD_LINK;
              end
            end else if (rd == 4'hF) begin
              u.rdr = RD_ALU;
              u.pct = PT_KEEP;
              if (ins[20]) begin
                u.restore = 1'b1;
                u.flags = FL_NONE;
              end
            end else begin
              u.wen = 1'b1;
              u.wa = phys_reg(rd, mode1);
            end
          end
        end

        C_MRS: begin
          u.alu = AL_PSR;
          u.psr_spsr = ins[22];
          u.wen = (rd != 4'hF);
          u.wa = phys_reg(rd, mode1);
        end

        C_MSR: begin
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

        C_MUL: begin
          if (MULW && !ins[20]) begin                         // MUL/MLA without S: one uop, written in WB2
            u.mul_start = 1'b1;
            u.mul_kind = MK_32;
            u.mulw = 1'b1; u.macc = ins[21];
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            u.rc = phys_reg(rd, mode1);  u.c_pc = 1'b0;     // the accumulator (Rn, bits 15:12)
            u.a_sel = OA_ZERO;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);                    // Rd is bits 19:16
          end else if (c_step == 2'd0) begin
            u.mul_start = 1'b1;
            u.mul_kind = MK_32;
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            more = 1'b1; nstep = 2'd1;
          end else begin
            u.ra = phys_reg(rd, mode1); u.a_pc = 1'b0;     // Rn (accumulate) is bits 15:12
            u.a_sel = ins[21] ? OA_REG : OA_ZERO;
            u.b_sel = OB_PLO;
            u.alu = AL_ADD;
            u.flags = ins[20] ? FL_NZ : FL_NONE;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);                    // Rd is bits 19:16
          end
        end

        C_MULL: begin
          if (MLONG && !ins[20] && !ins[21] && c_step == 2'd0) begin      // UMULL/SMULL: RdLo now, RdHi next uop (the product register holds)
            u.mul_start = 1'b1;
            u.mul_kind = MK_32;
            u.mul_signed = ins[22];
            u.mulw = 1'b1; u.macc = 1'b0;
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            u.a_sel = OA_ZERO;
            u.wen = (rd != 4'hF);
            u.wa = phys_reg(rd, mode1);                    // RdLo is bits 15:12
            more = 1'b1; nstep = 2'd1;
          end else if (MLONG && !ins[20] && !ins[21] && c_step == 2'd1) begin
            u.mulw = 1'b1; u.macc = 1'b0; u.mulhi = 1'b1;
            u.a_sel = OA_ZERO;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);                    // RdHi is bits 19:16
          end else if (c_step == 2'd0) begin
            u.mul_start = 1'b1;
            u.mul_kind = MK_32;
            u.mul_signed = ins[22];
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            more = 1'b1; nstep = 2'd1;
          end else if (c_step == 2'd1) begin
            u.ra = phys_reg(rd, mode1); u.a_pc = 1'b0;     // RdLo
            u.a_sel = ins[21] ? OA_REG : OA_ZERO;
            u.b_sel = OB_PLO;
            u.alu = AL_ADD;
            u.tc_save = 1'b1;
            u.wen = (rd != 4'hF);
            u.wa = phys_reg(rd, mode1);
            more = 1'b1; nstep = 2'd2;
          end else begin
            u.ra = phys_reg(rn, mode1); u.a_pc = 1'b0;     // RdHi
            u.a_sel = ins[21] ? OA_REG : OA_ZERO;
            u.b_sel = OB_PHI;
            u.alu = AL_ADC;
            u.cin_tc = 1'b1;
            u.flags = ins[20] ? FL_NZ : FL_NONE;
            u.z64 = 1'b1;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);
          end
        end

        C_SMUL: begin
          if (MULW && (ins[22:21] == 2'b11 || (ins[22:21] == 2'b01 && ins[5]))) begin   // SMULxy, SMULWy: one uop
            u.mul_start = 1'b1;
            u.mul_kind = (ins[22:21] == 2'b01) ? MK_WY : MK_XY;
            u.mul_signed = 1'b1;
            u.mul_xh = ins[5];
            u.mul_yh = ins[6];
            u.mulw = 1'b1; u.macc = 1'b0;
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            u.a_sel = OA_ZERO;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);
          end else if (c_step == 2'd0) begin
            u.mul_start = 1'b1;
            u.mul_kind = (ins[22:21] == 2'b01) ? MK_WY : MK_XY;
            u.mul_signed = 1'b1;
            u.mul_xh = ins[5];
            u.mul_yh = ins[6];
            u.ra = phys_reg(rm, mode1);  u.a_pc = 1'b0;
            u.rb = phys_reg(rs, mode1);  u.b_pc = 1'b0;
            more = 1'b1; nstep = 2'd1;
          end else if (ins[22:21] == 2'b10) begin         // SMLALxy
            if (c_step == 2'd1) begin
              u.ra = phys_reg(rd, mode1); u.a_pc = 1'b0;
              u.b_sel = OB_PLO;
              u.alu = AL_ADD;
              u.tc_save = 1'b1;
              u.wen = (rd != 4'hF);
              u.wa = phys_reg(rd, mode1);
              more = 1'b1; nstep = 2'd2;
            end else begin
              u.ra = phys_reg(rn, mode1); u.a_pc = 1'b0;
              u.b_sel = OB_PHI;
              u.alu = AL_ADC;
              u.cin_tc = 1'b1;
              u.wen = (rn != 4'hF);
              u.wa = phys_reg(rn, mode1);
            end
          end else begin
            // SMLAxy (00), SMLAWy (01, bit5=0), SMULWy (01, bit5=1), SMULxy (11)
            acc = (ins[22:21] == 2'b00) || (ins[22:21] == 2'b01 && !ins[5]);
            u.ra = phys_reg(rd, mode1); u.a_pc = 1'b0;
            u.a_sel = acc ? OA_REG : OA_ZERO;
            u.b_sel = OB_PLO;
            u.alu = AL_ADD;
            u.flags = acc ? FL_Q : FL_NONE;
            u.wen = (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);
          end
        end

        C_SWP: begin
          u.maddr = MA_A;
          u.msize = ins[22] ? MS_B : MS_W;
          // load into Rd and keep Rm aside, then store Rm from the temp: the
          // store then uses the old Rm even if Rd = Rm or the store is replayed
          if (c_step == 2'd0) begin
            u.mem = MO_LOAD;
            u.rc = phys_reg(rm, mode1);
            u.c_pc = (rm == 4'hF);
            u.st_save = 1'b1;
            u.wsrc = WS_MEM;
            u.wen = (rd != 4'hF);
            u.wa = phys_reg(rd, mode1);
            u_ld = (rd != 4'hF); u_ldr = rd;
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
            if (!wb || c_step != 2'd0) begin
              u.mem = MO_LOAD;
              u.msize = lsize;
              u.msigned = lsigned;
              u.maddr = wb ? MA_TADDR : MA_SUM;
              u.wsrc = WS_MEM;
              if (rd == 4'hF) begin
                u.wpc = 1'b1;
                u.pct = v5c ? PT_DATA0 : PT_KEEP;
              end else begin
                u.wen = 1'b1;
                u.wa = phys_reg(rd, mode1);
                u_ld = 1'b1; u_ldr = rd;
              end
            end else begin
              // base writeback first, so a load into the base register wins
              u.maddr = pre ? MA_SUM : MA_A;
              u.taddr = TA_ADDR;
              u.wen = (rn != 4'hF);
              u.wa = phys_reg(rn, mode1);
              more = 1'b1; nstep = 2'd1;
            end
          end else if (is_store) begin
            u.mem = MO_STORE;
            u.msize = lsize;
            u.maddr = pre ? MA_SUM : MA_A;
            u.rc = phys_reg(rd, mode1);
            u.c_pc = (rd == 4'hF);
            u.wen = wb && (rn != 4'hF);
            u.wa = phys_reg(rn, mode1);
          end else if (!ins[5]) begin
            // LDRD: address (+ writeback), Rd, Rd+1
            if (c_step == 2'd0) begin
              u.maddr = pre ? MA_SUM : MA_A;
              u.taddr = TA_ADDR;
              u.wen = wb && (rn != 4'hF);
              u.wa = phys_reg(rn, mode1);
              more = 1'b1; nstep = 2'd1;
            end else begin
              u.mem = MO_LOAD;
              u.maddr = MA_TADDR;
              u.taddr = TA_NEXT;
              u.norot = 1'b1;
              u.wsrc = WS_MEM;
              u.wen = 1'b1;
              u.wa = phys_reg((c_step == 2'd1) ? rd : {rd[3:1], 1'b1}, mode1);
              u_ld = 1'b1; u_ldr = (c_step == 2'd1) ? rd : {rd[3:1], 1'b1};
              more = (c_step == 2'd1);
              nstep = 2'd2;
            end
          end else begin
            // STRD: Rd (+ writeback), Rd+1
            u.mem = MO_STORE;
            if (c_step == 2'd0) begin
              u.maddr = pre ? MA_SUM : MA_A;
              u.taddr = TA_NEXT;
              u.rc = phys_reg(rd, mode1);
              u.c_pc = 1'b0;
              u.wen = wb && (rn != 4'hF);
              u.wa = phys_reg(rn, mode1);
              more = 1'b1; nstep = 2'd1;
            end else begin
              u.maddr = MA_TADDR;
              u.rc = phys_reg({rd[3:1], 1'b1}, mode1);
              u.c_pc = (rd[3:1] == 3'b111);
            end
          end
        end

        C_BLK: begin
          // steps: 0 address, 1 transfers, 2 final base writeback (ARMv5 LDM
          // with the base in the list), 3 the PC load after that writeback
          u.blkm = 1'b1;
          rl0 = ins[15:0];
          list = (rl0 == 16'h0) ? (v5c ? 16'h0000 : 16'h8000) : rl0;
          cnt = (rl0 == 16'h0) ? 5'd16 : popcnt16(rl0);
          ubank = ins[22] && !(ins[20] && list[15]);
          bmode = ubank ? M_USR : mode1;
          base_in = rl0[rn];
          fwb = ins[21] && base_in && v5c &&
                ((rl0 == (16'h1 << rn)) || ((rl0 >> rn) > 16'h1));
          if (c_step == 2'd0) begin
            u.b_imm = 1'b1;
            u.imm = {25'h0, cnt, 2'b00};
            u.alu = ins[23] ? AL_ADD : AL_SUB;
            u.taddr = TA_BLOCK;
            u.blk_u = ins[23];
            u.blk_pu = (ins[24] == ins[23]);
            u.wa = phys_reg(rn, mode1);
            if (ins[20]) u.wen = ins[21] && !base_in;
            else         u.wen = ins[21] && (list == 16'h0);
            if (list != 16'h0) begin
              more = 1'b1; nstep = 2'd1; nrl = list;
            end
          end else if (c_step == 2'd2 || (c_step == 2'd1 && ins[20] && fwb && c_rl == 16'h8000)) begin
            // final base writeback; a PC load comes after it, so a redirecting
            // uop is always the last one of its instruction
            u.wen = 1'b1;
            u.wsrc = WS_TWB;
            u.wa = phys_reg(rn, mode1);
            more = (c_rl == 16'h8000) && (c_step == 2'd1);
            nstep = 2'd3;
          end else begin
            r = rl_r[1];
            nrl = c_rl & ~(16'h1 << r);
            lastx = (nrl == 16'h0);
            firstx = (c_rl == list);
            u.maddr = MA_TADDR;
            u.taddr = TA_NEXT;
            u.norot = 1'b1;
            if (ins[20]) begin
              u.mem = MO_LOAD;
              u.wsrc = WS_MEM;
              if (r == 4'hF) begin
                u.wpc = 1'b1;
                u.restore = ins[22];
                u.pct = (v5c && !ins[22]) ? PT_DATA0 : PT_KEEP;
              end else begin
                u.wen = 1'b1;
                u.wa = phys_reg(r, bmode);
                u_ld = 1'b1; u_ldr = r;
              end
              more = !lastx || (fwb && c_step == 2'd1);
              nstep = lastx ? 2'd2 : 2'd1;
            end else begin
              u.mem = MO_STORE;
              u.rc = phys_reg(r, bmode);
              u.c_pc = (r == 4'hF);
              u.wen = ins[21] && (v5c ? lastx : firstx);
              u.wsrc = WS_TWB;
              u.wa = phys_reg(rn, mode1);
              more = !lastx;
              nstep = 2'd1;
            end
          end
        end

        C_B, C_BLXI: begin
          // the target was computed in PD; unconditional branches and
          // predicted-taken ones were redirected there already
          u.imm = c_tgt;
          u.pred = c_pred;
          u.bp = (cls == C_B) && ins[31:28] != 4'hE;
          u.bp_ctr = ib_d.ctr;
          u.bp_bwd = ib_d.bwd;
          if (cls == C_BLXI) begin
            u.cond = 4'hE;
            u.set_thumb = 1'b1;
          end else if (!c_pred && ins[31:28] != 4'hE) begin
            u.rdr = RD_IMM;
          end
          if (ins[24] || cls == C_BLXI) begin
            u.wen = 1'b1;
            u.wsrc = WS_LINK;
            u.wa = phys_reg(4'hE, mode1);
          end
        end

        C_TBR: begin
          case (c_kind)
            TK_B: begin
              u.imm = c_tgt;
              u.pred = c_pred;
              u.bp = ins[31:28] != 4'hE;
              u.bp_ctr = ib_d.ctr;
              u.bp_bwd = ib_d.bwd;
              if (!c_pred && ins[31:28] != 4'hE) u.rdr = RD_IMM;
            end
            TK_BL1: begin
              u.wen = 1'b1;
              u.wsrc = WS_LINK;
              u.wa = phys_reg(4'hE, mode1);
              u.link = c_tgt;
            end
            default: begin                       // BL / BLX suffix
              u.ra = phys_reg(4'hE, mode1);
              u.a_pc = 1'b0;
              u.b_imm = 1'b1;
              u.imm = {20'h0, ins[10:0], 1'b0};
              u.alu = AL_ADD;
              // redirected in PD when it came right after its prefix
              u.rdr = c_pred ? RD_NONE : RD_ALU;
              u.clr_thumb = c_pred && c_kind == TK_BLX2;
              u.pct = (c_kind == TK_BLX2) ? PT_ARM : PT_KEEP;
              u.wen = 1'b1;
              u.wsrc = WS_LINK;
              u.wa = phys_reg(4'hE, mode1);
              u.link = link4 | 32'h1;
            end
          endcase
        end

        C_BX, C_BLXR: begin
          u.alu = AL_MOV;
          u.rdr = RD_ALU;
          u.pct = PT_DATA0;
          if (cls == C_BLXR) begin
            u.wen = 1'b1;
            u.wsrc = WS_LINK;
            u.wa = phys_reg(4'hE, mode1);
            u.link = c_thumb ? (link4 | 32'h1) : link4;
          end
        end

        C_CLZ: begin
          u.alu = AL_CLZ;
          u.wen = (rd != 4'hF);
          u.wa = phys_reg(rd, mode1);
        end

        C_QOP: begin
          u.alu = ins[21] ? AL_QSUB : AL_QADD;
          u.qdbl = ins[22];
          u.wen = (rd != 4'hF);
          u.wa = phys_reg(rd, mode1);
        end

        C_CP: begin
          u.mem = MO_CP;
          u.msigned = !ins[20];                  // MCR
          u.norot = 1'b1;                        // MRC data is a whole word
          u.cp_op = {2'b00, ins[23:21], ins[19:16], ins[3:0], ins[7:5]};
          u.rc = phys_reg(rd, mode1);
          u.c_pc = (rd == 4'hF);
          u.wsrc = WS_MEM;
          u.wen = ins[20] && (rd != 4'hF);
          u.wa = phys_reg(rd, mode1);
          if (ins[20] && rd != 4'hF) begin
            u_ld = 1'b1; u_ldr = rd;
          end
          // MCR p15, 0, Rd, c7, c0, 4 / c7, c8, 2: wait for interrupt
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
          exc_any = 1'b1; emode = M_ABT; evec = 32'h0C; u.link = c_pc + 32'd4; u.cond = 4'hE;
        end
        C_UND: begin
          exc_any = 1'b1; emode = M_UND; evec = 32'h04;
          if (c_kind == TK_UND || ins[31:28] == 4'hF) u.cond = 4'hE;
        end
        default: u.cond = 4'hF;                  // C_NOP: never
      endcase
    end

    if (exc_any) begin
      u.exc = 1'b1;
      u.exc_mode = emode;
      u.wen = 1'b1;
      u.wsrc = WS_LINK;
      u.wa = phys_reg(4'hE, emode);
      u.mem = MO_NONE;
      u.wpc = 1'b0;
      u.restore = 1'b0;
      u.flags = FL_NONE;
      u.rdr = RD_IMM;
      u.imm = (hivecs[c1] ? 32'hFFFF0000 : 32'h0) + evec;
      more = 1'b0;
      u_ld = 1'b0;
    end
    u.last = !more;
    // the decode without a taken interrupt or prefetch abort: the issue rules read u0 and exc_p, so an interrupt
    // doesn't sit in front of have -> more -> the buffer's head (take_irq -> u -> sbub -> have, #1322 -2.06 ns).
    // more and the others count only with !inject.
    u0 = u;
    if (c_pabt || take_fiq || take_irq) begin
      u = ud;
      emode = c_pabt ? M_ABT : take_fiq ? M_FIQ : M_IRQ;
      evec  = c_pabt ? 32'h0C : take_fiq ? 32'h1C : 32'h18;
      u.exc_f = !c_pabt && take_fiq;
      u.link = c_pc + 32'd4;
      u.cond = 4'hE;
      u.exc = 1'b1;
      u.exc_mode = emode;
      u.wen = 1'b1;
      u.wsrc = WS_LINK;
      u.wa = phys_reg(4'hE, emode);
      u.mem = MO_NONE;
      u.wpc = 1'b0;
      u.restore = 1'b0;
      u.flags = FL_NONE;
      u.rdr = RD_IMM;
      u.imm = (hivecs[c1] ? 32'hFFFF0000 : 32'h0) + evec;
      u.last = 1'b1;
    end
  end

  // Register file: read addresses from D (to), written in WB2 (te). D and WB2
  // never work for the same context in the same cycle, so a read never hits
  // the address being written.
  logic [31:0] rf_a, rf_b, rf_c;
  logic        rf_we;
  logic [5:0]  rf_wa;
  logic [31:0] rf_wd;

  arm_regfile #(.RAM_STYLE(RF_STYLE)) u_rf (
    .clk(clk), .we(rf_we), .wa(rf_wa), .wd(rf_wd),
    .ra0({c1, u.ra}), .ra1({c1, u.rb}), .ra2({c1, u.rc}),
    .rd0(rf_a), .rd1(rf_b), .rd2(rf_c)
  );

  // ---------------------------------------------------------------- E1 (te)
  // Register-file data and the selects for E2's bypasses. The uop now in E3
  // is this context's previous one (distance 1: its result arrives in E2
  // through the WB registers); the uop now in WB2 is the one before that
  // (distance 2: its register write, wbq, arrives in E2). Loads at distance
  // 1 are excluded: D's interlock keeps their consumers two slots behind.
  logic        wbq_en;
  logic [5:0]  wbq_a;
  logic [31:0] wbq_d;
  logic [31:0] e1_va, e1_vb, e1_vc;
  logic [1:0]  e1_sa, e1_sb, e1_sc;    // {distance 1, distance 2}
  logic [2:0]  e1_s3, e2_s3;           // A9_OPT[5] {a, b, c}: the ALU result now in WB2 (solo distance 3) goes to E2
  logic [4:0]  e1_rot;
  logic [31:0] e1_keep;
  logic        e1_fasr, e1_frrx;
  logic [2:0]  e1_csel;

  // WB2-stage registers (written by WB)
  logic        x_valid, x_exec, x_last, x_wen, x_ld, x_msigned, x_wpc;
  logic [1:0]  x_pct, x_msize, x_alo;
  logic [4:0]  x_wa;
  logic [31:0] x_wd, x_rdata, x_pc, x_acc, w_acc;
  logic        x_mulw, x_macc, w_mulw, w_macc, x_mulhi, w_mulhi;
  logic        x_w;                    // will write the register file
  logic        x_replay, x_abort;
  // the temporaries as they were before this uop's WB, put back in WB2 if
  // its access is replayed or aborted
  logic [31:0] x_taddr, x_twb;
  logic        x_tc, x_tlz;
  assign x_w = x_valid && x_exec && x_wen && !x_replay;
  // load alignment decided in WB (timing, #484: the WB2 path into the register
  // file's write port): per output byte the rdata byte it takes (ls_src) and
  // whether it is that byte, a sign fill or zero (ls_mode 0/1/2); ls_sgn: the
  // byte whose bit 7 is the sign
  logic [1:0]  ls_src [0:3];
  logic [1:0]  ls_mode [0:3];
  logic [1:0]  ls_sgn;

  localparam logic [2:0] CS_OLD = 3'd0, CS_R0 = 3'd1, CS_R31 = 3'd2, CS_X31 = 3'd3, CS_ZERO = 3'd4;

  assign e1_va = e1.a_pc ? e1.pcv : rf_a;
  assign e1_vb = e1.b_imm ? e1.imm : e1.b_pc ? e1.pcv : rf_b;
  assign e1_vc = e1.c_pc ? e1.pcv_c : rf_c;

  // (the condition result of that uop, known in E3 now, is folded in here
  // so E2's mux select comes straight from a register)
  logic e3_fw;
  assign e3_fw = e3_exec && e3.wen && e3.wsrc != WS_MEM && !e3.mulw;
  assign e1_sa = {e3_fw && !e1.a_pc && e3.wa == e1.ra, x_w && !e1.a_pc && x_wa == e1.ra};
  assign e1_sb = {e3_fw && !e1.b_pc && !e1.b_imm && e3.wa == e1.rb,
                  x_w && !e1.b_pc && !e1.b_imm && x_wa == e1.rb};
  assign e1_sc = {e3_fw && !e1.c_pc && e3.wa == e1.rc, x_w && !e1.c_pc && x_wa == e1.rc};

  // Shifter controls: E2 computes x ror e1_rot, keeps the bits in e1_keep and
  // fills the rest with x[31] (ASR) or C (RRX, bit 31 only)
  always_comb begin
    logic [7:0] n;
    logic [4:0] n5;
    n = e1.sh_reg ? ((AMTF && e2.valid && e2.amt_save) ? e2_c[7:0] : temp_amt[0]) : e1.sh_amt;
    n5 = n[4:0];
    e1_rot = 5'd0;
    e1_keep = 32'hFFFFFFFF;
    e1_fasr = 1'b0;
    e1_frrx = 1'b0;
    e1_csel = CS_OLD;
    case (e1.sh_type)
      SH_LSL: begin
        if (n == 8'd0) begin
        end else if (n < 8'd32) begin
          e1_rot = 5'd0 - n5;                      // rotate right by 32-n
          e1_keep = 32'hFFFFFFFF << n5;
          e1_csel = CS_R0;                         // x[32-n]
        end else if (n == 8'd32) begin
          e1_keep = 32'h0;
          e1_csel = CS_R0;                         // x[0]
        end else begin
          e1_keep = 32'h0;
          e1_csel = CS_ZERO;
        end
      end
      SH_LSR, SH_ASR: begin
        if (n == 8'd0) begin
        end else if (n < 8'd32) begin
          e1_rot = n5;
          e1_keep = 32'hFFFFFFFF >> n5;
          e1_csel = CS_R31;                        // x[n-1]
          e1_fasr = (e1.sh_type == SH_ASR);
        end else if (n == 8'd32 || e1.sh_type == SH_ASR) begin
          e1_keep = 32'h0;
          e1_csel = CS_X31;
          e1_fasr = (e1.sh_type == SH_ASR);
        end else begin
          e1_keep = 32'h0;
          e1_csel = CS_ZERO;
        end
      end
      SH_ROR: begin
        if (n != 8'd0) begin
          e1_rot = n5;
          e1_csel = CS_R31;
        end
      end
      default: begin                               // RRX
        e1_rot = 5'd1;
        e1_keep = 32'h7FFFFFFF;
        e1_frrx = 1'b1;
        e1_csel = CS_R0;                           // x[0], see E2
      end
    endcase
  end

  // Solo issue rules (sbub: no uop this cycle). The uop issued last cycle is
  // in E1 (distance 1), the one before in E2 (2), then E3 (3), WB (4), WB2
  // (5). E2's bypasses cover distances 2 (ALU results) and 4 (anything); a
  // register written at distance 1, 3 or 5 (the latter: D's register-file read
  // meets WB2's write of the same context) waits, as does a load's result at
  // distance 2. The uop after one that changes a PSR waits if it reads PSR
  // state in E2/E3 (condition, carry, the shifter's old carry, PSR reads,
  // exceptions, memory privilege); after one that may redirect from WB (ALU
  // result into the PC) every uop waits; memory accesses are two cycles apart
  // (arm9_mem forwards a store to the access right after it, and replays kill
  // younger uops in order); a later uop of a multi-uop instruction keeps the
  // barrel's spacing (temporaries, the product). A uop that changes the CPSR
  // or halts in E3 (exception entry, SPSR restore, BLX's T, WFI) waits until
  // the previous uop is in WB2: in the barrel that one has always answered
  // before (its replay or abort kills E3 in the same cycle), and its retire
  // record shows the CPSR as it left it.
  function automatic logic rd_reg(input uop_t x, input logic [4:0] r);
    if (UFLD)
      return (r == x.ra && !x.a_pc && (x.a_sel != OA_ZERO || x.mul_start)) || (r == x.rb && !x.b_pc && !x.b_imm && (x.b_sel == OB_SH || x.mul_start)) ||
             (r == x.rc && !x.c_pc && (x.amt_save || x.macc || x.mem == MO_STORE || x.mem == MO_CP || x.st_save));
    return (r == x.ra && !x.a_pc) || (r == x.rb && !x.b_pc && !x.b_imm) || (r == x.rc && !x.c_pc);
  endfunction
  // D1FWD (A9_OPT bit 13): a plain ALU/load/store consumer issued right behind a plain ALU producer (distance 1)
  // does not wait: when the producer's result comes out of E3, it is also written into the consumer's E3 operand
  // registers (A: the Rn side, B: the Rm side when it is not shifted). {ok, use_b, use_a}
  function automatic logic [2:0] d1chk(input uop_t c, input uop_t p);
    logic prod_ok, cons_ok, dA, dAn, dB, dC, ident;
    prod_ok = p.valid && p.wen && p.wsrc == WS_ALU && !p.wpc && !p.mulw && p.mem == MO_NONE && !p.mul_start && p.b_sel == OB_SH &&
              p.rdr == RD_NONE && !p.msr && !p.exc && !p.restore && !p.set_thumb && !p.clr_thumb && !p.wfi && !p.st_save;
    cons_ok = c.alu <= AL_MVN && !c.qdbl && !c.cin_tc && !c.mul_start && c.mem != MO_CP && !c.psr_spsr && !c.msr &&
              !c.exc && !c.restore && !c.wfi && !c.st_save && !c.st_temp && c.b_sel == OB_SH && !c.amt_save;
    dAn   = !c.a_pc && p.wa == c.ra;
    dA    = dAn && c.a_sel == OA_REG;
    dB    = !c.b_pc && !c.b_imm && p.wa == c.rb;
    dC    = !c.c_pc && p.wa == c.rc && (c.sh_reg || c.mem == MO_STORE);        // (port C is read only for a register shift or store data)
    ident = c.sh_type == SH_LSL && !c.sh_reg && c.sh_amt == 8'd0;
    return {prod_ok && cons_ok && !dC && (!dB || ident) && !(dAn && c.a_sel == OA_TADDR), dB, dA};
  endfunction
  // LDFWD (A9_OPT bit 20): the same for a load as the producer (distance 2): the loaded value, aligned in WB, goes into
  // the consumer's E3 operand registers while the consumer is in E2, so LDR + dependent use takes 3 cycles
  localparam bit STF = A9_SOLO && (A9_OPT & 2097152) != 0;   // bit 21: also into a store's data register (LDR r4; STR r4 ...)
  function automatic logic [3:0] ldchk(input uop_t c, input uop_t p);
    logic prod_ok, cons_ok, dA, dAn, dB, dC, dCs, ident;
    prod_ok = p.valid && p.wen && p.wsrc == WS_MEM && !p.wpc && p.mem == MO_LOAD && p.msize == MS_W;   // (LDRB/LDRH + use stay at the DS's +2: run 30)
    cons_ok = c.alu <= AL_MVN && !c.qdbl && !c.cin_tc && !c.mul_start && c.mem != MO_CP && !c.psr_spsr && !c.msr &&
              !c.exc && !c.restore && !c.wfi && !c.st_save && !c.st_temp && c.b_sel == OB_SH && !c.amt_save;
    dAn   = !c.a_pc && p.wa == c.ra;
    dA    = dAn && c.a_sel == OA_REG;
    dB    = !c.b_pc && !c.b_imm && p.wa == c.rb;
    dC    = !c.c_pc && p.wa == c.rc && (c.sh_reg || (c.mem == MO_STORE && !STF));
    dCs   = STF && !c.c_pc && p.wa == c.rc && c.mem == MO_STORE && !c.sh_reg;
    ident = c.sh_type == SH_LSL && !c.sh_reg && c.sh_amt == 8'd0;
    return {prod_ok && cons_ok && !dC && (!dB || ident) && !(dAn && c.a_sel == OA_TADDR), dCs, dB, dA};
  endfunction
  localparam bit LDF = A9_SOLO && (A9_OPT & 1048576) != 0;
  logic [3:0] ldc_u, ldn;
  assign ldc_u = ldchk(u0, e2);          // the consumer in D, the load in E2
  assign ldn   = ldchk(e1, e3);         // one stage later: the consumer in E1, the load in E3
  localparam bit D1 = A9_SOLO && (A9_OPT & 8192) != 0;
  localparam bit FLFWD = A9_SOLO && (A9_OPT & 32768) != 0;   // bit 15: E3 sees the flags the WB uop writes (a conditional uop right behind a flag setter does not wait)
  localparam bit AMTF  = A9_SOLO && (A9_OPT & 65536) != 0;   // bit 16: a register-shift DP issues right behind its Rs uop (the amount is taken from E2)
  localparam bit MLONG = A9_SOLO && (A9_OPT & 131072) != 0;  // bit 17: UMULL/SMULL (no S, no accumulate): both halves written in WB2
  localparam bit UFLD  = A9_SOLO && (A9_OPT & 262144) != 0;  // bit 18: the issue rules compare only the register fields a uop reads
  localparam bit MULW = A9_SOLO && (A9_OPT & 16384) != 0;   // A9_OPT bit 14: MUL/MLA (S = 0) and SMULxy/SMULWy are one uop, written in WB2
  logic [2:0] d1c;
  assign d1c = d1chk(u0, e1);
  logic [2:0] d1n;                      // the same check one stage later (the consumer in E1, the producer in E2)
  assign d1n = d1chk(e1, e2);
  logic [8:0] sb_cause;                     // (sim) the solo issue rules that hold D: d1 d3 d5 loaduse psr alu-pc mem2 multi exc
  wire exc_p = take_fiq || take_irq || c_pabt;                        // (not inject: have -> inject -> sbub -> have was a combinational loop)
  always_comb begin
    logic h1, hl, h3, h4, h5, h6, h7, h8, psrw, psru;
    h1 = (e1.valid && e1.wen && rd_reg(u0, e1.wa) && !(D1 && d1c[2])) ||
         (MULW && ((e2.valid && e2.wen && e2.mulw && rd_reg(u0, e2.wa)) || (e3.valid && e3.wen && e3.mulw && e3.macc && rd_reg(u0, e3.wa)))) ||
         (e3.valid && e3.wen && rd_reg(u0, e3.wa) && !((A9_OPT & 32) != 0 && (e3.wsrc != WS_MEM || (A9_OPT & 128) != 0) && !e3.wpc)) ||
         (x_valid && x_wen && rd_reg(u0, x_wa) && (A9_OPT & 256) == 0);
    hl = e2.valid && e2.wen && e2.wsrc == WS_MEM && rd_reg(u0, e2.wa) && !(LDF && ldc_u[3]);
    psrw = e1.flags != FL_NONE || e1.msr || e1.exc || e1.restore || e1.set_thumb || e1.clr_thumb;
    psru = u0.cond != 4'hE || (u0.flags != FL_NONE && !(D1 && (u0.alu == AL_ADD || u0.alu == AL_SUB || u0.alu == AL_RSB || u0.alu == AL_CMP || u0.alu == AL_CMN))) || u0.alu == AL_ADC || u0.alu == AL_SBC ||
           u0.alu == AL_RSC || u0.alu == AL_PSR || u0.sh_type == SH_RRX || u0.cin_tc || u0.exc ||
           u0.restore || u0.msr || u0.psr_spsr || u0.mem != MO_NONE || exc_p;
    if (FLFWD) begin
      logic psrw_o, flw, psru_e2, psru_x;
      psrw_o  = e1.msr || e1.exc || e1.restore || e1.set_thumb || e1.clr_thumb;
      flw     = e1.flags != FL_NONE && !psrw_o;
      psru_e2 = u0.sh_type == SH_RRX || (u0.flags != FL_NONE && !(u0.alu == AL_ADD || u0.alu == AL_SUB || u0.alu == AL_RSB || u0.alu == AL_CMP || u0.alu == AL_CMN));
      psru_x  = u0.exc || u0.restore || u0.msr || u0.psr_spsr || u0.alu == AL_PSR || exc_p;
      h3 = e1.valid && ((psrw_o && psru) || (flw && (psru_e2 || psru_x)));
    end else
    h3 = e1.valid && psrw && psru;
    h4 = e1.valid && e1.rdr == RD_ALU;
    h5 = e1.valid && e1.mem != MO_NONE && u0.mem != MO_NONE && !MEM1;
    h6 = e1.valid && !fresh && !(AMTF && e1.amt_save && u0.sh_reg) && !(MEM1 && e1.blkm && u0.blkm);
    h8 = MULW && e1.valid && e1.mulw && e1.mul_start && e1.mul_kind == MK_32;              // MUL/MLA take two cycles (the DS: hwref run 22)
    h7 = e1.valid && (u0.exc || (u0.restore && !u0.wpc) || u0.set_thumb || u0.clr_thumb || u0.wfi || exc_p);
    sbub = A9_SOLO && solo && (h1 || hl || h3 || h4 || h5 || h6 || h7 || h8);
    sb_cause = {(e1.valid && e1.wen && rd_reg(u, e1.wa)), (e3.valid && e3.wen && rd_reg(u, e3.wa) && !((A9_OPT & 32) != 0 && (e3.wsrc != WS_MEM || (A9_OPT & 128) != 0) && !e3.wpc)), (x_valid && x_wen && rd_reg(u, x_wa) && (A9_OPT & 256) == 0), hl, h3, h4, h5, h6, h7};
  end

  // ---------------------------------------------------------------- E2 (to)
  logic [31:0] e2_va, e2_vb, e2_vc, e2_keep;
  logic [1:0]  e2_sa, e2_sb, e2_sc;
  logic        e2_lfa, e2_lfb, e2_lfc;      // LDFWD: take the load now in WB into the operand
  logic        e2_f1a, e2_f1b;          // D1FWD: take the producer's result out of E3 into the operand
  logic        e2_fasr, e2_frrx;
  logic [4:0]  e2_rot;
  logic [2:0]  e2_csel;

  // WB-stage registers (written by E3)
  logic        w_valid, w_exec, w_last, w_wen, w_ld, w_msigned, w_thumb;
  logic        w_wpc, w_rdalu, w_tc, w_z64, w_c, w_v, w_q, w_arith, w_restore;
  logic        w_msr, w_psr_spsr, w_tsave, w_twbsave, w_tc_val;
  logic [1:0]  w_mem, w_flags, w_pct, w_msize, w_alo, w_step;
  logic [3:0]  w_msr_mask, w_rr;
  logic [4:0]  w_wa;
  logic [15:0] w_rl;
  logic [31:0] w_wd, w_res, w_pc, w_tnext, w_twb;

  logic [31:0] e2_a, e2_b, e2_c, e2_ad, sh_out, x_rot;
  logic        sh_c, sh_cold, cfwd, qsat_d;
  logic        w_fw;
  assign w_fw = w_valid && w_exec;
  // solo distance 3 (A9_OPT[5]): the uop now in WB (an ALU result, not a load) is in WB2 when E2 needs it;
  // the nearer uop (distance 2, e3) wins
  logic w3_fw;
  assign w3_fw = A9_SOLO && (A9_OPT & 32) != 0 && solo && w_valid && w_exec && w_wen && (!w_ld || (A9_OPT & 128) != 0) && !w_wpc;
  assign e1_s3 = {w3_fw && !e1.a_pc && w_wa == e1.ra && !(e3_fw && e3.wa == e1.ra),
                  w3_fw && !e1.b_pc && !e1.b_imm && w_wa == e1.rb && !(e3_fw && e3.wa == e1.rb),
                  w3_fw && !e1.c_pc && w_wa == e1.rc && !(e3_fw && e3.wa == e1.rc)};

  logic [31:0] x_fwd;                  // the value WB2 writes (A9_OPT[7]: a load's aligned data too), for the distance-3 bypass
  assign e2_a = e2_sa[1] ? w_wd : e2_s3[2] ? x_fwd : e2_sa[0] ? wbq_d : e2_va;
  assign e2_b = e2_sb[1] ? w_wd : e2_s3[1] ? x_fwd : e2_sb[0] ? wbq_d : e2_vb;
  assign e2_c = e2_sc[1] ? w_wd : e2_s3[0] ? x_fwd : e2_sc[0] ? wbq_d : e2_vc;

  // C as it will be after the uop now in WB (same context)
  assign cfwd = (w_fw && w_flags == FL_DP) ? w_c : cpsr[1][29];

  // ROT_DSP (with SLOW): the rotator in a DSP multiplier (#403: -56 ALMs, 71 MHz; off since #648:
  // the multiply on the e2_sb -> e3_x path missed 67 MHz by 1.16 ns in the chain build): rotating
  // right by r is rotating left by s = -r mod 32, and b * 2^s holds b << s in
  // its low word and the bits shifted out in its high word
  (* multstyle = "dsp" *) logic [63:0] rot_p;
  wire [4:0] rot_s = 5'(-e2_rot);
  assign rot_p = (SLOW && ROT_DSP) ? {32'd0, e2_b} * {32'd0, 32'd1 << rot_s} : 64'd0;
  always_comb begin
    if (SLOW && ROT_DSP) x_rot = rot_p[31:0] | rot_p[63:32];
    else begin
      x_rot = (e2_b >> e2_rot) | (e2_b << (6'd32 - {1'b0, e2_rot}));
      if (e2_rot == 5'd0) x_rot = e2_b;
    end
    for (int i = 0; i < 32; i++)
      sh_out[i] = e2_keep[i] ? x_rot[i] : ((e2_fasr & e2_b[31]) | (e2_frrx & cfwd & (i == 31)));
    sh_cold = 1'b0;
    case (e2_csel)
      CS_R0:   sh_c = e2_frrx ? e2_b[0] : x_rot[0];
      CS_R31:  sh_c = x_rot[31];
      CS_X31:  sh_c = e2_b[31];
      CS_ZERO: sh_c = 1'b0;
      default: begin sh_c = 1'b0; sh_cold = 1'b1; end
    endcase
    // QDADD/QDSUB: saturate 2*Rn
    qsat_d = 1'b0;
    e2_ad = e2_a;
    if (e2.qdbl) begin
      if (e2_a[31] != e2_a[30]) begin
        qsat_d = 1'b1;
        e2_ad = e2_a[31] ? 32'h80000000 : 32'h7FFFFFFF;
      end else begin
        e2_ad = {e2_a[30:0], 1'b0};
      end
    end
  end

  // Adder operands for E3, chosen and inverted here so E3 starts at the
  // carry chain: E3 computes x + y + ci (y is replaced there by the product
  // for the uops that use it, which only add)
  logic [31:0] e2_x, e2_y, e2_av;
  always_comb begin
    e2_av = (e2.a_sel == OA_ZERO) ? 32'h0 : e2_a;
    case (e2.alu)
      AL_SUB, AL_CMP, AL_SBC: begin e2_x = e2_av;  e2_y = ~sh_out; end
      AL_RSB, AL_RSC:         begin e2_x = sh_out; e2_y = ~e2_av;  end
      AL_QADD:                begin e2_x = sh_out; e2_y = e2_ad;   end
      AL_QSUB:                begin e2_x = sh_out; e2_y = ~e2_ad;  end
      default:                begin e2_x = e2_av;  e2_y = sh_out;  end
    endcase
  end

  // Multiplier operands
  logic [32:0] mul_a, mul_b;
  always_comb begin
    logic [15:0] ha, hb;
    ha = e2.mul_xh ? e2_a[31:16] : e2_a[15:0];
    hb = e2.mul_yh ? e2_b[31:16] : e2_b[15:0];
    case (e2.mul_kind)
      MK_XY: begin
        mul_a = {{17{ha[15]}}, ha};
        mul_b = {{17{hb[15]}}, hb};
      end
      MK_WY: begin
        mul_a = {e2_a[31], e2_a};
        mul_b = {{17{hb[15]}}, hb};
      end
      default: begin
        mul_a = {e2.mul_signed & e2_a[31], e2_a};
        mul_b = {e2.mul_signed & e2_b[31], e2_b};
      end
    endcase
  end

  // (named wires: Icarus mis-evaluates struct-member expressions on ports)
  logic [63:0] prod_q;                 // product of the context now in E3
  logic        mul_go, mul_wy;
  assign mul_go = e2.valid && e2.mul_start;
  assign mul_wy = (e2.mul_kind == MK_WY);

  arm_mul u_mul (
    .clk(clk), .start(mul_go), .hold(A9_SOLO && solo), .wy(mul_wy),
    .a(mul_a), .b(mul_b), .prod(prod_q)
  );

  // ---------------------------------------------------------------- E3 (te)
  logic [31:0] e3_a, e3_b, e3_c, e3_x, e3_y;
  logic        e3_shc, e3_shcold, e3_qsat;

  logic [31:0] opa, opb, res, maddr, psr_val, cur_cpsr;
  logic [32:0] sum33;
  logic        add_c, add_v, alu_arith, cflag, cin, shc_res;
  logic [2:0]  sidx;
  logic        spsr_ok;

  assign cflag    = cur_cpsr[29];
  assign e3_exec  = e3.valid && !x2_rdr && cond_pass(e3.cond, cur_cpsr[31:28]);
  assign sidx     = spsr_idx(cur_cpsr[4:0]);
  assign spsr_ok  = (sidx != 3'd7);
  assign shc_res  = e3_shcold ? cflag : e3_shc;

  always_comb begin
    logic [31:0] x, y;
    logic        ci;
    logic [5:0]  lz;
    logic [33:0] s34;

    opa = (e3.a_sel == OA_ZERO) ? 32'h0 : e3_a;
    case (e3.b_sel)
      OB_PLO:  opb = prod_q[31:0];
      OB_PHI:  opb = prod_q[63:32];
      default: opb = e3_b;
    endcase
    cin = e3.cin_tc ? temp_c[0] : cflag;

    // One adder computes x + y + ci (operands prepared in E2); the carry-in
    // rides in an extra low bit so it stays on the same carry chain
    x = e3_x;
    y = (e3.b_sel == OB_SH) ? e3_y : opb;
    alu_arith = 1'b1;
    case (e3.alu)
      AL_SUB, AL_CMP, AL_RSB, AL_QSUB: ci = 1'b1;
      AL_ADC, AL_SBC, AL_RSC:          ci = cin;
      AL_ADD, AL_CMN, AL_QADD:         ci = 1'b0;
      default: begin ci = 1'b0; alu_arith = 1'b0; end
    endcase
    s34 = {1'b0, x, 1'b1} + {1'b0, y, ci};
    sum33 = s34[33:1];
    add_c = sum33[32];
    add_v = (x[31] == y[31]) && (sum33[31] != x[31]);

    psr_val = cur_cpsr;
    if (e3.psr_spsr && spsr_ok) psr_val = spsr_e3;

    lz = 6'd32;
    for (int i = 0; i < 32; i++) if (opb[i]) lz = 6'd31 - i[5:0];

    case (e3.alu)
      AL_AND, AL_TST: res = opa & opb;
      AL_EOR, AL_TEQ: res = opa ^ opb;
      AL_ORR:         res = opa | opb;
      AL_MOV:         res = opb;
      AL_BIC:         res = opa & ~opb;
      AL_MVN:         res = ~opb;
      AL_CLZ:         res = {26'h0, lz};
      AL_PSR:         res = psr_val;
      AL_QADD, AL_QSUB:
        res = add_v ? (sum33[31] ? 32'h7FFFFFFF : 32'h80000000) : sum33[31:0];
      default:        res = sum33[31:0];
    endcase
  end

  logic [31:0] tadr_f, twb_f;
  assign maddr = (e3.maddr == MA_SUM) ? sum33[31:0] :
                 (e3.maddr == MA_A)   ? opa : tadr_f;

  // Data and coprocessor ports
  logic [31:0] st_data;
  assign st_data = e3.st_temp ? temp_st[0] : e3_c;
  assign d_req   = e3_exec && (e3.mem == MO_LOAD || e3.mem == MO_STORE);
  assign d_tid   = c0;
  assign d_priv  = (cur_cpsr[4:0] != M_USR);
  assign d_we    = (e3.mem == MO_STORE);
  assign d_size  = e3.msize;
  assign d_addr  = maddr;
  always_comb begin
    case (e3.msize)
      MS_B: begin
        d_wdata = {4{st_data[7:0]}};
        d_be = 4'b0001 << maddr[1:0];
      end
      MS_H: begin
        d_wdata = {2{st_data[15:0]}};
        d_be = maddr[1] ? 4'b1100 : 4'b0011;
      end
      default: begin
        d_wdata = st_data;
        d_be = 4'b1111;
      end
    endcase
  end
  assign cp_req   = e3_exec && (e3.mem == MO_CP);
  assign cp_we    = e3.msigned;
  assign cp_op    = e3.cp_op;
  assign cp_wdata = e3_c;

  logic [31:0] psr_mask;
  assign psr_mask = V5[c0] ? 32'hF80000FF : 32'hF00000FF;

  // E3's CPSR write: exception entry, SPSR restore, Thumb changes
  logic        e3_cw;
  logic [12:0] e3_cv;
  always_comb begin
    logic [31:0] c;
    e3_cw = e3_exec;
    e3_cv = psr13(cur_cpsr);
    c = cur_cpsr;
    if (e3.exc) e3_cv = psr13({cur_cpsr[31:8], 1'b1, cur_cpsr[6] | e3.exc_f, 1'b0, e3.exc_mode});
    else if (e3.restore && !e3.wpc) begin
      e3_cw = e3_exec && spsr_ok;
      e3_cv = psr13(spsr_e3 & psr_mask);
    end else begin
      if (e3.set_thumb) c[5] = 1'b1;
      if (e3.clr_thumb) c[5] = 1'b0;
      if (e3_rdr) c[5] = e3_newt;
      e3_cv = psr13(c);
    end
  end

  // E3 redirects: exceptions, flushes, branches to the PD target, and
  // predicted branches whose condition failed. Targets computed by the ALU
  // (BX, MOV pc, BL suffix) redirect from WB, off the adder path.
  always_comb begin
    logic t;
    e3_rdr = 1'b0;
    e3_tgt = e3.link;
    if (e3.valid && !x2_rdr && e3.pred && !e3_exec) begin
      e3_rdr = 1'b1;
    end else if (e3_exec) begin
      case (e3.rdr)
        RD_IMM:  begin e3_rdr = 1'b1; e3_tgt = e3.imm; end
        RD_LINK: begin e3_rdr = 1'b1; e3_tgt = e3.link; end
        default: ;
      endcase
    end
    // Thumb state after the redirect
    t = cur_cpsr[5];
    if (e3_exec && e3.restore && !e3.wpc && spsr_ok) t = spsr_e3[5];
    if (e3_exec && e3.exc) t = 1'b0;
    e3_newt = t;
  end

  // ---------------------------------------------------------------- WB (to)
  // Memory answer for the request made in E3 last cycle
  // The memory's ready/abort answer is only registered here: WB writes the
  // uop's temporaries regardless (the memory's MPU lookup is too deep to
  // gate them), and WB2 puts the old values back if the access is replayed
  // or aborted. The next uop of the context, in E3 meanwhile, is killed.
  logic        w_go, w_ismem, wb_rda;
  logic        w_bp, w_bp_tk, w_bp_bwd;
  logic [1:0]  w_bp_ctr;
  logic [31:0] w_n, w_psr_mask;
  logic [2:0]  w_sidx;

  assign w_go      = w_valid && w_exec && !(solo && x2_rdr);
  // MEM1: the temporaries of the uop now in WB (the previous transfer of an LDM/STM, one cycle ahead) are used directly
  assign tadr_f = (MEM1 && solo && w_go && w_tsave)   ? w_tnext : temp_addr[0];
  assign twb_f  = (MEM1 && solo && w_go && w_twbsave) ? w_twb   : temp_wb[0];

  // a resolved conditional branch moves its predictor counter
  always_comb begin
    logic [1:0] n;
    n = w_bp_tk ? ((w_bp_ctr == 2'd3) ? 2'd3 : w_bp_ctr + 2'd1)
                : ((w_bp_ctr == 2'd0) ? 2'd0 : w_bp_ctr - 2'd1);
    bp_we = w_bp && !(solo && x2_rdr);
    bp_wa = {c1, w_pc[8:1]};
    bp_wd = n ^ {w_bp_bwd, !w_bp_bwd};
  end
  assign w_ismem   = (w_mem != MO_NONE);
  assign wb_rda    = w_go && w_rdalu;
  assign wb_kill   = wb_rda;
  assign w_psr_mask = V5[c1] ? 32'hF80000FF : 32'hF00000FF;
  assign w_sidx    = spsr_idx(cpsr[1][4:0]);

  assign wb_tgt  = w_res;
  assign wb_newt = (w_pct == PT_DATA0) ? w_res[0] : (w_pct == PT_ARM) ? 1'b0 : cpsr[1][5];

  // CPSR after this uop: flags, MSR, T for ALU-result branches (memory uops
  // set no flags; LDM^ restore and data abort entry are in WB2)
  always_comb begin
    w_n = cpsr[1];
    if (w_go) begin
      case (w_flags)
        FL_DP: begin
          w_n[31] = w_res[31];
          w_n[30] = (w_res == 32'h0);
          w_n[29] = w_c;
          if (w_arith) w_n[28] = w_v;
        end
        FL_NZ: begin
          w_n[31] = w_res[31];
          w_n[30] = (w_res == 32'h0) && (!w_z64 || temp_lz[1]);
        end
        default: ;
      endcase
      if (w_q && V5[c1]) w_n[27] = 1'b1;
      if (w_msr && !w_psr_spsr) begin
        if (w_msr_mask[3]) w_n[31:24] = w_res[31:24] & w_psr_mask[31:24];
        if (w_msr_mask[0] && w_n[4:0] != M_USR && valid_mode(w_res[4:0]))
          w_n[7:0] = {w_res[7:6], w_n[5], w_res[4:0]};
      end
      if (wb_rda) w_n[5] = wb_newt;
    end
  end
  // E3's view of the CPSR: the flags the uop in WB writes (FLFWD, solo) are already in
  assign cur_cpsr = (FLFWD && solo) ? {w_n[31:28], cpsr[0][27:0]} : cpsr[0];

  // ---------------------------------------------------------------- WB2 (te)
  logic [31:0] ld_rot, ld_val, x_cpsr;

  always_comb begin
    logic [15:0] h;
    logic [7:0]  b;
    ld_rot = (x_rdata >> {x_alo, 3'b000}) | (x_rdata << (6'd32 - {1'b0, x_alo, 3'b000}));
    if (x_alo == 2'd0) ld_rot = x_rdata;
    h = x_alo[1] ? x_rdata[31:16] : x_rdata[15:0];
    b = ld_rot[7:0];
    case (x_msize)
      MS_B: ld_val = x_msigned ? {{24{b[7]}}, b} : {24'h0, b};
      MS_H: begin
        if (x_alo[0] && !V5[c0]) begin
          // ARM7TDMI: LDRH from an odd address rotates, LDRSH loads a signed byte
          if (x_msigned) ld_val = {{24{b[7]}}, b};
          else           ld_val = {h[7:0], 16'h0, h[15:8]};
        end else begin
          ld_val = x_msigned ? {{16{h[15]}}, h} : {16'h0, h};
        end
      end
      default: ld_val = ld_rot;
    endcase
  end

  // LDFWD: the loaded value of the uop in WB, aligned the way ls_* does it for WB2 (decided here from the WB registers)
  logic [31:0] lw_val;
  always_comb begin
    logic [1:0] a, sgn;
    logic [7:0] src, md;                     // per output byte k: src[2k+:2], md[2k+:2] (0 byte, 1 sign fill, 2 zero)
    logic       odd4;
    a = w_alo;
    odd4 = w_msize == MS_H && a[0] && !V5[c1];
    sgn = a;
    for (int k = 0; k < 4; k++) begin src[2*k +: 2] = 2'(a + k); md[2*k +: 2] = 2'd0; end
    if (w_msize == MS_B || (odd4 && w_msigned)) begin
      for (int k = 1; k < 4; k++) md[2*k +: 2] = w_msigned ? 2'd1 : 2'd2;
    end else if (w_msize == MS_H && !odd4) begin
      src[1:0] = {a[1], 1'b0}; src[3:2] = {a[1], 1'b1};
      sgn = {a[1], 1'b1};
      for (int k = 2; k < 4; k++) md[2*k +: 2] = w_msigned ? 2'd1 : 2'd2;
    end else if (odd4) begin
      src[1:0] = {a[1], 1'b1}; src[7:6] = {a[1], 1'b0};
      md[3:2] = 2'd2; md[5:4] = 2'd2;
    end
    for (int k = 0; k < 4; k++)
      lw_val[k*8 +: 8] = md[2*k +: 2] == 2'd0 ? d_rdata[{src[2*k +: 2], 3'd0} +: 8] :
                         md[2*k +: 2] == 2'd1 ? {8{d_rdata[{sgn, 3'd7}]}} : 8'h00;
  end

  logic [31:0] ld_v2;
  always_comb begin
    logic sg;
    sg = x_rdata[{ls_sgn, 3'd7}];
    for (int k = 0; k < 4; k++)
      ld_v2[k*8 +: 8] = ls_mode[k] == 2'd0 ? x_rdata[{ls_src[k], 3'd0} +: 8] :
                        ls_mode[k] == 2'd1 ? {8{sg}} : 8'h00;
  end
`ifndef SYNTHESIS
  // simulation: the WB-decided alignment equals the WB2 one it replaces
  always_ff @(posedge clk)
    if (!rst && x_valid && x_exec && x_ld && !x_replay && !x_abort && ld_v2 !== ld_val)
      $error("arm_core: load alignment %h, expected %h (alo %0d size %0d signed %b)", ld_v2, ld_val, x_alo, x_msize, x_msigned);
`endif

  // WB2 redirects: load into the PC, replay (memory not ready), data abort
  logic        x_go, x_thumb, x_restore;
  logic [1:0]  x_step;
  logic [15:0] x_rl;
  logic [3:0]  x_rr;
  logic [2:0]  x_sidx;
  logic [31:0] x_psr_mask, x_abt_vec;
  assign x_go       = x_valid && x_exec;
  assign x_sidx     = spsr_idx(cpsr[0][4:0]);
  assign x_psr_mask = V5[c0] ? 32'hF80000FF : 32'hF00000FF;
  assign x_abt_vec  = (hivecs[c0] ? 32'hFFFF0000 : 32'h0) + 32'h10;

  // CPSR after an LDM^ restore or a data abort entry
  always_comb begin
    x_cpsr = cpsr[0];
    if (x_go && x_abort)
      x_cpsr = {cpsr[0][31:8], 1'b1, cpsr[0][6], 1'b0, M_ABT};
    else if (x_go && !x_replay && x_restore && x_sidx != 3'd7)
      x_cpsr = spsr_x2 & x_psr_mask;
    if (x2_rdr && !x_replay && !x_abort) x_cpsr[5] = x2_newt;
  end

  assign x2_rdr  = x_go && (x_wpc || x_replay || x_abort);
  assign d_kill  = MEM1 && solo && x2_rdr;
  wire [31:0] ld_w2 = (SLOW && !SOLO_ONLY) ? ld_val : ld_v2;   // SLOW: WB2's own alignment (#484's precompute unused); SOLO_ONLY: the precompute
  assign x2_tgt  = x_replay ? x_pc : x_abort ? x_abt_vec : ld_w2;
  assign x2_newt = x_replay ? x_thumb : x_abort ? 1'b0 :
                   (x_pct == PT_DATA0) ? ld_w2[0] :
                   (x_restore && x_sidx != 3'd7) ? spsr_x2[5] : cpsr[0][5];

  // a replayed uop writes nothing; an aborted one writes r14_abt = PC + 8
  assign rf_we = x_go && !x_replay && (x_wen || x_abort);
  assign rf_wa = {c0, x_abort ? 5'd28 : x_wa};
  assign rf_wd = x_abort ? (x_pc + 32'd8) : x_ld ? ld_w2 : x_mulw ? (x_mulhi ? prod_q[63:32] : (prod_q[31:0] + (x_macc ? x_acc : 32'd0))) : x_wd;
  assign x_fwd = ((A9_OPT & 128) != 0 && x_ld) ? ld_w2 : x_mulw ? (x_mulhi ? prod_q[63:32] : prod_q[31:0]) : x_wd;

  assign dbg_wen    = rf_we;
  assign dbg_wa     = rf_wa;
  assign dbg_wd     = rf_wd;
  assign dbg_retire = x_valid && (x_last || x_abort) && !(x_exec && x_replay);
  assign dbg_tid    = c0;
  assign dbg_pc     = x_pc;
  assign dbg_cpsr   = x_cpsr;

  // ---------------------------------------------------------------- SPSRs
  always_comb begin
    logic msr;
    msr = w_go && w_msr && w_psr_spsr && w_sidx != 3'd7;
    sp_wf = 1'b0; sp_wc = 1'b0;
    sp_wa = {c1, w_sidx};
    sp_wd = {w_res[31:27] & w_psr_mask[31:27], w_res[7:0]};
    if (se_v) begin
      sp_wf = 1'b1; sp_wc = 1'b1; sp_wa = {c1, se_b}; sp_wd = se_d;
    end else if (sa_v) begin
      sp_wf = 1'b1; sp_wc = 1'b1; sp_wa = {c1, 3'd3}; sp_wd = sa_d;
    end else if (msr) begin
      sp_wf = w_msr_mask[3]; sp_wc = w_msr_mask[0];
      if (!sp_vld[{c1, w_sidx}]) begin        // first write: the other lane is 0
        if (!w_msr_mask[3]) sp_wd[12:8] = 5'h0;
        if (!w_msr_mask[0]) sp_wd[7:0] = 8'h0;
        sp_wf = sp_wf || sp_wc; sp_wc = sp_wf || sp_wc;
      end
    end
  end
  assign spsr_e3 = sp_vld[{c0, sidx}]   ? psr32({spf_e[{c0, sidx}], spc_e[{c0, sidx}]}) : 32'h0;
  assign spsr_x2 = sp_vld[{c0, x_sidx}] ? psr32({spf_x[{c0, x_sidx}], spc_x[{c0, x_sidx}]}) : 32'h0;
  always_ff @(posedge clk) begin
    if (sp_wf) begin spf_e[sp_wa] <= sp_wd[12:8]; spf_x[sp_wa] <= sp_wd[12:8]; end
    if (sp_wc) begin spc_e[sp_wa] <= sp_wd[7:0];  spc_x[sp_wa] <= sp_wd[7:0];  end
    if (sp_wf || sp_wc) sp_vld[sp_wa] <= 1'b1;
    se_v <= !rst && e3_exec && e3.exc;
    se_b <= spsr_idx(e3.exc_mode);
    se_d <= psr13(cur_cpsr);
    sa_v <= !rst && x2_rdr && x_abort;
    sa_d <= psr13(cpsr[0]);
  end

  // ---------------------------------------------------------------- sequential

  always_ff @(posedge clk) begin
    if (rst) begin
      tid <= 1'b0;
      solo_r <= 1'b0; solo_e <= 1'b0; solo_x <= 1'b0; r_cnt <= 9'd0; s_cnt <= 9'd0; pk_burst <= 1'b0; ib4_n <= 3'd0; ib4_h <= 2'd0;
      f2_v <= 1'b0;
      p_v <= 1'b0;
      e1 <= '0;
      e2 <= '0;
      e3 <= '0;
      w_valid <= 1'b0;
      w_bp <= 1'b0;
      w_exec <= 1'b0;
      x_valid <= 1'b0;
      x_exec <= 1'b0;
      wbq_en <= 1'b0;
      for (int t = 0; t < 2; t++) begin
        fetch_pc[t] <= (t == 0) ? reset_pc0 : reset_pc1;
        fetch_thumb[t] <= 1'b0;
        cpsr_s[t] <= psr13({24'h0, 8'hD3});
        ib_v[t] <= 1'b0;
        ib1_v[t] <= 1'b0;
        ib_h[t] <= 1'b0;
        ustep[t] <= 2'd0;
        ll_v[t] <= 1'b0;
        halted[t] <= 1'b0;
        irq_r[t] <= 1'b0;
        rh[t] <= 1'b0;
        fiq_r[t] <= 1'b0;
        dwait_r[t] <= 1'b0;
        bl_v[t] <= 1'b0;
      end
    end else begin
      tid <= ~tid;
      // per-context state rotates: slot 0 holds te, slot 1 holds to; even
      // stages write slot 1 and odd stages slot 0 (the roles swap at the edge)
      fetch_pc[0] <= fetch_pc[1]; fetch_pc[1] <= fetch_pc[0];
      fetch_thumb[0] <= fetch_thumb[1]; fetch_thumb[1] <= fetch_thumb[0];
      cpsr_s[0] <= cpsr_s[1]; cpsr_s[1] <= cpsr_s[0];
      ib_h[0] <= ib_h[1]; ib_h[1] <= ib_h[0];
      ib_v[0] <= ib_v[1]; ib_v[1] <= ib_v[0];
      ib1_v[0] <= ib1_v[1]; ib1_v[1] <= ib1_v[0];
      ustep[0] <= ustep[1]; ustep[1] <= ustep[0];
      rl_rem[0] <= rl_rem[1]; rl_rem[1] <= rl_rem[0];
      rl_r[0] <= rl_r[1]; rl_r[1] <= rl_r[0];
      ll_v[0] <= ll_v[1]; ll_v[1] <= ll_v[0];
      ll_r[0] <= ll_r[1]; ll_r[1] <= ll_r[0];
      temp_addr[0] <= temp_addr[1]; temp_addr[1] <= temp_addr[0];
      temp_wb[0] <= temp_wb[1]; temp_wb[1] <= temp_wb[0];
      temp_c[0] <= temp_c[1]; temp_c[1] <= temp_c[0];
      temp_lz[0] <= temp_lz[1]; temp_lz[1] <= temp_lz[0];
      temp_st[0] <= temp_st[1]; temp_st[1] <= temp_st[0];
      temp_amt[0] <= temp_amt[1]; temp_amt[1] <= temp_amt[0];
      bl_v[0] <= bl_v[1]; bl_v[1] <= bl_v[0];
      bl_t[0] <= bl_t[1]; bl_t[1] <= bl_t[0];
      halted[1] <= (halted[0] || halt_req[c0]) && !(wake[c0] || fiq[c0]);
      halted[0] <= (halted[1] || halt_req[c1]) && !(wake[c1] || fiq[c1]);
      irq_r[1] <= irq[c0]; irq_r[0] <= irq[c1];
      rh[0] <= rh[1]; rh[1] <= rh[0];
      fiq_r[1] <= fiq[c0]; fiq_r[0] <= fiq[c1];
      dwait_r[1] <= d_wait[c0]; dwait_r[0] <= d_wait[c1];

      // ---- F (te): fetch, unless an even stage of te redirects this cycle
      f2_v <= fetch_en && !kill_e && !pd_br && !pd_rew && !(solo && wb_kill);
      f2_pc <= fetch_pc[0];
      f2_thumb <= fetch_thumb[0];
      if (fetch_en) fetch_pc[1] <= fetch_pc[0] + (fetch_thumb[0] ? 32'd2 : 32'd4);

      // ---- F2 (to): a fetch the memory could not answer is fetched again
      p_v <= f2_v && !wb_kill && !(solo && (kill_e || pd_br || pd_rew));
      p_ok <= i_ok;
      p_pc <= f2_pc;
      p_thumb <= f2_thumb;
      p_word <= i_rdata;
      p_pabt <= i_abort;
      p_ctr <= bp_q;

      // ---- PD (te)
      if (pd_br) begin
        fetch_pc[1] <= pd_tgt;
        fetch_thumb[1] <= pd_newt;
      end
      if (pd_go) begin
        bl_v[1] <= pd_bl1;
        if (pd_bl1) bl_t[1] <= pd_tgt;
      end
      if (pd_rew) begin
        fetch_pc[1] <= p_pc;
        fetch_thumb[1] <= p_thumb;
      end
      if (pd_go) begin
        if (ib_v[0]) ib1_v[1] <= 1'b1;
        else         ib_v[1] <= 1'b1;
      end

      // ---- D (to)
      e1 <= u;
      ll_v[0] <= have && !inject && u_ld;
      ll_r[0] <= u_ldr;
      if (have && !inject) begin
        rh[0] <= 1'b0;                      // the replayed instruction is issued again
        ustep[0] <= more ? nstep : 2'd0;
        rl_rem[0] <= nrl;
        rl_r[0] <= nrl_r;
        if (!more) begin                    // entry 1 moves up
          ib_h[0] <= !ib_h[1];
          ib_v[0] <= ib1_v[1];
          ib1_v[0] <= 1'b0;
        end
      end

      // ---- E1 (te)
      e2 <= e1;
      if (kill_e || (solo && wb_kill)) e2.valid <= 1'b0;
      e2_va <= (A9_OPT[8] && solo && wbq_en && !e1.a_pc && wbq_a == {1'b0, e1.ra}) ? wbq_d : e1_va;
      e2_vb <= (A9_OPT[8] && solo && wbq_en && !e1.b_pc && !e1.b_imm && wbq_a == {1'b0, e1.rb}) ? wbq_d : e1_vb;
      e2_vc <= (A9_OPT[8] && solo && wbq_en && !e1.c_pc && wbq_a == {1'b0, e1.rc}) ? wbq_d : e1_vc;
      e2_sa <= e1_sa;
      e2_f1a <= D1 && solo && d1n[2] && d1n[0];
      e2_f1b <= D1 && solo && d1n[2] && d1n[1];
      e2_lfa <= LDF && solo && ldn[3] && ldn[0];
      e2_lfb <= LDF && solo && ldn[3] && ldn[1];
      e2_lfc <= LDF && solo && ldn[3] && ldn[2];
      e2_sb <= e1_sb;
      e2_sc <= e1_sc;
      e2_s3 <= e1_s3;
      e2_rot <= e1_rot;
      e2_keep <= e1_keep;
      e2_fasr <= e1_fasr;
      e2_frrx <= e1_frrx;
      e2_csel <= e1_csel;

      // ---- E2 (to)
      e3 <= e2;
      if (wb_kill || (solo && kill_e)) e3.valid <= 1'b0;
      e3_a <= e2_a;
      e3_x <= e2_x;
      e3_y <= e2_y;
      e3_b <= sh_out;
      e3_c <= e2_c;
      if (LDF && (e2_lfa || e2_lfb || e2_lfc) && w_go && w_mem == MO_LOAD) begin
        if (e2_lfc) e3_c <= lw_val;
        if (e2_lfa) begin
          e3_a <= lw_val;
          case (e2.alu)
            AL_RSB, AL_RSC: e3_y <= ~lw_val;
            default:        e3_x <= lw_val;
          endcase
        end
        if (e2_lfb) begin
          e3_b <= lw_val;
          case (e2.alu)
            AL_SUB, AL_CMP, AL_SBC: e3_y <= ~lw_val;
            AL_RSB, AL_RSC:         e3_x <= lw_val;
            default:                e3_y <= lw_val;
          endcase
        end
      end
      if (D1 && e3_exec) begin
        if (e2_f1a) begin
          e3_a <= res;
          case (e2.alu)
            AL_RSB, AL_RSC: e3_y <= ~res;
            default:        e3_x <= res;
          endcase
        end
        if (e2_f1b) begin
          e3_b <= res;
          case (e2.alu)
            AL_SUB, AL_CMP, AL_SBC: e3_y <= ~res;
            AL_RSB, AL_RSC:         e3_x <= res;
            default:                e3_y <= res;
          endcase
        end
      end
      e3_shc <= sh_c;
      e3_shcold <= sh_cold;
      e3_qsat <= qsat_d;
      if (e2.valid && e2.amt_save) temp_amt[0] <= e2_c[7:0];

      // ---- E3 (te)
      if (e3_exec) begin
        if (e3.st_save) temp_st[1] <= e3_c;
        if (e3.wfi) halted[1] <= 1'b1;
        if (e3_cw) cpsr_s[1] <= e3_cv;
      end
      if (e3_rdr) begin
        fetch_pc[1] <= e3_newt ? {e3_tgt[31:1], 1'b0} : {e3_tgt[31:2], 2'b00};
        fetch_thumb[1] <= e3_newt;
      end

      w_valid    <= e3.valid && !x2_rdr;
      w_bp       <= e3.valid && !x2_rdr && e3.bp;
      w_bp_tk    <= e3_exec;
      w_bp_ctr   <= e3.bp_ctr;
      w_bp_bwd   <= e3.bp_bwd;
      w_exec     <= e3_exec;
      w_last     <= e3.last;
      w_pc       <= e3.pc;
      w_thumb    <= e3.thumb;
      w_step     <= e3.step;
      w_rl       <= e3.rl;
      w_rr       <= e3.rr;
      w_wen      <= e3.wen;
      w_wa       <= e3.wa;
      w_wpc      <= e3.wpc;
      w_rdalu    <= (e3.rdr == RD_ALU);
      w_restore  <= e3.restore && e3.wpc;
      w_msr      <= e3.msr;
      w_psr_spsr <= e3.psr_spsr;
      w_msr_mask <= e3.msr_mask;
      w_pct      <= e3.pct;
      w_mem      <= e3.mem;
      w_ld       <= (e3.mem == MO_LOAD) || (e3.mem == MO_CP && !e3.msigned);
      w_msize    <= e3.msize;
      w_msigned  <= e3.msigned;
      w_alo      <= e3.norot ? 2'b00 :
                    (e3.msize == MS_H && V5[c0]) ? {maddr[1], 1'b0} : maddr[1:0];
      w_res      <= res;
      w_mulw <= e3.mulw; w_macc <= e3.macc; w_acc <= e3_c; w_mulhi <= e3.mulhi;
      w_wd       <= (e3.wsrc == WS_LINK) ? e3.link :
                    (e3.wsrc == WS_TWB)  ? twb_f : res;
      w_flags    <= e3.flags;
      w_arith    <= alu_arith;
      w_c        <= alu_arith ? add_c : shc_res;
      w_v        <= add_v;
      w_q        <= ((e3.flags == FL_Q) && add_v) ||
                    ((e3.alu == AL_QADD || e3.alu == AL_QSUB) && (add_v || e3_qsat));
      w_tc       <= e3.tc_save;
      w_tc_val   <= add_c;
      w_z64      <= e3.z64;
      w_tsave    <= (e3.taddr != TA_NONE);
      w_twbsave  <= (e3.taddr == TA_BLOCK);
      case (e3.taddr)
        TA_NEXT:  w_tnext <= maddr + 32'd4;
        TA_BLOCK: w_tnext <= (e3.blk_u ? opa : sum33[31:0]) + (e3.blk_pu ? 32'd4 : 32'd0);
        default:  w_tnext <= maddr;
      endcase
      w_twb      <= sum33[31:0];

      // ---- WB (to)
      if (w_go) begin
        if (w_tsave) temp_addr[0] <= w_tnext;
        if (w_twbsave) temp_wb[0] <= w_twb;
        if (w_tc) begin
          temp_c[0] <= w_tc_val;
          temp_lz[0] <= (w_res == 32'h0);
        end
      end
      cpsr_s[0] <= psr13(w_n);
      if (wb_kill) begin
        fetch_pc[0] <= wb_newt ? {wb_tgt[31:1], 1'b0} : {wb_tgt[31:2], 2'b00};
        fetch_thumb[0] <= wb_newt;
        bl_v[0] <= 1'b0;
        ib_v[0] <= 1'b0;
        ib1_v[0] <= 1'b0;
        ll_v[0] <= 1'b0;
        ustep[0] <= 2'd0;
      end

      x_valid   <= w_valid && !(solo && x2_rdr);
      x_exec    <= w_go;
      x_replay  <= w_ismem && !d_ok;
      x_abort   <= w_ismem && d_ok && d_abort;
      x_last    <= w_last;
      x_pc      <= w_pc;
      x_thumb   <= w_thumb;
      x_step    <= w_step;
      x_rl      <= w_rl;
      x_rr      <= w_rr;
      x_restore <= w_restore;
      x_wen     <= w_wen;
      x_wa      <= w_wa;
      x_wd      <= w_wd;
      x_mulw    <= w_mulw; x_macc <= w_macc; x_acc <= w_acc; x_mulhi <= w_mulhi;
      x_ld      <= w_ld;
      x_wpc     <= w_wpc;
      x_pct     <= w_pct;
      x_msize   <= w_msize;
      x_msigned <= w_msigned;
      x_alo     <= w_alo;
      begin
        logic [1:0] a;
        logic       odd4;
        a = w_alo;
        odd4 = w_msize == MS_H && a[0] && !V5[c1];          // ARM7TDMI LDRH/LDRSH from an odd address
        for (int k = 0; k < 4; k++) begin ls_src[k] <= 2'(a + k); ls_mode[k] <= 2'd0; end   // word: rotated
        ls_sgn <= a;
        if (w_msize == MS_B || (odd4 && w_msigned)) begin   // a byte (signed or not)
          for (int k = 1; k < 4; k++) ls_mode[k] <= w_msigned ? 2'd1 : 2'd2;
        end else if (w_msize == MS_H && !odd4) begin        // the halfword at a[1]
          ls_src[0] <= {a[1], 1'b0}; ls_src[1] <= {a[1], 1'b1};
          ls_sgn <= {a[1], 1'b1};
          for (int k = 2; k < 4; k++) ls_mode[k] <= w_msigned ? 2'd1 : 2'd2;
        end else if (odd4) begin                            // unsigned, odd: {h[7:0], 16'h0, h[15:8]}
          ls_src[0] <= {a[1], 1'b1}; ls_src[3] <= {a[1], 1'b0};
          ls_mode[1] <= 2'd2; ls_mode[2] <= 2'd2;
        end
      end
      x_rdata   <= d_rdata;
      x_taddr   <= temp_addr[1];
      x_twb     <= temp_wb[1];
      x_tc      <= temp_c[1];
      x_tlz     <= temp_lz[1];

      // ---- WB2 (te)
      wbq_en <= rf_we;
      wbq_a  <= rf_wa;
      wbq_d  <= rf_wd;
      if (x2_rdr) begin
        fetch_pc[1] <= x2_newt ? {x2_tgt[31:1], 1'b0} : {x2_tgt[31:2], 2'b00};
        fetch_thumb[1] <= x2_newt;
        cpsr_s[1] <= psr13(x_cpsr);
      end
      if (kill_e) begin
        bl_v[1] <= 1'b0;
        ib_v[1] <= 1'b0;
        ib1_v[1] <= 1'b0;
        ustep[1] <= 2'd0;
        ll_v[1] <= 1'b0;
      end
      if (x2_rdr && (x_replay || x_abort)) begin
        temp_addr[1] <= x_taddr;
        temp_wb[1] <= x_twb;
        temp_c[1] <= x_tc;
        temp_lz[1] <= x_tlz;
      end
      if (x2_rdr && x_replay) begin
        rh[1] <= 1'b1;
        // D resumes at the replayed uop
        ustep[1] <= x_step;
        rl_rem[1] <= x_rl;
        rl_r[1] <= x_rr;
      end

      // ---- solo (A9_SOLO; docs/arm-pipeline.md): overrides the rotation above
      if (A9_SOLO) begin
        logic        drained7, done9, a7go;
        logic [31:0] npc, ta, tw, bt;
        logic        nth, nlv, nrh, tcc, tlz, bv, hn;
        logic [12:0] nc, wn;
        logic [1:0]  nu, ih;
        logic [15:0] nrr;
        logic [3:0]  nr, nlr;
        logic [2:0]  in;
        logic [31:0] tst;
        logic [7:0]  tam;
        // the ARM7 (te now: all its work is in the even stages) has left the
        // pipeline and does not run
        drained7 = te && ((halted[0] && !(wake[1] || fiq[1])) || !run[1] || (park_req && !f2_v)) && !ib_v[0] && !ib1_v[0] &&
                   !p_v && !e1.valid && !e3.valid && !x_valid && !rh[0] && !dwait_r[0] &&
                   ustep[0] == 2'd0 && !bl_v[0] && !ll_v[0];            // (the ARM7 between instructions: this state is not parked)
        done9 = ib4_n == 3'd0 && !f2_v && !p_v && !e1.valid && !e2.valid && !e3.valid &&
                !w_valid && !x_valid && !se_v && !sa_v;
        a7go = run[1] && (pk_burst ? (s_cnt >= 9'(BS) || irq[1] || fiq[1] || wake[1]) : (!pk_halt || wake[1] || fiq[1]));
        solo_e <= !SOLO_ONLY && !solo && !solo_e && drained7;
        if (!solo && !solo_e && drained7) begin
          pk_pc <= fetch_pc[0]; pk_thumb <= fetch_thumb[0]; pk_cpsr <= cpsr_s[0];
          pk_halt <= halted[0] && !(wake[1] || fiq[1]);
          pk_burst <= park_req && !halted[0] && run[1];
        end
        if (solo || solo_e) r_cnt <= 9'd0; else if (r_cnt != 9'h1FF) r_cnt <= r_cnt + 9'd1;
        if (solo) begin if (s_cnt != 9'h1FF) s_cnt <= s_cnt + 9'd1; end else s_cnt <= 9'd0;
        if (solo_e) solo_r <= 1'b1;
        if (solo) begin
          if (wake[1] || fiq[1]) pk_halt <= 1'b0;
          if (a7go && !SOLO_ONLY) solo_x <= 1'b1;
        end

        if (solo || solo_e) begin
          // the fetch address: the oldest redirect wins
          npc = fetch_pc[0]; nth = fetch_thumb[0];
          if (fetch_en) npc = fetch_pc[0] + (fetch_thumb[0] ? 32'd2 : 32'd4);
          if (pd_br) begin npc = pd_tgt; nth = pd_newt; end
          if (pd_rew) begin npc = p_pc; nth = p_thumb; end
          if (e3_rdr) begin npc = e3_newt ? {e3_tgt[31:1], 1'b0} : {e3_tgt[31:2], 2'b00}; nth = e3_newt; end
          if (solo && wb_kill) begin npc = wb_newt ? {wb_tgt[31:1], 1'b0} : {wb_tgt[31:2], 2'b00}; nth = wb_newt; end
          if (x2_rdr) begin npc = x2_newt ? {x2_tgt[31:1], 1'b0} : {x2_tgt[31:2], 2'b00}; nth = x2_newt; end
          fetch_pc[0] <= npc; fetch_pc[1] <= npc; fetch_thumb[0] <= nth; fetch_thumb[1] <= nth;
          // CPSR: E3's write, then the bits WB changed (the older uop), then WB2
          nc = e3_cw ? e3_cv : cpsr_s[0];
          wn = psr13(w_n);
          if (solo) nc = (nc & ~(cpsr_s[0] ^ wn)) | (wn & (cpsr_s[0] ^ wn));
          if (x2_rdr) nc = psr13(x_cpsr);
          cpsr_s[0] <= nc; cpsr_s[1] <= nc;
          // instruction buffer
          if (solo_e) begin
            ib4_h <= 2'd0; ib4_x <= ib_h[0];
            ib4_n <= kill_e ? 3'd0 : {2'b00, ib_v[0]} + {2'b00, ib1_v[0]} + {2'b00, pd_go};
          end else begin
            ih = ib4_h; in = ib4_n;
            if (have && !inject && !more) begin ih = ih + 2'd1; in = in - 3'd1; end
            if (pd_go) in = in + 3'd1;
            if (kill_e || wb_kill) in = 3'd0;
            ib4_h <= ih; ib4_n <= in;
          end
          // D's state
          nu = ustep[0]; nrr = rl_rem[0]; nr = rl_r[0]; nlv = ll_v[0]; nlr = ll_r[0]; nrh = rh[0];
          if (solo) begin
            nlv = have && !inject && u_ld; nlr = u_ldr;
            if (have && !inject) begin nrh = 1'b0; nu = more ? nstep : 2'd0; nrr = nrl; nr = nrl_r; end
            if (wb_kill) begin nu = 2'd0; nlv = 1'b0; end
          end
          if (kill_e) begin nu = 2'd0; nlv = 1'b0; end
          if (x2_rdr && x_replay) begin nrh = 1'b1; nu = x_step; nrr = x_rl; nr = x_rr; end
          ustep[0] <= nu; ustep[1] <= nu; rl_rem[0] <= nrr; rl_rem[1] <= nrr; rl_r[0] <= nr; rl_r[1] <= nr;
          ll_v[0] <= nlv; ll_v[1] <= nlv; ll_r[0] <= nlr; ll_r[1] <= nlr; rh[0] <= nrh; rh[1] <= nrh;
          // temporaries
          ta = temp_addr[0]; tw = temp_wb[0]; tcc = temp_c[0]; tlz = temp_lz[0]; tst = temp_st[0]; tam = temp_amt[0];
          if (solo) begin
            if (w_go && w_tsave) ta = w_tnext;
            if (w_go && w_twbsave) tw = w_twb;
            if (w_go && w_tc) begin tcc = w_tc_val; tlz = (w_res == 32'h0); end
            if (e2.valid && e2.amt_save) tam = e2_c[7:0];
          end
          if (e3_exec && e3.st_save) tst = e3_c;
          if (x2_rdr && (x_replay || x_abort)) begin ta = x_taddr; tw = x_twb; tcc = x_tc; tlz = x_tlz; end
          temp_addr[0] <= ta; temp_addr[1] <= ta; temp_wb[0] <= tw; temp_wb[1] <= tw;
          temp_c[0] <= tcc; temp_c[1] <= tcc; temp_lz[0] <= tlz; temp_lz[1] <= tlz;
          temp_st[0] <= tst; temp_st[1] <= tst; temp_amt[0] <= tam; temp_amt[1] <= tam;
          // Thumb BL prefix
          bv = bl_v[0]; bt = bl_t[0];
          if (pd_go) begin bv = pd_bl1; if (pd_bl1) bt = pd_tgt; end
          if ((solo && wb_kill) || kill_e) bv = 1'b0;
          bl_v[0] <= bv; bl_v[1] <= bv; bl_t[0] <= bt; bl_t[1] <= bt;
          // halt, interrupts
          hn = (halted[0] || halt_req[0]) && !(wake[0] || fiq[0]);
          if (e3_exec && e3.wfi) hn = 1'b1;
          halted[0] <= hn; halted[1] <= hn;
          irq_r[0] <= irq[0]; irq_r[1] <= irq[0]; fiq_r[0] <= fiq[0]; fiq_r[1] <= fiq[0];
          dwait_r[0] <= d_wait[0]; dwait_r[1] <= d_wait[0];
        end

        // leave: the ARM9 has drained; it takes the slot of the next te or to,
        // the ARM7 the other one, from the parking register
        if (solo && solo_x && done9) begin
          solo_r <= 1'b0; solo_x <= 1'b0;
          for (int k = 0; k < 2; k++) if (k[0] == tid) begin      // slot 0 belongs to the next te (~tid): the ARM7's is slot tid
            fetch_pc[k] <= pk_pc; fetch_thumb[k] <= pk_thumb; cpsr_s[k] <= pk_cpsr;
            halted[k] <= pk_halt && !(wake[1] || fiq[1]);
            ustep[k] <= 2'd0; ll_v[k] <= 1'b0; bl_v[k] <= 1'b0; rh[k] <= 1'b0;
            irq_r[k] <= irq[1]; fiq_r[k] <= fiq[1]; dwait_r[k] <= d_wait[1];
          end
          ib_v[0] <= 1'b0; ib_v[1] <= 1'b0; ib1_v[0] <= 1'b0; ib1_v[1] <= 1'b0;
        end
      end
    end
  end

`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $test$plusargs)
`ifndef SYNTHESIS
  // simulation (+solostat): clock cycles, solo cycles and the ARM7's idle
  // cycles (halted or not running), printed at the end of the run
  longint st_cyc = 0, st_solo = 0, st_idle7 = 0;
  always_ff @(posedge clk) begin
    st_cyc  <= st_cyc + 1;
    st_solo <= st_solo + (solo ? 1 : 0);
    st_idle7 <= st_idle7 + ((solo || !run[1] || (te ? halted[0] : halted[1])) ? 1 : 0);
  end
  final if ($test$plusargs("solostat") && st_cyc != 0)
    $display("solostat: %0d cycles, solo %0d (%.1f%%), ARM7 idle %0d (%.1f%%)", st_cyc,
             st_solo, 100.0 * st_solo / st_cyc, st_idle7, 100.0 * st_idle7 / st_cyc);
`endif
`endif

  // halted per CPU: slot 0 is te's context (te = 1: the ARM7)
  assign dbg_halt = te ? {halted[0], halted[1]} : {halted[1], halted[0]};


`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
  // simulation (+hzstat): load-use holds on the ARM9 that the exact check would not make
  longint hz_n = 0, hz_spur = 0, hz_t = 0;
  int hz_from = 0; initial if (!$value$plusargs("a9from=%d", hz_from)) hz_from = 0;
  always_ff @(posedge clk) if ($test$plusargs("hzstat")) begin
    hz_t <= hz_t + 1;
    if (hz_t >= longint'(hz_from) && ib_v[1] && c_kind == TK_ARM) begin
      if (hz_old) hz_n <= hz_n + 1;
      if (hz_old && !hz_new) hz_spur <= hz_spur + 1;
    end
  end
  final if ($test$plusargs("hzstat")) $display("hzstat: load-use holds %0d, of them not a true read (ARM) %0d", hz_n, hz_spur);
`endif
`endif

`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
  // simulation (+solocause): in solo, how often each issue rule holds a valid uop in D, alone and in all
  longint sc_n = 0, sc_any = 0, sc_all [0:8], sc_alone [0:8];
  initial for (int i = 0; i < 9; i++) begin sc_all[i] = 0; sc_alone[i] = 0; end
  int sc_from = 0; initial if (!$value$plusargs("a9from=%d", sc_from)) sc_from = 0;
  longint sc_t = 0;
  always_ff @(posedge clk) if ($test$plusargs("solocause")) begin
    sc_t <= sc_t + 1;
    if (solo && ib4_n != 3'd0 && !wb_kill && !hazard && !kill_e && !inject && sc_t >= longint'(sc_from)) begin
      sc_n <= sc_n + 1;
      if (sb_cause != 9'd0) begin
        sc_any <= sc_any + 1;
        for (int i = 0; i < 9; i++) if (sb_cause[i]) begin
          sc_all[i] <= sc_all[i] + 1;
          if (sb_cause == (9'd1 << i)) sc_alone[i] <= sc_alone[i] + 1;
        end
      end
    end
  end
  final if ($test$plusargs("solocause") && sc_n != 0)
    $display("solocause: solo uops at D %0d, held %0d | all/alone: exc %0d/%0d, multi %0d/%0d, mem2 %0d/%0d, alu-pc %0d/%0d, psr %0d/%0d, load-use %0d/%0d, d5 %0d/%0d, d3 %0d/%0d, d1 %0d/%0d",
             sc_n, sc_any, sc_all[0], sc_alone[0], sc_all[1], sc_alone[1], sc_all[2], sc_alone[2], sc_all[3], sc_alone[3], sc_all[4], sc_alone[4],
             sc_all[5], sc_alone[5], sc_all[6], sc_alone[6], sc_all[7], sc_alone[7], sc_all[8], sc_alone[8]);
`endif
`endif

endmodule
