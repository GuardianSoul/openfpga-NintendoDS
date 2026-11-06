// Shared definitions for the two-context ARM pipeline (docs/arm-pipeline.md).
package arm_pkg;

  // Processor modes
  localparam logic [4:0] M_USR = 5'h10, M_FIQ = 5'h11, M_IRQ = 5'h12, M_SVC = 5'h13,
                         M_ABT = 5'h17, M_UND = 5'h1B, M_SYS = 5'h1F;

  // ALU operations. 0..15 are the ARM data-processing opcodes.
  localparam logic [4:0] AL_AND = 5'd0,  AL_EOR = 5'd1,  AL_SUB = 5'd2,  AL_RSB = 5'd3,
                         AL_ADD = 5'd4,  AL_ADC = 5'd5,  AL_SBC = 5'd6,  AL_RSC = 5'd7,
                         AL_TST = 5'd8,  AL_TEQ = 5'd9,  AL_CMP = 5'd10, AL_CMN = 5'd11,
                         AL_ORR = 5'd12, AL_MOV = 5'd13, AL_BIC = 5'd14, AL_MVN = 5'd15,
                         AL_CLZ = 5'd16, AL_QADD = 5'd17, AL_QSUB = 5'd18, AL_PSR = 5'd19;

  // Shifter types
  localparam logic [2:0] SH_LSL = 3'd0, SH_LSR = 3'd1, SH_ASR = 3'd2, SH_ROR = 3'd3, SH_RRX = 3'd4;

  // Flag update modes
  localparam logic [1:0] FL_NONE = 2'd0, FL_DP = 2'd1, FL_NZ = 2'd2, FL_Q = 2'd3;

  // Operand A / B sources
  localparam logic [1:0] OA_REG = 2'd0, OA_TADDR = 2'd1, OA_ZERO = 2'd2;
  localparam logic [1:0] OB_SH = 2'd0, OB_PLO = 2'd1, OB_PHI = 2'd2;

  // Register write source
  localparam logic [1:0] WS_ALU = 2'd0, WS_LINK = 2'd1, WS_TWB = 2'd2, WS_MEM = 2'd3;

  // Memory operation / address source
  localparam logic [1:0] MO_NONE = 2'd0, MO_LOAD = 2'd1, MO_STORE = 2'd2, MO_CP = 2'd3;
  localparam logic [1:0] MA_SUM = 2'd0, MA_A = 2'd1, MA_TADDR = 2'd2;
  localparam logic [1:0] MS_B = 2'd0, MS_H = 2'd1, MS_W = 2'd2;

  // temp_addr update
  localparam logic [1:0] TA_NONE = 2'd0, TA_ADDR = 2'd1, TA_NEXT = 2'd2, TA_BLOCK = 2'd3;

  // Thumb state after a PC write
  localparam logic [1:0] PT_KEEP = 2'd0, PT_DATA0 = 2'd1, PT_ARM = 2'd2;

  // Redirect taken in E3 when the condition passes: to the ALU result, to imm
  // (branch target, exception vector) or to link (the next instruction: flush)
  localparam logic [1:0] RD_NONE = 2'd0, RD_ALU = 2'd1, RD_IMM = 2'd2, RD_LINK = 2'd3;

  // Multiplier kinds
  localparam logic [1:0] MK_32 = 2'd0, MK_XY = 2'd1, MK_WY = 2'd2;

  // One micro-op, built in D and executed in E1-E3/WB. The condition is
  // checked in E3; a uop whose condition fails has no side effects.
  typedef struct packed {
    logic        valid;     // occupies a pipeline slot (retire trace)
    logic [3:0]  cond;
    logic        last;      // last uop of the instruction
    logic        thumb;     // instruction was fetched in Thumb state
    logic [31:0] pc;        // instruction address
    logic [31:0] pcv;       // value read for r15 on ports A/B
    logic [31:0] pcv_c;     // value read for r15 on port C (stored PC)
    logic [4:0]  ra, rb, rc;// physical register (per context) for the read ports
    logic        a_pc, b_pc, c_pc;
    logic [1:0]  a_sel;
    logic [1:0]  b_sel;
    logic        b_imm;
    logic [31:0] imm;
    logic [2:0]  sh_type;
    logic        sh_reg;    // shift amount from temp_amt (register-specified shift)
    logic        amt_save;  // temp_amt <= port C [7:0]
    logic [7:0]  sh_amt;
    logic [4:0]  alu;
    logic        qdbl;      // QDADD/QDSUB: saturate 2*Rn first
    logic [1:0]  flags;
    logic        cin_tc;    // carry-in from temp_c (long multiply high half)
    logic        tc_save;   // save carry and zero of the low half
    logic        z64;       // Z covers the saved low half too
    logic        wen;
    logic [4:0]  wa;
    logic [1:0]  wsrc;
    logic        wpc;       // loaded data goes to the PC (redirect in WB)
    logic [1:0]  rdr;       // redirect in E3 (RD_*)
    logic        pred;      // branch predicted taken in PD: redirect to link if the condition fails
    logic        bp;        // conditional branch: update the direction predictor
    logic [1:0]  bp_ctr;    // its counter as read in PD (backward-taken default folded in)
    logic        bp_bwd;    // backward branch
    logic [1:0]  pct;
    logic [31:0] link;
    logic [1:0]  mem;
    logic [1:0]  msize;
    logic        msigned;   // signed load; for MO_CP: MCR
    logic        norot;     // word load without rotation (LDM, LDRD)
    logic [1:0]  maddr;
    logic [1:0]  taddr;
    logic        blk_pu;    // block start is one word above the lowest address
    logic        blk_u;
    logic        blkm;      // a uop of LDM/STM (MEM1: back to back, the temporaries forwarded from WB)
    logic        st_save;   // E3 keeps port C (store data) in temp_st (SWP)
    logic        st_temp;   // store data comes from temp_st (SWP)
    logic        mul_start;
    logic [1:0]  mul_kind;
    logic        mul_signed;
    logic        mul_xh, mul_yh;
    logic        mulw;      // MULW: one uop; the product (+ the accumulator) is written in WB2
    logic        mulhi;     // MLONG: the second half (the product's high word)
    logic        macc;      // ... with the accumulator on port C
    logic        psr_spsr;  // MRS/MSR act on the SPSR
    logic        msr;
    logic [3:0]  msr_mask;
    logic        restore;   // CPSR <= SPSR
    logic        exc;       // exception entry
    logic [4:0]  exc_mode;
    logic        exc_f;
    logic        set_thumb; // BLX immediate
    logic        clr_thumb; // Thumb BLX suffix redirected in PD
    logic [15:0] cp_op;     // {2'b0, opc1[2:0], CRn, CRm, opc2[2:0]} for MCR/MRC
    logic        wfi;       // MCR p15 wait-for-interrupt: halt after this uop
    // D's sequencer position when this uop was issued, restored when the uop
    // is replayed (memory not ready)
    logic [1:0]  step;
    logic [15:0] rl;
    logic [3:0]  rr;
  } uop_t;

  function automatic logic [4:0] phys_reg(input logic [3:0] r, input logic [4:0] mode);
    // r0-r7 shared; r8-r12 banked for FIQ; r13-r14 banked per privileged mode.
    // Index 15 is never written (the PC lives outside the register file), 31 unused.
    logic [4:0] p;
    p = {1'b0, r};
    if (r >= 4'd8 && r <= 4'd14 && mode == M_FIQ) p = 5'd16 + {1'b0, r} - 5'd8;
    else if (r == 4'd13 || r == 4'd14) begin
      case (mode)
        M_IRQ: p = (r == 4'd13) ? 5'd23 : 5'd24;
        M_SVC: p = (r == 4'd13) ? 5'd25 : 5'd26;
        M_ABT: p = (r == 4'd13) ? 5'd27 : 5'd28;
        M_UND: p = (r == 4'd13) ? 5'd29 : 5'd30;
        default: ;
      endcase
    end
    return p;
  endfunction

  function automatic logic cond_pass(input logic [3:0] c, input logic [3:0] nzcv);
    logic n, z, cc, v;
    {n, z, cc, v} = nzcv;
    case (c)
      4'h0: return z;
      4'h1: return !z;
      4'h2: return cc;
      4'h3: return !cc;
      4'h4: return n;
      4'h5: return !n;
      4'h6: return v;
      4'h7: return !v;
      4'h8: return cc && !z;
      4'h9: return !cc || z;
      4'hA: return n == v;
      4'hB: return n != v;
      4'hC: return !z && (n == v);
      4'hD: return z || (n != v);
      4'hE: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic valid_mode(input logic [4:0] m);
    return m == M_USR || m == M_FIQ || m == M_IRQ || m == M_SVC ||
           m == M_ABT || m == M_UND || m == M_SYS;
  endfunction

  // SPSR bank index; 7 means "no SPSR" (USR/SYS)
  function automatic logic [2:0] spsr_idx(input logic [4:0] m);
    case (m)
      M_FIQ: return 3'd0;
      M_IRQ: return 3'd1;
      M_SVC: return 3'd2;
      M_ABT: return 3'd3;
      M_UND: return 3'd4;
      default: return 3'd7;
    endcase
  endfunction

endpackage
