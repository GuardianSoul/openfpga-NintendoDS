`timescale 1ps/1ps
`default_nettype none
module h1_chips #(parameter NAME = "s", parameter SKEW=0, GAPS=0) (
    input wire clk_mem, clk_cram, clk_en,
    input wire [21:16] c0a, c1a, inout wire [15:0] c0dq, c1dq, output wire c0w, c1w,
    input wire c0adv, c1adv, c0cre, c1cre, c0ce0, c0ce1, c1ce0, c1ce1, c0oe, c1oe, c0we, c1we, c0ub, c0lb, c1ub, c1lb);
    wire [1:0] cclk;
    altddio_out #(.width(2)) ck (.datain_h({2{clk_en}}), .datain_l(2'b0), .outclock(clk_cram), .dataout(cclk),
        .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0));
    if4_cram_model #(.NAME({NAME, "0"}), .LAT(SKEW==2?12:4), .ROW_WAIT(GAPS?5:2), .ROW_MASK(GAPS?22'h1:22'h7f)) m0 (.sclk(clk_mem), .clk(cclk[0]), .a(c0a), .dq(c0dq), .wait_o(c0w),
        .adv_n(c0adv), .cre(c0cre), .ce0_n(c0ce0), .ce1_n(c0ce1), .oe_n(c0oe), .we_n(c0we), .ub_n(c0ub), .lb_n(c0lb));
    if4_cram_model #(.NAME({NAME, "1"}), .LAT(SKEW==1?12:4), .ROW_WAIT(GAPS?5:2), .ROW_MASK(GAPS?22'h1:22'h7f)) m1 (.sclk(clk_mem), .clk(cclk[1]), .a(c1a), .dq(c1dq), .wait_o(c1w),
        .adv_n(c1adv), .cre(c1cre), .ce0_n(c1ce0), .ce1_n(c1ce1), .oe_n(c1oe), .we_n(c1we), .ub_n(c1ub), .lb_n(c1lb));
endmodule

module lane2 #(parameter GROUP=0, SERVICE=0) (input logic clk_sys,clk_mem,clk_cram,clk2,rst_sys,rst_mem,
 input logic a9_req,a9_we,a9_n8,a9_ldm,input logic[6:0]a9_ldm_meta,input logic[31:0]a9_addr,a9_wdata,input logic[3:0]a9_be,
 output logic a9_ack,a9_rvalid,output logic[31:0]a9_rdata,
 input logic a7_req,a7_we,input logic[31:0]a7_addr,a7_wdata,output logic a7_ack,
 output logic initialized,idle,output wire[79:0]pins,output integer reads=0,writes=0);
 wire clk=clk_sys,rst=rst_sys;
 always @(posedge clk)begin snd_ack<=snd_req;gx_ack<=gx_req;wf_ack<=wf_req;end

 logic fm_req,fm_we,fm_ack,fm_rvalid,fm_n8,fm_wnext,fm_if4,fm_ld4,fm_dmaw;
 logic[21:2]fm_addr;logic[3:0]fm_be;logic[31:0]fm_wdata;
 logic mr_req,mr_we,mr_n8,mr_if4,mr_ld4,mr_dmaw,mr_ack,mr_rvalid,mr_wnext;
 logic[22:2]mr_addr;logic[3:0]mr_be;logic[31:0]mr_wdata,mr_rdata;
 logic mon_we;logic[31:0]mon_addr,mon_wdata;logic[3:0]mon_be;logic[31:0]a7_rdata;
 logic a9_wnext;
  wire io_req,io_cpu,io_we,io_ack;wire[23:2]io_addr;wire[3:0]io_be;wire[31:0]io_wdata,io_rdata;
  wire sys_req,snd_req,gx_req,wf_req;wire[31:0]sys_rdata;
  logic snd_ack=0,gx_ack=0,wf_ack=0;logic[31:0]snd_rdata=0,gx_rdata=32'h1234abcd,wf_rdata=32'h5678dcba;
  wire[7:0]tmr_oh;wire[15:0]exmemcnt,powcnt1,biosprot;wire[1:0]powcnt2,wramcnt;wire[71:0]vramcnt;
  wire[31:0]bootctl;wire halt7,irq9,irq7;wire[1:0]dm_busy;wire[1:0]mon_master;wire disp_req;wire[31:0]disp_data=0;
  logic dx_idle=1,tick_on=0;
  wire[3:0]a9_tmr=a9_we && a9_addr[31:4]==28'h0400010 ? 4'b1<<a9_addr[3:2] : 4'd0;

 logic timer_phase=0;always @(posedge clk)timer_phase<=!timer_phase;wire tick=timer_phase;
  nds_io
`ifndef FROZEN
    #(.SOUND_ACK_EARLY(1))
`endif
    hub(.clk,.rst,.io_req,.io_cpu,.io_we,.io_be,.io_addr,.io_wdata,.io_ack,.io_rdata,
    .sys_req,.sys_rdata,.disp_req(disp_req),.disp_rdata(disp_data),.cart_req(),.cart_reg(),.cart_rdata(32'hface0022),.spi_req(),.spi_rdata(32'hface0033),.rtc_req(),.rtc_rdata(32'hface0044),
    .snd_req,.snd_ack,.snd_rdata,.snd_real(1'b1),.gx_req,.gx_ack,.gx_rdata,.gx_real(1'b1),.gx_ovf(1'b0),.wf_req,.wf_ack,.wf_rdata,.disp3dcnt_o(),
    .keys(12'h805),.pen_down(1'b0),.lid_closed(1'b0),.rom_size(32'h1234567),.mem_dirty(1'b0),.save_info(8'h5a),.rtc_valid(1'b1),.rtc_date(32'h20261101),.rtc_time(32'h00123456),.vramstat(2'd2),
    .powcnt1,.powcnt2,.exmemcnt,.wramcnt,.vramcnt,.biosprot,.bootctl,.tsc_kx(),.tsc_ky(),.tsc_ox(),.tsc_oy(),.halt7,.irq_key9(),.irq_key7(),.gx_irq());
  nds_sys #(.DMA_FAST(1),.PUMP(1)) sys(.clk,.clk2(clk2),.rst,.tick,.io_req(sys_req),.tmr_oh,.io_cpu,.io_we,.io_be,.io_addr(io_addr[20:2]),.io_wdata,.io_rdata(sys_rdata),.io_hit(),
    .dma_trig9(7'd0),.dma_gx_low(1'b0),.dma_stop9(7'd0),.dma_trig7(3'd0),.m_req(),.m_we(),.m_cpu(),.m_size32(),.m_addr(),.m_wgroup(),.m_last(),.m_vcut(),.m_unit(),.m_dst(),.m_more(),.m_wdata(),.m_ack(1'b0),.m_rdata(32'd0),.dma_busy(dm_busy),
    .irq_ext9(32'd0),.irq_ext7(32'd0),.irq9,.irq7,.wake7(),.math_late(),.dbg_dma_run(),.dma_lat_lost());

    nds_fabric #(.MR_BLOCK(1), .IO_GRANT_EARLY(1), 
`ifndef OLD_FABRIC
 .LDM_GROUP_OWNERSHIP(GROUP),
`ifndef NO_SERVICE
 .LDM_SERVICE(SERVICE),
`endif
`endif
 .LDM_STREAM4(1), .A7_FIRST(1), .LDM_HIT_EARLY(1), .OAM_SHARE(1)) u_fab (.clk, .rst, .dm_vcut(1'b0), .dm_unit(1'b0), .dm_more(1'b0), .dm_dst(32'd0), .dx_valid(), .dx_ready(1'b1), .dx_idle(1'b1), .wramcnt(2'd3), .exmemcnt9(8'd0), .pb_busy(1'b0),
        .dm_req(1'b0), .dm_we(1'b0), .dm_cpu(1'b0), .dm_size32(1'b1), .dm_addr(32'd0), .dm_wdata(32'd0), .dm_ack(), .dm_rdata(),
        .a9_ldm,.a9_ldm_meta, .a9_tmr(a9_tmr), .a9_req, .a9_we, .a9_addr, .a9_be, .a9_wdata, .a9_ack, .a9_rdata, .a9_n8, .a9_rvalid, .a9_wnext,
        .a7_n4(1'b0), .a7_req, .a7_we, .a7_addr, .a7_be(4'hf), .a7_wdata, .a7_ack, .a7_rdata,
        .sn_n4(1'b0), .sn_req(1'b0), .sn_we(1'b0), .sn_addr(32'd0), .sn_wdata(32'd0), .sn_ack(), .sn_rdata(),
        .mr_req(fm_req), .mr_we(fm_we), .mr_addr(fm_addr), .mr_be(fm_be), .mr_wdata(fm_wdata),
        .mr_ack(fm_ack), .mr_rvalid(fm_rvalid), .mr_rdata, .mr_n8(fm_n8), .mr_if4(fm_if4), .mr_ld4(fm_ld4), .mr_dmaw(fm_dmaw), .mr_wnext(fm_wnext),
        .fx_req(), .fx_we(), .fx_addr(), .fx_be(), .fx_wdata(), .fx_done(1'b0), .fx_rdata(32'd0),
        .boot_addr(), .boot_q(32'd0), .ram_wdata(),
        .io_req(io_req), .io_cpu(io_cpu), .io_we(io_we), .io_be(io_be), .io_addr(io_addr), .io_wdata(io_wdata), .io_ack(io_ack), .io_rdata(io_rdata), .io_tmr_oh(tmr_oh),
        .vr_req(), .vr_cpu(), .vr_we(), .vr_addr(), .vr_be(), .vr_wdata(), .vr_ack(1'b0), .vr_rdata(32'd0),
        .pal_cq(32'd0), .pal_we(), .oam_we(), .oam_cre(), .oam_cgnt(1'b1), .oam_cq(32'd0), .po_waddr(), .po_wdata(), .po_be(),
        .mon_we, .mon_master(), .mon_cpu(), .mon_addr, .mon_be, .mon_wdata);
 nds_mr_arb u_arb(.clk,.rst,.a_req(fm_req),.a_we(fm_we),.a_addr(fm_addr),.a_be(fm_be),.a_wdata(fm_wdata),.a_ack(fm_ack),.a_rvalid(fm_rvalid),.a_n8(fm_n8),.a_if4(fm_if4),.a_dmaw(fm_dmaw),.a_wnext(fm_wnext),
 .b_req(1'b0),.b_we(1'b0),.b_addr(21'd0),.b_wdata(32'd0),.b_ack(),.b_rvalid(),.mr_req,.mr_we,.mr_addr,.mr_be,.mr_wdata,.mr_ack,.mr_rvalid,.mr_n8,.mr_if4,.mr_dmaw,.mr_wnext,.a_ld4(fm_ld4),.mr_ld4);
 wire cke;wire[21:16]c0a,c1a;wire[15:0]c0dq,c1dq;wire c0w,c1w;
 wire c0adv,c1adv,c0cre,c1cre,c0ce0,c0ce1,c1ce0,c1ce1,c0oe,c1oe,c0we,c1we,c0ub,c0lb,c1ub,c1lb;
 nds_psram #(.T_INIT(100),.B8(1),.BW(1),.STREAM(1),.IF_STREAM4(1),.LDM_STREAM4(1)) u_phy(.clk_sys,.clk_mem,.reset_sys(rst_sys),.reset_mem(rst_mem),.initialized,
 .s_req(mr_req),.s_we(mr_we),.s_addr({3'b0,mr_addr}),.s_wdata(mr_wdata),.s_be(mr_be),.s_ack(mr_ack),.s_rvalid(mr_rvalid),.s_rdata(mr_rdata),.s_n8(mr_n8),.s_if4(mr_if4),.s_dmaw(mr_dmaw),.s_wnext(mr_wnext),.s_ld4(mr_ld4),
 .chip_clk_en(cke),.cram0_a(c0a),.cram1_a(c1a),.cram0_dq(c0dq),.cram1_dq(c1dq),.cram0_wait(c0w),.cram1_wait(c1w),
 .cram0_adv_n(c0adv),.cram1_adv_n(c1adv),.cram0_cre(c0cre),.cram1_cre(c1cre),.cram0_ce0_n(c0ce0),.cram0_ce1_n(c0ce1),.cram1_ce0_n(c1ce0),.cram1_ce1_n(c1ce1),
 .cram0_oe_n(c0oe),.cram1_oe_n(c1oe),.cram0_we_n(c0we),.cram1_we_n(c1we),.cram0_ub_n(c0ub),.cram0_lb_n(c0lb),.cram1_ub_n(c1ub),.cram1_lb_n(c1lb));
 h1_chips #(.NAME("lane2")) chips(.clk_mem,.clk_cram,.clk_en(cke),.c0a,.c1a,.c0dq,.c1dq,.c0w,.c1w,.c0adv,.c1adv,.c0cre,.c1cre,.c0ce0,.c0ce1,.c1ce0,.c1ce1,.c0oe,.c1oe,.c0we,.c1we,.c0ub,.c0lb,.c1ub,.c1lb);
 assign pins={cke,c0a,c1a,c0dq,c1dq,c0adv,c1adv,c0cre,c1cre,c0ce0,c0ce1,c1ce0,c1ce1,c0oe,c1oe,c0we,c1we,c0ub,c0lb,c1ub,c1lb};
 assign idle=u_fab.st==0 && !u_phy.busy && !u_phy.strm && u_phy.out_n==0 && u_arb.own==0;
 logic tail=0;int beat=0;logic[22:2]owned_base;
 always @(posedge clk_sys)begin
  if(rst_sys)begin tail<=0;beat<=0;end
  else begin
   if(mr_req&&mr_ack)begin
    if(mr_we)writes++;
    else begin reads++;tail<=1;beat<=0;owned_base<=mr_addr&~21'd3;$display("PHYSICAL lane2 read%0d base%h n8%b LD%b",reads,mr_addr&~21'd3,mr_n8,mr_ld4);end
   end
   if(tail)begin
    if(u_arb.own!=1||!u_arb.rd||mr_we||(mr_addr&~21'd3)!=owned_base)$fatal(1,"physical tail owner/address changed");
    if(mr_rvalid)begin beat<=beat+1;if(beat==(mr_n8?7:3))tail<=0;end
   end
  end
 end
endmodule

