// Thumb -> ARM expansion. Every Thumb instruction except the branches maps
// onto an ARM encoding with the same behaviour, so the ARM decoder handles
// both states. Branches come out as a kind plus a ready-made offset (the BL
// and BLX suffixes also keep their 11-bit offset in arm[10:0]).
module arm_thumb (
  input  logic [15:0] hw,
  input  logic        v5,
  output logic [31:0] arm,
  output logic [2:0]  kind,     // TK_* below
  output logic [31:0] boff,     // branch offset, or BL prefix value
  output logic        pcalign   // r15 reads as (PC+4) & ~3
);
  localparam logic [2:0] TK_ARM = 3'd0, TK_B = 3'd1, TK_BL1 = 3'd2, TK_BL2 = 3'd3,
                         TK_BLX2 = 3'd4, TK_UND = 3'd5;

  localparam logic [3:0] OP_AND = 4'h0, OP_EOR = 4'h1, OP_SUB = 4'h2, OP_RSB = 4'h3,
                         OP_ADD = 4'h4, OP_ADC = 4'h5, OP_SBC = 4'h6, OP_TST = 4'h8,
                         OP_CMP = 4'hA, OP_CMN = 4'hB, OP_ORR = 4'hC, OP_MOV = 4'hD,
                         OP_BIC = 4'hE, OP_MVN = 4'hF;

  function automatic logic [31:0] dp_rs(input logic [3:0] op, input logic s, input logic [3:0] rn,
                                        input logic [3:0] rd, input logic [3:0] rm,
                                        input logic [1:0] ty, input logic [4:0] sh);
    return {4'hE, 3'b000, op, s, rn, rd, sh, ty, 1'b0, rm};
  endfunction
  function automatic logic [31:0] dp_rr(input logic [3:0] op, input logic [3:0] rd,
                                        input logic [3:0] rs, input logic [1:0] ty,
                                        input logic [3:0] rm);
    return {4'hE, 3'b000, op, 1'b1, 4'h0, rd, rs, 1'b0, ty, 1'b1, rm};
  endfunction
  function automatic logic [31:0] dp_i(input logic [3:0] op, input logic s, input logic [3:0] rn,
                                       input logic [3:0] rd, input logic [3:0] rot,
                                       input logic [7:0] imm);
    return {4'hE, 3'b001, op, s, rn, rd, rot, imm};
  endfunction

  logic [3:0] rd, rs, rb;
  logic [3:0] hrd, hrs;

  always_comb begin
    arm = 32'h0;
    kind = TK_ARM;
    boff = 32'h0;
    pcalign = 1'b0;
    rd = {1'b0, hw[2:0]};
    rs = {1'b0, hw[5:3]};
    rb = {1'b0, hw[5:3]};
    hrd = {hw[7], hw[2:0]};
    hrs = {hw[6], hw[5:3]};

    case (hw[15:13])
      3'b000: begin
        if (hw[12:11] != 2'b11)            // LSL/LSR/ASR Rd, Rs, #imm
          arm = dp_rs(OP_MOV, 1'b1, 4'h0, rd, rs, hw[12:11], hw[10:6]);
        else if (hw[10])                   // ADD/SUB Rd, Rs, #imm3
          arm = dp_i(hw[9] ? OP_SUB : OP_ADD, 1'b1, rs, rd, 4'h0, {5'b0, hw[8:6]});
        else                               // ADD/SUB Rd, Rs, Rn
          arm = dp_rs(hw[9] ? OP_SUB : OP_ADD, 1'b1, rs, rd, {1'b0, hw[8:6]}, 2'b00, 5'd0);
      end
      3'b001: begin                        // MOV/CMP/ADD/SUB Rd, #imm8
        case (hw[12:11])
          2'b00: arm = dp_i(OP_MOV, 1'b1, 4'h0, {1'b0, hw[10:8]}, 4'h0, hw[7:0]);
          2'b01: arm = dp_i(OP_CMP, 1'b1, {1'b0, hw[10:8]}, 4'h0, 4'h0, hw[7:0]);
          2'b10: arm = dp_i(OP_ADD, 1'b1, {1'b0, hw[10:8]}, {1'b0, hw[10:8]}, 4'h0, hw[7:0]);
          default: arm = dp_i(OP_SUB, 1'b1, {1'b0, hw[10:8]}, {1'b0, hw[10:8]}, 4'h0, hw[7:0]);
        endcase
      end
      3'b010: begin
        if (hw[12:10] == 3'b000) begin
          begin
            case (hw[9:6])                 // ALU operations
              4'h0: arm = dp_rs(OP_AND, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              4'h1: arm = dp_rs(OP_EOR, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              4'h2: arm = dp_rr(OP_MOV, rd, rs, 2'b00, rd);
              4'h3: arm = dp_rr(OP_MOV, rd, rs, 2'b01, rd);
              4'h4: arm = dp_rr(OP_MOV, rd, rs, 2'b10, rd);
              4'h5: arm = dp_rs(OP_ADC, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              4'h6: arm = dp_rs(OP_SBC, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              4'h7: arm = dp_rr(OP_MOV, rd, rs, 2'b11, rd);
              4'h8: arm = dp_rs(OP_TST, 1'b1, rd, 4'h0, rs, 2'b00, 5'd0);
              4'h9: arm = dp_i(OP_RSB, 1'b1, rs, rd, 4'h0, 8'h00);
              4'hA: arm = dp_rs(OP_CMP, 1'b1, rd, 4'h0, rs, 2'b00, 5'd0);
              4'hB: arm = dp_rs(OP_CMN, 1'b1, rd, 4'h0, rs, 2'b00, 5'd0);
              4'hC: arm = dp_rs(OP_ORR, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              4'hD: arm = {4'hE, 7'b0000000, 1'b1, rd, 4'h0, rs, 4'b1001, rd};
              4'hE: arm = dp_rs(OP_BIC, 1'b1, rd, rd, rs, 2'b00, 5'd0);
              default: arm = dp_rs(OP_MVN, 1'b1, 4'h0, rd, rs, 2'b00, 5'd0);
            endcase
          end
        end else if (hw[12:10] == 3'b001) begin // hi-register ops, BX/BLX
          case (hw[9:8])
            2'b00: arm = dp_rs(OP_ADD, 1'b0, hrd, hrd, hrs, 2'b00, 5'd0);
            2'b01: arm = dp_rs(OP_CMP, 1'b1, hrd, 4'h0, hrs, 2'b00, 5'd0);
            2'b10: arm = dp_rs(OP_MOV, 1'b0, 4'h0, hrd, hrs, 2'b00, 5'd0);
            default: arm = (hw[7] && v5) ? (32'hE12FFF30 | {28'h0, hrs})
                                         : (32'hE12FFF10 | {28'h0, hrs});
          endcase
        end else if (hw[12:11] == 2'b01) begin  // LDR Rd, [PC, #imm]
          arm = {4'hE, 3'b010, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 4'hF, {1'b0, hw[10:8]}, 2'b00, hw[7:0], 2'b00};
          pcalign = 1'b1;
        end else if (!hw[9]) begin              // LDR/STR{B} Rd, [Rb, Ro]
          arm = {4'hE, 3'b011, 1'b1, 1'b1, hw[10], 1'b0, hw[11], rb, rd, 7'b0, 1'b0, {1'b0, hw[8:6]}};
        end else begin                          // STRH/LDRH/LDSB/LDSH Rd, [Rb, Ro]
          case ({hw[10], hw[11]})               // {S, H}
            2'b00: arm = {4'hE, 3'b000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, rb, rd, 4'h0, 4'b1011, {1'b0, hw[8:6]}};
            2'b01: arm = {4'hE, 3'b000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, rb, rd, 4'h0, 4'b1011, {1'b0, hw[8:6]}};
            2'b10: arm = {4'hE, 3'b000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, rb, rd, 4'h0, 4'b1101, {1'b0, hw[8:6]}};
            default: arm = {4'hE, 3'b000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, rb, rd, 4'h0, 4'b1111, {1'b0, hw[8:6]}};
          endcase
        end
      end
      3'b011: begin                        // LDR/STR{B} Rd, [Rb, #imm]
        arm = {4'hE, 3'b010, 1'b1, 1'b1, hw[12], 1'b0, hw[11], rb, rd,
               hw[12] ? {7'b0, hw[10:6]} : {5'b0, hw[10:6], 2'b00}};
      end
      3'b100: begin
        if (!hw[12]) begin                 // STRH/LDRH Rd, [Rb, #imm]
          arm = {4'hE, 3'b000, 1'b1, 1'b1, 1'b1, 1'b0, hw[11], rb, rd,
                 2'b00, hw[10:9], 4'b1011, hw[8:6], 1'b0};
        end else begin                     // LDR/STR Rd, [SP, #imm]
          arm = {4'hE, 3'b010, 1'b1, 1'b1, 1'b0, 1'b0, hw[11], 4'hD, {1'b0, hw[10:8]}, 2'b00, hw[7:0], 2'b00};
        end
      end
      3'b101: begin
        if (!hw[12]) begin                 // ADD Rd, PC/SP, #imm
          arm = dp_i(OP_ADD, 1'b0, hw[11] ? 4'hD : 4'hF, {1'b0, hw[10:8]}, 4'hF, hw[7:0]);
          pcalign = !hw[11];
        end else if (hw[11:8] == 4'b0000) begin // ADD/SUB SP, #imm
          arm = dp_i(hw[7] ? OP_SUB : OP_ADD, 1'b0, 4'hD, 4'hD, 4'hF, {1'b0, hw[6:0]});
        end else if (hw[10:9] == 2'b10) begin   // PUSH/POP
          if (!hw[11]) arm = {4'hE, 3'b100, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 4'hD, 1'b0, hw[8], 6'b0, hw[7:0]};
          else         arm = {4'hE, 3'b100, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 4'hD, hw[8], 7'b0, hw[7:0]};
        end else if (hw[11:8] == 4'b1110 && v5) begin // BKPT
          arm = {4'hE, 8'h12, 12'h000, 4'h7, 4'h0} | {20'h0, hw[7:4], 4'h0, hw[3:0]};
        end else begin
          kind = TK_UND;
        end
      end
      3'b110: begin
        if (!hw[12]) begin                 // STMIA/LDMIA Rb!, {rlist}
          arm = {4'hE, 3'b100, 1'b0, 1'b1, 1'b0, 1'b1, hw[11], {1'b0, hw[10:8]}, 8'h00, hw[7:0]};
        end else if (hw[11:8] == 4'hF) begin   // SWI
          arm = {4'hE, 4'hF, 16'h0, hw[7:0]};
        end else if (hw[11:8] == 4'hE) begin
          kind = TK_UND;
        end else begin                     // B<cond>
          arm = {hw[11:8], 28'h0};
          kind = TK_B;
          boff = {{23{hw[7]}}, hw[7:0], 1'b0};
        end
      end
      default: begin                       // 111xx
        case (hw[12:11])
          2'b00: begin
            arm = {4'hE, 28'h0};
            kind = TK_B;
            boff = {{20{hw[10]}}, hw[10:0], 1'b0};
          end
          2'b01: begin
            kind = (v5 && !hw[0]) ? TK_BLX2 : TK_UND;
            arm = {4'hE, 17'h0, hw[10:0]};
            boff = {20'h0, hw[10:0], 1'b0};
          end
          2'b10: begin
            kind = TK_BL1;
            arm = {4'hE, 28'h0};
            boff = {{9{hw[10]}}, hw[10:0], 12'h000};
          end
          default: begin
            kind = TK_BL2;
            arm = {4'hE, 17'h0, hw[10:0]};
            boff = {20'h0, hw[10:0], 1'b0};
          end
        endcase
      end
    endcase
  end
endmodule
