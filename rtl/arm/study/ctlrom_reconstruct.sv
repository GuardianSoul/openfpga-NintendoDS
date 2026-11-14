module ctlrom_reconstruct import arm_pkg::*; (input logic[31:0]c_ins,h_pc,c_bl2t,
 input logic[15:0]f_hw,rl_rem,
 input logic[4:0]c_cls,mode_in,
 input logic[3:0]rl_r,
 input logic[2:0]c_kind,
 input logic[1:0]ustep,
 input logic h_th,h_ab,h_v,qpa,c_bl2,take_fiq,take_irq,hivec,
input logic[300:0]shape,input logic[23:0]route,output logic[300:0]packet);
  localparam logic [2:0] TK_ARM = 3'd0, TK_B = 3'd1, TK_BL1 = 3'd2, TK_BL2 = 3'd3,
                         TK_BLX2 = 3'd4, TK_UND = 3'd5;
  localparam logic [4:0] C_DP = 5'd0, C_MRS = 5'd1, C_MSR = 5'd2, C_MUL = 5'd3, C_MULL = 5'd4,
                         C_SWP = 5'd5, C_HW = 5'd6, C_BX = 5'd7, C_BLXR = 5'd8, C_CLZ = 5'd9,
                         C_QOP = 5'd10, C_SMUL = 5'd11, C_BKPT = 5'd12, C_SDT = 5'd13,
                         C_BLK = 5'd14, C_B = 5'd15, C_BLXI = 5'd16, C_SWI = 5'd17, C_CP = 5'd18,
                         C_UND = 5'd19, C_NOP = 5'd20, C_TBR = 5'd21;
  localparam logic [2:0] CS_OLD = 3'd0, CS_R0 = 3'd1, CS_R31 = 3'd2, CS_X31 = 3'd3, CS_ZERO = 3'd4;

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

logic[31:0]cpsr,c_tgt;logic[1:0]hivecs;logic[0:0]q_pa;
assign cpsr={27'd0,mode_in};assign hivecs={1'b0,hivec};assign q_pa={qpa};
logic more;logic[1:0]nstep;logic[15:0]nrl;logic[3:0]nrl_r;
assign nrl_r = (ustep == 2'd0) ? ((c_ins[15:0] == 16'h0) ? 4'd15 : lowest16(c_ins[15:0])) :
                 (rl_rem == 16'h8000) ? 4'd15 : lowest16(rl_rem & ~(16'h1 << rl_r));
always_comb begin
 logic[31:0]off;
 if(h_th)begin
  if(f_hw[15:11]==5'b11100)off={{20{f_hw[10]}},f_hw[10:0],1'b0};
  else if(f_hw[15:11]==5'b11110)off={{9{f_hw[10]}},f_hw[10:0],12'b0};
  else off={{23{f_hw[7]}},f_hw[7:0],1'b0};
 end else off={{6{c_ins[23]}},c_ins[23:0],(c_ins[31:25]==7'b1111101)&c_ins[24],1'b0};
 c_tgt=h_pc+(h_th?32'd4:32'd8)+off;
end
uop9_t u,u0;

always_comb begin
 logic[31:0]pc8,link4,immv,linkv;logic[4:0]bank;logic[3:0]wr;logic[4:0]cnt;logic[31:0]evec;
 u=uop9_t'(shape);pc8=h_pc+(h_th?32'd4:32'd8);link4=h_pc+(h_th?32'd2:32'd4);
 cnt=c_ins[15:0]==0?5'd16:popcnt16(c_ins[15:0]);
 evec=(h_ab?32'h0c:take_fiq?32'h1c:take_irq?32'h18:(c_cls==C_SWI?32'h08:c_cls==C_BKPT?32'h0c:32'h04));
 immv=0;
 case(route[3:0])
  1:immv={24'd0,c_ins[7:0]};2:immv={24'd0,c_ins[11:8],c_ins[3:0]};3:immv={20'd0,c_ins[11:0]};
  4:immv={25'd0,cnt,2'b0};5:immv=c_tgt;6:immv={20'd0,c_ins[10:0],1'b0};7:immv=c_bl2t;
  8:immv=(hivec?32'hffff0000:32'd0)+evec;
  default:;
 endcase
 linkv=0;
 case(route[6:4])
  1:linkv=link4;2:linkv=c_tgt;3:linkv=link4|32'd1;4:linkv=h_th?(link4|32'd1):link4;5:linkv=h_pc+32'd4;default:;
 endcase
 wr=0;
 case(route[14:12])
  1:wr=c_ins[15:12];2:wr=c_ins[19:16];3:wr=ustep==1?c_ins[15:12]:{c_ins[15:13],1'b1};4:wr=rl_r;5:wr=4'he;default:;
 endcase
 bank=route[16:15]==1?mode_in:route[16:15]==2?route[23:19]:M_USR;
 u.pc=h_pc;u.pcv=0;
 if(route[8:7]==1)u.pcv=qpa?{pc8[31:2],2'b0}:pc8;
 else if(route[8:7]==2)u.pcv=h_pc+32'd12;
 u.pcv_c=route[9]?h_pc+32'd12:32'd0;
 u.imm=immv;u.link=linkv;u.cond=route[11:10]==1?c_ins[31:28]:route[11:10]==2?4'he:route[11:10]==3?4'hf:4'd0;
 u.wa=phys_reg(wr,bank);u.lw=wr;u.cp_op=route[18]?{2'b00,c_ins[23:21],c_ins[19:16],c_ins[3:0],c_ins[7:5]}:16'd0;
 u.msr_mask=route[17]?c_ins[19:16]:4'd0;u.exc_mode=route[23:19];
end
assign packet=u;
endmodule
