`timescale 1ns/1ps
// Ordered DMA main-to-GX/FIFO/I/O stream against independent source words.
// Cover target backpressure, concurrent sound reads, exactly-once monitor
// events, the unit pacing floor and a CPU read after the final posted word.
`default_nettype none
module tb_dma_words #(parameter TURN=0, TAIL=0, WCAP=0, PIPE=0, ENABLE=1, EARLY=1, OVERLAP=0, REISSUE=1, GROUP=0, ARB_GROUP=GROUP, SOURCE=1, PBW=1, START=0);
    logic clk = 0, rst = 1;
    // Root PLL simulation phase/period: sys=2*bus, mem=3*bus.
    initial begin #14.919;forever begin clk=1;#7.460;clk=0;#7.459;end end
    logic clk_mem=0; always #4.973 clk_mem=!clk_mem;
    // ARM9 and ARM7 ports
    logic        a9_req = 0, a9_we = 0, a9_n8 = 0;
    logic [31:0] a9_addr = 0, a9_wdata = 0;
    logic [3:0]  a9_be = 0;
    logic        a9_ack, a9_rvalid, a9_wnext;
    logic [31:0] a9_rdata;
    logic        a7_req = 0, a7_we = 0;
    logic [31:0] a7_addr = 0, a7_wdata = 0;
    logic [3:0]  a7_be = 0;
    logic        a7_ack;
    logic [31:0] a7_rdata;
    // main RAM
    logic        fm_req, fm_we, fm_ack, fm_rvalid, fm_n8, fm_wnext;wire fm_dmaw,mr_dmaw;wire dwgroup,dlast,fwgroup,fwlast,mwgroup,mwlast;
    logic [21:2] fm_addr;
    logic [3:0]  fm_be;
    logic [31:0] fm_wdata;
    logic        mr_req, mr_we, mr_n8;
    logic [22:2] mr_addr;
    logic [3:0]  mr_be;
    wire [31:0] mr_wdata, mr_rdata;
    wire mr_ack, mr_rvalid, mr_wnext;
    logic        mon_we;
    logic [31:0] mon_addr, mon_wdata;
    logic [3:0]  mon_be;
    wire dm_req, dm_we, dm_unit, dm_size32, dm_ack, dm_cpu, dm_vcut;
    wire [31:0] dm_addr,dm_dst,dm_wdata,dm_rdata;
    wire vr_req, vr_we, vr_ack,vr_cpu,vr_cut;
    wire[3:0] vr_be;wire[31:0] vr_wdata;
    logic [23:2] vr_addr;
    wire[31:0] vr_rdata;wire vr_dma_read;
    logic sn_req=0, sn_ack;
    logic [31:0] sn_rdata;
    logic sn_we=0;logic[31:0] sn_addr=32'h020003fc,sn_wdata=0;
    logic [1:0] mon_master;
    logic dx_valid, dx_ready=1, dx_idle;
    logic io_req, io_we, io_ack=0;
    logic [3:0] io_be;
    logic [31:0] io_wdata;
    logic [31:0] ioreg[64];
    logic [23:2] io_addr;
    logic [31:0] io_rdata=0, pal_cq=0;
    logic [8:0] po_waddr;
    wire more;
    nds_fabric #(
`ifndef OLD_FAB

`ifndef OLD_PIPE
 .DMA_WRITE_CAPTURE_ACK(PIPE),
`endif
 .DMA_VRAM_OVERLAP(OVERLAP),
`endif
`ifndef OLD_READ_GRANT
      .DMA_READ_EARLY(START),
`endif
      .A7_IO(1), .MR_BLOCK(1), .DMA_FAST(1), .DMA_RA(2), .VRAM_WRITE_CUT(ENABLE ? 3 : 0), .DMA_GX(1), .DMA_PACE(52), .DMA_PACE_GX(34)) u_fab (.clk, .rst, .dm_vcut(dm_vcut), .dm_unit(dm_unit), .dm_more(more), .dm_dst(dm_dst), .dx_valid(dx_valid), .dx_ready(dx_ready), .dx_idle(dx_idle), .wramcnt(2'd3), .exmemcnt9(8'd0), .pb_busy(1'b0),
        .dm_req(dm_req), .dm_we(dm_we), .dm_cpu(dm_cpu), .dm_size32(dm_size32), .dm_addr(dm_addr), .dm_wdata(dm_wdata), .dm_ack(dm_ack), .dm_rdata(dm_rdata),
        .a9_tmr(4'd0), .a9_req, .a9_we, .a9_addr, .a9_be, .a9_wdata, .a9_ack, .a9_rdata, .a9_n8, .a9_rvalid, .a9_wnext,
        .a7_req, .a7_we, .a7_addr, .a7_be, .a7_wdata, .a7_ack, .a7_rdata,
        .sn_req(sn_req), .sn_we(sn_we), .sn_addr(sn_addr), .sn_wdata(sn_wdata), .sn_ack(sn_ack), .sn_rdata(sn_rdata),
        .mr_req(fm_req), .mr_we(fm_we), .mr_addr(fm_addr), .mr_be(fm_be), .mr_wdata(fm_wdata),

`ifndef OLD_FAB
        .mr_dmaw(fm_dmaw),
`ifndef OLD_GROUP
        .dm_wgroup(dwgroup),.dm_last(dlast),.mr_wgroup(fwgroup),.mr_wlast(fwlast),
`endif
`endif
        .mr_ack(fm_ack), .mr_rvalid(fm_rvalid), .mr_rdata, .mr_n8(fm_n8), .mr_wnext(fm_wnext),
        .fx_req(), .fx_we(), .fx_addr(), .fx_be(), .fx_wdata(), .fx_done(1'b0), .fx_rdata(32'd0),
        .boot_addr(), .boot_q(32'd0), .ram_wdata(),
        .io_req(io_req), .io_cpu(), .io_we(io_we), .io_be(io_be), .io_addr(io_addr), .io_wdata(io_wdata), .io_ack(io_ack), .io_rdata(io_rdata),

`ifndef OLD_SOURCE
        .vr_dma_read(vr_dma_read),
`else
`endif
        .vr_cut(vr_cut), .vr_req(vr_req), .vr_cpu(vr_cpu), .vr_we(vr_we), .vr_addr(vr_addr), .vr_be(vr_be), .vr_wdata(vr_wdata), .vr_ack(vr_ack), .vr_rdata(vr_rdata),
        .oam_cq(32'd0), .pal_cq(pal_cq), .pal_we(), .oam_we(), .po_waddr(po_waddr), .po_wdata(), .po_be(),
        .mon_we, .mon_master(mon_master), .mon_cpu(), .mon_addr, .mon_be, .mon_wdata);
`ifdef OLD_FAB
    assign fm_dmaw=0;assign mr_dmaw=0;
`endif
`ifdef OLD_GROUP
    assign dwgroup=0;assign dlast=0;assign fwgroup=0;assign fwlast=0;assign mwgroup=0;assign mwlast=0;
`endif
    logic poly_req=0;wire poly_ack,poly_rvalid;
    nds_mr_arb
`ifndef OLD_GROUP
      #(.DMA_WRITE_GROUP(ARB_GROUP)
`ifndef OLD_PIPE
 , .DMA_WRITE_CAPTURE_ACK(PIPE)
`endif
)
`endif
      u_arb (.clk, .rst,
        .a_req(h_gap?1'b0:h_on?1'b1:fm_req), .a_we(h_on?h_we:fm_we), .a_addr(h_on?h_addr:fm_addr), .a_be(h_on?h_be:fm_be), .a_wdata(h_on?h_data:fm_wdata), .a_ack(fm_ack), .a_rvalid(fm_rvalid),
        .a_n8(h_on?h_n8:fm_n8),
`ifndef OLD_FAB
        .a_dmaw(h_on?h_dmaw:fm_dmaw),.mr_dmaw(mr_dmaw),
`ifndef OLD_GROUP
        .a_wgroup(h_on?h_group:fwgroup),.a_wlast(h_on?h_last:fwlast),.mr_wgroup(mwgroup),.mr_wlast(mwlast),
`endif
`endif
        .a_wnext(fm_wnext),
        .b_req(poly_req), .b_we(1'b0), .b_addr(21'h100000), .b_wdata(32'd0), .b_ack(poly_ack), .b_rvalid(poly_rvalid),
        .mr_req, .mr_we, .mr_addr, .mr_be, .mr_wdata, .mr_ack, .mr_rvalid, .mr_n8, .mr_wnext);




    wire ps_init,ps_cke;
    wire[21:16] p0a,p1a;wire[15:0]p0dq,p1dq;wire p0w,p1w;
    wire p0adv,p1adv,p0cre,p1cre,p0ce0,p0ce1,p1ce0,p1ce1,p0oe,p1oe,p0we,p1we,p0ub,p0lb,p1ub,p1lb;
    logic clk_cram=0;always @(clk_mem)clk_cram<=#6.838 clk_mem;
    nds_psram #(
`ifndef OLD_FAB
      .DMA_WRITE_REISSUE(REISSUE),
`ifndef OLD_GROUP

`ifndef OLD_PIPE
 .DMA_WRITE_CAPTURE_ACK(PIPE),
`endif
 .DMA_WRITE_GROUP(GROUP),
`endif
`endif
      .T_INIT(200),.B8(1),.BW(PBW),.STREAM(1)) psram(.clk_sys(clk),.clk_mem,.reset_sys(rst),.reset_mem(mem_init),.initialized(ps_init),
      .s_req(mr_req),.s_we(mr_we),.s_addr({3'd0,mr_addr}),.s_wdata(mr_wdata),.s_be(mr_be),.s_ack(mr_ack),.s_rvalid(mr_rvalid),.s_rdata(mr_rdata),.s_n8(mr_n8),.s_if4(1'b0),
`ifndef OLD_FAB
      .s_dmaw(mr_dmaw),
`ifndef OLD_GROUP
      .s_wgroup(mwgroup),.s_wlast(mwlast),
`endif
`endif
      .s_wnext(mr_wnext),
      .chip_clk_en(ps_cke),.cram0_a(p0a),.cram1_a(p1a),.cram0_dq(p0dq),.cram1_dq(p1dq),.cram0_wait(p0w),.cram1_wait(p1w),
      .cram0_adv_n(p0adv),.cram1_adv_n(p1adv),.cram0_cre(p0cre),.cram1_cre(p1cre),.cram0_ce0_n(p0ce0),.cram0_ce1_n(p0ce1),.cram1_ce0_n(p1ce0),.cram1_ce1_n(p1ce1),
      .cram0_oe_n(p0oe),.cram1_oe_n(p1oe),.cram0_we_n(p0we),.cram1_we_n(p1we),.cram0_ub_n(p0ub),.cram0_lb_n(p0lb),.cram1_ub_n(p1ub),.cram1_lb_n(p1lb));
    wire[1:0]pclk;
    altddio_out #(.width(2)) pck(.datain_h({2{ps_cke}}),.datain_l(2'b0),.outclock(clk_cram),.dataout(pclk),
      .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
    if4_cram_model #(.NAME("main0")) chip0(.sclk(clk_mem),.clk(pclk[0]),.a(p0a),.dq(p0dq),.wait_o(p0w),
      .adv_n(p0adv),.cre(p0cre),.ce0_n(p0ce0),.ce1_n(p0ce1),.oe_n(p0oe),.we_n(p0we),.ub_n(p0ub),.lb_n(p0lb));
    if4_cram_model #(.NAME("main1")) chip1(.sclk(clk_mem),.clk(pclk[1]),.a(p1a),.dq(p1dq),.wait_o(p1w),
      .adv_n(p1adv),.cre(p1cre),.ce0_n(p1ce0),.ce1_n(p1ce1),.oe_n(p1oe),.we_n(p1we),.ub_n(p1ub),.lb_n(p1lb));
    import gpu2d_pkg::*;
    logic[71:0] vramcnt=72'h000000000000008080;
    logic cnt_we=0,cpucfg=0;logic[31:0] cfg_src,cfg_dst,cfg_cnt;logic[4:0] reg_a;logic[63:0] reg_d=0;
    wire[7:0] enq;wire[1:0] busy;
    sys_dma #(.FAST(1)) dmac(.clk,.rst,.cnt_we,.cpu(cpucfg),.ch(2'd3),.be(4'hf),.wdata(cfg_cnt),.en_q(enq),
      .reg_gnt(1'b1),.reg_raddr(reg_a),.reg_rd(reg_d),.trig9(7'd0),.gx_low(1'b0),.stop9(7'd0),.trig7(3'd0),
      .m_req(dm_req),.m_we(dm_we),.m_cpu(dm_cpu),.m_size32(dm_size32),.m_addr(dm_addr),.m_vcut(dm_vcut),

`ifndef OLD_GROUP
      .m_wgroup(dwgroup),.m_last(dlast),
`endif
      .m_unit(dm_unit),.m_dst(dm_dst),.m_more(more),.m_wdata(dm_wdata),.m_ack(dm_ack),.m_rdata(dm_rdata),.busy,.irq9(),.irq7(),.dbg_run(),.lat_lost());
    always @(posedge clk)reg_d<=reg_a[3:2]==0?{cfg_dst,cfg_src}:{32'd0,cfg_cnt};
    wire vm_cut,sf;wire vm_req,vm_we,vm_blk,vm_ack,vm_rvalid;wire[20:2] vm_addr;wire[31:0] vm_wdata,vm_rdata;wire[3:0] vm_be;
    logic g_req=0;blk_t g_blk;wire g_ack,g_rvalid;wire[63:0] g_rdata;
`ifdef OLD_SOURCE
    assign vr_dma_read=0;
`endif
    logic cap_we=0;logic[17:0]cap_addr=0;logic[15:0]cap_data=0;wire cap_ready;wire cw_valid,cw_ack;wire[23:0]cw_addr;wire[31:0]cw_data;
    nds_vram #(
`ifdef NEW_TAIL
      .DMA_WRITE_TAIL(TAIL),
`endif
`ifndef OLD_SOURCE
      .DMA_READ_EARLY(SOURCE),
`endif
`ifndef ORIGINAL
      .WRITE_ACCEPT_EARLY(EARLY),
`endif

`ifndef OLD_PIPE
 .DMA_READ_RETURN_EARLY(PIPE),
`ifndef OLD_WCAP
 .DMA_WRITE_CAPTURE_EARLY(WCAP),
`endif

`endif
 .CAP_CHAIN(1),.CRB(1)) vram(.clk,.rst,.vramcnt,.c_cut(vr_cut),
`ifndef OLD_SOURCE
      .c_dma_read(vr_dma_read),
`endif
      .c_req(vr_req),.c_cpu(vr_cpu),.c_we(vr_we),
      .c_addr(vr_addr),.c_be(vr_be),.c_wdata(vr_wdata),.c_ack(vr_ack),.c_rdata(vr_rdata),
      .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata,.cap_we,.cap_addr,.cap_data,.cap_ready,.cw_valid,.cw_addr,.cw_data,.cw_ack,
      .sv_req(1'b0),.sv_we(1'b0),.sv_addr(19'd0),.sv_be(4'd0),.sv_wdata(32'd0),.sv_ack(),.sv_rdata(),
      .vm_cut,.vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,
`ifndef OLD_PIPE

`ifndef OLD_WCAP
 .vm_write_capture(write_capture),
`endif
.vm_early_rvalid(rawv),.vm_early_rdata(rawd),
`endif
 .vramstat());
    wire sq,sw,sb,sa,srv;wire[23:0] saddr;wire[31:0] swd,srd;wire[3:0] sbe;
    nds_vm_split #(.OCT(1)) split(.clk,.reset(rst),.vm_cut,.vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,
      .s_cut(sf),.s_req(sq),.s_we(sw),.s_quad(sb),.s_addr(saddr),.s_wdata(swd),.s_be(sbe),.s_ack(sa),.s_rvalid(srv),.s_rdata(srd));
    wire write_capture;wire held_cut;wire rawv;wire[31:0]rawd;
`ifdef OLD_PIPE
 assign rawv=0;assign rawd=0;
`endif

    bit dma_phase=0, manual_cut=0;bit expected_held=0;int class_checks=0;
    wire mv,mw,mt;wire[23:0] ma;wire[3:0] mn,mb;wire[31:0] md;
    wire wv;wire[31:0]wd;
    nds_sdram_xport #(
`ifdef NEW_TURN
 .CUT_WRITE_TURN(TURN),
`endif
 .QW(8),.SHARED(1),.CUT_TAG(ENABLE)) xp(.clk_sys(clk),.clk_mem,.reset(rst),.s_cut(sf),.s_req(sq),.s_we(sw),.s_quad(sb),.s_addr(saddr),.s_wdata(swd),.s_be(sbe),
      .s_ack(sa),.s_rvalid(srv),.s_rdata(srd),
`ifndef OLD_PIPE

`ifndef OLD_WCAP
 .s_write_capture(write_capture),
`endif
.s_early_rvalid(rawv),.s_early_rdata(rawd),
`endif
 .m_cut(held_cut),.m_valid(mv),.m_we(mw),.m_addr(ma),.m_n(mn),.m_wdata(md),.m_be(mb),.m_take(mt),.w_valid(wv),.w_data(wd));
    int cyc=0,mc=0,seed=1,ops=128,mode=0,words=0,desc=0,phys=0,srcstate=0,srcwait=0,srcbeat=0,started,finished;
    logic[21:2] srcbase;
    bit stress=0,running=0,vm_direction=0,unmapped=0,cap_race=0,cap_injected=0;int destoff=0;int phase=1;int main_writes=0;
    logic[31:0] actual[int],expected[int],main_expected[int];
    logic[31:0] digest=0,monhash=0;
    int read_addr[$],read_n[$];int rn=0,ra=0,rdelay=0;
    function automatic logic[31:0] source(input logic[31:0] a);return 32'(a[21:2])*32'h9e3779b9^32'h12345678;endfunction
    function automatic logic[31:0] initial_word(input int a);return 32'(a)^32'hc001c0de;endfunction
    function automatic logic[31:0] actual_word(input int a);return actual.exists(a)?actual[a]:initial_word(a);endfunction
    function automatic logic[31:0] expected_word(input int a);return expected.exists(a)?expected[a]:initial_word(a);endfunction
    // Real physical take is supplied by the SDRAM arbiter/controller below.
    // Test-owned expected class follows the programmed transaction stream,
    // not the DUT's grant/mst/uvr fields. Read/block traffic must be untagged.
    always @(posedge clk)if(!rst && (!xp.busy || write_capture) && sq && !sa)begin
      expected_held=ENABLE && sw && (dma_phase ? (!vm_direction && !cpucfg && cfg_cnt[26] && cfg_cnt[24:23]==0 && (cfg_cnt[22:21]==0 || cfg_cnt[22:21]==3)) : manual_cut);
      if(sf!==expected_held)$fatal(1,"request class %0d/%0d",sf,expected_held);
    end
    always @(posedge clk_mem)begin
      mc++;
      if(mv && !rst)begin class_checks++;if(held_cut!==expected_held)$fatal(1,"held class mismatch");end
      if(mt)begin
        if(mw)begin
          logic[31:0] x;x=actual_word(int'(ma));for(int b=0;b<4;b++)if(mb[b])x[b*8+:8]=md[b*8+:8];actual[int'(ma)]=x;phys++;
        end else begin
          $display("VRREAD %06h %0d",ma,mn);

        end
      end
    end
    always @(posedge clk)begin
      cyc++;io_ack<=io_req;
      if(!rst && (!xp.busy || write_capture) && sq && !sa && sw)desc++;
      if(dm_req && dm_unit && !vm_direction && dm_vcut !== (!cpucfg && cfg_cnt[26] && cfg_cnt[24:23]==0 && (cfg_cnt[22:21]==0 || cfg_cnt[22:21]==3)))$fatal(1,"class hint mismatch");
      if(mon_we && mon_master==0 && (mon_addr[31:24]==8'h06 || mon_addr[31:24]==8'h02))begin
        logic[31:0] ea,es,ed,x;int step,nbytes;
        if(!vm_direction && !unmapped && desc<=words)$fatal(1,"ACK before descriptor capture words%0d desc%0d addr%h c_res%h vc%h vrreq%0d wr%0d cpu%0d st%0d vmack%0d",words,desc,mon_addr,vram.c_res,vramcnt,vr_req,vr_we,vr_cpu,vram.st,vm_ack);
        nbytes=cfg_cnt[26]?4:2;
        es=cfg_src+32'(words)*(cfg_cnt[24:23]==0?nbytes:cfg_cnt[24:23]==1?-nbytes:0);
        ea=cfg_dst+32'(words)*(cfg_cnt[22:21]==0 || cfg_cnt[22:21]==3?nbytes:cfg_cnt[22:21]==1?-nbytes:0);
        ed=vm_direction?(unmapped?32'd0:initial_word(mode==12?(32'h10000|int'(es[17:2])):int'(es[19:2]))):source(es);if(cap_race && cap_injected && vm_direction && es==cfg_src+4)ed=32'hcafebeef;
        if(!cfg_cnt[26])begin ed=es[1]?{2{ed[31:16]}}:{2{ed[15:0]}};end
        if(mon_addr!=={ea[31:1],1'b0} || mon_wdata!==ed || mon_be!==(cfg_cnt[26]?4'hf:ea[1]?4'hc:4'h3))$fatal(1,"ordered monitor%0d addr%h/%h data%h/%h be%h",words,mon_addr,ea,mon_wdata,ed,mon_be);
        if(vm_direction)begin
          x=main_expected.exists(int'(ea[21:2]))?main_expected[int'(ea[21:2])]:source(ea);
          for(int b=0;b<4;b++)if(mon_be[b])x[b*8+:8]=ed[b*8+:8];
          main_expected[int'(ea[21:2])]=x;
        end else begin
        x=expected_word(mode==5?(32'h10000|int'(ea[17:2])):int'(ea[19:2]));for(int b=0;b<4;b++)if(mon_be[b])x[b*8+:8]=ed[b*8+:8];expected[mode==5?(32'h10000|int'(ea[17:2])):int'(ea[19:2])]=x;
        end
        monhash={monhash[26:0],monhash[31:27]}^ea^ed^{28'd0,mon_be};words++;
      end
      if(mr_req && mr_ack && mr_we)begin
        main_writes++;
        $display("MAINWRITE %06h %08h %h",mr_addr,mr_wdata,mr_be);
      end

    end
    task automatic cpu_read(input logic[31:0] a,output logic[31:0] v);
      @(negedge clk);a9_req=1;a9_we=0;a9_addr=a;a9_be=15;do @(posedge clk);while(!a9_ack);v=a9_rdata;@(negedge clk);a9_req=0;
    endtask
    task automatic manual_write(input int master,input[31:0] address,input[31:0] data,input[3:0] be,input bit eligible);
      wait(!xp.busy);@(negedge clk);manual_cut=eligible;vm_capture_cyc=-1;
      if(master==9)begin a9_req=1;a9_we=1;a9_n8=0;a9_addr=address;a9_wdata=data;a9_be=be;do @(posedge clk);while(!a9_ack);end
      else if(master==7)begin a7_req=1;a7_we=1;a7_addr=address;a7_wdata=data;a7_be=be;do @(posedge clk);while(!a7_ack);end
      else begin sn_req=1;sn_we=1;sn_addr=address;sn_wdata=data;do @(posedge clk);while(!sn_ack);end
      @(negedge clk);a9_req=0;a7_req=0;sn_req=0;wait(!xp.busy);manual_cut=0;
    endtask
    bit hold_take=0;
    task automatic fast_store(input int k);
      @(negedge clk);a7_req=1;a7_we=1;a7_addr=32'h06018000+32'(4*k);a7_be=15;a7_wdata=32'h67ab0000+32'(k);manual_cut=1;vm_capture_cyc=-1;
      do @(posedge clk);while(!a7_ack);
      @(negedge clk);a7_req=0;
    endtask
    int poly_done=0,sound_done=0,arm7_done=0,reissues=0,finish_waits=0;
    task automatic polygon_read;
      // Force an original-priority B winner to coincide with a qualified
      // incoming A word; the bypass must remain closed on this edge.
      if(vm_direction && !cpucfg && cfg_cnt[26])wait((u_fab.st==u_fab.S_WAIT || u_fab.st==u_fab.S_GO) && vr_ack && u_fab.u);
      @(negedge clk);poly_req=1;
      do @(posedge clk);while(!poly_ack);
      @(negedge clk);poly_req=0;
      for(int k=0;k<4;k++)begin
        logic[15:0] halfword;int word_index;word_index=32'h100000+k;
        do @(posedge clk);while(!poly_rvalid);
        halfword=16'(word_index)^(16'(word_index>>7)*16'h3b)^16'h5a5a;
        if(mr_dmaw || mr_rdata!=={halfword,halfword})$fatal(1,"polygon descriptor/data mixed with DMA");
      end
      poly_done++;
    endtask
    task automatic sound_read;
      @(negedge clk);sn_req=1;sn_we=0;sn_addr=32'h020003fc;
      do @(posedge clk);while(!sn_ack);
      if(sn_rdata!==source(sn_addr))$fatal(1,"sound descriptor/data mixed with DMA");
      @(negedge clk);sn_req=0;sound_done++;
    endtask
    task automatic arm7_read;
      logic[31:0]address,want;
      address=mode==8?cfg_dst:32'h020003fc;
      want=mode==8?initial_word(int'(cfg_src[19:2])):source(address);
      @(negedge clk);a7_req=1;a7_we=0;a7_addr=address;a7_be=15;
      do @(posedge clk);while(!a7_ack);
      if(a7_rdata!==want)$fatal(1,"ARM7 fenced read visibility mismatch");
      @(negedge clk);a7_req=0;arm7_done++;
    endtask
    always @(posedge clk)if(!rst && GROUP && u_arb.own==u_arb.O_NONE && poly_req && u_arb.last_a && mr_req)
      $fatal(1,"wrong owner grouped write bypass");
    int groups=0,group_words=0,within_bank=0,group_captures=0,gmemcycle=0;realtime last_start=0;
    always @(posedge clk_mem)begin
      gmemcycle++;
`ifndef OLD_GROUP
      if(!psram.reset_mem_i && psram.state==psram.IDLE && psram.req_valid && psram.req_group)begin
        groups++;group_words+=int'(psram.req_gcount);within_bank=0;
        $display("GROUP bank%0d count%0d base%06h",psram.req_gbank,psram.req_gcount,psram.b_word);
      end
      if(psram.write_en && psram.req_group)begin
        if(within_bank>0 && ($realtime-last_start<109.405 || $realtime-last_start>109.407))$fatal(1,"group write inner cadence changed delta%0d",$time-last_start);
        $display("GSTART mem%0d t%0t word%0d addr%06h",gmemcycle,$time,within_bank,psram.chip_addr);
        within_bank++;last_start=$realtime;
      end
`endif
    end
    always @(posedge clk)if(!rst && dma_phase)begin
      `ifndef OLD_GROUP
      if(GROUP && psram.g_accept)begin
        group_captures++;
        $display("GCAP cycle%0d addr%06h last%0d bank%0d index%0d",cyc,mr_addr,mwlast,psram.g_bank,psram.g_count);
      end
      if(dm_req && dm_unit && u_fab.st==u_fab.S_IDLE && u_fab.grant[0] && (dwgroup !== (vm_direction && !cpucfg && cfg_cnt[26] && cfg_cnt[24:23]==0 && (cfg_cnt[22:21]==0 || cfg_cnt[22:21]==3)) || dlast !== (words==ops-1)))$fatal(1,"programmed group/last metadata mismatch");
      if(GROUP && dm_ack && dlast && dwgroup && (psram.busy || psram.g_count!=0 || psram.cbusy!=0))$fatal(1,"DMA final ACK before durable physical drain");
`endif
      if(mr_req && mr_dmaw && (!vm_direction || cpucfg || !cfg_cnt[26] || cfg_cnt[24:23]!=0 || !mr_we || mr_be!=15))
        $fatal(1,"DMA write class on unqualified owner");
      if(mr_req && mr_we && psram.busy && psram.b_write && psram.done_t!=psram.done_seen)begin
        finish_waits++;
        $display("WRITEBOUNDARY cycle%0d reissue%0d",cyc,REISSUE && mr_dmaw);
`ifndef OLD_FAB
        if(psram.dma_reissue)reissues++;
`endif
      end
    end
    task automatic capture_source_word;
      wait(vram.st==vram.S_CFILL && vr_ack && u_fab.u);
      @(negedge clk);cap_addr=18'((int'(cfg_src[19:2])+1)*2);cap_data=16'hbeef;
      while(!cap_ready)@(negedge clk);cap_we=1;
      @(negedge clk);cap_we=0;cap_addr=cap_addr+1;cap_data=16'hcafe;
      while(!cap_ready)@(negedge clk);cap_we=1;
      @(negedge clk);cap_we=0;cap_injected=1;
    endtask
    initial begin
      logic[31:0] v;
      void'($value$plusargs("ops=%d",ops));void'($value$plusargs("phase=%d",phase));void'($value$plusargs("mode=%d",mode));stress=$test$plusargs("stall");cap_race=$test$plusargs("cap_race");void'($value$plusargs("offset=%d",destoff));
      cfg_src=32'h02001000;cfg_dst=32'h06804000;
      cfg_cnt=32'h84000000|32'(ops);if(mode==1)cfg_cnt|=32'h00200000;if(mode==2)cfg_cnt|=32'h00400000;if(mode==3)cfg_cnt|=32'h00600000;
      if(mode==4)cfg_cnt&=~32'h04000000;if(mode==5)begin cpucfg=1;cfg_dst=32'h06004000;vramcnt=72'h000000000000820000;end
      if(mode==6)cfg_cnt|=32'h00800000;if(mode==7)cfg_cnt|=32'h01000000;
      if(mode>=8 && mode<=12 || mode==15 || mode==16)begin
        vm_direction=1;cfg_src=32'h06804000;cfg_dst=32'h02003000;
        if(mode==9)cfg_cnt|=32'h00200000;
        if(mode==10)cfg_cnt|=32'h00400000;
        if(mode==16)cfg_cnt|=32'h00600000;
        if(mode==11)cfg_cnt&=~32'h04000000;
        if(mode==12)begin cpucfg=1;cfg_src=32'h06004000;vramcnt=72'h000000000000820000;end
      end
      if(mode==14 || mode==15)begin vramcnt=0;unmapped=1;end
      if(vm_direction)cfg_dst+=32'(4*destoff);
      for(int a=0;a<32'h20000;a++)begin logic[31:0]x;x=initial_word(a);dram_chip.mem[chip_index(a)]=x[15:0];dram_chip.mem[chip_index(a)+1]=x[31:16];end
      for(int i=0;i<8192;i++)begin logic[31:0]x;x=source(32'h02000000+32'(4*i));chip0.mem[i]=x[15:0];chip1.mem[i]=x[31:16];end
      repeat(8)@(negedge clk);rst=0;wait(ps_init && sdram_ready);
      // Prime the CPU block buffer before a DMA write into the same block.
      if(mode!=5 && mode!=12)cpu_read(cfg_dst,v);
      @(negedge clk);cnt_we=1;started=cyc;running=1;dma_phase=1;@(negedge clk);cnt_we=0;
      if(cap_race)fork capture_source_word();join_none
      if(stress && ops>=18)fork
        begin wait(words>=2);polygon_read();wait(words>=14);polygon_read();end
        begin wait(words>=3);sound_read();wait(words>=17);sound_read();end
        begin wait(words>=5);arm7_read();end
      join_none
      wait(enq[cpucfg?7:3]);wait(!enq[cpucfg?7:3]);
      // Intentional cancellation is checked by reset_actual_turn, not the
      // complete-copy cardinality/readback path below.
      if($test$plusargs("reset_turn"))wait(1'b0);
      finished=cyc;running=0;dma_phase=0;
      $display("DMAEND src%h dst%h rem%h cnt%h en%h run%h inprog%h",dmac.e_src,dmac.e_dst,dmac.e_rem,dmac.e_cnt,dmac.en,dmac.run,dmac.inprog);
      wait(g_done && cap_done);wait(bw_empty && !xp.busy && !mv);repeat(40)@(negedge clk);
      for(int j=0;j<(stress?8:0);j++)if(pin_word(32'h18040+j)!=={16'hbeef+16'(j),16'h5a00+16'(j)})$fatal(1,"CAP_CHAIN durable word%0d",j);
      if(stress && ops>=18)wait(poly_done==2 && sound_done==2 && arm7_done==1);
      if(mode==5 || mode==12)vramcnt=72'h000000000000800000;
      if(words!=ops)$fatal(1,"word count%0d/%0d",words,ops);
      // All words around the destination, including unwritten guards. ARM7 map goes to bankC.
      for(int i=-ops-4;i<ops+4;i++)begin
        logic[31:0] a;a=cfg_dst+32'(i*4);if(vm_direction)begin
          logic[31:0]want;int key;key=int'(a[21:2]);
          cpu_read(a,v);want=main_expected.exists(key)?main_expected[key]:source(a);
          if(v!==want)$fatal(1,"MAIN DMA readback %h got%h want%h",a,v,want);
        end else if(unmapped)begin cpu_read(a,v);if(v!==0)$fatal(1,"unmapped DMA response");
        end else if(mode==5)begin
          // CPU ARM9 reads bankC through LCDC, preserving the ARM7 view translation.
          cpu_read(32'h06840000+{14'd0,a[17:2],2'd0},v);
          if(v!==expected_word(32'h10000|int'(a[17:2])))$fatal(1,"ARM7 readback%h/%h",v,expected_word(32'h10000|int'(a[17:2])));
        end else begin cpu_read(a,v);if(v!==expected_word(int'(a[19:2])))$fatal(1,"readback addr%h got%h expected%h",a,v,expected_word(int'(a[19:2])));end
        digest={digest[26:0],digest[31:27]}^v;
      end
      repeat(30)@(negedge clk);
      // ARM7 CPU word/half stores are separate from the false-class ARM7 DMA case.
      vramcnt=72'h000000000000820000;
      manual_write(7,32'h06012000,32'h13579bdf,15,1);
      manual_write(7,32'h06012000,32'h00002468,3,0);
      vramcnt=72'h000000000000800000;
      cpu_read(32'h06852000,v);if(v!==32'h13572468)$fatal(1,"ARM7 word/half payload %h",v);
      manual_write(9,32'h06852004,32'h89abcdef,15,0);
      manual_write(9,32'h06852004,32'h55550000,12,0);
      cpu_read(32'h06852004,v);if(v!==32'h5555cdef)$fatal(1,"ARM9 fallback payload %h",v);
      vramcnt=72'h000000000000820000;
      manual_write(0,32'h06012008,32'hf0e1d2c3,15,0);
      vramcnt=72'h000000000000800000;
      cpu_read(32'h06852008,v);if(v!==32'hf0e1d2c3)$fatal(1,"sound fallback payload %h",v);
      vramcnt=72'h000000000000820000;
      for(int k=0;k<24;k++)fast_store(k);
      wait(!xp.busy);manual_cut=0;
      vramcnt=72'h000000000000800000;
      for(int k=0;k<24;k++)begin cpu_read(32'h06858000+32'(4*k),v);if(v!==32'h67ab0000+32'(k))$fatal(1,"back-to-back physical payload");end
      vramcnt=72'h000000000000820000;
      hold_take=1;fast_store(24);
      @(negedge clk);rst=1;
      repeat(2)@(negedge clk);hold_take=0;
      repeat(16)@(negedge clk);rst=0;manual_cut=0;
      wait(!mv);repeat(8)@(negedge clk);
      vramcnt=72'h000000000000800000;
      cpu_read(32'h06858060,v);if(v!==32'h67ab0018)$fatal(1,"reset retained physical payload");
      repeat(30)@(negedge clk);
      if(chip0.errors || chip1.errors || dram_chip.errors)$fatal(1,"MAIN physical chip errors");
      if(GROUP && vm_direction && !cpucfg && cfg_cnt[26] && cfg_cnt[24:23]==0 && (cfg_cnt[22:21]==0 || cfg_cnt[22:21]==3) && group_captures!=ops)$fatal(1,"group input replay/count mismatch %0d/%0d",group_captures,ops);
      if(GROUP && mode==8 && !stress && destoff==0 && ops%8==0 && (groups!=ops/8 || group_words!=ops))$fatal(1,"quiet full-bank coverage failed packets%0d words%0d",groups,group_words);
      $display("GROUPTOTAL packets%0d words%0d",groups,group_words);
      $display("REISSUE boundaries%0d accepted%0d poly%0d sound%0d a7%0d",finish_waits,reissues,poly_done,sound_done,arm7_done);
      $display("MAINPHYS low%0d high%0d accepted%0d",chip0.writes,chip1.writes,main_writes);
      $display("CLASS checks%0d",class_checks);
      $display("STATE mode%0d words%0d desc%0d phys%0d mon%h read%h",mode,words,desc,phys,monhash,digest);
      $display("CYCLES DMA%0d total%0d",finished-started,cyc);
      $display("PASS DMA words real DMA/PSRAM/VRAM enabled%0d",ENABLE);$finish;
    end
    initial begin #50000000;$fatal(1,"timeout");end
    int vm_capture_cyc=-1;
    logic[63:0] trace_hash=0;
    always @(posedge clk) if(!rst)begin
      trace_hash={trace_hash[58:0],trace_hash[63:59]}^{32'd0,vr_wdata}^{60'd0,vr_ack,vm_ack,a7_ack,a9_ack}^{32'd0,vr_rdata};
      if(vm_req && vm_we && vm_ack && vram.st==4 && !vram.vsv)vm_capture_cyc=cyc;
      if(vr_ack && !vr_req)$fatal(1,"duplicate/orphan VRAM ACK");
      if(a7_ack && a7_we)begin
        if(vm_capture_cyc<0)$fatal(1,"owner ACK before capture");
        if(cyc-vm_capture_cyc != (EARLY && a7_be==15 && manual_cut ? 0 : 1))$fatal(1,"owner ACK boundary delta%0d",cyc-vm_capture_cyc);
        $display("OWNER7 capture_to_ack%0d",cyc-vm_capture_cyc);
      end
    end
    always @(posedge clk_mem) if(mt && mw)$display("PHYS %06h %08h %h",ma,md,mb);
    int src_ready=-1;
    always @(posedge clk)if(!rst && running)begin
      if((u_fab.st==u_fab.S_WAIT || u_fab.st==u_fab.S_GO) && vr_ack && u_fab.u)begin
        src_ready=cyc;
        if(OVERLAP && fm_req)$display("PIPE VM ready%0d request%0d",src_ready,cyc);
      end
      if(u_fab.st==u_fab.S_MAIN && src_ready>=0 && !u_fab.sd_busy)begin
        if(!OVERLAP)$display("PIPE VM ready%0d request%0d",src_ready,cyc);
        src_ready=-1;
      end
      if(u_fab.st==u_fab.S_GO && u_fab.tgt==u_fab.T_MAIN && u_fab.u && u_fab.uvr && u_fab.lb_hit)begin
        src_ready=cyc;
        if(OVERLAP && vr_req)$display("PIPE MV ready%0d request%0d",src_ready,cyc);
      end
      if(u_fab.st==u_fab.S_GO && u_fab.tgt==u_fab.T_VRAM && !u_fab.u && src_ready>=0)begin
        if(!OVERLAP)$display("PIPE MV ready%0d request%0d",src_ready,cyc);
        src_ready=-1;
      end
    end
    always @(posedge clk) if(!rst && running && $test$plusargs("refill_trace") && words<10)
      $display("REFILL %0d fab%0d grant%h pg%0d lim%0d c%0d ack%0d vr%0d n%0d fill%0d vm%0d va%0h ack%0d valid%0d xpbusy%0d sq%0d sa%0d wv%0d",cyc,u_fab.st,u_fab.grant,u_fab.pg,u_fab.plim,vr_req,vr_ack,vram.st,vram.cb_n,(vm_req && vram.st==vram.S_IDLE),vm_req,vm_addr,vm_ack,vm_rvalid,xp.busy,sq,sa,wv);
    final $display("TRACE %016h cycles%0d",trace_hash,cyc);

`ifndef ORIGINAL
    initial if(vram.WRITE_ACCEPT_EARLY!=EARLY)$fatal(1,"actual VRAM ACK option route");
`endif


    bit hold_old;initial hold_old=$test$plusargs("hold_req");
    int held_n=0,held_checks=0;
    wire h_on=held_n>1; wire h_gap=held_n==1;
    logic h_we,h_n8,h_dmaw,h_group,h_last;logic[21:2]h_addr;logic[3:0]h_be;logic[31:0]h_data;
    always @(posedge clk)begin
        if(rst)held_n<=0;
        else if(held_n!=0)begin
            if(u_arb.a_ack)$fatal(1,"held old request acknowledged twice");
            held_checks++;held_n<=held_n-1;
        end else if(hold_old && u_arb.a_ack && u_arb.a_dmaw && u_arb.a_wgroup && !u_arb.a_wlast)begin
            held_n<=3;h_we<=u_arb.a_we;h_n8<=u_arb.a_n8;h_dmaw<=u_arb.a_dmaw;
            h_group<=u_arb.a_wgroup;h_last<=u_arb.a_wlast;h_addr<=u_arb.a_addr;
            h_be<=u_arb.a_be;h_data<=u_arb.a_wdata;
        end
        if(!rst && mr_req && mr_we && mwgroup && mwlast && mr_ack &&
           (psram.busy || psram.g_count!=0 || psram.cbusy!=0))$fatal(1,"final ACK before physical drain");
    end
    final if(hold_old)begin
        if(held_checks==0)$fatal(1,"held request coverage");
        $display("HELD_OWNER_PASS checks%0d",held_checks);
    end


    logic[63:0] g_expect[$];int g_due[$],g_birth[$];int g_clock=0,g_ready=-1,g_pairs=0,g_max=0;
    logic[31:0]g_digest=0;
    always @(posedge clk)begin : independent_2d
        logic[63:0]want;int due,born,latency;
        g_clock<=g_clock+1;
        if(rst)begin g_expect.delete();g_due.delete();g_birth.delete();g_ready=-1;end
        else begin
            if(g_req && g_ready<0)g_ready=g_clock;
            if(g_ack)begin
                for(int k=0;k<4;k++)begin
                    want=vramcnt[15:8]==8'h80 ? {initial_word(32'h8001+2*k),initial_word(32'h8000+2*k)}:64'd0;
                    g_expect.push_back(want);g_due.push_back(g_ready+197);g_birth.push_back(g_ready);
                end
                g_ready=-1;
            end
            if(g_due.size()!=0 && g_clock>g_due[0])$fatal(1,"2D outstanding fixed197 deadline");
            if(g_ready>=0 && g_clock-g_ready>197)$fatal(1,"2D admission fixed197 deadline");
            if(g_rvalid)begin
                if(g_expect.size()==0)$fatal(1,"2D orphan return");
                want=g_expect.pop_front();due=g_due.pop_front();born=g_birth.pop_front();
                if(g_rdata!==want)$fatal(1,"2D ordered data got%h want%h",g_rdata,want);
                if(g_clock>due)$fatal(1,"2D response missed fixed request period");
                latency=g_clock-born;if(latency>g_max)g_max=latency;
                g_pairs++;g_digest={g_digest[26:0],g_digest[31:27]}^g_rdata[31:0]^g_rdata[63:32];
            end
        end
    end
    final begin
        if(g_expect.size()!=0)$fatal(1,"2D tail not drained");
        $display("GDATA_PASS pairs%0d max%0d period197 digest%h",g_pairs,g_max,g_digest);
    end


    // Exact CAP_CHAIN1 FIFO/guard and real SDRAM port2/controller/pins.
    wire bw_full,bw_empty,bw_valid,bw_read,allow_cut;wire[55:0]bw_q;
    logic cap_busy=0;bit g_done=0,cap_done=0;
    assign cw_ack=cw_valid&&!bw_full;
    nds_dcfifo #(.W(56),.A(6),.RAM_STYLE("MLAB, no_rw_check")) cap_fifo(.wclk(clk),.wreset(rst),.wr(cw_ack),.wdata({cw_addr,cw_data}),.full(bw_full),.wempty(bw_empty),.wfill(),.overflow(),.rclk(clk_mem),.rd(bw_read),.valid(bw_valid),.rdata(bw_q));
    nds_vram_cut_guard cut_guard(.clk_sys(clk),.clk_mem,.reset(rst),.cap_busy,.cw_valid,.fifo_empty(bw_empty),.m_allow(allow_cut));
    wire[3:0]pv,pwe,pt,pwv,psv;wire[95:0]pa;wire[15:0]pn,pbe;wire[127:0]pd;wire[31:0]pwd,psd;
    assign pv={1'b0,mv&&!hold_take,2'b00};assign pwe={1'b0,mw,2'b00};assign pa={24'd0,ma,48'd0};assign pn={4'd0,mn,8'd0};assign pbe={4'd0,mb,8'd0};assign pd={32'd0,md,64'd0};assign mt=pt[2];
    wire sdram_ready;wire[15:0]dq;wire[12:0]sda;wire[1:0]sba,dqm;wire snwe,snras,sncas,scke,sclk;
    logic mem_init=1;initial begin repeat(8)@(negedge clk);mem_init=0;end
    nds_sdram_bus #(.N(4),.OPEN(1),.OUT_REG(1),.CUT(1)) sdram(.clk(clk_mem),.init(mem_init),.ready(sdram_ready),.m_cut({1'b0,held_cut&&allow_cut,2'b00}),.m_hurry(4'd0),.m_valid(pv),.m_we(pwe),.m_addr(pa),.m_n(pn),.m_wdata(pd),.m_be(pbe),.m_take(pt),.w_valid(pwv),.w_data(pwd),.bw_valid,.bw_addr(bw_q[55:32]),.bw_data(bw_q[31:0]),.bw_read,.ref_late(),.SDRAM_DQ(dq),.SDRAM_A(sda),.SDRAM_BA(sba),.SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),.SDRAM_nWE(snwe),.SDRAM_nRAS(snras),.SDRAM_nCAS(sncas),.SDRAM_CKE(scke),.SDRAM_CLK(sclk));
    nds_sdram_words #(.N(4),.SEL(4'b0100),.A(4)) words_sys(.clk_mem,.w_valid(pwv),.w_data(pwd),.rclk(clk),.o_valid(psv),.o_data(psd));
    assign wv=psv[2];assign wd=psd;
    wire #2.0 chip_clk=sclk;
    sdram_chip_model #(.CAS(3),.T_AC(6.0),.T_OH(2.5),.T_RET(2.0),.NAME("VRAM"))dram_chip(.clk(chip_clk),.cke(scke),.ncs(1'b0),.nras(snras),.ncas(sncas),.nwe(snwe),.a(sda),.ba(sba),.dqm,.dq);
    function automatic int chip_index(input int w);return ((w>>21&3)<<23)|((w>>8&8191)<<10)|((w>>23&1)<<9)|((w&255)<<1);endfunction
    function automatic logic[31:0]pin_word(input int w);return {dram_chip.peek(chip_index(w)+1),dram_chip.peek(chip_index(w))};endfunction
    initial begin
      wait(running);
      if(stress)for(int k=0;k<8;k++)begin
        while(cyc<started+phase+k*197)@(negedge clk);
        g_req=1;g_blk={SP_LCDC,1'b0,14'h1000};do @(posedge clk);while(!g_ack);@(negedge clk);g_req=0;
      end
      g_done=1;
    end
    initial begin
      wait(running);
      if(stress)begin
        repeat(5)@(negedge clk);cap_busy=1;
        for(int k=0;k<8;k++)begin
          cap_addr=18'h30080+18'(2*k);cap_data=16'h5a00+16'(k);while(!cap_ready)@(negedge clk);cap_we=1;@(negedge clk);cap_we=0;
          cap_addr++;cap_data=16'hbeef+16'(k);while(!cap_ready)@(negedge clk);cap_we=1;@(negedge clk);cap_we=0;repeat(3)@(negedge clk);
        end
        cap_busy=0;
      end
      cap_done=1;
    end
    int pending_turn=0,write_captures=0,cap_pairs=0,cap_pops=0;
    always @(posedge clk)if(!rst)begin
      if(running && xp.busy && xp.take_t!=xp.take_seen && !sa && sq && sf && sw && !sb && sbe==15 && xp.b_we && xp.b_cut)pending_turn++;
      if(write_capture)write_captures++;
      if(cw_ack)cap_pairs++;
      if(running)begin
        if(u_fab.st==u_fab.S_IDLE && u_fab.grant[0])$display("FEED GRANT %0d src%h dst%h",cyc,dm_addr,dm_dst);
        if(u_fab.st==u_fab.S_GO && u_fab.tgt==u_fab.T_MAIN && u_fab.u && u_fab.lb_hit)$display("FEED SOURCE %0d src%h data%h",cyc,dm_addr,u_fab.lb_q);
        if(write_capture)$display("FEED CAPTURE %0d addr%h data%h",cyc,saddr,swd);
        if(dm_ack)$display("FEED ACK %0d src%h dst%h",cyc,dm_addr,dm_dst);
      end
    end
    always @(posedge clk_mem)if(bw_read)cap_pops++;
    int performed=0;
`ifdef NEW_TURN
    always @(posedge clk)if(!rst && xp.cut_turn)begin
      performed++;
      if(xp.take_t==xp.take_seen)$fatal(1,"turnover preceded actual physical take");
    end
`endif
    logic held_track=0;logic[65:0]held_tuple;
    always @(posedge clk_mem)begin
      if(rst)held_track=0;
      else if(mv)begin
        if(held_track && {mw,held_cut,ma,mn,md,mb}!==held_tuple)$fatal(1,"untaken physical descriptor changed");
        if(mt)held_track=0;
        else if(!held_track)begin held_track=1;held_tuple={mw,held_cut,ma,mn,md,mb};end
      end else held_track=0;
    end
    initial begin : reset_actual_turn
      bit enabled;enabled=$test$plusargs("reset_turn");
      if(enabled)begin
        wait(running);
        do @(posedge clk);while(!(xp.busy && xp.take_t!=xp.take_seen && !sa && sq && sf && sw && !sb && sbe==15 && xp.b_we && xp.b_cut));
        @(negedge clk);running=0;rst=1;a9_req=0;a7_req=0;sn_req=0;poly_req=0;g_req=0;cap_we=0;
        repeat(8)@(negedge clk);rst=0;wait(ps_init);wait(!mv && !xp.busy && bw_empty);repeat(60)@(negedge clk);
        for(int k=0;k<desc;k++)if(pin_word(32'h1000+k)!==source(cfg_src+32'(4*k)))$fatal(1,"reset lost captured DMA word%0d",k);
        if(pin_word(32'h1000+desc)!==initial_word(32'h1000+desc) || pin_word(32'hfff)!==initial_word(32'hfff))$fatal(1,"reset phantom adjacent write");
        if(phys!=desc || desc==0 || words>desc || desc>words+1 || dm_req || enq!=0 || chip0.errors || chip1.errors || dram_chip.errors)$fatal(1,"reset retained/dropped owner or captured write count logical%0d captured%0d physical%0d",words,desc,phys);
        $display("TURN_RESET_PASS logical%0d captured%0d physical%0d ownercleared1",words,desc,phys);$finish;
      end
    end
    final $display("PERFORMED turns%0d",performed);
    final $display("TURN pending%0d captures%0d capPairs%0d capPops%0d chipR%0d chipW%0d chipErrors%0d",pending_turn,write_captures,cap_pairs,cap_pops,dram_chip.reads,dram_chip.writes,dram_chip.errors);

    int tail_attempts=0,tail_captures=0,tail_unready=0;
`ifdef NEW_TAIL
    always @(posedge clk)if(!rst && vram.tail_cw)begin
      tail_attempts++;
      if(vm_ack || g_req || vram.bw_left==0)$fatal(1,"tail admission outside owned-return window");
      if(write_capture)tail_captures++;
      else begin
        tail_unready++;
        if(vr_ack)$fatal(1,"uncaptured DMA tail ACK");
      end
    end
`endif
    final $display("TAIL attempts%0d captures%0d unready%0d",tail_attempts,tail_captures,tail_unready);

endmodule
`default_nettype wire
