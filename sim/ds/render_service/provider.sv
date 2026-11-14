// Fixture at the original accepted per-line polygon-stream boundary.
module render_provider(input logic clk,rst,cancel,frame_go,
    input logic line_req,input logic[7:0]line_y,input logic[8:0]y_lim,
    output logic valid,input logic ready,output logic[1:0]typ,output logic[127:0]data,
    input logic[2:0]generation);
    logic pending=0;logic[7:0]y;integer k=0;
    function automatic [127:0] header(input integer p);
        logic[127:0]b;
        b=0;b[31:0]=32'h011f00c0+32'(p<<24);
        b[63:32]=32'h11300000+32'(p*4096); // format4,64x32 texels
        b[80:77]=4;b[84:81]=0;b[88:85]=2;
        b[96:89]=p==0?3:5;b[104:97]=p==0?11:17;b[105]=1;
        return b;
    endfunction
    function automatic [127:0] vertex(input integer p,input integer v);
        logic[127:0]b;integer x0,x1,y0,y1;
        x0=p==0?8:128;x1=p==0?96:240;y0=p==0?3:5;y1=p==0?11:17;
        b=0;b[8:0]=9'((v==1||v==2)?x1:x0);b[16:9]=8'(v>=2?y1:y0);
        b[40:17]=24'h400000;b[56:41]=16'h8000;
        b[65:57]=9'(511-int'(generation)*32);b[74:66]=9'(255+int'(generation)*16);b[83:75]=511;
        b[99:84]=16'((v==1||v==2)?4096:0);b[115:100]=16'(v>=2?512:0);
        return b;
    endfunction
    always_comb begin
        valid=pending && {1'b0,y}<=y_lim;
        typ=2'd3;data=0;
        if(y>=3 && y<17) begin
            if(k<5 && y<11)begin typ=k==0?0:1;data=k==0?header(0):vertex(0,k-1);end
            else if(k<10 && y>=5)begin typ=k==5?0:1;data=k==5?header(1):vertex(1,k-6);end
        end
    end
    always @(posedge clk)begin
        if(rst||cancel||frame_go)begin pending<=0;k<=0;end
        else begin
            if(line_req)begin pending<=1;y<=line_y;k<=line_y>=11?5:0;end
            if(valid&&ready)begin
                if(typ==3)pending<=0;
                else if(k==4 && y<5)k<=10;
                else k<=k+1;
            end
        end
    end
endmodule
