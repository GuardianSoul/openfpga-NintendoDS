`timescale 1ns/1ps
module tb_dma_title;
 import gpu2d_pkg::*;
 parameter bit EN=1;
 logic clk=0,rst=1;always #5 clk=!clk;
 logic[71:0]vramcnt=72'h80848080;
 logic c_req=0,c_we=0;logic[23:2]c_addr=0;logic[3:0]c_be=15;logic[31:0]c_wdata=0,c_rdata;wire c_ack;
 logic g_req=0;blk_t g_blk;wire g_ack,g_rvalid;wire[63:0]g_rdata;
 logic cap_we=0;logic[17:0]cap_addr=0;logic[15:0]cap_data=0;wire cap_ready;
 wire cw_valid;wire[23:0]cw_addr;wire[31:0]cw_data;wire[1:0]cw_he;
 logic cw_ack=0,cw_drained=1;logic[6:0]cw_fill=0,cw_pcnt=0;logic allow_cw=1;
 logic sv_req=0,sv_we=0;wire sv_ack;wire[31:0]sv_rdata;
 wire vm_req,vm_we,vm_blk;wire[20:2]vm_addr;wire[3:0]vm_be;wire[31:0]vm_wdata;
 logic vm_ack=0,vm_rvalid=0;logic[31:0]vm_rdata=0;
 wire vc_req,vc_we,vc_cpu,vc_dma,vc_ack;wire[23:2]vc_addr;wire[3:0]vc_be;wire[31:0]vc_wdata,vc_rdata;
 logic[7:1]trig9=0;
 logic cnt_we=0;logic[1:0]ch=0;logic[31:0]cnt_data=0;wire[7:0]en_q;wire[4:0]reg_raddr;
 logic[63:0]regfile[32];logic[63:0]reg_rd;wire[1:0]busy;wire[3:0]irq9,irq7;wire[7:0]dbg_run;wire lat_lost;
 wire dm_req,dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_ack;wire[31:0]dm_addr,dm_dst,dm_wdata,dm_rdata;
 always @(posedge clk)reg_rd<=regfile[reg_raddr];
 sys_dma #(.FAST(1)) engine(.clk,.rst,.cnt_we,.cpu(1'b0),.ch,.be(4'hF),.wdata(cnt_data),.en_q,
  .reg_gnt(1'b1),.reg_raddr,.reg_rd,.trig9,.gx_low(1'b0),.stop9(7'd0),.trig7(3'd0),
  .m_req(dm_req),.m_we(dm_we),.m_cpu(dm_cpu),.m_size32(dm_size32),.m_addr(dm_addr),.m_unit(dm_unit),.m_dst(dm_dst),.m_more(dm_more),.m_wdata(dm_wdata),.m_ack(dm_ack),.m_rdata(dm_rdata),.busy,.irq9,.irq7,.dbg_run,.lat_lost);
 wire mr_req,mr_we;wire[21:2]mr_addr;wire[3:0]mr_be;wire[31:0]mr_wdata;logic mr_ack=0,mr_rvalid=0;logic[31:0]mr_rdata=0;wire mr_n8;
 nds_fabric #(.OAM_SHARE(1),.MR_BLOCK(1),.DMA_FAST(1),.DMA_RA(1),.DMA_B8(1),.DMA_GX(3),.DMA_IOF(1),.DMA_PW(1),.DMA_PMM(36)) fabric(
  .clk,.rst,.wramcnt(2'd0),.pb_busy(1'b0),.dm_req,.dm_we,.dm_cpu,.dm_size32,.dm_addr, .dm_src(dm_addr),.dm_unit,.dm_more,.dm_dst,.dx_ready(1'b1),.dx_idle(1'b1),.dm_wdata,.dm_ack,.dm_rdata,
  .a9_req(c_req),.a9_we(c_we),.a9_addr(32'h06000000|{8'd0,c_addr,2'b00}),.a9_be(c_be),.a9_tmr(4'd0),.a9_wdata(c_wdata),.a9_n8(1'b0),.a9_ack(c_ack),.a9_rdata(c_rdata),
  .a7_req(1'b0),.a7_we(1'b0),.a7_addr(32'd0),.a7_be(4'd0),.a7_wdata(32'd0),.sn_req(1'b0),.sn_we(1'b0),.sn_addr(32'd0),.sn_wdata(32'd0),
  .mr_req,.mr_we,.mr_addr,.mr_be,.mr_wdata,.mr_ack,.mr_rvalid,.mr_rdata,.mr_n8,.mr_wnext(1'b0),
  .fx_done(1'b0),.fx_rdata(32'd0),.boot_q(32'd0),.io_ack(1'b0),.io_rdata(32'd0),
  .vr_req(vc_req),.vr_cpu(vc_cpu),.vr_dma(vc_dma),.vr_we(vc_we),.vr_addr(vc_addr),.vr_be(vc_be),.vr_wdata(vc_wdata),.vr_ack(vc_ack),.vr_rdata(vc_rdata),.pal_cq(32'd0),.oam_cgnt(1'b0),.oam_cq(32'd0));
 nds_vram #(.CAP_CHAIN(1),.VR_POST(1),.VR_RDB(1),.VR_PASS(1),.VR_WB(1),.VR_CWF(1),.VR_PDRAIN(1),.VR_PH(1),.VR_RHIT(EN),.VR_PF(0),.VR_HIT(0)) dut(
 .clk,.rst,.vramcnt,.c_req(vc_req),.c_cpu(vc_cpu),.c_dma(vc_dma),.c_we(vc_we),.c_addr(vc_addr),.c_be(vc_be),.c_wdata(vc_wdata),.c_ack(vc_ack),.c_rdata(vc_rdata),
 .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata,.cap_we,.cap_addr,.cap_data,.cap_ready,.cw_valid,.cw_addr,.cw_data,.cw_he,.cw_ack,.cw_drained,.cw_fill,.cw_pcnt,
 .sv_req,.sv_we,.sv_addr(19'd0),.sv_be(4'hF),.sv_wdata(32'd0),.sv_ack,.sv_rdata,.vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,.vramstat());
 logic[31:0]mem[262144];integer qa[$],qn[$];logic[63:0]ge[$];integer wa[$];logic[31:0]wd[$];logic[1:0]wh[$];
 integer eligibility[12]='{default:0};
 integer cur=-1,left_=0,delay_=0,return_delay=2,cyc=0,hits=0,reads=0,blocks=0,capwrites=0;
 function automatic logic[31:0]pattern(input integer a);return 32'hA5000000 ^ (32'(a)*32'h10201);endfunction
 always @(posedge clk)begin
  cyc++;
  vm_ack<=0;vm_rvalid<=0;cw_ack<=0;
  if(rst)begin qa.delete();qn.delete();ge.delete();wa.delete();wd.delete();wh.delete();cur=-1;left_=0;delay_=0;cw_fill<=0;cw_pcnt<=0;cw_drained<=1;end
  else begin
   if(dut.rhit)hits++;
   if(dut.st==dut.S_IDLE&&dut.bw_left!=0&&vc_req&&!vc_ack&&!vc_we&&vc_dma&&!vc_cpu)begin
    integer reason;
    reason=g_req?1:dut.wb_v?2:!dut.c_res_owned?3:!dut.res_q[20]?4:!dut.lhit[0]?5:dut.post_p?6:dut.cap_v?7:dut.cap_p?8:cap_we?9:(sv_req&&sv_we)?10:0;
    eligibility[reason]++;
   end
   if(g_req&&g_ack)begin
    integer base;base=int'(g_blk[13:0])*8;
    for(integer b=0;b<4;b++)ge.push_back({mem[base+b*2+1],mem[base+b*2]});
   end
   if(g_rvalid)begin
    logic[63:0]expected;if(ge.size()==0)$fatal(1,"UNOWNED_BLOCK_RETURN");expected=ge.pop_front();
    if(g_rdata!==expected)$fatal(1,"BLOCK_DATA_ORDER got=%h expected=%h",g_rdata,expected);blocks++;
   end
   if(vm_req&&!vm_ack)begin
    vm_ack<=1;
    if(vm_we)begin for(integer b=0;b<4;b++)if(vm_be[b])mem[vm_addr][b*8+:8]=vm_wdata[b*8+:8];capwrites++;end
    else begin qa.push_back(int'(vm_addr));qn.push_back(vm_blk?8:1);end
   end
   if(cur<0&&qa.size()!=0)begin cur=qa.pop_front();left_=qn.pop_front();delay_=return_delay;end
   if(cur>=0)begin
    if(delay_!=0)delay_--;
    else begin vm_rvalid<=1;vm_rdata<=mem[cur];cur++;left_--;delay_=1;if(left_==0)cur=-1;end
   end
   if(cw_valid&&!cw_ack&&allow_cw&&wa.size()<16)cw_ack<=1;
   if(cw_valid&&cw_ack)begin wa.push_back(int'(cw_addr));wd.push_back(cw_data);wh.push_back(cw_he);end
   if(cur<0&&qa.size()==0&&wa.size()!=0)begin
    integer a;logic[31:0]d;logic[1:0]he;a=wa.pop_front();d=wd.pop_front();he=wh.pop_front();
    if(he[0])mem[a][15:0]=d[15:0];if(he[1])mem[a][31:16]=d[31:16];cw_pcnt<=cw_pcnt+1;
   end
   cw_fill<=7'(wa.size());cw_drained<=wa.size()==0;
  end
 end
 localparam logic[31:0]RB_SRC=32'h06860000,RB_DST=32'h0218786C,HB_SRC=32'h0218B06C,HB_DST=32'h06204000;
 localparam integer RB_WORDS=24576,HB_WORDS=128,HB_JOBS=8,D_WORD=98304,C_WORD=69632;
 logic[31:0]goldv[262144],mainmem[1048576],goldmain[1048576],hb_last[128];
 integer rb_reads=0,rb_writes=0,rb_commits=0,hb_units=0,hb_offers=0,hb_cw=0,hb_irqs=0,rb_irqs=0,preempts=0,resumes=0,hold_checks=0;
 integer main_overlap=0,post_read_fence=0,wb_wait=0,cw_wait=0,block_overlap=0;
 logic traffic=0;integer mqa[$],mqn[$],mcur=-1,mleft=0,mdelay=0,request_delay=0;logic main_pending=0;
 integer exp_cwa[$];logic[31:0]exp_cwd[$];logic prev_vwrite=0;
 logic mwait=0,vwait=0,gwait=0,cwait=0;logic[100:0]oldm;logic[60:0]oldv;blk_t oldg;logic[57:0]oldc;
 function automatic logic[31:0]main_pattern(input integer a);return 32'h6D000000^(32'(a)*32'h10103);endfunction
 always @(posedge clk)begin
  mr_ack<=0;mr_rvalid<=0;
  if(rst)begin main_pending=0;mqa.delete();mqn.delete();mcur=-1;mleft=0;mwait=0;vwait=0;gwait=0;cwait=0;prev_vwrite=0;end
  else begin
   if(mwait)begin
    hold_checks++;
    if(!dm_req||{dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_addr,dm_dst,dm_wdata}!==oldm)$fatal(1,"DMA_HELD_CONTRACT");
   end
   mwait=dm_req&&!dm_ack;oldm={dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_addr,dm_dst,dm_wdata};
   if(vwait&&(!vc_req||{vc_cpu,vc_dma,vc_we,vc_addr,vc_be,vc_wdata}!==oldv))$fatal(1,"VRAM_HELD_CONTRACT");
   vwait=vc_req&&!vc_ack;oldv={vc_cpu,vc_dma,vc_we,vc_addr,vc_be,vc_wdata};
   if(gwait&&(!g_req||g_blk!==oldg))$fatal(1,"BLOCK_HELD_CONTRACT");gwait=g_req&&!g_ack;oldg=g_blk;
   if(cwait&&(!cw_valid||{cw_addr,cw_data,cw_he}!==oldc))$fatal(1,"POSTED_HELD_CONTRACT");cwait=cw_valid&&!cw_ack;oldc={cw_addr,cw_data,cw_he};
   main_overlap+=int'(mr_req&&dm_req&&!dm_we&&dm_addr[31:24]==8'h06);
   post_read_fence+=int'(fabric.st==fabric.S_GO&&fabric.tgt==fabric.T_MAIN&&!fabric.we&&fabric.pw_v);
   wb_wait+=int'(dut.wb_v&&vc_req);cw_wait+=int'(cw_valid&&!cw_ack);block_overlap+=int'(vc_req&&dut.bw_left!=0);
   if(lat_lost||irq7!=0||(irq9&4'h5)!=0)$fatal(1,"DMA_CONTROL_STATUS");
   if(irq9[1])hb_irqs++;if(irq9[3])rb_irqs++;
   if(engine.save_go&&engine.e_why==0)begin
    if(engine.ek!=3||rb_reads!=rb_writes)$fatal(1,"PREEMPT_NOT_UNIT_BOUNDARY");
    $display("SAVE src=%h dst=%h remain=%0d owner=%0d write_src=%h write_dst=%h write_remain=%0d units=%0d",engine.e_src,engine.e_dst,engine.e_rem,engine.work_wa,engine.work_wd[31:0],engine.work_wd[63:32],engine.work_wd[84:64],rb_writes);
    if(engine.e_src!==RB_SRC+32'(rb_reads*4)||engine.e_dst!==RB_DST+32'(rb_writes*4)||engine.e_rem!=RB_WORDS-rb_writes)$fatal(1,"PREEMPT_SNAPSHOT_STATE");
    preempts++;
   end
   if(engine.est==engine.E_SETUP&&engine.rtag==0&&engine.e_res)begin
    if(engine.ek!=3)$fatal(1,"UNEXPECTED_RESUME_CHANNEL");resumes++;
    $display("RESUME next_unit=%0d expected_src=%h expected_dst=%h remaining=%0d",rb_reads,RB_SRC+32'(rb_reads*4),RB_DST+32'(rb_writes*4),RB_WORDS-rb_writes);
   end
   if(dm_req&&dm_ack)begin
    if(dm_cpu||!dm_size32)$fatal(1,"DMA_TITLE_CLASS");
    if(dm_unit)begin
     logic[31:0]expected_;integer epoch,unit_;epoch=hb_units/HB_WORDS;unit_=hb_units%HB_WORDS;
     expected_=goldmain[((HB_SRC&32'h3FFFFF)>>2)+hb_units];
     if(hb_units>=HB_JOBS*HB_WORDS||dm_we||dm_addr!==HB_SRC+32'(hb_units*4)||dm_dst!==HB_DST+32'(unit_*4))$fatal(1,"HB_SOURCE_OR_RELOAD_ADDRESS epoch=%0d unit=%0d got_src=%h got_dst=%h",epoch,unit_,dm_addr,dm_dst);
     // FAST combined units consume the destination write, not m_rdata.
     // Validate source payload at actual VRAM offer/CW commit and final memory.
     hb_units++;
    end else if(!dm_we)begin
     if(rb_reads>=RB_WORDS||dm_addr!==RB_SRC+32'(rb_reads*4))$fatal(1,"RB_SOURCE_ADDRESS unit=%0d got=%h expected=%h",rb_reads,dm_addr,RB_SRC+32'(rb_reads*4));
     if(dm_rdata!==goldv[D_WORD+rb_reads])$fatal(1,"RB_READ_PAYLOAD unit=%0d got=%h expected=%h",rb_reads,dm_rdata,goldv[D_WORD+rb_reads]);
     rb_reads++;
    end else begin
     if(rb_writes>=RB_WORDS||rb_reads!=rb_writes+1||dm_addr!==RB_DST+32'(rb_writes*4))$fatal(1,"RB_DEST_ADDRESS_OR_ORDER unit=%0d got=%h",rb_writes,dm_addr);
     if(dm_wdata!==goldv[D_WORD+rb_writes])$fatal(1,"RB_WRITE_PAYLOAD unit=%0d",rb_writes);
     goldmain[((RB_DST&32'h3FFFFF)>>2)+rb_writes]=goldv[D_WORD+rb_writes];rb_writes++;
    end
   end
   if(vc_req&&vc_we&&!prev_vwrite)begin
    integer unit_;logic[31:0]expected_;unit_=hb_offers%HB_WORDS;expected_=goldmain[((HB_SRC&32'h3FFFFF)>>2)+hb_offers];
    if(hb_offers>=HB_JOBS*HB_WORDS||!vc_dma||vc_cpu||vc_be!=15||vc_addr!==(HB_DST[23:2]+22'(unit_)))$fatal(1,"HB_VRAM_RELOAD_ADDRESS unit=%0d got=%h",hb_offers,vc_addr);
    if(vc_wdata!==expected_)$fatal(1,"HB_VRAM_WRITE_PAYLOAD unit=%0d got=%h expected=%h",hb_offers,vc_wdata,expected_);
    exp_cwa.push_back(C_WORD+unit_);exp_cwd.push_back(expected_);hb_last[unit_]=expected_;hb_offers++;
   end
   prev_vwrite=vc_req&&vc_we;
   if(cw_valid&&cw_ack)begin
    integer a;logic[31:0]d;
    if(exp_cwa.size()==0)$fatal(1,"UNOWNED_HB_POSTED_WRITE");a=exp_cwa.pop_front();d=exp_cwd.pop_front();
    if(cw_addr!==24'(a)||cw_data!==d||cw_he!=3)$fatal(1,"HB_POSTED_PAYLOAD_OR_ADDRESS unit=%0d got_addr=%h expected_addr=%h",hb_cw,cw_addr,a);
    hb_cw++;
   end
   if(mr_req&&mr_ack)begin
    main_pending=0;
    if(mr_we)begin
     logic[31:0]expected_;expected_=goldv[D_WORD+rb_commits];
     if(rb_commits>=RB_WORDS||mr_addr!==RB_DST[21:2]+20'(rb_commits)||mr_be!=15)$fatal(1,"RB_COMMIT_ADDRESS unit=%0d got=%h",rb_commits,mr_addr);
     if(mr_wdata!==expected_)$fatal(1,"RB_COMMIT_PAYLOAD unit=%0d",rb_commits);
     mainmem[mr_addr]=mr_wdata;rb_commits++;
    end else begin mqa.push_back(int'(mr_addr)&(mr_n8?~7:~3));mqn.push_back(mr_n8?8:4);end
   end else if(mr_req)begin
    if(!main_pending)begin main_pending=1;request_delay=mr_we?25:3;end
    else if(request_delay!=0)request_delay--;
    else mr_ack<=1;
   end else main_pending=0;
   if(mcur<0&&mqa.size()!=0)begin mcur=mqa.pop_front();mleft=mqn.pop_front();mdelay=3;end
   if(mcur>=0)begin
    if(mdelay!=0)mdelay--;
    else begin mr_rvalid<=1;mr_rdata<=mainmem[mcur];mcur++;mleft--;mdelay=1;if(mleft==0)mcur=-1;end
   end
  end
 end
 task automatic settle;repeat(300)@(negedge clk);endtask
 task automatic prime;
  @(negedge clk);c_req=1;c_we=0;c_addr=RB_SRC[23:2];
  do @(posedge clk);while(!c_ack);
  if(c_rdata!==goldv[D_WORD])$fatal(1,"PRIME_PAYLOAD");
  @(negedge clk);c_req=0;@(negedge clk);
 endtask
 task automatic block_(input integer a);
  @(negedge clk);g_req=1;g_blk={SP_LCDC,1'b0,14'(a/8)};
  do @(posedge clk);while(!g_ack);
  @(negedge clk);g_req=0;
  while(!(dut.st==dut.S_IDLE&&dut.bw_left!=0))@(negedge clk);
 endtask
 task automatic enable_(input logic[1:0]k,input logic[31:0]src,input logic[31:0]dst,input logic[31:0]cnt);
  @(negedge clk);ch=k;regfile[int'(k)]={dst,src};regfile[4+int'(k)]={32'd0,cnt};cnt_data=cnt;cnt_we=1;
  @(negedge clk);cnt_we=0;repeat(4)@(negedge clk);
 endtask
 initial begin
  g_blk=0;
  for(integer a=0;a<262144;a++)begin mem[a]=pattern(a);goldv[a]=pattern(a);end
  for(integer a=0;a<1048576;a++)begin mainmem[a]=main_pattern(a);goldmain[a]=main_pattern(a);end
  for(integer a=0;a<32;a++)regfile[a]=0;
  repeat(4)@(negedge clk);rst=0;return_delay=50;
  prime();$display("TITLE_PRIME_PASS");settle();block_(64);
  // An older lone capture halfword must land before DMA3's source read.
  @(negedge clk);cap_addr=18'h30000;cap_data=16'hBEEF;cap_we=1;
  do @(posedge clk);while(!cap_ready);
  @(negedge clk);cap_we=0;goldv[D_WORD][15:0]=16'hBEEF;
  enable_(1,HB_SRC,HB_DST,32'hD6600000|HB_WORDS);
  traffic=1;
  fork
   begin
    enable_(3,RB_SRC,RB_DST,32'hC4000000|RB_WORDS);
    do @(negedge clk);while(en_q[3]||busy!=0||rb_irqs==0);
    traffic=0;
   end
   begin
    for(integer j=0;j<HB_JOBS;j++)begin
     integer threshold;case(j)
      0:threshold=32;1:threshold=512;2:threshold=1024;3:threshold=2048;
      4:threshold=4096;5:threshold=8192;6:threshold=16384;default:threshold=22000;
     endcase
     while(!(dm_req&&dm_we&&!dm_ack&&dm_addr==RB_DST+32'(threshold*4)))@(negedge clk);
     trig9[2]=1;@(negedge clk);trig9=0;
     while(hb_irqs<j+1)@(negedge clk);
     if(!en_q[1])$fatal(1,"HB_REPEAT_ENABLE_LOST");
     $display("HBLANK_JOB_PASS epoch=%0d source_next=%h reloaded_dst=%h units=%0d",j,HB_SRC+32'((j+1)*HB_WORDS*4),HB_DST,hb_units);
    end
   end
   begin integer b=0;while(traffic)begin repeat(8)@(negedge clk);block_(64+(b%8)*8);b++;if(b%8==0)repeat(220)@(negedge clk);end end
  join
  settle();
  if(rb_reads!=RB_WORDS||rb_writes!=RB_WORDS||rb_commits!=RB_WORDS||hb_units!=HB_JOBS*HB_WORDS||hb_offers!=hb_units||hb_cw!=hb_units||hb_irqs!=HB_JOBS||rb_irqs!=1||preempts!=HB_JOBS||resumes!=HB_JOBS)$fatal(1,"TITLE_DMA_COUNTS rb=%0d/%0d/%0d hb=%0d/%0d/%0d irq=%0d/%0d preempt=%0d resume=%0d",rb_reads,rb_writes,rb_commits,hb_units,hb_offers,hb_cw,hb_irqs,rb_irqs,preempts,resumes);
  if(en_q!==8'h02||busy!=0)$fatal(1,"TITLE_DMA_ENABLE_FINAL");
  for(integer n=0;n<RB_WORDS;n++)if(mainmem[((RB_DST&32'h3FFFFF)>>2)+n]!==goldv[D_WORD+n])$fatal(1,"FINAL_RB_PAYLOAD unit=%0d",n);
  for(integer n=0;n<HB_WORDS;n++)if(mem[C_WORD+n]!==hb_last[n])$fatal(1,"FINAL_HB_PAYLOAD unit=%0d",n);
  enable_(1,HB_SRC,HB_DST,0);settle();if(en_q!=0||busy!=0)$fatal(1,"HB_DISABLE_FAILED");
  if(ge.size()!=0||qa.size()!=0||left_!=0||wa.size()!=0||mqa.size()!=0||mleft!=0||exp_cwa.size()!=0)$fatal(1,"UNFINISHED_TITLE_WORK");
  if(EN&&hits==0||post_read_fence==0||wb_wait==0||cw_wait==0)$fatal(1,"MISSING_TITLE_CONTENTION_WITNESS");
  for(integer r=0;r<12;r++)$display("ELIGIBILITY reason=%0d cycles=%0d",r,eligibility[r]);
  $display("TITLE_DMA_PASS rb_units=%0d hb_units=%0d hb_jobs=%0d preempts=%0d resumes=%0d hits=%0d blockbeats=%0d held_checks=%0d main_overlap=%0d post_read_fence=%0d wb_wait=%0d cw_wait=%0d block_overlap=%0d",rb_writes,hb_units,hb_irqs,preempts,resumes,hits,blocks,hold_checks,main_overlap,post_read_fence,wb_wait,cw_wait,block_overlap);
  $finish;
 end
 initial begin #100000000;$fatal(1,"TITLE_DMA_TIMEOUT rb=%0d/%0d hb=%0d irq=%0d/%0d engine=%0d fabric=%0d vram=%0d bw=%0d cap=%0d CW=%0d",rb_reads,rb_writes,hb_units,rb_irqs,hb_irqs,engine.est,fabric.st,dut.st,dut.bw_left,dut.cap_v,wa.size());end
endmodule
