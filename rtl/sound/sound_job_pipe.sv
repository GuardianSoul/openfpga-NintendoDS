// Private shared arithmetic prototype. Logical workers own all public edges.
// One typed job per FAST edge: PCM bypass, ADPCM, or weighted contribution.
// Branches have independent completion ports; the caller must retain tags and
// publish only at the original logical deadline. No timer or memory service.
module sound_job_pipe #(
    parameter integer TW = 24
) (
    input logic clk, en, rst,
    input logic valid,
    input logic [1:0] op, // 0 PCM sample, 1 ADPCM sample, 2 volume/pan
    input logic [TW-1:0] tag,
    input logic signed [15:0] sample_in,
    input logic [6:0] index_in,
    input logic [3:0] nibble_in,
    input logic [6:0] volume_in, pan_in,
    input logic [1:0] divider_in,
    output logic pcm_valid,
    output logic [TW-1:0] pcm_tag,
    output logic signed [15:0] pcm_sample,
    output logic decode_valid,
    output logic [TW-1:0] decode_tag,
    output logic signed [15:0] decode_sample,
    output logic [6:0] decode_index,
    output logic weight_valid,
    output logic [TW-1:0] weight_tag,
    output logic signed [27:0] weight_left, weight_right, weight_postvol,
    // Final-stage D values, stable BEFORE the accepting FAST edge. A logical
    // SYS owner sharing that edge must consume these, not the F2 output FF.
    output logic decode_now, weight_now,
    output logic [TW-1:0] decode_now_tag, weight_now_tag,
    output logic signed [15:0] decode_now_sample,
    output logic [6:0] decode_now_index,
    output logic signed [27:0] weight_now_left,weight_now_right,weight_now_postvol
);
    // PCM is consumed on the accepting edge, with no added sample stage.
    assign pcm_valid = en && valid && op == 0 && !rst;
    assign pcm_tag = tag;
    assign pcm_sample = sample_in;

    function automatic logic [14:0] step(input logic [6:0] i);
        case (i)
            0:step=7;1:step=8;2:step=9;3:step=10;4:step=11;5:step=12;6:step=13;7:step=14;
            8:step=16;9:step=17;10:step=19;11:step=21;12:step=23;13:step=25;14:step=28;15:step=31;
            16:step=34;17:step=37;18:step=41;19:step=45;20:step=50;21:step=55;22:step=60;23:step=66;
            24:step=73;25:step=80;26:step=88;27:step=97;28:step=107;29:step=118;30:step=130;31:step=143;
            32:step=157;33:step=173;34:step=190;35:step=209;36:step=230;37:step=253;38:step=279;39:step=307;
            40:step=337;41:step=371;42:step=408;43:step=449;44:step=494;45:step=544;46:step=598;47:step=658;
            48:step=724;49:step=796;50:step=876;51:step=963;52:step=1060;53:step=1166;54:step=1282;55:step=1411;
            56:step=1552;57:step=1707;58:step=1878;59:step=2066;60:step=2272;61:step=2499;62:step=2749;63:step=3024;
            64:step=3327;65:step=3660;66:step=4026;67:step=4428;68:step=4871;69:step=5358;70:step=5894;71:step=6484;
            72:step=7132;73:step=7845;74:step=8630;75:step=9493;76:step=10442;77:step=11487;78:step=12635;79:step=13899;
            80:step=15289;81:step=16818;82:step=18500;83:step=20350;84:step=22385;85:step=24623;86:step=27086;87:step=29794;
            88:step=32767;default:step=0;
        endcase
    endfunction
    function automatic logic [17:0] carry3(input logic [17:0] a,b,c);
        carry3=((a&b)|(a&c)|(b&c))<<1;
    endfunction

    logic d0,d1;
    logic [TW-1:0] dt0,dt1;
    logic signed [15:0] sample0;
    logic [6:0] index0,index1;
    logic [3:0] nibble0;
    logic [14:0] step0;
    logic [17:0] sum1,carry1;
    wire [17:0] a={{2{sample0[15]}},sample0};
    wire [17:0] b={18{nibble0[3]}} ^ {6'd0,step0[14:3]};
    wire [17:0] c={18{nibble0[3]}} ^ (nibble0[0]?{5'd0,step0[14:2]}:18'd0);
    wire [17:0] d={18{nibble0[3]}} ^ (nibble0[1]?{4'd0,step0[14:1]}:18'd0);
    wire [17:0] e={18{nibble0[3]}} ^ (nibble0[2]?{3'd0,step0}:18'd0);
    wire [17:0] f={15'd0,nibble0[3],2'd0};
    wire [17:0] s0=a^b^c,c0=carry3(a,b,c);
    wire [17:0] s2=d^e^f,c2=carry3(d,e,f);
    wire [17:0] s3=s0^c0^s2,c3=carry3(s0,c0,s2);
    wire [17:0] final_sum=sum1+carry1;
    wire overflow=final_sum[17] ? final_sum[16:15]!=2'b11 || final_sum[14:0]==0
                                            : final_sum[16:15]!=0;
    wire [7:0] ni={1'b0,index0}+(nibble0[2]?{5'd0,nibble0[1:0],1'b0}+8'd2:8'hff);

    logic w0,w1;
    logic [TW-1:0] wt0,wt1;
    logic signed [23:0] product0;
    logic signed [32:0] pan_product1;
    logic signed [28:0] scaled1;
    logic [7:0] pan0;
    logic [1:0] div0,div1;
    wire [7:0] vol=volume_in==127?8'd128:{1'b0,volume_in};
    wire [7:0] pan=pan_in==127?8'd128:{1'b0,pan_in};
    logic signed [28:0] scaled0;
    always_comb case(div0)
        0:scaled0=29'(product0)<<<4;
        1:scaled0=29'(product0)<<<3;
        2:scaled0=29'(product0)<<<2;
        default:scaled0=29'(product0);
    endcase
    logic signed [47:0] lp,rp;
    always_comb begin
        case(div1)
            0:lp=48'(pan_product1)<<<4;
            1:lp=48'(pan_product1)<<<3;
            2:lp=48'(pan_product1)<<<2;
            default:lp=48'(pan_product1);
        endcase
        rp=(48'(scaled1)<<<7)-lp;
    end
    assign decode_now=en && d1 && !rst;
    assign decode_now_tag=dt1;
    assign decode_now_sample=overflow?{final_sum[17],{14{!final_sum[17]}},1'b1}:final_sum[15:0];
    assign decode_now_index=index1;
    assign weight_now=en && w1 && !rst;
    assign weight_now_tag=wt1;
    assign weight_now_left={{2{lp[35]}},lp[35:10]};
    assign weight_now_right={{2{rp[35]}},rp[35:10]};
    assign weight_now_postvol=28'(scaled1>>>3);
    always_ff @(posedge clk) begin
        if(rst)begin
            d0<=0;d1<=0;decode_valid<=0;
            w0<=0;w1<=0;weight_valid<=0;
        end else if(en)begin
            d0<=valid && op==1;d1<=d0;decode_valid<=d1;
            if(valid && op==1)begin
                dt0<=tag;sample0<=sample_in;index0<=index_in;nibble0<=nibble_in;step0<=step(index_in);
            end
            if(d0)begin
                dt1<=dt0;sum1<=s3^c3^c2;carry1<=carry3(s3,c3,c2);
                index1<=index0>88 || ni[7]?7'd0:ni[6:0]>88?7'd88:ni[6:0];
            end
            if(d1)begin
                decode_tag<=dt1;decode_index<=index1;
                decode_sample<=overflow?{final_sum[17],{14{!final_sum[17]}},1'b1}:final_sum[15:0];
            end
            w0<=valid && op==2;w1<=w0;weight_valid<=w1;
            if(valid && op==2)begin
                wt0<=tag;product0<=sample_in*$signed({1'b0,vol});pan0<=pan;div0<=divider_in;
            end
            if(w0)begin
                wt1<=wt0;pan_product1<=product0*$signed(9'(128-pan0));scaled1<=scaled0;div1<=div0;
            end
            if(w1)begin
                weight_tag<=wt1;weight_left<={{2{lp[35]}},lp[35:10]};
                weight_right<={{2{rp[35]}},rp[35:10]};weight_postvol<=28'(scaled1>>>3);
            end
        end
    end
endmodule
