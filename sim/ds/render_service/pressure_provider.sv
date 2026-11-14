// Predeclared legal pressure input at the same accepted PS boundary.
// Two opaque full-screen indexed8 quads, distinct64KiB textures in bank A.
module render_provider(input logic clk,rst,cancel,frame_go,
    input logic line_req,input logic[7:0]line_y,input logic[8:0]y_lim,
    output logic valid,input logic ready,output logic[1:0]typ,output logic[127:0]data,
    input logic[2:0]generation);
    logic pending=0;logic[7:0]y;integer k=0;
    function automatic [127:0] header(input integer p);
        logic[127:0]b;
        b=0;b[31:0]=32'h011f00c0+32'(p<<24);
        b[63:32]=32'h12d00000+32'(p*8192); // format4 indexed8,256x256,base=p*64KiB
        b[80:77]=4;b[84:81]=0;b[88:85]=2;
        b[96:89]=0;b[104:97]=192;b[105]=1;
        return b;
    endfunction
    function automatic [127:0] vertex(input integer p,input integer v);
        logic[127:0]b;
        b=0;b[8:0]=9'((v==1||v==2)?256:0);b[16:9]=8'(v>=2?192:0);
        b[40:17]=p==0?24'h400000:24'h300000;b[56:41]=16'h8000;
        b[65:57]=9'(511-int'(generation)*32);b[74:66]=9'(255+int'(generation)*16);b[83:75]=511;
        b[99:84]=16'((v==1||v==2)?4096:0);b[115:100]=16'(v>=2?4096:0);
        return b;
    endfunction
    always_comb begin
        valid=pending&&{1'b0,y}<=y_lim;typ=2'd3;data=0;
        if(y<192&&k<10)begin
            typ=k%5==0?0:1;data=k%5==0?header(k/5):vertex(k/5,k%5-1);
        end
    end
    always @(posedge clk)begin
        if(rst||cancel||frame_go)begin pending<=0;k<=0;end
        else begin
            if(line_req)begin pending<=1;y<=line_y;k<=0;end
            if(valid&&ready)begin if(typ==3)pending<=0;else k<=k+1;end
        end
    end
endmodule
