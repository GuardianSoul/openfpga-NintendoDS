module dsp_add_equiv_case #(parameter int W=18, parameter bit SG=0)
    (input logic clk, output logic done=0);
    logic [W-1:0] a='0,b='0;
    wire [W:0] old_sum,new_sum,opt_sum;
    nds_dsp_add_before #(.W(W),.SIGNED(SG)) old_u(.clk,.a,.b,.s(old_sum));
    nds_dsp_add #(.W(W),.SIGNED(SG)) new_u(.clk,.a,.b,.s(new_sum));
    nds_dsp_add #(.W(W),.SIGNED(SG),.USE_DSP(1)) opt_u(.clk,.a,.b,.s(opt_sum));
    task automatic check;
        logic [W:0] expected;
        expected = SG ? $signed({a[W-1],a})+$signed({b[W-1],b}) : {1'b0,a}+{1'b0,b};
        if (old_sum !== expected || new_sum !== old_sum || opt_sum !== old_sum)
            $fatal(1,"ADD_EQ W=%0d SG=%0d a=%h b=%h old=%h new=%h opt=%h expected=%h",
                   W,SG,a,b,old_sum,new_sum,opt_sum,expected);
    endtask
    initial begin
        if (W <= 6) begin
            for(int i=0;i<(1<<W);i++) for(int j=0;j<(1<<W);j++) begin
                a=W'(i);b=W'(j);#1;check();
            end
        end
        for(int i=0;i<10008;i++) begin
            case(i)
                0:begin a='0;b='0;end
                1:begin a='1;b='1;end
                2:begin a='1;b=W'(1);end
                3:begin a=W'(1)<<(W-1);b=a;end
                4:begin a=(W'(1)<<(W-1))-1'b1;b=a;end
                5:begin a='0;b='1;end
                6:begin a='1;b='0;end
                7:begin a=W'(1)<<(W-1);b='1;end
                default:begin a=W'($urandom);b=W'($urandom);end
            endcase
            #1;check();
        end
        done=1;
    end
endmodule
module tb_dsp_add_equiv;
    logic clk=0;
    always #2 clk=~clk;
    wire [35:0] done;
    genvar w,s;
    generate for(w=1;w<=18;w++) begin : g_width
        for(s=0;s<2;s++) begin : g_sign
            dsp_add_equiv_case #(.W(w),.SG(s)) u(.clk,.done(done[(w-1)*2+s]));
        end
    end endgenerate
    initial begin
        wait (&done);
        $display("PASS ADD_EQ: 36 width/sign configs, previous/default/optional paths, exhaustive W1..6 and random/edge inputs");
        $finish;
    end
endmodule
