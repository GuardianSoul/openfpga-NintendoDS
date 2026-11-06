`timescale 1ns/1ps
// Reuses the retained DMA/CAP_CHAIN pin-memory endpoint, without timing stubs.
module a7_read_pin_memory (
 input wire clk,clk_mem,rst,mem_init,output wire ready,idle,
 input wire mr_req,mr_we,mr_n8,mr_if4,mr_ld4,mr_dmaw,input wire[21:2]mr_addr,input wire[3:0]mr_be,input wire[31:0]mr_wdata,
 output wire mr_ack,mr_rvalid,output wire[31:0]mr_rdata,
 input wire mv,mw,mcut,allow_cut,input wire[23:0]ma,input wire[3:0]mn,mb,input wire[31:0]md,output wire mt,wv,output wire[31:0]wvdata,
 input wire bw_valid,input wire[55:0]bw_q,output wire bw_rd
);
 wire ps_init,ps_cke;logic clk_cram=0;always @(clk_mem)clk_cram<=#6.838 clk_mem;
 wire[21:16]p0a,p1a;wire[15:0]p0dq,p1dq;wire p0w,p1w;
 wire p0adv,p1adv,p0cre,p1cre,p0ce0,p0ce1,p1ce0,p1ce1,p0oe,p1oe,p0we,p1we,p0ub,p0lb,p1ub,p1lb;
 nds_psram #(.T_INIT(200),.B8(1),.BW(1),.STREAM(1),.IF_STREAM4(1),.IF_PREFILL8(1),.LDM_STREAM4(1),.DMA_WRITE_REISSUE(1),.DMA_WRITE_GROUP(1),.DMA_WRITE_CAPTURE_ACK(1)) psram(
 .clk_sys(clk),.clk_mem,.reset_sys(rst),.reset_mem(mem_init),.initialized(ps_init),
 .s_req(mr_req),.s_we(mr_we),.s_addr({2'd0,mr_addr}),.s_wdata(mr_wdata),.s_be(mr_be),.s_ack(mr_ack),.s_rvalid(mr_rvalid),.s_rdata(mr_rdata),.s_n8(mr_n8),.s_if4(mr_if4),.s_ld4(mr_ld4),.s_dmaw(mr_dmaw),.s_wgroup(1'b0),.s_wlast(1'b0),.s_wnext(),.s_ifseq(1'b0),.s_ifgen(2'b0),
 .chip_clk_en(ps_cke),.cram0_a(p0a),.cram1_a(p1a),.cram0_dq(p0dq),.cram1_dq(p1dq),.cram0_wait(p0w),.cram1_wait(p1w),
 .cram0_adv_n(p0adv),.cram1_adv_n(p1adv),.cram0_cre(p0cre),.cram1_cre(p1cre),.cram0_ce0_n(p0ce0),.cram0_ce1_n(p0ce1),.cram1_ce0_n(p1ce0),.cram1_ce1_n(p1ce1),
 .cram0_oe_n(p0oe),.cram1_oe_n(p1oe),.cram0_we_n(p0we),.cram1_we_n(p1we),.cram0_ub_n(p0ub),.cram0_lb_n(p0lb),.cram1_ub_n(p1ub),.cram1_lb_n(p1lb));
 wire[1:0]pclk;altddio_out #(.width(2))pck(.datain_h({2{ps_cke}}),.datain_l(2'b0),.outclock(clk_cram),.dataout(pclk),.aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
 if4_cram_model #(.NAME("main0"))chip0(.sclk(clk_mem),.clk(pclk[0]),.a(p0a),.dq(p0dq),.wait_o(p0w),.adv_n(p0adv),.cre(p0cre),.ce0_n(p0ce0),.ce1_n(p0ce1),.oe_n(p0oe),.we_n(p0we),.ub_n(p0ub),.lb_n(p0lb));
 if4_cram_model #(.NAME("main1"))chip1(.sclk(clk_mem),.clk(pclk[1]),.a(p1a),.dq(p1dq),.wait_o(p1w),.adv_n(p1adv),.cre(p1cre),.ce0_n(p1ce0),.ce1_n(p1ce1),.oe_n(p1oe),.we_n(p1we),.ub_n(p1ub),.lb_n(p1lb));
 wire main_idle=!psram.busy&&!psram.strm&&psram.out_n==0&&psram.state==psram.IDLE;
 function automatic logic[31:0]main_word(input int a);return {chip1.peek(a),chip0.peek(a)};endfunction
 wire[3:0]pv,pwe,pt,pwv,psv;wire[95:0]pa;wire[15:0]pn,pbe;wire[127:0]pd;wire[31:0]pwd,psd;
 assign pv={1'b0,mv,2'b00};assign pwe={1'b0,mw,2'b00};assign pa={24'd0,ma,48'd0};assign pn={4'd0,mn,8'd0};assign pbe={4'd0,mb,8'd0};assign pd={32'd0,md,64'd0};assign mt=pt[2];
 wire sdram_ready;wire[15:0]sdq;wire[12:0]sda;wire[1:0]sba,dqm;wire snwe,snras,sncas,scke,sclk;
 nds_sdram_bus #(.N(4),.OPEN(1),.OUT_REG(1),.CUT(1))sdram(.clk(clk_mem),.init(mem_init),.ready(sdram_ready),.m_cut({1'b0,mcut&&allow_cut,2'b00}),.m_hurry(4'd0),.m_valid(pv),.m_we(pwe),.m_addr(pa),.m_n(pn),.m_wdata(pd),.m_be(pbe),.m_take(pt),.w_valid(pwv),.w_data(pwd),.bw_valid,.bw_addr(bw_q[55:32]),.bw_data(bw_q[31:0]),.bw_read(bw_rd),.ref_late(),.SDRAM_DQ(sdq),.SDRAM_A(sda),.SDRAM_BA(sba),.SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),.SDRAM_nWE(snwe),.SDRAM_nRAS(snras),.SDRAM_nCAS(sncas),.SDRAM_CKE(scke),.SDRAM_CLK(sclk));
 nds_sdram_words #(.N(4),.SEL(4'b0100),.A(4))words_sys(.clk_mem,.w_valid(pwv),.w_data(pwd),.rclk(clk),.o_valid(psv),.o_data(psd));
 assign wv=psv[2];assign wvdata=psd;wire #2.0 chip_clk=sclk;
 sdram_chip_model #(.CAS(3),.T_AC(6.0),.T_OH(2.5),.T_RET(2.0),.NAME("VRAM"))dram_chip(.clk(chip_clk),.cke(scke),.ncs(1'b0),.nras(snras),.ncas(sncas),.nwe(snwe),.a(sda),.ba(sba),.dqm,.dq(sdq));
 function automatic int chip_index(input int w);return ((w>>21&3)<<23)|((w>>8&8191)<<10)|((w>>23&1)<<9)|((w&255)<<1);endfunction
 function automatic logic[31:0]vram_word(input int a);return {dram_chip.peek(chip_index(a)+1),dram_chip.peek(chip_index(a))};endfunction
 assign ready=ps_init&&sdram_ready;
 assign idle=main_idle&&!mv&&!bw_valid&&sdram.mc.st==sdram.mc.S_IDLE&&sdram.mc.rd_tag==0&&!sdram.mc.r_valid&&!wv;
 initial begin
  #1;
  for(int a=0;a<32'h10000;a++)begin logic[31:0]v;v=32'h02000000^(32'(a)<<2)^32'h13579bdf;chip0.mem[a]=v[15:0];chip1.mem[a]=v[31:16];end
  for(int a=0;a<32'h20000;a++)begin logic[31:0]v;v=a>=32'h10040&&a<32'h10060 ? 32'hd34a8000+32'(a-32'h10040):32'hc001c0de^32'(a);dram_chip.mem[chip_index(a)]=v[15:0];dram_chip.mem[chip_index(a)+1]=v[31:16];end
 end
 final begin
  $display("PIN_MEMORY errors%0d/%0d/%0d",chip0.errors,chip1.errors,dram_chip.errors);
  if(chip0.errors||chip1.errors||dram_chip.errors)$fatal(1,"physical pin memory protocol errors");
 end
endmodule
