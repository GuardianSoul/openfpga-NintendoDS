// gpu3d_gxeng's ALU result path before (alu_old, 18993fdd) and after (alu_new) the funnel shifter and the
// logic unit, by op code as odec decodes it; miter: equal res, sum and lt_s for kreg 0..32 (sim/gpu3d/alu_eq/prove.sh)
// old and new ALU result paths of gpu3d_gxeng (from the op code, as odec does), for synthesis and the SAT proof
module alu_old(input [4:0] op, input [31:0] xo, yo, input [5:0] kreg, output [31:0] res, output [32:0] sum, output lt_s);
    wire sub = op != 5'd0, rsub = op == 5'd2, shl = op == 5'd6, sar = op == 5'd8, fsh = op == 5'd18;
    wire [31:0] ax = rsub ? yo : xo, ay = rsub ? xo : yo;
    assign sum = {1'b0, ax} + {1'b0, sub ? ~ay : ay} + {32'd0, sub};
    assign lt_s = (ax[31] != ay[31]) ? ax[31] : sum[31];
    wire [5:0] sh_amt = fsh ? kreg : {1'b0, yo[4:0]};
    wire [31:0] mabs_h = yo ^ {32{yo[31]}};
    wire [7:0] k4_nz = {|xo[31:28], |xo[27:24], |xo[23:20], |xo[19:16], |xo[15:12], |xo[11:8], |xo[7:4], |xo[3:0]};
    logic [5:0] k4_k; always_comb begin k4_k = 0; for (int i = 0; i < 8; i++) if (k4_nz[i]) k4_k = 6'(4 * (i + 1)); end
    logic [31:0] x_rev, sh_in, sh_out, sh_res;
    always_comb begin
        for (int k = 0; k < 32; k++) x_rev[k] = xo[31 - k];
        sh_in  = shl ? x_rev : xo;
        sh_out = 32'({fsh ? yo : {32{sar && xo[31]}}, sh_in} >> sh_amt);
        for (int k = 0; k < 32; k++) sh_res[k] = shl ? sh_out[31 - k] : sh_out[k];
    end
    wire s_sum = op <= 2, s_and = op == 3, s_or = op == 4, s_xor = op == 5, s_bic = op == 13, s_sh = op == 6 || op == 7 || op == 8 || op == 18;
    wire s_sx16 = op == 9, s_sx11 = op == 10, s_max = op == 11, s_min = op == 12, s_slt = op == 15, s_mabs = op == 16, s_k4 = op == 17;
    wire s_x = !(s_sum || s_and || s_or || s_xor || s_bic || s_sh || s_sx16 || s_sx11 || s_max || s_min || s_slt || s_mabs || s_k4);
    wire [31:0] res_e = ({32{s_sum}} & sum[31:0]) | ({32{s_and}} & (xo & yo)) | ({32{s_or}} & (xo | yo)) | ({32{s_xor}} & (xo ^ yo)) |
                 ({32{s_bic}} & (xo & ~yo)) | ({32{s_sh}} & sh_res) | ({32{s_sx16}} & {{16{xo[15]}}, xo[15:0]}) | ({32{s_sx11}} & {{21{xo[10]}}, xo[10:0]}) |
                 ({32{s_mabs}} & {mabs_h[30:0], xo[31] ^ yo[31]}) | ({32{s_k4}} & {26'd0, k4_k}) | ({32{s_x}} & xo);
    wire [31:0] res_l1 = ({32{s_max}} & yo) | ({32{s_min}} & xo) | {31'd0, s_slt};
    wire [31:0] res_l0 = ({32{s_max}} & xo) | ({32{s_min}} & yo);
    assign res = res_e | (lt_s ? res_l1 : res_l0);
endmodule
module alu_new(input [4:0] op, input [31:0] xo, yo, input [5:0] kreg, output [31:0] res, output [32:0] sum, output lt_s);
    wire sub = op != 5'd0, rsub = op == 5'd2, shl = op == 5'd6, sar = op == 5'd8, fsh = op == 5'd18;
    wire [31:0] ax = rsub ? yo : xo, ay = rsub ? xo : yo;
    assign sum = {1'b0, ax} + {1'b0, sub ? ~ay : ay} + {32'd0, sub};
    assign lt_s = (ax[31] != ay[31]) ? ax[31] : sum[31];
    wire [5:0] sh_amt = fsh ? kreg : {1'b0, yo[4:0]};
    wire [31:0] mabs_h = yo ^ {32{yo[31]}};
    wire [7:0] k4_nz = {|xo[31:28], |xo[27:24], |xo[23:20], |xo[19:16], |xo[15:12], |xo[11:8], |xo[7:4], |xo[3:0]};
    logic [5:0] k4_k; always_comb begin k4_k = 0; for (int i = 0; i < 8; i++) if (k4_nz[i]) k4_k = 6'(4 * (i + 1)); end
    logic [31:0] sh_lo, sh_res, sh_f; logic [30:0] sh_hi; logic [4:0] sh_a;
    always_comb begin
        sh_hi  = fsh ? yo[30:0] : shl ? xo[31:1] : {31{sar && xo[31]}};
        sh_lo  = shl ? {xo[0], 31'd0} : xo;
        sh_a   = fsh ? kreg[4:0] : shl ? ~yo[4:0] : yo[4:0];
        sh_f   = 32'({sh_hi, sh_lo} >> sh_a);
        sh_res = (fsh && kreg[5]) ? yo : sh_f;
    end
    logic [3:0] lgt; logic [31:0] lg_res;
    always_comb begin
        lgt = op == 3 ? 4'b1000 : op == 4 ? 4'b1110 : op == 5 ? 4'b0110 : op == 13 ? 4'b0100 : 4'b1100;
        for (int k = 0; k < 32; k++) lg_res[k] = lgt[{xo[k], yo[k]}];
    end
    wire s_sum = op <= 2, s_and = op == 3, s_or = op == 4, s_xor = op == 5, s_bic = op == 13, s_sh = op == 6 || op == 7 || op == 8 || op == 18;
    wire s_sx16 = op == 9, s_sx11 = op == 10, s_max = op == 11, s_min = op == 12, s_slt = op == 15, s_mabs = op == 16, s_k4 = op == 17;
    wire s_x = !(s_sum || s_and || s_or || s_xor || s_bic || s_sh || s_sx16 || s_sx11 || s_max || s_min || s_slt || s_mabs || s_k4);
    wire s_lg = s_and || s_or || s_xor || s_bic || s_x;
    wire [31:0] res_e = ({32{s_sum}} & sum[31:0]) | ({32{s_lg}} & lg_res) | ({32{s_sh}} & sh_res) | ({32{s_sx16}} & {{16{xo[15]}}, xo[15:0]}) | ({32{s_sx11}} & {{21{xo[10]}}, xo[10:0]}) |
                 ({32{s_mabs}} & {mabs_h[30:0], xo[31] ^ yo[31]}) | ({32{s_k4}} & {26'd0, k4_k});
    wire [31:0] res_l1 = ({32{s_max}} & yo) | ({32{s_min}} & xo) | {31'd0, s_slt};
    wire [31:0] res_l0 = ({32{s_max}} & xo) | ({32{s_min}} & yo);
    assign res = res_e | (lt_s ? res_l1 : res_l0);
endmodule
module miter(input [4:0] op, input [31:0] xo, yo, input [5:0] kreg, output ok);
    wire [31:0] r0, r1; wire [32:0] s0, s1; wire l0, l1;
    alu_old u0(.op, .xo, .yo, .kreg, .res(r0), .sum(s0), .lt_s(l0));
    alu_new u1(.op, .xo, .yo, .kreg, .res(r1), .sum(s1), .lt_s(l1));
    // kreg as K4 leaves it: 0..32 (FSH reads it only after a K4)
    assign ok = (kreg > 6'd32) || (r0 == r1 && s0 == s1 && l0 == l1);
endmodule
