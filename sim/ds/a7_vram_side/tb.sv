`timescale 1ns/1ps
module tb_side import gpu2d_pkg::*; #(parameter SIDE=0);
 logic clk=0,clk_mem=0,rst=1;always #7.4595 clk=~clk;always #4.973 clk_mem=~clk_mem;
 int cycle=0,epoch=-1;int pressure=1,late=0,owner=1,phase=1;
 int hostwrite=0,nextwrite=0,snwrite=0,dma=0,resetmode=0;bit reset_seen=0,dma_done=0,snwrite_done=0;
 logic run=0,ir,io,iseq,iarm,iredirect,iconsume,dr,dw,dok,wen,ret;
 logic[31:0]ia,iq,da,dd,dq,pc,psr,wd;logic[3:0]db;logic[4:0]wa;
 logic fr,fn,fw,fseq,fack,frvalid;logic[1:0]fgen,fword;logic[31:0]fa,fd,fq;logic[3:0]fb;
 logic wr,ww,wok=0;logic[17:2]waddr;logic[3:0]wbe;logic[31:0]wwd,wrd=0;
 logic xr,xw,xdone=0;logic[17:2]xa;logic[31:0]xrd=0;
 logic[31:0]wram[4096],shadow[32];int begin_pc,end_pc,fail_pc,nret=0,cpu_end=-1;
 integer sf,df,ef,mf,pf;string image,out;
 arm7_ds #(.MAIN_IF_FLOW(1))cpu(.clk,.rst,.run,.reset_pc(32'h03808000),.hivecs(1'b0),.irq(1'b0),.fiq(1'b0),.wake(1'b0),
 .i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .dbg_wen(wen),.dbg_wa(wa),.dbg_wd(wd),.dbg_retire(ret),.dbg_pc(pc),.dbg_cpsr(psr),.dbg_halted());
 nds_arm7_port #(.WRAM_M10K(1),.MAIN_IF_EARLY(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.MAIN_STORE_TURN(1),.MAIN_IF_REJOIN(1),.DATA_ACK_HANDOFF(0))p7(
 .clk,.rst,.wramcnt(2'd3),.biosprot(16'd0),.i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),.i_seq(iseq),.i_arm(iarm),.i_redirect(iredirect),.i_consume(iconsume),
 .d_req(dr),.d_we(dw),.d_be(db),.d_addr(da),.d_wdata(dd),.d_rdata(dq),.d_ok(dok),
 .w_req(wr),.w_we(ww),.w_addr(waddr),.w_be(wbe),.w_wdata(wwd),.w_ok(wok),.w_rdata(wrd),
 .ib_addr(),.i_boot_q(32'd0),.db_addr(),.d_boot(),.d_boot_q(32'd0),
 .x_req(xr),.x_we(xw),.x_addr(xa),.x_be(),.x_wdata(),.x_stores(),.x_done(xdone),.x_rdata(xrd),.inv(1'b0),.inv_addr(16'd0),
 .f_req(fr),.f_n4(fn),.f_ifseq(fseq),.f_ifgen(fgen),.f_ifword(fword),.f_we(fw),.f_addr(fa),.f_be(fb),.f_wdata(fd),.f_ack(fack),.f_rvalid(frvalid),.f_rdata(fq),.wr_mon(mon_we),.wr_addr(mon_addr));
 always @(posedge clk)begin
  cycle++;wok<=wr&&!rst;xdone<=xr&&!rst;
  if(wr)begin wrd<=wram[waddr[13:2]];if(ww)for(int b=0;b<4;b++)if(wbe[b])wram[waddr[13:2]][8*b+:8]<=wwd[8*b+:8];end
  if(xr)begin if(xw)$fatal(1,"unexpected BIOS write");xrd<=32'he1a00000;end
 end
 always @(negedge clk)if(!rst&&run)begin
  if(wen)shadow[wa]=wd;
  if(ret)begin
   nret++;$fwrite(sf,"%h,%h",pc,psr);for(int j=0;j<32;j++)$fwrite(sf,",%h",shadow[j]);for(int j=0;j<5;j++)$fwrite(sf,",%h",cpu.spsr[j]);$fwrite(sf,"\n");
   if(pc==32'(begin_pc)&&epoch<0)epoch=cycle;
   if(pc==32'(fail_pc))$fatal(1,"ARM7 program self-check failed");
   if(pc==32'(end_pc))begin cpu_end=cycle;run=0;end
  end
 end
 logic rq_w;logic[31:0]rq_a,rq_d;logic[3:0]rq_be;
 always @(posedge clk)if(!rst)begin
  if(dr)begin rq_w<=dw;rq_a<=da;rq_d<=dd;rq_be<=db;end
  if(dok&&((cpu.st==cpu.S_PIPE&&cpu.ph&&cpu.dm_rq)||(dr&&cpu.st!=cpu.S_PIPE)))$fdisplay(df,"%h,%b,%h,%h",rq_a,rq_w,rq_be,rq_w?rq_d:dq);
 end

 logic a9_req=0,a9_we=0,a9_n8=0,a9_ack,a9_rvalid;logic[31:0]a9_addr=0,a9_wdata=0,a9_rdata;
 logic sn_req=0,sn_we=0,sn_ack,sn_rvalid;logic[31:0]sn_addr=0,sn_wdata=0,sn_rdata;
 logic dm_req=0,dm_we=0,dm_cpu=0;logic[31:0]dm_addr=0,dm_dst=0,dm_wdata=0;wire dm_ack;wire[31:0]dm_rdata;
 wire mr_req,mr_we,mr_n8,mr_if4,mr_ld4,mr_dmaw;wire[21:2]mr_addr;wire[31:0]mr_wdata;wire[3:0]mr_be;
 logic mr_ack=0,mr_rvalid=0;logic[31:0]mr_rdata=0;
 wire mon_we;wire[1:0]mon_master;wire mon_cpu;wire[31:0]mon_addr,mon_data;wire[3:0]mon_be;
 wire vr_req,vr_we,vr_cpu,vr_cut,vr_dma_read,vr_ack;wire[23:2]vr_addr;wire[31:0]vr_data,vr_rdata;wire[3:0]vr_be;
 wire io_req,io_we;logic io_ack=0;wire[23:2]io_addr;wire[31:0]io_data;
 nds_fabric #(
`ifdef NEW_SIDE
 .A7_VRAM_SIDE(SIDE),
`endif
 .A7_IO(1),.A7_FIRST(1),.MR_BLOCK(1),.MAIN_IF_QUAD(1),.MAIN_IF_FLOW(1),.SOUND_MEM_QUAD(1),.LDM_STREAM4(1),.LDM_SERVICE(3),.LDM_HIT_EARLY(1),.IO_GRANT_EARLY(1),.DMA_FAST(1),.DMA_RA(2),.VRAM_WRITE_CUT(3),.DMA_VRAM_OVERLAP(1),.DMA_WRITE_CAPTURE_ACK(1),.DMA_READ_EARLY(1))fab(
 .clk,.rst,.wramcnt(2'd3),.exmemcnt9(8'd0),.pb_busy(1'b0),
 .dm_req,.dm_we,.dm_cpu,.dm_size32(1'b1),.dm_addr,.dm_wdata,.dm_ack,.dm_rdata,.dm_unit(1'b1),.dm_dst,.dm_more(1'b0),.dm_wgroup(1'b0),.dm_last(1'b1),.dm_vcut(1'b0),.dx_valid(),.dx_ready(1'b1),.dx_idle(1'b1),
 .a9_req,.a9_we,.a9_n8,.a9_ldm(1'b0),.a9_ldm_meta(7'd0),.a9_addr,.a9_be(4'hf),.a9_tmr(4'd0),.a9_wdata,.a9_ack,.a9_rdata,.a9_rvalid,.a9_wnext(),
 .a7_req(fr),.a7_we(fw),.a7_addr(fa),.a7_be(fb),.a7_wdata(fd),.a7_n4(fn),.a7_ifseq(fseq),.a7_ifgen(fgen),.a7_ifword(fword),.a7_ack(fack),.a7_rdata(fq),.a7_rvalid(frvalid),
 .sn_req,.sn_we,.sn_n4(!sn_we),.sn_addr,.sn_wdata,.sn_ack,.sn_rdata,.sn_rvalid,
 .mr_req,.mr_we,.mr_addr,.mr_be,.mr_wdata,.mr_n8,.mr_if4,.mr_ld4,.mr_dmaw,.mr_wgroup(),.mr_wlast(),.mr_ifseq(),.mr_ifgen(),.mr_ifword(),.mr_wnext(1'b0),.mr_ack,.mr_rvalid,.mr_rdata,
 .fx_req(),.fx_we(),.fx_addr(),.fx_be(),.fx_wdata(),.fx_done(1'b0),.fx_rdata(32'd0),.boot_addr(),.boot_q(32'd0),.ram_wdata(),
 .io_req,.io_cpu(),.io_we,.io_be(),.io_addr,.io_wdata(io_data),.io_tmr_oh(),.io_ack,.io_rdata(32'h12345678),
 .vr_req,.vr_we,.vr_cpu,.vr_addr,.vr_be,.vr_wdata(vr_data),.vr_cut,.vr_dma_read,.vr_ack,.vr_rdata,
 .pal_cq(32'd0),.oam_cq(32'd0),.oam_cgnt(1'b1),.pal_we(),.oam_we(),.oam_cre(),.po_waddr(),.po_be(),.po_wdata(),
 .mon_we,.mon_master,.mon_cpu,.mon_addr,.mon_be,.mon_wdata(mon_data));
 always @(posedge clk)io_ack<=io_req&&!rst;

 // Controlled MAIN endpoint: each real admitted descriptor owns every
 // returned word. Latency is fixture pressure, never a DS timing price.
 function automatic logic[31:0] main_initial(input int a);return 32'h02000000^(32'(a)<<2)^32'h13579bdf;endfunction
 logic[31:0]main_mem[int];function automatic logic[31:0]main_word(input int a);return main_mem.exists(a)?main_mem[a]:main_initial(a);endfunction
 int main_left=0,main_delay=0,main_base=0,main_beat=0,main_count=0;bit main_owned=0,main_sent=0,main_write=0;logic[31:0]main_wd;logic[3:0]main_wbe;
 always @(posedge clk)begin
  mr_ack<=0;mr_rvalid<=0;
  if(rst)begin main_owned<=0;main_sent<=0;main_left<=0;end
  else if(!main_owned&&!mr_ack&&mr_req)begin
   main_owned<=1;main_sent<=0;main_base=int'(mr_addr)&~3;main_beat=0;main_count=mr_n8?8:4;main_left=main_count;main_write=mr_we;main_wd=mr_wdata;main_wbe=mr_be;main_delay=late?1:pressure?23:1;
   if(mr_we)main_base=int'(mr_addr);
  end else if(main_owned&&!main_sent)begin
   if(main_delay>0)main_delay--;else begin
    mr_ack<=1;main_sent<=1;main_delay=0;
    if(main_write)begin
     logic[31:0]v;v=main_word(main_base);for(int b=0;b<4;b++)if(main_wbe[b])v[8*b+:8]=main_wd[8*b+:8];main_mem[main_base]=v;main_owned<=0;
     $fdisplay(pf,"MAIN %h %h %h",32'(main_base),main_wd,main_wbe);
    end
   end
  end else if(main_owned&&main_sent)begin
   if(main_delay>0)main_delay--;else begin
    mr_rvalid<=1;mr_rdata<=main_word(main_base+main_beat);main_beat++;main_left--;main_delay=late?0:pressure?3:0;
    if(main_left==0)main_owned<=0;
   end
  end
 end

 logic[71:0]vramcnt=72'h000000000080828080;
 logic g_req=0;blk_t g_blk={SP_LCDC,1'b0,14'h1000};wire g_ack,g_rvalid;wire[63:0]g_data;
 logic cap_we=0,cap_busy=0;logic[17:0]cap_addr=0;logic[15:0]cap_data=0;wire cap_ready,cw_valid,cw_ack;wire[23:0]cw_addr;wire[31:0]cw_data;
 wire vm_req,vm_we,vm_blk,vm_cut,vm_ack,vm_rvalid;wire[20:2]vm_addr;wire[3:0]vm_be;wire[31:0]vm_data,vm_rdata;wire capture,rawv;wire[31:0]rawd;
 nds_vram #(.CAP_CHAIN(1),.CRB(1),.WRITE_ACCEPT_EARLY(1),.DMA_READ_EARLY(1),.DMA_READ_RETURN_EARLY(1),.DMA_WRITE_CAPTURE_EARLY(1),.DMA_WRITE_TAIL(0))vram(
 .clk,.rst,.vramcnt,.c_req(vr_req),.c_we(vr_we),.c_cpu(vr_cpu),.c_cut(vr_cut),.c_dma_read(vr_dma_read),.c_addr(vr_addr),.c_be(vr_be),.c_wdata(vr_data),.c_ack(vr_ack),.c_rdata(vr_rdata),
 .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata(g_data),.cap_we,.cap_addr,.cap_data,.cap_ready,.cw_valid,.cw_addr,.cw_data,.cw_ack,
 .sv_req(1'b0),.sv_we(1'b0),.sv_addr(19'd0),.sv_be(4'd0),.sv_wdata(32'd0),.sv_ack(),.sv_rdata(),
 .vm_req,.vm_we,.vm_blk,.vm_cut,.vm_addr,.vm_be,.vm_wdata(vm_data),.vm_ack,.vm_rvalid,.vm_rdata,.vm_write_capture(capture),.vm_early_rvalid(rawv),.vm_early_rdata(rawd),.vramstat());
 wire sq,sw,sb,sc,sa,srv;wire[23:0]saddr;wire[31:0]swd,srd;wire[3:0]sbe;
 nds_vm_split #(.OCT(1))split(.clk,.reset(rst),.vm_req,.vm_we,.vm_blk,.vm_cut,.vm_addr,.vm_be,.vm_wdata(vm_data),.vm_ack,.vm_rvalid,.vm_rdata,
 .s_req(sq),.s_we(sw),.s_quad(sb),.s_cut(sc),.s_addr(saddr),.s_be(sbe),.s_wdata(swd),.s_ack(sa),.s_rvalid(srv),.s_rdata(srd));
 wire mv,mw,mcut,mt;wire[23:0]ma;wire[3:0]mn,mb;wire[31:0]md;logic wv=0;logic[31:0]wvdata=0;
 nds_sdram_xport #(.QW(8),.SHARED(1),.CUT_TAG(1))xp(.clk_sys(clk),.clk_mem,.reset(rst),.s_req(sq),.s_we(sw),.s_quad(sb),.s_cut(sc),.s_addr(saddr),.s_be(sbe),.s_wdata(swd),.s_ack(sa),.s_rvalid(srv),.s_rdata(srd),
 .s_write_capture(capture),.s_early_rvalid(rawv),.s_early_rdata(rawd),.m_cut(mcut),.m_valid(mv),.m_we(mw),.m_addr(ma),.m_n(mn),.m_wdata(md),.m_be(mb),.m_take(mt),.w_valid(wv),.w_data(wvdata));
 // Same CAP_CHAIN FIFO and cut guard contract as core_top_ds. The controlled
 // physical endpoint drains capture before another port access and never
 // interleaves a second read owner into a returned block.
 wire bw_full,bw_empty,bw_valid,bw_rd;wire[55:0]bw_q;wire allow_cut;
 assign cw_ack=cw_valid&&!bw_full;
 nds_dcfifo #(.W(56),.A(6),.RAM_STYLE("MLAB, no_rw_check"))capture_fifo(.wclk(clk),.wreset(rst),.wr(cw_ack),.wdata({cw_addr,cw_data}),.full(bw_full),.wempty(bw_empty),.wfill(),.overflow(),.rclk(clk_mem),.rd(bw_rd),.rdata(bw_q),.valid(bw_valid));
 nds_vram_cut_guard guard_cut(.clk_sys(clk),.clk_mem,.reset(rst),.cap_busy,.cw_valid,.fifo_empty(bw_empty),.m_allow(allow_cut));
 function automatic logic[31:0] initial_vram(input int a);return 32'hc001c0de^32'(a);endfunction
 logic[31:0]vram_mem[int];function automatic logic[31:0]word_vram(input int a);return vram_mem.exists(a)?vram_mem[a]:initial_vram(a);endfunction
 int vm_read_addr[$],vm_read_count[$];int vn=0,va=0,vd=0,memcycle=0,phys_cpu=0,phys_cap=0;
 assign bw_rd=bw_valid&&vn==0;
 assign mt=mv&&!bw_valid&&vn==0&&(!pressure||memcycle%37>12)&&(!mcut||allow_cut);
 always @(posedge clk_mem)begin
  memcycle++;
  if(bw_rd)begin vram_mem[int'(bw_q[55:32])]=bw_q[31:0];phys_cap++;$fdisplay(pf,"CAP %h %h",bw_q[55:32],bw_q[31:0]);end
  if(mt)begin
   if(mw)begin
    logic[31:0]v;v=word_vram(int'(ma));for(int b=0;b<4;b++)if(mb[b])v[8*b+:8]=md[8*b+:8];vram_mem[int'(ma)]=v;
    if(ma>=24'h10040&&ma<24'h10060)phys_cpu++;
    $fdisplay(pf,"VRAM %h %h %h",ma,md,mb);
   end else begin vm_read_addr.push_back(int'(ma));vm_read_count.push_back(int'(mn));end
  end
 end
 always @(posedge clk)begin
  wv<=0;
  if(vn==0&&vm_read_addr.size()!=0)begin va=vm_read_addr.pop_front();vn=vm_read_count.pop_front();vd=late?12:2;end
  if(vn>0)begin if(vd>0)vd--;else begin wv<=1;wvdata<=word_vram(va);va++;vn--;vd=late?11:0;end end
 end

 int awrites=0,mwrites=0,cap_accepts=0,side_starts=0,side_ends=0,outlives=0;logic[31:0]expect_cpu=32'h89abc000;
 always @(posedge clk)if(!rst)begin
  if(a9_ack&&!a9_req)$fatal(1,"orphan ARM9 ACK");
  if(sn_ack&&!sn_req)$fatal(1,"orphan sound ACK");
  if(fack&&!fr)$fatal(1,"orphan ARM7 ACK");
  if(fr&&!fw&&fa==32'h02001000&&awrites<32)$fatal(1,"P7 MAIN read passed an older VRAM store");
  if(cw_ack)cap_accepts++;
  if(mon_we)begin
   $fdisplay(mf,"%0d %h %h %h",mon_master,mon_addr,mon_be,mon_data);
   if(mon_master==2)begin
    if(!mon_cpu||mon_addr[31:24]!=8'h06)$fatal(1,"wrong ARM7 write owner/address");
    if(awrites<32)begin
     if(mon_addr!==32'h06000100+32'(awrites*4)||mon_be!==15||mon_data!==expect_cpu)$fatal(1,"ARM7 write order/payload %0d",awrites);
     expect_cpu++;end
    else if(awrites==32)begin if(mon_addr!==32'h06000100||mon_be!==3||mon_data[15:0]!==16'h2468)$fatal(1,"low halfword fallback");end
    else if(awrites==33)begin if(mon_addr!==32'h06000102||mon_be!==12||mon_data[31:16]!==16'h1357)$fatal(1,"high halfword fallback");end
    else $fatal(1,"duplicate ARM7 commit");
    awrites++;
   end else mwrites++;
  end
`ifdef NEW_SIDE
  if(fab.v7_start)begin side_starts++;if(!fr||!fw||fb!=15)$fatal(1,"side captures no actual ARM7 store");end
  if(fab.v7_live)begin
   if(fab.st==fab.S_IDLE)outlives++;
   if(fab.grant[2]&&fab.st==fab.S_IDLE)$fatal(1,"double ARM7 admission");
   if((fab.st==fab.S_GO&&fab.tgt==fab.T_VRAM)||(fab.st==fab.S_WAIT&&fab.tgt_q==fab.T_VRAM))$fatal(1,"global VRAM conflicts with side owner");
   if(fab.v7_end)side_ends++;
   if(fab.v7_end&&(fab.vm_capture_done||(fab.done&&fab.we&&!fab.blk)||fab.sd_mon||fab.bk_mon))$fatal(1,"two writes on single monitor event");
  end
`endif
  $fdisplay(ef,"%0d %b%b%b %h %h %h %b %b %b %b %h %h %b %h %h",cycle,fr,fw,fack,fa,fb,fd,a9_req,a9_ack,a9_rvalid,sn_ack,a9_rdata,sn_rdata,mon_we,mon_addr,mon_data);
 end

 logic[63:0]g_expect[$];int g_birth[$],g_pending=-1,g_pairs=0,g_max=0;
 always @(posedge clk)if(rst)begin g_expect.delete();g_birth.delete();g_pending=-1;end else begin
  if(g_req&&g_pending<0)g_pending=cycle;
  if(g_ack)begin
   for(int k=0;k<4;k++)begin g_expect.push_back({initial_vram(32'h8001+2*k),initial_vram(32'h8000+2*k)});g_birth.push_back(g_pending);end
   g_pending=-1;
  end
  if(g_rvalid)begin
   logic[63:0]v;int born;if(g_expect.size()==0)$fatal(1,"2D orphan return");v=g_expect.pop_front();born=g_birth.pop_front();
   if(g_data!==v)$fatal(1,"2D data/order");if(cycle-born>197)$fatal(1,"2D fixed197 deadline");if(cycle-born>g_max)g_max=cycle-born;g_pairs++;
  end
  // Check time even when a return never arrives. Completion must drain the
  // actual VRAM block receiver, not a transiently idle physical transport.
  if(g_birth.size()!=0&&cycle-g_birth[0]>197)$fatal(1,"2D outstanding fixed197 deadline");
  if(g_pending>=0&&cycle-g_pending>197)$fatal(1,"2D admission fixed197 deadline");
 end
 bit main_done=0,g_done=0,c_done=0;int main_answers=0;
 task automatic a9_read(input logic[31:0]a,input bit block);
  int n;logic[31:0]v;n=0;@(negedge clk);a9_req=1;a9_we=0;a9_n8=block;a9_addr=a;
  do begin @(posedge clk);if(a9_rvalid)begin v=main_word(int'(a[21:2])+n);if(a9_rdata!==v)$fatal(1,"ARM9 MAIN data/owner beat%0d",n);n++;end end while(!a9_ack);
  if(block&&n!=8)$fatal(1,"ARM9 block count %0d",n);
  if(!block&&a[31:24]==8'h06&&a9_rdata!==initial_vram(0))$fatal(1,"mapped ARM9 VRAM conflict read got%h",a9_rdata);
  main_answers++;@(negedge clk);a9_req=0;a9_n8=0;
 endtask
 task automatic sn_read(input logic[31:0]a);
  int n;n=0;@(negedge clk);sn_req=1;sn_we=0;sn_addr=a;
  do begin @(posedge clk);if(sn_rvalid)begin if(sn_rdata!==main_word(int'(a[21:2])+n))$fatal(1,"sound MAIN data/owner");n++;end end while(!sn_ack);
  if(n!=4)$fatal(1,"sound block count");main_answers++;@(negedge clk);sn_req=0;
 endtask
 task automatic a9_write(input logic[31:0]a,input logic[31:0]d);
  @(negedge clk);a9_req=1;a9_we=1;a9_n8=0;a9_addr=a;a9_wdata=d;
  do @(posedge clk);while(!a9_ack);
  if(main_word(int'(a[21:2]))!==d)$fatal(1,"durable ARM9 MAIN write");
  @(negedge clk);a9_req=0;a9_we=0;
 endtask
 initial begin
  wait(epoch>=0);
  if(pressure)begin
   for(int k=0;k<8;k++)begin
    if(owner==3)sn_read(32'h02004000+32'(k*256));else if(hostwrite)a9_write(32'h02004000+32'(k*256),32'hfeed0000+32'(k));else a9_read(32'h02004000+32'(k*256),1);
    if(late&&k==0&&owner==1)a9_read(32'h06800000,0);
    if(nextwrite&&k==0&&owner==1)a9_write(32'h02008000,32'hfeedbad0);
   end
  end
  main_done=1;
 end
 initial begin
  wait(epoch>=0);
  if(pressure&&resetmode!=1)for(int k=0;k<8;k++)begin
   while(cycle<epoch+phase+k*197)@(negedge clk);
   g_req=1;do @(posedge clk);while(!g_ack);@(negedge clk);g_req=0;
  end
  g_done=1;
 end
 initial begin
  wait(epoch>=0);
  if(pressure&&resetmode==0)begin
   repeat(5)@(negedge clk);cap_busy=1;
   for(int k=0;k<8;k++)begin
    cap_addr=18'h30080+18'(2*k);cap_data=16'h5a00+16'(k);while(!cap_ready)@(negedge clk);cap_we=1;
    @(negedge clk);cap_we=0;cap_addr++;cap_data=16'hbeef+16'(k);while(!cap_ready)@(negedge clk);cap_we=1;
    @(negedge clk);cap_we=0;repeat(3)@(negedge clk);
   end
   cap_busy=0;
  end
  c_done=1;
 end
 initial begin
  wait(epoch>=0);
  if(snwrite)begin
   wait(fr&&fw);repeat(2)@(negedge clk);sn_req=1;sn_we=1;sn_addr=32'h0200a000;sn_wdata=32'h01020304;
   do @(posedge clk);while(!sn_ack);
   if(main_word(32'h2800)!==32'h01020304)$fatal(1,"durable sound MAIN write");
   @(negedge clk);sn_req=0;sn_we=0;
  end
  snwrite_done=1;
 end
 initial begin
  wait(epoch>=0);
  if(dma)begin
   wait(fr&&fw);repeat(2)@(negedge clk);dm_req=1;dm_we=0;dm_cpu=0;dm_addr=32'h02030000;dm_dst=32'h06808000;
   do @(posedge clk);while(!dm_ack);
   @(negedge clk);dm_req=0;
  end
  dma_done=1;
 end
 // Reset is applied at an actual endpoint boundary, not an invented number
 // of clocks. These interrupted-prefix cases check cancellation/durability;
 // complete CPU state equivalence belongs to the uninterrupted cases above.
 initial begin
  wait(epoch>=0);
  if(resetmode!=0)begin
   if(resetmode==1)begin
    do @(posedge clk);while(!(capture&&vm_we&&vm_addr==19'h10040));
   end else begin
    do @(negedge clk);while(!(vr_req&&vr_we&&vr_cpu&&vram.bw_left!=0&&!capture));
   end
   @(negedge clk);run=0;rst=1;reset_seen=1;a9_req=0;sn_req=0;dm_req=0;g_req=0;cap_we=0;cap_busy=0;
   repeat(8)@(negedge clk);rst=0;
   repeat(200)@(negedge clk);
   wait(!xp.busy&&!mv&&vn==0&&vm_read_addr.size()==0&&bw_empty);
   repeat(8)@(negedge clk);
   if(fr||fack||vr_req||awrites!=0)$fatal(1,"reset kept CPU/VRAM owner or published a canceled write");
`ifdef NEW_SIDE
   if(fab.v7_live)$fatal(1,"reset kept side owner");
`endif
   if(resetmode==1)begin
    if(phys_cpu!=1||word_vram(32'h10040)!==32'h89abc000)$fatal(1,"reset lost/duplicated accepted physical write");
   end else if(phys_cpu!=0||word_vram(32'h10040)!==initial_vram(32'h10040))$fatal(1,"reset committed an uncaptured store");
   $display("PASS_RESET mode%0d physical%0d logical%0d ownercleared1",resetmode,phys_cpu,awrites);$finish;
  end
 end
 initial begin
  void'($value$plusargs("pressure=%d",pressure));void'($value$plusargs("late=%d",late));void'($value$plusargs("owner=%d",owner));void'($value$plusargs("phase=%d",phase));
  void'($value$plusargs("hostwrite=%d",hostwrite));void'($value$plusargs("nextwrite=%d",nextwrite));void'($value$plusargs("snwrite=%d",snwrite));void'($value$plusargs("dma=%d",dma));void'($value$plusargs("resetmode=%d",resetmode));
  if(!$value$plusargs("img=%s",image)||!$value$plusargs("out=%s",out)||!$value$plusargs("begin=%h",begin_pc)||!$value$plusargs("done=%h",end_pc)||!$value$plusargs("fail=%h",fail_pc))$fatal(1,"missing test inputs");
  sf=$fopen({out,".state"},"w");df=$fopen({out,".data"},"w");ef=$fopen({out,".edge"},"w");mf=$fopen({out,".mon"},"w");pf=$fopen({out,".physical"},"w");
  for(int k=0;k<4096;k++)wram[k]=0;for(int k=0;k<32;k++)shadow[k]=0;$readmemh(image,wram);
  repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);run=1;
  wait(cpu_end>=0&&main_done&&g_done&&c_done&&dma_done&&snwrite_done);wait(!xp.busy&&!mv&&bw_empty&&vn==0&&vm_read_addr.size()==0&&!fr&&!main_owned);repeat(12)@(negedge clk);
  $display("LEGACY_FINAL cycle%0d Gpairs%0d expected%0d bw_left%0d vm_req%0b split_req%0b transport_busy%0b queued%0d words%0d",cycle,g_pairs,g_expect.size(),vram.bw_left,vm_req,sq,xp.busy,vm_read_addr.size(),vn);
  wait(g_expect.size()==0&&g_pending<0&&vram.bw_left==0&&vram.st==vram.S_IDLE&&!g_rvalid&&!vm_req&&!sq&&!xp.busy&&!mv&&!wv&&!srv&&!vm_rvalid&&bw_empty&&vn==0&&vm_read_addr.size()==0);
  repeat(4)@(negedge clk);
  for(int k=0;k<32;k++)begin
   logic[31:0]v;v=k==0?32'h13572468:32'h89abc000+32'(k);if(word_vram(32'h10040+k)!==v)$fatal(1,"durable ARM7 VRAM data %0d",k);
  end
  for(int k=0;k<(pressure?8:0);k++)if(word_vram(32'h18040+k)!=={16'hbeef+16'(k),16'h5a00+16'(k)})$fatal(1,"durable capture data %0d",k);
  if(dma&&word_vram(32'h2000)!==main_initial(32'hc000))$fatal(1,"durable DMA destination/owner");
  if(hostwrite&&side_starts!=0)$fatal(1,"side admission on older MAIN writes");
  if(mwrites!=(hostwrite?8:0)+(nextwrite?1:0)+(snwrite?1:0)+(dma?1:0))$fatal(1,"other-master commit count %0d",mwrites);
  if(awrites!=34||phys_cpu!=34||phys_cap!=(pressure?8:0)||cap_accepts!=(pressure?8:0)||g_pairs!=(pressure?32:0)||g_expect.size()!=0)$fatal(1,"cardinality CPU%0d/%0d cap%0d/%0d g%0d",awrites,phys_cpu,cap_accepts,phys_cap,g_pairs);
  $display("PASS_SIDE CPUend%0d states%0d writes%0d physical%0d capture%0d Gpairs%0d Gmax%0d MAINanswers%0d side%0d/%0d outlives%0d",cpu_end,nret,awrites,phys_cpu,phys_cap,g_pairs,g_max,main_answers,side_starts,side_ends,outlives);$finish;
 end
 initial begin #3000000;$fatal(1,"test timeout");end
endmodule
