// space-cg item 4: gxeng accumulator next state, old (669c40c9) vs new, SMALL=1; FF as a parameter
// (acc_a 3 bits: all 8 modes; vacc lanes 1..3). a63/az/nfit are registers of acc, unchanged.
localparam int ACC_NONE = 0, ACC_LD = 1, ACC_ADD = 2, ACC_SUB = 3, ACC_ADDM = 4, ACC_VLD = 5, ACC_VADD = 6, ACC_VLDT = 7;
module acc_old #(parameter bit FF = 1) (input logic [2:0] acc_a, input logic [63:0] acc, pr,
    input logic [43:0] v1, v2, v3, p1, p2, p3, output logic [63:0] acc_n, output logic [43:0] n1, n2, n3);
    wire        acc_sub = acc_a == ACC_SUB;
    wire [63:0] acc_opd = (acc_a == ACC_ADDM) ? {44'd0, pr[19:0]} : pr;
    wire [63:0] acc_sum = acc + (acc_sub ? ~acc_opd : acc_opd) + {63'd0, acc_sub};
    always_comb begin
        acc_n = acc;
        case (acc_a)
            ACC_LD:   acc_n = pr;
            ACC_VLD, ACC_VLDT: if (FF) acc_n = pr;
            ACC_VADD: if (FF) acc_n = acc_sum;
            ACC_ADD:  acc_n = acc_sum;
            ACC_SUB:  acc_n = acc_sum;
            ACC_ADDM: acc_n = acc_sum;
            default: ;
        endcase
    end
    logic [43:0] va [1:3], vp [1:3], vn [1:3];
    assign va[1] = v1; assign va[2] = v2; assign va[3] = v3; assign vp[1] = p1; assign vp[2] = p2; assign vp[3] = p3;
    always_comb for (int c = 1; c < 4; c++) begin
        vn[c] = va[c];
        if (acc_a == 3'(ACC_VLD) || acc_a == 3'(ACC_VLDT)) vn[c] = vp[c];
        else if (acc_a == 3'(ACC_VADD)) vn[c] = va[c] + vp[c];
    end
    assign n1 = vn[1]; assign n2 = vn[2]; assign n3 = vn[3];
endmodule

module acc_new #(parameter bit FF = 1, parameter bit MUT = 0) (input logic [2:0] acc_a, input logic [63:0] acc, pr,
    input logic [43:0] v1, v2, v3, p1, p2, p3, output logic [63:0] acc_n, output logic [43:0] n1, n2, n3);
    // (the RTL block, as in rtl/gpu3d/gpu3d_gxeng.sv)
    wire        acc_sub = acc_a == ACC_SUB;
    wire [63:0] acc_opd = (acc_a == ACC_ADDM) ? {44'd0, pr[19:0]} : pr;
    wire        acc_vl  = acc_a == ACC_VLD || acc_a == ACC_VLDT;
    wire        acc_ld  = acc_a == ACC_LD || (acc_vl && !MUT);
    wire        acc_en  = acc_a == ACC_LD || acc_a == ACC_ADD || acc_a == ACC_SUB || acc_a == ACC_ADDM ||
                          (FF && (acc_vl || acc_a == ACC_VADD));
    wire [63:0] acc_sum = (acc_ld ? 64'd0 : acc) + (acc_sub ? ~acc_opd : acc_opd) + {63'd0, acc_sub};
    assign acc_n = acc_en ? acc_sum : acc;
    wire        v_en = acc_vl || acc_a == ACC_VADD;
    logic [43:0] va [1:3], vp [1:3], vn [1:3];
    assign va[1] = v1; assign va[2] = v2; assign va[3] = v3; assign vp[1] = p1; assign vp[2] = p2; assign vp[3] = p3;
    always_comb for (int c = 1; c < 4; c++) vn[c] = v_en ? (acc_vl ? 44'd0 : va[c]) + vp[c] : va[c];
    assign n1 = vn[1]; assign n2 = vn[2]; assign n3 = vn[3];
endmodule

module acc_new_ff0 (input logic [2:0] acc_a, input logic [63:0] acc, pr, input logic [43:0] v1, v2, v3, p1, p2, p3,
    output logic [63:0] acc_n, output logic [43:0] n1, n2, n3);
    acc_new #(.FF(0)) u (.*);
endmodule
module acc_old_ff0 (input logic [2:0] acc_a, input logic [63:0] acc, pr, input logic [43:0] v1, v2, v3, p1, p2, p3,
    output logic [63:0] acc_n, output logic [43:0] n1, n2, n3);
    acc_old #(.FF(0)) u (.*);
endmodule
// mutation: VLD/VLDT no longer zero the accumulator (acc + pr instead of pr)
module acc_mut (input logic [2:0] acc_a, input logic [63:0] acc, pr, input logic [43:0] v1, v2, v3, p1, p2, p3,
    output logic [63:0] acc_n, output logic [43:0] n1, n2, n3);
    acc_new #(.MUT(1)) u (.*);
endmodule
// registered wrappers for the area count only (the accumulators fed back, the hold as a clock enable)
module accq_old (input logic clk, input logic [2:0] acc_a, input logic [63:0] pr, input logic [43:0] p1, p2, p3,
    output logic [63:0] acc, output logic [43:0] v1, v2, v3);
    logic [63:0] acc_n; logic [43:0] n1, n2, n3;
    acc_old u (.*);
    always_ff @(posedge clk) begin acc <= acc_n; v1 <= n1; v2 <= n2; v3 <= n3; end
endmodule
module accq_new (input logic clk, input logic [2:0] acc_a, input logic [63:0] pr, input logic [43:0] p1, p2, p3,
    output logic [63:0] acc, output logic [43:0] v1, v2, v3);
    logic [63:0] acc_n; logic [43:0] n1, n2, n3;
    acc_new u (.*);
    always_ff @(posedge clk) begin acc <= acc_n; v1 <= n1; v2 <= n2; v3 <= n3; end
endmodule
