`timescale 1ns/1ps
module render_service_tb;
 import gpu2d_pkg::*;
 wire clk,clk_2x,memclk,sys_base,fast_base;integer phase_ps=0;
 initial void'($value$plusargs("phase_ps=%d",phase_ps));
 // Exact clock generator from the retained game model; stress phase is
 // explicitly separate from its unshifted production-clock component case.
 nds_pll_ds pll(.refclk(1'b0),.rst(1'b0),.clk_mem(memclk),.clk_sys(sys_base),.clk_2x(fast_base));
 assign #(real'(phase_ps)/1000.0) clk=sys_base;
 assign #(real'(phase_ps)/1000.0) clk_2x=fast_base;
 logic rst=1,init=1,fg_now=0;logic[2:0]generation=0;
 logic ref_fg_now=0;logic[2:0]ref_generation=0;integer ref_cooldown=0;
 integer syscycles=0,memcycles=0,frame_at=0,traffic_at=0,traffic_mem_at=0;logic load=0;
 wire ps_line_req,ps_ready,ps_valid;wire[7:0]ps_line_y;wire[1:0]ps_type;wire[127:0]ps_data;
 wire rline,rready,rvalid;wire[7:0]ry;wire[1:0]rtype;wire[127:0]rdata;
 wire px_valid;wire[7:0]px_x,px_y;wire[22:0]px_color;
 wire ref_px;wire[7:0]ref_x,ref_y;wire[22:0]ref_color;
 wire[8:0]y_lim_rg;wire frame_done,ref_done;
 wire tex_req,pal_req;wire[18:0]tex_addr;wire[16:0]pal_addr;
 logic l3d_go=0,l3d_done=0;logic[7:0]l3d_line=0,l3d_raddr=0;
 wire[22:0]l3d_rdata;wire l3d_have;
 wire t_req,t_ack,t_rvalid;blk_t t_blk;wire[63:0]g_rdata;
 wire rg_wreq,rg_wack,rg_rreq,rg_rack,rg_rvalid,rg_hurry;wire[23:0]rg_waddr,rg_raddr;
 wire[31:0]rg_wdata,rg_rdata;wire[6:0]rg_wfill,rg_wpcnt;
 logic ring_due_valid=0;logic[7:0]ring_due_line=0;logic[13:0]ring_due_sys=0;
 integer next_job_at=0,next_job_row=0;logic job_stream=0;
 render_cone #(.FRPOOL(1),.TL(9),.PL(8),.TC_V2(1),.TC_V2W(4),.TC_POOL(1),.TC_CWF(1),
  .PUMP(1),.TXD(5),.PXD(5),.FPSKIP(1),.TRU(1),.TRUL(1),.FPCLR(1),.LLR(1),.YLIM2(1),
  .RH_AT(2800),.RING(1),.RDEADLINE(1),.RESTART(1),.VREG(1),.LOV(1),.EDIV4(1),.EP2(1),.FDB(1),
  .FEAT_AA(0),.FEAT_EDGE(0),.FEAT_TOON(0),.FEAT_SHADOW(0),.FEAT_LOWER(0)) dut(.*,.t_rdata(g_rdata));
 render_cone_reference #(.FRPOOL(1),.TL(9),.PL(8),.TC_V2(1),.TC_V2W(4),.TC_POOL(1),.TC_CWF(1),
  .PUMP(1),.TXD(5),.PXD(5),.FPSKIP(1),.TRU(1),.TRUL(1),.FPCLR(1),.LLR(1),.YLIM2(1),
  .RH_AT(2800),.RING(1),.RDEADLINE(1),.RESTART(1),.VREG(1),.LOV(1),.EDIV4(1),.EP2(1),.FDB(1),
  .FEAT_AA(0),.FEAT_EDGE(0),.FEAT_TOON(0),.FEAT_SHADOW(0),.FEAT_LOWER(0)) reference(
  .clk,.clk_2x,.rst,.fg_now(ref_fg_now),.generation(ref_generation),.frame_done(ref_done),.ps_line_req(rline),.ps_line_y(ry),
  .ps_valid(rvalid),.ps_type(rtype),.ps_data(rdata),.ps_ready(rready),.px_valid(ref_px),.px_x(ref_x),.px_y(ref_y),.px_color(ref_color),
  .l3d_go(1'b0),.l3d_done(1'b0),.l3d_line(8'd0),.l3d_raddr(8'd0),.t_ack(1'b0),.t_rvalid(1'b0),.t_rdata(64'd0),
  .rg_wack(1'b0),.rg_rack(1'b0),.rg_rvalid(1'b0),.rg_rdata(32'd0),.rg_wfill(7'd0),.rg_wpcnt(7'd0),
  .ring_due_valid(1'b0),.ring_due_line(8'd0),.ring_due_sys(14'd0));
 render_provider provider(.clk,.rst,.cancel(dut.r_abort),.frame_go(dut.frame_go),.line_req(ps_line_req),.line_y(ps_line_y),.y_lim(y_lim_rg),.valid(ps_valid),.ready(ps_ready),.typ(ps_type),.data(ps_data),.generation);
 render_provider ref_provider(.clk,.rst,.cancel(reference.r_abort),.frame_go(reference.frame_go),.line_req(rline),.line_y(ry),.y_lim(9'd511),.valid(rvalid),.ready(rready),.typ(rtype),.data(rdata),.generation(ref_generation));
 // Each exact-input oracle frame completes independently. Native service
 // can let final-pass pixels lead an ideal-memory renderer briefly, and an
 // actual cancellation must not cancel generation-tagged oracle values.
 always @(negedge clk)if(!rst)begin
  ref_fg_now=0;
  if(ref_done)ref_cooldown=2;
  else if(ref_cooldown>0)ref_cooldown--;
  else if(ref_generation<generation&&!reference.r_busy&&!reference.frame_go)begin ref_generation++;ref_fg_now=1;end
 end

 logic d_req=0;blk_t d_blk=0;wire d_ack,d_rvalid,g_req,g_ack,g_rvalid;blk_t g_blk;
 nds_blk_arb arb(.clk,.rst,.a_req(d_req),.a_blk(d_blk),.a_ack(d_ack),.a_rvalid(d_rvalid),
  .b_req(t_req),.b_blk(t_blk),.b_ack(t_ack),.b_rvalid(t_rvalid),.g_req,.g_blk,.g_ack,.g_rvalid);
 logic c_req=0,c_we=0;logic[23:2]c_addr=0;logic[3:0]c_be=15;logic[31:0]c_wdata=0;wire c_ack;wire[31:0]c_rdata;
 logic cap_we=0;logic[17:0]cap_addr=18'h30000;logic[15:0]cap_data=0;wire cap_ready;
 wire cw_valid,cw_ack;wire[23:0]cw_addr;wire[31:0]cw_data;wire[1:0]cw_he;
 wire vm_req,vm_we,vm_blk,vm_ack,vm_rvalid;wire[20:2]vm_addr;wire[3:0]vm_be;wire[31:0]vm_wdata,vm_rdata;
 wire[71:0]vramcnt=72'h80808181839b938b83;
 nds_vram #(.CAP_CHAIN(1),.VR_POST(1),.VR_RDB(1),.VR_PASS(1),.VR_WB(1),.VR_CWF(1),.VR_YIELD(1),.VR_PDRAIN(1),.VR_PH(1)) vram(
  .clk,.rst,.vramcnt,.c_req,.c_cpu(1'b0),.c_dma(1'b1),.c_we,.c_addr,.c_be,.c_wdata,.c_ack,.c_rdata,
  .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata,.cap_we,.cap_addr,.cap_data,.cap_ready,
  .cw_valid,.cw_addr,.cw_data,.cw_he,.cw_ack,.cw_drained(empty),.cw_fill(rg_wfill),.cw_pcnt(rg_wpcnt),
  .sv_req(1'b0),.sv_we(1'b0),.sv_addr(18'd0),.sv_be(4'd0),.sv_wdata(32'd0),.sv_ack(),.sv_rdata(),
  .vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,.vramstat());
 wire vs_req,vs_we,vs_quad,vs_ack,vs_rvalid;wire[23:0]vs_addr;wire[31:0]vs_wdata,vs_rdata;wire[3:0]vs_be;
 nds_vm_split #(.BASE_W(0),.OCT(1)) split(.clk,.reset(rst),.vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,
  .s_req(vs_req),.s_we(vs_we),.s_quad(vs_quad),.s_addr(vs_addr),.s_wdata(vs_wdata),.s_be(vs_be),.s_ack(vs_ack),.s_rvalid(vs_rvalid),.s_rdata(vs_rdata));
 logic[6:0]p_valid=0,p_we=0;logic[167:0]p_addr=0;logic[27:0]p_n=0,p_be=0;logic[223:0]p_wdata=0;
 wire[6:0]p_take,p_w,ws_v;wire[31:0]p_wd,ws_d;
 nds_sdram_xport #(.QW(8),.SHARED(1)) xv(.clk_sys(clk),.clk_mem(memclk),.reset(rst),
  .s_req(vs_req),.s_we(vs_we),.s_quad(vs_quad),.s_addr(vs_addr),.s_wdata(vs_wdata),.s_be(vs_be),.s_ack(vs_ack),.s_rvalid(vs_rvalid),.s_rdata(vs_rdata),
  .m_valid(p_valid[2]),.m_we(p_we[2]),.m_addr(p_addr[71:48]),.m_n(p_n[11:8]),.m_wdata(p_wdata[95:64]),.m_be(p_be[11:8]),.m_take(p_take[2]),.w_valid(ws_v[2]),.w_data(ws_d));
 nds_sdram_xport #(.QW(8),.SHARED(1)) xr(.clk_sys(clk),.clk_mem(memclk),.reset(rst),
  .s_req(rg_rreq),.s_we(1'b0),.s_quad(1'b1),.s_addr(rg_raddr),.s_wdata(32'd0),.s_be(4'hf),.s_ack(rg_rack),.s_rvalid(rg_rvalid),.s_rdata(rg_rdata),
  .m_valid(p_valid[6]),.m_we(p_we[6]),.m_addr(p_addr[167:144]),.m_n(p_n[27:24]),.m_wdata(p_wdata[223:192]),.m_be(p_be[27:24]),.m_take(p_take[6]),.w_valid(ws_v[6]),.w_data(ws_d));
 wire video_req;wire video_ack,full,empty,bw_valid,bw_read,overflow;wire[57:0]bw_q;
 integer video_words=0,cap_halves=0,d_blocks=0,cpu_ops=0;integer next_d=0,next_cpu=0,next_cap=0;
 integer video_stop=0;
 logic d_taken=0,cap_taken=0,c_taken=0;
 always @(posedge clk)begin d_taken<=d_req&&d_ack;cap_taken<=cap_we&&cap_ready;c_taken<=c_req&&c_ack;end
 // Complete 128-word bottom rows arrive once per DS line. Native reads
 // below fetch complete rows one short line ahead, as nds_video does.
 assign video_req=video_words<(load?128*(1+(syscycles-traffic_at)/4260):video_stop);
 wire[23:0]video_addr=24'h380000+24'(video_words%2048);wire[31:0]video_data=32'h76ca0000^32'(video_words);
 nds_ring_post_arb poster(.clk,.reset(rst),.video_req,.ring_req(rg_wreq),.capture_req(cw_valid),.ring_last(1'b0),.full,.video_ack,.ring_ack(rg_wack),.capture_ack(cw_ack));
 wire[57:0]post_word=rg_wack?{2'b11,rg_waddr,rg_wdata}:cw_ack?{cw_he,cw_addr,cw_data}:{2'b11,video_addr,video_data};
 nds_dcfifo #(.W(58),.A(6)) fifo(.wclk(clk),.wreset(rst),.wr(video_ack||rg_wack||cw_ack),.wdata(post_word),.full,.wempty(empty),.wfill(rg_wfill),.wpcnt(rg_wpcnt),.overflow,
  .rclk(memclk),.rd(bw_read),.valid(bw_valid),.rdata(bw_q));
 logic[1:0]h2=0,hr=0;wire hurry2=d_req && syscycles%4260>=2800;
 always @(posedge memclk)begin h2<={h2[0],hurry2};hr<={hr[0],rg_hurry};end
 wire ready,ref_late;wire[15:0]dq;wire[12:0]a;wire[1:0]ba,dqm;wire nwe,nras,ncas,cke,sclk;
 nds_sdram_bus #(.N(7),.OPEN(1),.OUT_REG(1),.HURRY(1),.BOUNDED(1)) bus(.clk(memclk),.init,.ready,
  .m_hurry({hr[1],3'b000,h2[1],2'b00}),.m_valid(p_valid),.m_we(p_we),.m_addr(p_addr),.m_n(p_n),.m_wdata(p_wdata),.m_be(p_be),.m_take(p_take),.w_valid(p_w),.w_data(p_wd),.ref_late,
  .bw_valid,.bw_addr(bw_q[55:32]),.bw_data(bw_q[31:0]),.bw_he(bw_q[57:56]),.bw_read,
  .SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),.SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CKE(cke),.SDRAM_CLK(sclk));
 wire #2.0 chip_clk=sclk;
 sdram_chip_model #(.CAS(3),.T_AC(6.0),.T_OH(2.5),.T_RET(2.0)) chip(.clk(chip_clk),.cke,.ncs(1'b0),.nras,.ncas,.nwe,.a,.ba,.dqm,.dq);
 nds_sdram_words #(.N(7),.SEL(7'b1010101),.A(4)) words(.clk_mem(memclk),.w_valid(p_w),.w_data(p_wd),.rclk(clk),.o_valid(ws_v),.o_data(ws_d));
 `include "image.svh"
 `include "observe.svh"
 always @(posedge clk)begin
  syscycles++;
  if(syscycles>2000000)$fatal(1,"COMPLETE_CONE_TIMEOUT");
  if(video_ack)video_words<=video_words+1;
  if(overflow||words.words.overflow)$fatal(1,"FIFO_OVERFLOW");
  // Register a conservative one-line forecast from this fixture's actual
  // A-job admission schedule. Blank time is not an already-due row0.
  ring_due_valid<=job_stream && next_job_row<192 && next_job_at-syscycles<=4260;
  ring_due_line<=8'(next_job_row);
  ring_due_sys<=next_job_at<=syscycles?14'd0:next_job_at-syscycles>16383?14'd16383:14'(next_job_at-syscycles);
 end
 always @(negedge clk)begin
  if(d_taken)begin d_req=0;d_blocks++;end
  else if(load&&!d_req&&d_blocks<64*(1+(syscycles-traffic_at)/4260))begin d_req=1;d_blk={SP_BG,1'b0,14'(d_blocks%256)};end
  if(c_taken)begin c_req=0;cpu_ops++;end
  else if(load&&!c_req&&syscycles>=next_cpu)begin c_req=1;c_we=cpu_ops%3==0;c_addr=22'((24'h898000+24'((cpu_ops%256)*4))>>2);c_be=cpu_ops[0]?4'b0011:4'b1111;c_wdata=32'hca710000^32'(cpu_ops);next_cpu=syscycles+137;end
  if(cap_taken)begin cap_we=0;cap_halves++;end
  else if(load&&!cap_we&&cap_halves<256*(1+(syscycles-traffic_at)/4260)&&syscycles>=next_cap)begin
   cap_we=1;cap_addr=18'h30000+18'(cap_halves%8192);cap_data=16'h91c5^16'(cap_halves);
   // Adjacent halves normally arrive within the real pair window. One
   // deliberately sparse pair per64 halves also exercises lone-half service.
   next_cap=syscycles+(cap_halves%64==0?9:1);
  end
 end
 integer native_seq[7];
 always @(negedge memclk)if(load)begin
  for(integer i=0;i<5;i++)if(i!=2)begin
   if(p_take[i])p_valid[i]=0;
   else if(!p_valid[i] && (i==0 ? native_seq[0]*4<128*(1+(memcycles-traffic_mem_at)/2100) : memcycles%193==0))begin
    native_seq[i]++;p_valid[i]=1;p_we[i]=i==1;p_n[i*4+:4]=i==1?1:4;p_be[i*4+:4]=15;
    p_addr[i*24+:24]=i==0?24'h380000+24'(((native_seq[i]-1)*4)%2048):i==1?24'h300000+24'(native_seq[i]%64):24'h200000+24'(i*1024);
    p_wdata[i*32+:32]=32'hb31d0000^32'(native_seq[i]);
   end
  end
 end
 else for(integer i=0;i<5;i++)if(i!=2&&p_take[i])p_valid[i]=0;
 task automatic tick(input integer n=1);repeat(n)@(negedge clk);endtask
 task automatic restart;
  generation++;fg_now=1;tick();fg_now=0;tick(2);frame_at=syscycles;
  job_stream=1;next_job_row=0;next_job_at=frame_at+48*4260;
 endtask
 task automatic consume(input integer y,input bit cancel_here=0);
  integer lease_gen;
  l3d_line=8'(y);l3d_go=1;tick();l3d_go=0;tick();
  if(!l3d_have)$fatal(1,"DELIVERY_DEADLINE row=%0d SYS=%0d",y,syscycles);
  lease_gen=int'(generation);
  next_job_row=y+1;next_job_at=frame_at+48*4260+(y+1)*4260;
  if(cancel_here)begin
   wait(nwp>nrp && n_owner[nrp%32]==6 && n_len[nrp%32]-nbeat>2);tick();
   if(!dut.u_service.consumer_valid)$fatal(1,"MISSING_CANCEL_LEASE");
   restart();cancel_read_seen++;
  end
  for(integer x=0;x<256;x++)begin
   l3d_raddr=8'(x);tick();
   if(!actual_valid[lease_gen][y*256+x]||l3d_rdata!==actual_pixels[lease_gen][y*256+x])$fatal(1,"CONSUMER_VALUE gen=%0d y=%0d x=%0d",lease_gen,y,x);
   if(fd)$fdisplay(fd,"CONSUMER,%0d,%0d,%0d,%0d,%0d,%h",syscycles,generation,lease_gen,y,x,l3d_rdata);
   consumer_checks++;
  end
  l3d_done=1;tick();l3d_done=0;
 endtask
 initial begin
  for(integer i=0;i<7;i++)native_seq[i]=0;
  for(integer w=0;w<'h2c000;w++)seed(24'(w));
  for(integer w=0;w<2048;w++)seed(24'h380000+24'(w));
  for(integer i=3;i<5;i++)for(integer w=0;w<4;w++)seed(24'h200000+24'(i*1024+w));
  repeat(6)@(negedge memclk);init=0;wait(ready);tick(4);rst=0;traffic_at=syscycles;traffic_mem_at=memcycles;load=1;restart();
  // Abort at an accepted real texture fill, with the request interfaces live.
  wait(dut.g_c2.u_tc.f_v[0]);tick();restart();cancel_cache_seen++;
  for(integer y=0;y<8;y++)begin
   while(syscycles<frame_at+48*4260+y*4260)tick();
   consume(y,y==7);
  end
  for(integer y=0;y<192;y++)begin
   while(syscycles<frame_at+48*4260+y*4260)tick();consume(y);
  end
  // Stop new work, preserving all offered transactions until their actual
  // handshakes. Every accepted native read and return owner must drain.
  video_stop=video_words+(video_req?1:0);load=0;
  wait(!d_req&&!c_req&&!cap_we&&p_valid==0&&empty&&!bw_valid&&!rg_wreq&&!vm_req&&nwp==nrp&&gwp==grp&&
       !vram.wb_v&&!vram.wb_p&&!cw_valid&&!vram.cap_v&&!vram.cap_p);tick(40);
  foreach(gold[address])begin
   automatic integer ix=chip_index(24'(address));
   if(known[address]==15 && {chip.peek(ix+1),chip.peek(ix)}!==gold[address])$fatal(1,"FINAL_PIN_MEMORY addr=%h",address);
   pin_memory_checks++;
  end
  wait(ref_generation==generation&&!reference.r_busy);tick(4);
  if(chip.errors||native_checks<1000||consumer_checks!=51200||pixel_checks<49152||pixel_checks!=actual_pixel_count||cancel_cache_seen!=1||cancel_read_seen!=1||refreshes<100)$fatal(1,"COMPLETE_CONE_COVERAGE compared=%0d actual=%0d",pixel_checks,actual_pixel_count);
  if(classes[0]==0||classes[1]==0||classes[2]==0||owner_blocks[0]==0||owner_blocks[1]==0||owner_blocks[2]==0||capture_pairs==0||cpu_posts<8||cpu_ops<32||lone_halves==0)$fatal(1,"SOURCE_CLASS_COVERAGE CPU=%0d posts=%0d",cpu_ops,cpu_posts);
  $display("CAPTURE_POST_COVERAGE paired=%0d CPU=%0d lonehalf=%0d",capture_pairs,cpu_posts,lone_halves);
  $display("BUFFER_BUDGET_COVERAGE maxVideoWriteWords=%0d maxVideoReadWords=%0d maxCaptureHalfwords=%0d max2DBlocks=%0d maxCPUwaitSYS=%0d pinMemoryWords=%0d",max_video_write_backlog,max_video_read_backlog,max_capture_backlog,max_2d_backlog,max_cpu_wait,pin_memory_checks);
  $display("TRAFFIC_DEADLINES mode=%0d violations=%0d,%0d,%0d,%0d",measure_traffic_deadlines,traffic_misses[0],traffic_misses[1],traffic_misses[2],traffic_misses[3]);
  $display("COMPLETE_CONE_PASS SYS=%0d MEM=%0d pixels=%0d consumer=%0d native=%0d classes=%0d,%0d,%0d blockowners=%0d,%0d,%0d CPU=%0d video=%0d capture=%0d refresh=%0d cancel=%0d,%0d",syscycles,memcycles,pixel_checks,consumer_checks,native_checks,classes[0],classes[1],classes[2],owner_blocks[0],owner_blocks[1],owner_blocks[2],cpu_ops,video_words,cap_halves,refreshes,cancel_cache_seen,cancel_read_seen);
  $finish;
 end
endmodule
