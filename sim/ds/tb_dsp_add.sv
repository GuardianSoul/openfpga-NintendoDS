// rtl/ds/nds_dsp_add.sv against a + b: random and edge operands, both signednesses,
// widths 18, 16, 12 and 1 (make dspadd-test)
module tb_dsp_add_one #(parameter int W = 18, parameter bit SG = 0) (input logic clk, output int bad);
    logic [W-1:0] a, b; logic [W:0] s, r;
    nds_dsp_add #(.W(W), .SIGNED(SG)) u (.clk(clk), .a(a), .b(b), .s(s));
    assign r = SG ? W'(0) + $signed({a[W-1], a}) + $signed({b[W-1], b}) : {1'b0, a} + {1'b0, b};
    int i = 0;
    initial bad = 0;
    always @(posedge clk) begin
        if (i > 1 && s !== r) begin bad <= bad + 1; if (bad < 3) $display("W=%0d SIGNED=%0d a=%h b=%h got %h want %h", W, SG, a, b, s, r); end
        i <= i + 1;
        a <= i < 4 ? (i[0] ? '1 : '0) : i == 4 ? {1'b0, {(W-1){1'b1}}} : i == 5 ? {1'b1, {(W-1){1'b0}}} : W'($urandom);
        b <= i < 4 ? (i[1] ? '1 : '0) : i == 4 ? {1'b0, {(W-1){1'b1}}} : i == 5 ? {1'b1, {(W-1){1'b0}}} : W'($urandom);
    end
endmodule
module tb_dsp_add;
    logic clk = 0;
    int b0, b1, b2, b3, b4, b5;
    tb_dsp_add_one #(18, 0) t0 (clk, b0); tb_dsp_add_one #(18, 1) t1 (clk, b1);
    tb_dsp_add_one #(16, 0) t2 (clk, b2); tb_dsp_add_one #(12, 1) t3 (clk, b3);
    tb_dsp_add_one #(1, 0)  t4 (clk, b4); tb_dsp_add_one #(1, 1)  t5 (clk, b5);
    initial begin
        repeat (200000) begin #1 clk = 1; #1 clk = 0; end
        if (b0 + b1 + b2 + b3 + b4 + b5 == 0) $display("PASS dspadd: 6 configurations, 200,000 cycles each");
        else $display("FAIL dspadd: %0d mismatches", b0 + b1 + b2 + b3 + b4 + b5);
        $finish;
    end
endmodule
