module tb_tpf_receiver(
 input logic clk,clk2,rst,flush,tex_req,pal_req,pf_v,
 input logic[18:0]tex_addr,pf_a,input logic[16:0]pal_addr,input logic[31:0]mem_epoch,
 input logic[2:0]t_ack,t_rvalid,input logic[63:0]t_rdata[0:2],
 output logic[2:0]tex_valid,pal_valid,t_req,idle,
 output logic[15:0]tex_data[0:2],pal_data[0:2],output logic[17:0]t_blk[0:2],
 output logic[31:0]tex_epoch[0:2],pal_epoch[0:2],hint_look[0:2],hint_drop[0:2],hint_pop_push[0:2],stale_fill[0:2],flush_ack[0:2],flush_last[0:2]
);
 import gpu2d_pkg::*;
 for(genvar k=0;k<3;k++)begin:g_profile
 localparam bit TC_V2=1,TC_MIF2=0;localparam int TC_NF=2;
 logic tc_req,pc_req,tc_ack,pc_ack,tc_rv,pc_rv,tc_v,pc_v;
 logic[13:0]tc_blk,pc_blk;logic[15:0]td,pd;
 logic tl,pl,th,ph,pg,fl,fs;logic[2:0]pn;logic ci,pi;
 if(k==2) begin:g_small
 rc8_receiver_probe #(.AW(19),.LW(9),.QL(4),.NF(2),.WAYS(4),.PUMP(1),.PF(1),.PF_SINGLE(1))u_tc(.clk,.clk2,.rst,.flush,.req(tex_req),.addr(tex_addr),.valid(tc_v),.data(td),.b_req(tc_req),.b_blk(tc_blk),.b_ack(tc_ack),.b_rvalid(tc_rv),.b_rdata(t_rdata[k]),.pf_v,.pf_a);
 assign tl=u_tc.l_en;assign th=u_tc.st==u_tc.C_LOOK&&u_tc.hit;assign pg=u_tc.p_go;assign pn=u_tc.pq_n;
 assign fl=u_tc.f_last;assign fs=u_tc.f_st[0];
 assign ci=u_tc.n==0&&u_tc.f_v==0&&!u_tc.r_v&&u_tc.pq_n==0&&u_tc.st==u_tc.C_IDLE;
 end
 else if(k==1) begin:g_four
 rc8_receiver_before #(.AW(19),.LW(9),.QL(4),.NF(2),.WAYS(4),.PUMP(1),.PF(1))u_tc(.clk,.clk2,.rst,.flush,.req(tex_req),.addr(tex_addr),.valid(tc_v),.data(td),.b_req(tc_req),.b_blk(tc_blk),.b_ack(tc_ack),.b_rvalid(tc_rv),.b_rdata(t_rdata[k]),.pf_v,.pf_a);
 assign tl=u_tc.l_en;assign th=u_tc.st==u_tc.C_LOOK&&u_tc.hit;assign pg=u_tc.p_go;assign pn=u_tc.pq_n;
 assign fl=u_tc.f_last;assign fs=u_tc.f_st[0];
 assign ci=u_tc.n==0&&u_tc.f_v==0&&!u_tc.r_v&&u_tc.pq_n==0&&u_tc.st==u_tc.C_IDLE;
 end
 else begin:g_off
 rc8_receiver_before #(.AW(19),.LW(9),.QL(4),.NF(2),.WAYS(4),.PUMP(1),.PF(0))u_tc(.clk,.clk2,.rst,.flush,.req(tex_req),.addr(tex_addr),.valid(tc_v),.data(td),.b_req(tc_req),.b_blk(tc_blk),.b_ack(tc_ack),.b_rvalid(tc_rv),.b_rdata(t_rdata[k]),.pf_v,.pf_a);
 assign tl=u_tc.l_en;assign th=u_tc.st==u_tc.C_LOOK&&u_tc.hit;assign pg=u_tc.p_go;assign pn=u_tc.pq_n;
 assign fl=u_tc.f_last;assign fs=u_tc.f_st[0];
 assign ci=u_tc.n==0&&u_tc.f_v==0&&!u_tc.r_v&&u_tc.pq_n==0&&u_tc.st==u_tc.C_IDLE;
 end
 rc8_receiver_before #(.AW(17),.LW(8),.QL(4),.NF(2),.PUMP(1))u_pc(.clk,.clk2,.rst,.flush,
 .req(pal_req),.addr(pal_addr),.valid(pc_v),.data(pd),.b_req(pc_req),.b_blk(pc_blk),.b_ack(pc_ack),.b_rvalid(pc_rv),.b_rdata(t_rdata[k]),.pf_v(1'b0),.pf_a(17'd0));
 assign pl=u_pc.l_en;assign ph=u_pc.st==u_pc.C_LOOK&&u_pc.hit;
 assign pi=u_pc.n==0&&u_pc.f_v==0&&!u_pc.r_v&&u_pc.st==u_pc.C_IDLE;
 assign tex_valid[k]=tc_v;assign pal_valid[k]=pc_v;assign tex_data[k]=td;assign pal_data[k]=pd;
 assign idle[k]=ci&&pi&&t_n==0&&!ow_v;
 logic[31:0]te=0,pe=0;
 initial begin hint_look[k]=0;hint_drop[k]=0;hint_pop_push[k]=0;stale_fill[k]=0;flush_ack[k]=0;flush_last[k]=0;end
 always @(posedge clk)begin
  if(tl)te<=mem_epoch;if(pl)pe<=mem_epoch;
  if(th)tex_epoch[k]<=te;if(ph)pal_epoch[k]<=pe;
  if(!rst)begin
   if(pg)hint_look[k]++;if(k!=0&&pf_v&&pn-3'(pg)>=(k==2?1:4))hint_drop[k]++;
   if(pg&&pf_v)hint_pop_push[k]++;if(fl&&fs)stale_fill[k]++;
   if(flush&&t_ack[k])flush_ack[k]++;if(flush&&t_last)flush_last[k]++;
  end
 end
    localparam int TNF = TC_V2 ? (TC_NF > 2 ? TC_NF : 2) : TC_MIF2 ? 2 : 1;
    logic [3:0] t_n;                   // blocks in flight
    logic [TNF > 1 ? TNF - 1 : 1:0] t_ownq;   // their owners, [0] the oldest (1 = palette)
    logic [1:0] t_beat;
    wire  t_pick = tc_req ? 1'b0 : 1'b1;
    wire  t_last = t_rvalid[k] && t_beat == 2'd3;
    assign t_req[k]  = (t_n < 4'(TNF)) && (tc_req || pc_req);
    assign t_blk[k]  = t_pick ? {SP_TPAL, 1'b0, pc_blk} : {SP_TEX, 1'b0, tc_blk};
    assign tc_ack = t_ack[k] && !t_pick;
    assign pc_ack = t_ack[k] && t_pick;
    assign tc_rv  = t_rvalid[k] && !t_ownq[0];
    assign pc_rv  = t_rvalid[k] && t_ownq[0];
    always_ff @(posedge clk) begin
        if (rst) begin t_n <= 4'd0; t_beat <= 2'd0; end
        else begin
            if (t_rvalid[k]) t_beat <= t_beat + 2'd1;
            t_n <= t_n + (t_ack[k] ? 4'd1 : 4'd0) - (t_last ? 4'd1 : 4'd0);
            // push at the next free slot (t_n, less the one popped), pop the oldest at its last beat
            if (t_last) t_ownq <= t_ownq >> 1;
            if (ow_v) t_ownq[ow_i - 4'(t_last)] <= ow_p;
        end
    end
    // the owner is written a clock after t_ack[k] (#879: fabric cpu -> blk_arb t_ack[k] -> t_ownq -0.221 ns): its
    // slot as taken then (t_n less a pop that clock), less a pop in the clock it is written. A block's
    // first beat comes two or more clocks after its ack (checked below), so t_ownq[0] is in place by then
    logic       ow_v, ow_p;
    logic [3:0] ow_i;
    always_ff @(posedge clk) begin
        ow_v <= !rst && t_ack[k]; ow_p <= t_pick; ow_i <= t_n - 4'(t_last);
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (!rst && t_rvalid[k] && t_n == 4'd0) $error("nds_gpu3d: a block beat with no block in flight");
    always_ff @(posedge clk) if (!rst && t_rvalid[k] && ow_v && ow_i == 4'd0)
        $error("nds_gpu3d: a block beat before its owner is written (t_ack[k] one clock earlier)");
`endif

 end
endmodule
