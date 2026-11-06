// Four logical clients on the existing eight-word SDRAM transport. Port 0
// (line ring) has priority at every free boundary; other clients rotate.
module nds_g3d_sp_arb (
 input logic clk,rst,
 input logic[3:0] w_req,r_req,
 input logic[95:0] w_addr,r_addr,
 input logic[127:0] w_data,
 output logic[3:0] w_ack,r_ack,r_valid,
 output logic sw_req,sr_req,
 output logic[23:0] sw_addr,sr_addr,
 output logic[31:0] sw_data,
 input logic sw_ack,sr_ack,sr_valid
);
 logic[2:0] wo,ro,wp,rp;
 logic[2:0] wc,rc;
 logic[1:0] wl,rl;
 function automatic[2:0] pick(input logic[3:0]req,input logic[1:0]last);
   integer k;
   begin
     pick=0;
     if(req[0])pick=1;
     else for(integer step=1;step<=3;step++)begin
       k=int'(last)+step;if(k>=3)k=k-3;
       if(pick==0 && req[k+1])pick=3'(k+2);
     end
   end
 endfunction
 always_comb begin
   wp=wo!=0?wo:pick(w_req,wl);rp=ro!=0?ro:pick(r_req,rl);
   sw_req=wp!=0 && w_req[wp-1];sr_req=rp!=0 && r_req[rp-1];
   sw_addr=wp==0?24'd0:w_addr[(wp-1)*24+:24];
   sr_addr=rp==0?24'd0:r_addr[(rp-1)*24+:24];
   sw_data=wp==0?32'd0:w_data[(wp-1)*32+:32];
   w_ack='0;r_ack='0;r_valid='0;
   if(wp!=0)w_ack[wp-1]=sw_ack;
   if(rp!=0)r_ack[rp-1]=sr_ack;
   if(ro!=0)r_valid[ro-1]=sr_valid;
 end
 always_ff @(posedge clk)begin
   if(rst)begin wo<='0;ro<='0;wc<='0;rc<='0;wl<=2;rl<=2;end
   else begin
     if(wo==0 && sw_req)wo<=wp;
     if(sw_req && sw_ack)begin
       wc<=wc+3'd1;if(wc==7)begin wo<='0;if(wp!=1)wl<=2'(wp-2);end
     end
     if(ro==0 && sr_req)ro<=rp;
     if(sr_valid && ro!=0)begin
       rc<=rc+3'd1;if(rc==7)begin ro<='0;if(ro!=1)rl<=2'(ro-2);end
     end
   end
 end
endmodule
