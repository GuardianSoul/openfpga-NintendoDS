`timescale 1ns/1ps
module tb_dma_vram16;
 import gpu2d_pkg::*;
 parameter bit EN=1;
 logic clk=0,rst=1;always #5 clk=!clk;
 logic[71:0]vramcnt=72'h808080;
 logic c_req=0,c_we=0;logic[23:2]c_addr=0;logic[3:0]c_be=15;logic[31:0]c_wdata=0,c_rdata;wire c_ack;
 logic g_req=0;blk_t g_blk;wire g_ack,g_rvalid;wire[63:0]g_rdata;
 logic cap_we=0;logic[17:0]cap_addr=0;logic[15:0]cap_data=0;wire cap_ready;
 wire cw_valid;wire[23:0]cw_addr;wire[31:0]cw_data;wire[1:0]cw_he;
 logic cw_ack=0,cw_drained=1;logic[6:0]cw_fill=0,cw_pcnt=0;logic allow_cw=1;
 logic sv_req=0,sv_we=0;wire sv_ack;wire[31:0]sv_rdata;
 wire vm_req,vm_we,vm_blk;wire[20:2]vm_addr;wire[3:0]vm_be;wire[31:0]vm_wdata;
 logic vm_ack=0,vm_rvalid=0;logic[31:0]vm_rdata=0;
 wire vc_req,vc_we,vc_cpu,vc_dma,vc_ack;wire[23:2]vc_addr;wire[3:0]vc_be;wire[31:0]vc_wdata,vc_rdata;
 logic cnt_we=0;logic[1:0]ch=0;logic[31:0]cnt_data=0;wire[7:0]en_q;wire[4:0]reg_raddr;
 logic[63:0]regfile[32];logic[63:0]reg_rd;wire[1:0]busy;wire[3:0]irq9,irq7;wire[7:0]dbg_run;wire lat_lost;
 wire dm_req,dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_ack;wire[31:0]dm_addr,dm_dst,dm_wdata,dm_rdata;
 always @(posedge clk)reg_rd<=regfile[reg_raddr];
 sys_dma #(.FAST(1)) engine(.clk,.rst,.cnt_we,.cpu(1'b0),.ch,.be(4'hF),.wdata(cnt_data),.en_q,
  .reg_gnt(1'b1),.reg_raddr,.reg_rd,.trig9(7'd0),.gx_low(1'b0),.stop9(7'd0),.trig7(3'd0),
  .m_req(dm_req),.m_we(dm_we),.m_cpu(dm_cpu),.m_size32(dm_size32),.m_addr(dm_addr),.m_unit(dm_unit),.m_dst(dm_dst),.m_more(dm_more),.m_wdata(dm_wdata),.m_ack(dm_ack),.m_rdata(dm_rdata),.busy,.irq9,.irq7,.dbg_run,.lat_lost);
 wire mr_req,mr_we;wire[21:2]mr_addr;wire[3:0]mr_be;wire[31:0]mr_wdata;logic mr_ack=0;
 nds_fabric #(.OAM_SHARE(1),.MR_BLOCK(1),.DMA_FAST(1),.DMA_RA(1),.DMA_B8(1),.DMA_GX(3),.DMA_IOF(1),.DMA_PW(1),.DMA_PMM(36)) fabric(
  .clk,.rst,.wramcnt(2'd0),.pb_busy(1'b0),.dm_req,.dm_we,.dm_cpu,.dm_size32,.dm_addr,.dm_unit,.dm_more,.dm_dst,.dx_ready(1'b1),.dx_idle(1'b1),.dm_wdata,.dm_ack,.dm_rdata,
  .a9_req(c_req),.a9_we(c_we),.a9_addr(32'h06000000|{8'd0,c_addr,2'b00}),.a9_be(c_be),.a9_tmr(4'd0),.a9_wdata(c_wdata),.a9_n8(1'b0),.a9_ack(c_ack),.a9_rdata(c_rdata),
  .a7_req(1'b0),.a7_we(1'b0),.a7_addr(32'd0),.a7_be(4'd0),.a7_wdata(32'd0),.sn_req(1'b0),.sn_we(1'b0),.sn_addr(32'd0),.sn_wdata(32'd0),
  .mr_req,.mr_we,.mr_addr,.mr_be,.mr_wdata,.mr_ack,.mr_rvalid(1'b0),.mr_rdata(32'd0),.mr_wnext(1'b0),
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
   if(cw_valid&&!cw_ack&&allow_cw)cw_ack<=1;
   if(cw_valid&&cw_ack)begin wa.push_back(int'(cw_addr));wd.push_back(cw_data);wh.push_back(cw_he);end
   if(cur<0&&qa.size()==0&&wa.size()!=0)begin
    integer a;logic[31:0]d;logic[1:0]he;a=wa.pop_front();d=wd.pop_front();he=wh.pop_front();
    if(he[0])mem[a][15:0]=d[15:0];if(he[1])mem[a][31:16]=d[31:16];cw_pcnt<=cw_pcnt+1;
   end
   cw_fill<=7'(wa.size());cw_drained<=wa.size()==0;
  end
 end
 logic[31:0]gold[262144],destmem[4096];
 integer main_overlap=0,wb_wait_cycles=0,cw_wait_cycles=0,block_read_overlap=0;
 integer job=-1,job_n=0,job_sctl=0,job_dctl=0,rdn=0,wrn=0,mrn=0,total_units=0,jobs=0,irq_count=0,hold_checks=0;
 logic job_live=0;logic[31:0]job_src,job_dst,job_phys;
 logic mwait=0,vwait=0,gwait=0,cwait=0;logic[100:0]oldm;logic[60:0]oldv;blk_t oldg;logic[57:0]oldc;
 function automatic logic[31:0]step_(input logic[31:0]base,input integer ctl,input integer n);
  return ctl==2?base:ctl==1?base-32'(2*n):base+32'(2*n);
 endfunction
 function automatic logic[15:0]source_half(input integer n);
  logic[31:0]p,w;p=step_(job_phys,job_sctl,n);w=gold[p>>2];return p[1]?w[31:16]:w[15:0];
 endfunction
 always @(posedge clk)begin
  if(rst)begin mr_ack<=0;mwait=0;vwait=0;gwait=0;cwait=0;end
  else begin
   mr_ack<=mr_req&&!mr_ack&&(cyc%7==0);
   if(job_live)begin
    main_overlap+=int'(mr_req&&dm_req&&!dm_we);
    wb_wait_cycles+=int'(dut.wb_v&&vc_req&&!vc_we);
    cw_wait_cycles+=int'(cw_valid&&!cw_ack);
    block_read_overlap+=int'(vc_req&&!vc_we&&dut.bw_left!=0);
   end
   if(mwait)begin
    hold_checks++;
    if(!dm_req||{dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_addr,dm_dst,dm_wdata}!==oldm)$fatal(1,"DMA_HELD_CONTRACT");
   end
   mwait=dm_req&&!dm_ack;oldm={dm_we,dm_cpu,dm_size32,dm_unit,dm_more,dm_addr,dm_dst,dm_wdata};
   if(vwait&&(!vc_req||{vc_cpu,vc_dma,vc_we,vc_addr,vc_be,vc_wdata}!==oldv))$fatal(1,"VRAM_HELD_CONTRACT");
   vwait=vc_req&&!vc_ack;oldv={vc_cpu,vc_dma,vc_we,vc_addr,vc_be,vc_wdata};
   if(gwait&&(!g_req||g_blk!==oldg))$fatal(1,"BLOCK_HELD_CONTRACT");gwait=g_req&&!g_ack;oldg=g_blk;
   if(cwait&&(!cw_valid||{cw_addr,cw_data,cw_he}!==oldc))$fatal(1,"POSTED_HELD_CONTRACT");cwait=cw_valid&&!cw_ack;oldc={cw_addr,cw_data,cw_he};
   if(lat_lost||irq7!=0)$fatal(1,"DMA_CONTROL_STATUS");
   if(irq9!=0)begin if(irq9!=1)$fatal(1,"DMA_WRONG_CHANNEL_IRQ");irq_count++;end
   if(dm_req&&dm_ack)begin
    logic[31:0]want;logic[15:0]half_;
    if(!job_live||dm_cpu||dm_size32||dm_unit)$fatal(1,"DMA_UNEXPECTED_CLASS");
    if(!dm_we)begin
     want=step_(job_src,job_sctl,rdn);half_=source_half(rdn);
     if(rdn>=job_n||dm_addr!==want)$fatal(1,"DMA_SOURCE_ADDRESS job=%0d unit=%0d got=%h expected=%h",job,rdn,dm_addr,want);
     if(dm_rdata!=={16'd0,half_})$fatal(1,"DMA_READ_PAYLOAD job=%0d unit=%0d got=%h expected=%h",job,rdn,dm_rdata,half_);
     rdn++;
    end else begin
     want=step_(job_dst,job_dctl,wrn);half_=source_half(wrn);
     if(wrn>=job_n||dm_addr!==want||rdn!=wrn+1)$fatal(1,"DMA_DEST_ADDRESS_OR_ORDER job=%0d unit=%0d",job,wrn);
     if(dm_wdata!=={half_,half_})$fatal(1,"DMA_WRITE_PAYLOAD job=%0d unit=%0d",job,wrn);
     wrn++;
    end
   end
   if(mr_req&&mr_ack)begin
    logic[31:0]want;logic[15:0]half_;logic[3:0]be_;
    want=step_(job_dst,job_dctl,mrn);half_=source_half(mrn);be_=want[1]?4'hC:4'h3;
    if(!job_live||!mr_we||mrn>=job_n||mr_addr!==want[21:2]||mr_be!==be_)$fatal(1,"DEST_COMMIT_ADDRESS_OR_LANE job=%0d unit=%0d",job,mrn);
    if(mr_wdata!=={half_,half_})$fatal(1,"DEST_COMMIT_PAYLOAD job=%0d unit=%0d",job,mrn);
    for(integer b=0;b<4;b++)if(mr_be[b])destmem[mr_addr[13:2]][b*8+:8]=mr_wdata[b*8+:8];
    mrn++;
   end
  end
 end
 task automatic settle;repeat(200)@(negedge clk);endtask
 task automatic manual_read(input logic[31:0]a,input logic[31:0]expect_);
  @(negedge clk);c_req=1;c_we=0;c_addr=a[23:2];
  do @(posedge clk);while(!c_ack);
  if(c_rdata!==expect_)$fatal(1,"PRIME_PAYLOAD got=%h expected=%h",c_rdata,expect_);
  @(negedge clk);c_req=0;@(negedge clk);
 endtask
 task automatic manual_write(input logic[31:0]a,input logic[31:0]d,input logic[3:0]be_);
  @(negedge clk);c_req=1;c_we=1;c_addr=a[23:2];c_wdata=d;c_be=be_;
  do @(posedge clk);while(!c_ack);
  @(negedge clk);c_req=0;c_we=0;c_be=15;@(negedge clk);
 endtask
 task automatic block_(input integer a);
  @(negedge clk);g_req=1;g_blk={SP_LCDC,1'b0,14'(a/8)};
  do @(posedge clk);while(!g_ack);
  @(negedge clk);g_req=0;
  while(!(dut.st==dut.S_IDLE&&dut.bw_left!=0))@(negedge clk);
 endtask
 task automatic capture_(input integer a,input logic[15:0]d);
  @(negedge clk);cap_addr=18'(a);cap_data=d;cap_we=1;
  do @(posedge clk);while(!cap_ready);
  @(negedge clk);cap_we=0;
 endtask
 task automatic program_(input logic[31:0]src,input logic[31:0]dst,input integer count_,input integer sc,input integer dc);
  @(negedge clk);regfile[0]={dst,src};cnt_data=32'hC0000000|(32'(sc)<<23)|(32'(dc)<<21)|32'(count_);regfile[4]={32'd0,cnt_data};cnt_we=1;
  @(negedge clk);cnt_we=0;
  do @(posedge clk);while(en_q!=0||busy!=0);
  settle();
 endtask
 task automatic run_job(input integer id,input logic[31:0]src,input logic[31:0]phys,input integer count_,input integer sc,input integer dc);
  integer h0,b0,irq0;logic[31:0]dst;integer blockbase;
  job=id;job_n=count_;job_sctl=sc;job_dctl=dc;job_src=src;job_phys=phys;
  dst=32'h02001000+32'(id*256)+(dc==1?32'h7E:(id==1?32'd2:32'd0));job_dst=dst;
  rdn=0;wrn=0;mrn=0;irq0=irq_count;h0=hits;b0=blocks;
  manual_read({src[31:2],2'b00},gold[phys>>2]);settle();
  blockbase=id==0?0:id==9?65536+64:32768+64;
  block_(blockbase);
  if(id==4)begin gold[0][15:0]=16'hBEEF;capture_(0,16'hBEEF);end
  if(id==5)begin allow_cw=0;gold[0]=32'hCDEFABCD;capture_(0,16'hABCD);capture_(1,16'hCDEF);end
  if(id==6)begin allow_cw=0;gold[0]=32'h9ABCDEF0;manual_write(32'h06800000,32'h9ABCDEF0,4'hF);end
  if(id==7)begin allow_cw=0;gold[0][15:0]=16'h1234;manual_write(32'h06800000,32'h00001234,4'h3);end
  job_live=1;
  fork
   program_(src,dst,count_,sc,dc);
   begin
    for(integer b=0;b<12;b++)begin
     repeat(6+(b%5))@(negedge clk);block_(blockbase+(id==0?0:(b%4)*8));
    end
   end
   begin repeat(80)@(negedge clk);allow_cw=1;end
  join
  settle();
  if(rdn!=count_||wrn!=count_||mrn!=count_||en_q!=0||busy!=0||irq_count!=irq0+1)$fatal(1,"DMA_UNIT_COUNTS job=%0d read=%0d write=%0d commit=%0d irq=%0d",job,rdn,wrn,mrn,irq_count-irq0);
  for(integer n=0;n<count_;n++)begin
   logic[31:0]a,w;logic[15:0]got;a=step_(dst,dc,n);w=destmem[a[13:2]];got=a[1]?w[31:16]:w[15:0];
   if(got!==source_half(n))$fatal(1,"FINAL_DEST_PAYLOAD job=%0d unit=%0d got=%h expected=%h",job,n,got,source_half(n));
  end
  job_live=0;total_units+=count_;jobs++;
  $display("DMA16_JOB_PASS id=%0d units=%0d source=%h physical=%h sctl=%0d dctl=%0d hits=%0d blockbeats=%0d",id,count_,src,phys,sc,dc,hits-h0,blocks-b0);
 endtask
 initial begin
  g_blk=0;for(integer a=0;a<262144;a++)begin mem[a]=pattern(a);gold[a]=pattern(a);end
  for(integer a=0;a<4096;a++)destmem[a]=32'hDEADBEEF;
  for(integer a=0;a<32;a++)regfile[a]=0;
  repeat(4)@(negedge clk);rst=0;return_delay=50;
  run_job(0,32'h06800006,6,33,0,0);
  run_job(1,32'h06800002,2,37,0,0);
  run_job(2,32'h0680007E,32'h7E,35,1,0);
  run_job(3,32'h06800006,6,17,2,1);
  run_job(4,32'h06800000,0,33,0,0);
  run_job(5,32'h06800000,0,33,0,0);
  run_job(6,32'h06800000,0,33,0,0);
  run_job(7,32'h06800000,0,33,0,0);
  vramcnt=72'h808081;settle();run_job(8,32'h06080002,2,35,0,0);
  vramcnt=72'h808100;settle();run_job(9,32'h06000002,32'h20002,35,0,0);
  if(ge.size()!=0||qa.size()!=0||left_!=0||wa.size()!=0||mwait||vwait||gwait||cwait)$fatal(1,"UNFINISHED_DMA16_WORK");
  if(main_overlap==0||wb_wait_cycles==0||cw_wait_cycles==0||block_read_overlap==0)$fatal(1,"MISSING_PROGRAMMED_CONTENTION_WITNESS");
  if(EN&&hits==0)$fatal(1,"NO_DMA16_HIT_WITNESS");
  for(integer r=0;r<12;r++)$display("ELIGIBILITY reason=%0d cycles=%0d",r,eligibility[r]);
  $display("DMA16_PASS EN=%0d jobs=%0d units=%0d reads=%0d writes=%0d commits=%0d hits=%0d blockbeats=%0d irq=%0d held_checks=%0d main_overlap=%0d wb_wait=%0d cw_wait=%0d block_read_overlap=%0d",EN,jobs,total_units,total_units,total_units,total_units,hits,blocks,irq_count,hold_checks,main_overlap,wb_wait_cycles,cw_wait_cycles,block_read_overlap);
  $finish;
 end
 initial begin #5000000;$fatal(1,"DMA16_TIMEOUT");end
endmodule
