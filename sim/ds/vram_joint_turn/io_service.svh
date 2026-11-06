// Real peripheral service for an older ARM9 I/O owner. No delayed/fake ACK.
logic clk2=0,tick=0;
initial forever begin #3.730;clk2=1;#3.729;clk2=0;#3.730;clk2=1;#3.730;clk2=0;end
always @(posedge clk)if(rst)tick<=0;else tick<=!tick;
wire sys_req;wire[31:0]sys_rdata;
wire irq9;logic[31:0]irq_ext7=0;
wire[15:0]io_pow1,io_exmem,io_bios;wire[1:0]io_pow2,io_wram;wire[71:0]io_vram;
wire[31:0]io_boot;wire io_halt;
nds_io #(.SOUND_ACK_EARLY(1))hub(.clk,.rst,.io_req,.io_cpu,.io_we,.io_be,.io_addr,.io_wdata(io_data),.io_ack,.io_rdata,
 .sys_req,.sys_rdata,.disp_req(),.disp_rdata(32'hface0011),.cart_req(),.cart_reg(),.cart_rdata(32'hface0022),
 .spi_req(),.spi_rdata(32'hface0033),.rtc_req(),.rtc_rdata(32'hface0044),
 .snd_req(),.snd_ack(1'b0),.snd_rdata(32'd0),.snd_real(1'b0),.gx_req(),.gx_ack(1'b0),.gx_rdata(32'd0),.gx_real(1'b0),.gx_ovf(1'b0),
 .wf_req(),.wf_ack(1'b0),.wf_rdata(32'd0),.disp3dcnt_o(),.keys(12'h805),.pen_down(1'b0),.lid_closed(1'b0),
 .rom_size(32'd0),.mem_dirty(1'b0),.save_info(8'd0),.rtc_valid(1'b0),.rtc_date(32'd0),.rtc_time(32'd0),.vramstat(2'd0),
 .powcnt1(io_pow1),.powcnt2(io_pow2),.exmemcnt(io_exmem),.wramcnt(io_wram),.vramcnt(io_vram),.biosprot(io_bios),.bootctl(io_boot),
 .tsc_kx(),.tsc_ky(),.tsc_ox(),.tsc_oy(),.halt7(io_halt),.irq_key9(),.irq_key7(),.gx_irq());
nds_sys #(.DMA_FAST(1),.PUMP(1))sys(.clk,.clk2,.rst,.tick,.io_req(sys_req),.tmr_oh(io_tmr_oh),.io_cpu,.io_we,.io_be,.io_addr(io_addr[20:2]),.io_wdata(io_data),.io_rdata(sys_rdata),.io_hit(),
 .dma_trig9(7'd0),.dma_gx_low(1'b0),.dma_stop9(7'd0),.dma_trig7(3'd0),
 .m_req(),.m_we(),.m_cpu(),.m_size32(),.m_addr(),.m_wgroup(),.m_last(),.m_vcut(),.m_unit(),.m_dst(),.m_more(),.m_wdata(),
 .m_ack(1'b0),.m_rdata(32'd0),.dma_busy(),.irq_ext9(32'd0),.irq_ext7,.irq9,.irq7(irq_cpu),.wake7(),.math_late(),.dbg_dma_run(),.dma_lat_lost());

bit io_cancel_pending=0,svc_pending=0,irq_sent=0,irq_seen=0;
logic[31:0]svc_expected=0,svc_wdata=0;logic[23:2]svc_addr=0;logic[3:0]svc_be=0;
logic svc_cpu=0,svc_we=0;integer svc_owner=0,svc_first=-1;
integer io_file=0,svc_CE=0,svc_ACK=0,io_orphans=0,io_side_starts=0;
initial begin wait(out!="");io_file=$fopen({out,".io"},"w");end
always @(posedge clk)begin
 if(rst)begin svc_pending=0;end
 else begin
  if(io_req)begin
   if(svc_pending)$fatal(1,"peripheral enabled twice for one owner");
   svc_pending=1;svc_CE++;svc_addr=io_addr;svc_cpu=io_cpu;svc_we=io_we;svc_be=io_be;svc_wdata=io_data;
   svc_owner=fab.io_grant ? (fab.grant[1]?1:2) : integer'(fab.mst);svc_first=cycle;
   if(!io_we&&io_addr==22'h40)svc_expected={sys.u_tmr9.cnt[0],sys.u_tmr9.ctr[0]};
   else if(!io_we&&io_addr==22'h4c)svc_expected=32'h000003fa;
   else if(!io_we&&io_addr==22'h69)svc_expected=32'hface0022;
   else svc_expected=0;
   $fdisplay(io_file,"CE %0d owner%0d cpu%0d wr%0d addr%h be%h wd%h expect%h",cycle,svc_owner,io_cpu,io_we,io_addr,io_be,io_data,svc_expected);
  end
  if(io_ack)begin
   if(!svc_pending)$fatal(1,"peripheral ACK without accepted request");
   if(io_addr!==svc_addr||io_cpu!==svc_cpu||io_we!==svc_we||io_be!==svc_be||io_data!==svc_wdata||integer'(fab.mst)!=svc_owner)
    $fatal(1,"older I/O descriptor changed before ACK");
   if(!svc_we&&io_rdata!==svc_expected)$fatal(1,"I/O returned a different owner or peripheral sample");
   if(cycle!=svc_first+1)$fatal(1,"older real I/O CE/ACK timing changed");
   if(svc_owner==1&&!a9_ack)$fatal(1,"older I/O owner lost its ACK");
   if(svc_owner==2&&!fack)$fatal(1,"ARM7 register owner lost its ACK");
   svc_pending=0;svc_ACK++;
   $fdisplay(io_file,"ACK %0d owner%0d data%h",cycle,svc_owner,io_rdata);
  end
  if(a9_ack&&!a9_req)begin
   if(!io_cancel_pending)$fatal(1,"wrong-owner ARM9 completion");io_orphans++;
  end
`ifdef NEW_VRAM_IO_SIDE
  if(fab.v7_start&&fab.v7_io_read)begin
   io_side_starts++;
   if(!IO_SIDE||fw||fab.mst!=1||fab.we||!fab.io_sent)$fatal(1,"IO-side capture has no older read owner");
   $fdisplay(io_file,"SIDE %0d actualA7%h oldIO%h ioACK%0d",cycle,fa,fab.addr,io_ack);
  end
`endif
 end
end

// An external source enters the real SYS IRQ controller. The guest enables
// IE/IME and acknowledges IF through real register writes in its handler.
always @(negedge clk)if(!rst&&run)begin
 if(irq_test&&!irq_sent&&cpu.pipe_fire&&cpu.dm_rq&&cpu.esub==1&&dok&&da==32'h06000100)begin
  irq_sent=1;irq_ext7=1;
 end
 if(irq_sent&&cpu.mode==5'h12)begin irq_seen=1;irq_ext7=0;end
end

task automatic real_io(input logic[31:0]a,input bit write_access,input logic[31:0]data,input bit cancel_access);
 a9_req=1;a9_we=write_access;a9_n8=0;a9_addr=a;a9_wdata=data;
 if(cancel_access)begin
  do @(posedge clk);while(!(io_req&&!io_cpu)&&!reset_park);
  @(negedge clk);io_cancel_pending=1;a9_req=0;
 end
 do @(posedge clk);while(!a9_ack&&!reset_park);
 if(!reset_park&&!write_access&&a9_rdata!==svc_expected)$fatal(1,"ARM9 I/O got another endpoint's data");
 @(negedge clk);a9_req=0;a9_we=0;io_cancel_pending=0;
endtask
initial begin
 wait(!rst&&pins_ready);@(negedge clk);
 real_io(32'h04000100,1,32'h00800000,0);io_init_done=1;
 wait(epoch>=0);
 if(io_mode)begin
  if(main_enable&&pressure&&owner==1)$fatal(1,"conflicting ARM9 stimulus owners");
  while(cpu_end<0&&!reset_park)begin
   @(negedge clk);
   if((!fetch_io && cpu.esub==0&&cpu.e_mem&&(cpu.ins[20]||store_io)
       && ((cpu.ins[24]?cpu.sum:cpu.opa)>>24)==32'h06
       && ((phase==0&&cpu.ph)||(phase==1&&!cpu.ph)))
      || (fetch_io&&p7.rp_v&&p7.rp_i&&!p7.busy&&p7.rp_a[31:24]==8'h06))begin
    logic[31:0]a;
    a=io_target==1?32'h04000100:io_target==2?32'h040001a4:io_target==4?32'h04000400:32'h04000130;
    real_io(a,io_target==3,0,cancel_io&&io_count==0);io_count++;
   end
  end
 end
 io_actor_done=1;
end
final begin
 if(!rst&&!reset_seen&&svc_CE!=svc_ACK)$fatal(1,"unfinished peripheral owner");
 if(!reset_seen&&irq_test&&!irq_seen)$fatal(1,"IRQ handler never entered");
 if(!reset_seen&&cancel_io&&io_orphans!=1)$fatal(1,"canceled owner completion count");
 $display("IO_SERVICE CE%0d ACK%0d side%0d reads%0d orphan%0d IRQ%0d",svc_CE,svc_ACK,io_side_starts,io_count,io_orphans,irq_seen);
end
