`timescale 1ns/1ps
module tb_rhit;
 import gpu2d_pkg::*;
 parameter bit EN=1, PF=0, LIVE=0, WRAP=0, HELD_MAP=0, MAP_BUS=0;
 logic clk=0,rst=1;always #5 clk=!clk;
 logic[71:0]vramcnt=72'h80;
 logic c_req=0,c_we=0,c_cpu=0,c_dma=1;logic[23:2]c_addr=22'h200000;
 logic[3:0]c_be=15;logic[31:0]c_wdata=0,c_rdata;wire c_ack;
 logic g_req=0;blk_t g_blk;wire g_ack,g_rvalid;wire[63:0]g_rdata;
 logic cap_we=0;logic[17:0]cap_addr=0;logic[15:0]cap_data=0;wire cap_ready;
 wire cw_valid;wire[23:0]cw_addr;wire[31:0]cw_data;wire[1:0]cw_he;
 logic cw_ack=0,cw_drained=1;logic[6:0]cw_fill=0,cw_pcnt=0;logic allow_cw=1;
 logic sv_req=0,sv_we=0;wire sv_ack;wire[31:0]sv_rdata;
 wire vm_req,vm_we,vm_blk;wire[20:2]vm_addr;wire[3:0]vm_be;wire[31:0]vm_wdata;
 logic vm_ack=0,vm_rvalid=0;logic[31:0]vm_rdata=0;
 logic map_req=0;wire map_ack;
 wire vc_req,vc_we,vc_cpu,vc_dma,vc_ack;wire[23:2]vc_addr;wire[3:0]vc_be;wire[31:0]vc_wdata,vc_rdata;
 generate if(WRAP)begin:wrapped
  wire dm_ack,a9_ack;wire[31:0]dm_rdata,a9_rdata;
  wire fi_req,fi_we,fi_cpu;wire[23:2]fi_addr;wire[31:0]fi_wdata;logic fi_ack=0;
  assign map_ack=a9_ack;
  always @(posedge clk)begin
   fi_ack<=!rst&&fi_req;
   if(!rst&&fi_req&&fi_we&&!fi_cpu&&fi_addr==22'h90)begin
    if(vc_req)$fatal(1,"MAPPING_WRITE_OVERLAPS_HELD_VRAM");
    vramcnt[31:0]=fi_wdata;
   end
  end
  wire[31:0]byteaddr=32'h06000000|{8'd0,c_addr,2'b00}|((c_be==4'hC)?32'd2:32'd0);
  nds_fabric #(.OAM_SHARE(1)) fabric(
   .clk,.rst,.wramcnt(2'd0),.pb_busy(1'b0),
   .dm_req(c_req&&c_dma),.dm_we(c_we),.dm_cpu(c_cpu),.dm_size32(c_be==15),.dm_addr(byteaddr),
   .dm_unit(1'b0),.dm_more(1'b0),.dm_dst(32'd0),.dx_ready(1'b1),.dx_idle(1'b1),.dm_wdata(c_wdata),.dm_ack,.dm_rdata,
   .a9_req((c_req&&!c_dma)||map_req),.a9_we(map_req||c_we),.a9_addr(map_req?32'h04000240:byteaddr),.a9_be(map_req?4'hF:c_be),.a9_tmr(4'd0),.a9_wdata(map_req?32'h00808100:c_wdata),.a9_n8(1'b0),.a9_ack,.a9_rdata,
   .a7_req(1'b0),.a7_we(1'b0),.a7_addr(32'd0),.a7_be(4'd0),.a7_wdata(32'd0),
   .sn_req(1'b0),.sn_we(1'b0),.sn_addr(32'd0),.sn_wdata(32'd0),
   .mr_ack(1'b0),.mr_rvalid(1'b0),.mr_rdata(32'd0),.mr_wnext(1'b0),
   .fx_done(1'b0),.fx_rdata(32'd0),.boot_q(32'd0),.io_req(fi_req),.io_cpu(fi_cpu),.io_we(fi_we),.io_addr(fi_addr),.io_wdata(fi_wdata),.io_ack(fi_ack),.io_rdata(32'd0),
   .vr_req(vc_req),.vr_cpu(vc_cpu),.vr_dma(vc_dma),.vr_we(vc_we),.vr_addr(vc_addr),.vr_be(vc_be),.vr_wdata(vc_wdata),.vr_ack(vc_ack),.vr_rdata(vc_rdata),
   .pal_cq(32'd0),.oam_cgnt(1'b0),.oam_cq(32'd0));
  assign c_ack=c_dma?dm_ack:a9_ack;assign c_rdata=c_dma?dm_rdata:a9_rdata;
 end else begin:direct_
  assign {vc_req,vc_we,vc_cpu,vc_dma,vc_addr,vc_be,vc_wdata}={c_req,c_we,c_cpu,c_dma,c_addr,c_be,c_wdata};
  assign c_ack=vc_ack;assign c_rdata=vc_rdata;
 end endgenerate
 nds_vram #(.CAP_CHAIN(1),.VR_POST(1),.VR_RDB(1),.VR_PASS(1),.VR_WB(1),.VR_CWF(1),.VR_PDRAIN(1),.VR_PH(1),.VR_RHIT(EN),.VR_PF(PF),.VR_HIT(LIVE)) dut(
 .clk,.rst,.vramcnt,.c_req(vc_req),.c_cpu(vc_cpu),.c_dma(vc_dma),.c_we(vc_we),.c_addr(vc_addr),.c_be(vc_be),.c_wdata(vc_wdata),.c_ack(vc_ack),.c_rdata(vc_rdata),
 .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata,.cap_we,.cap_addr,.cap_data,.cap_ready,
 .cw_valid,.cw_addr,.cw_data,.cw_he,.cw_ack,.cw_drained,.cw_fill,.cw_pcnt,
 .sv_req,.sv_we,.sv_addr(19'd0),.sv_be(4'hF),.sv_wdata(32'd0),.sv_ack,.sv_rdata,
 .vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,.vramstat());
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
    reason=PF?11:g_req?1:dut.wb_v?2:!dut.c_res_owned?3:!dut.res_q[20]?4:!dut.lhit[0]?5:dut.post_p?6:dut.cap_v?7:dut.cap_p?8:cap_we?9:(sv_req&&sv_we)?10:0;
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
 task automatic settle;repeat(200)@(negedge clk);endtask
 task automatic read_addr(input logic[21:0]a,input logic[31:0]expected,input logic[3:0]be_=15);
  integer start_;@(negedge clk);c_req=1;c_we=0;c_addr=a;c_be=be_;start_=cyc;
  do @(posedge clk);while(!c_ack);
  if(c_rdata!==((WRAP&&c_dma&&be_!=15)?(be_==12?{16'd0,expected[31:16]}:{16'd0,expected[15:0]}):expected))$fatal(1,"READ_PAYLOAD a=%0d got=%h expected=%h",a,c_rdata,expected);
  reads++;$display("READ a=%0d latency=%0d",a,cyc-start_);
  @(negedge clk);c_req=0;c_be=15;@(negedge clk);
 endtask
 task automatic read_(input integer a,input logic[31:0]expected);
  read_addr(22'h200000|22'(a),expected);
 endtask
 task automatic write_(input integer a,input logic[31:0]d,input logic[3:0]be_);
  @(negedge clk);c_req=1;c_we=1;c_addr=22'h200000|22'(a);c_wdata=d;c_be=be_;
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
 initial begin
  g_blk='0;for(integer a=0;a<262144;a++)mem[a]=pattern(a);
  repeat(4)@(negedge clk);rst=0;
  read_(0,pattern(0));settle();
  if(MAP_BUS)begin
   if(!WRAP)$fatal(1,"MAP_BUS_NEEDS_FABRIC");
   vramcnt=72'h808081;settle();read_addr(0,pattern(0));settle();return_delay=50;block_(65536+64);
   @(negedge clk);c_req=1;c_we=0;c_addr=3;
   @(posedge clk);@(negedge clk);map_req=1;
   do begin
    @(posedge clk);
    if(vramcnt!==72'h808081)$fatal(1,"MAP_CHANGED_BEFORE_DMA_ACK");
   end while(!c_ack);
   if(c_rdata!==pattern(3))$fatal(1,"READ_PAYLOAD before_map got=%h expected=%h",c_rdata,pattern(3));
   @(negedge clk);c_req=0;
   do @(posedge clk);while(!map_ack);
   @(negedge clk);map_req=0;settle();
   if(vramcnt!==72'h808100)$fatal(1,"MAP_WRITE_NOT_APPLIED");
   block_(65536+64);read_addr(3,pattern(32768+3));settle();
   $display("MAP_BUS_PASS hits=%0d",hits);$finish;
  end
  if(HELD_MAP)begin
   // Change the sideband map after the held request owns res_q but before ACK.
   // Control resolves the new B mapping after block drain; this probes whether
   // a registered hit improperly keeps the earlier A translation.
   vramcnt=72'h808081;settle();read_addr(0,pattern(0));settle();return_delay=50;block_(65536+64);
   @(negedge clk);c_req=1;c_we=0;c_addr=3;
   @(posedge clk);@(negedge clk);vramcnt=72'h808100;
   do @(posedge clk);while(!c_ack);
   if(c_rdata!==pattern(32768+3))$fatal(1,"READ_PAYLOAD held_map got=%h expected=%h",c_rdata,pattern(32768+3));
   @(negedge clk);c_req=0;
   settle();$display("HELD_MAP_PASS");$finish;
  end
  // Cached hit during an unrelated accepted block's delayed return.
  return_delay=50;block_(64);read_(3,pattern(3));settle();
  if(EN&&!PF&&!LIVE&&hits==0)$fatal(1,"NO_REGISTERED_HIT_WITNESS");
  // A tag from an older descriptor cannot certify a newly held CPU address.
  block_(0);read_(16,pattern(16));settle();
  // Non-DMA class keeps its ordinary fallback.
  c_dma=0;block_(64);read_(17,pattern(17));settle();c_dma=1;
  // Mapping changes do not reuse an old cached physical descriptor.
  block_(64);vramcnt=0;read_(16,32'd0);settle();vramcnt=72'h80;
  read_(0,pattern(0));settle();
  // Physical aliases and bank remaps, with another LCDC bank draining.
  // ABG mirror ignores byte bit19; both aliases must select physical A.
  vramcnt=72'h808081;settle();read_addr(0,pattern(0));settle();
  block_(65536+64);read_addr(22'h020003,pattern(3));settle();
  // Same virtual address now selects bank B, never the old cached A line.
  vramcnt=72'h808100;settle();block_(65536+64);
  read_addr(3,pattern(32768+3));settle();
  // All nine LCDC physical banks and both read byte-enable halfword classes.
  vramcnt=72'h808080808080808080;settle();
  for(integer b=0;b<9;b++)begin
   integer base;case(b)
    0:base=0;1:base=32768;2:base=65536;3:base=98304;
    4:base=131072;5:base=147456;6:base=151552;7:base=155648;default:base=163840;
   endcase
   read_(base,pattern(base));settle();
   block_(64);read_addr(22'h200000|22'(base+3),pattern(base+3),4'h3);settle();
   block_(64);read_addr(22'h200000|22'(base+5),pattern(base+5),4'hC);settle();
  end
  // ARM7 view maps C, but remains outside registered DMA eligibility.
  vramcnt=72'h828080;c_cpu=1;settle();block_(32768+64);
  read_addr(3,pattern(65536+3));settle();c_cpu=0;
  vramcnt=72'h80;settle();read_(0,pattern(0));settle();
  // An invalid translation must not return the resident physical line zero.
  block_(64);vramcnt=0;read_(0,32'd0);settle();vramcnt=72'h80;read_(0,pattern(0));settle();
  // The first pending capture halfword, before the single-write timer fires,
  // must fence a simultaneous same-word held read.
  block_(64);
  fork
   capture_(0,16'hBEAD);
   read_(0,(pattern(0)&32'hFFFF0000)|32'hBEAD);
  join
  settle();write_(0,pattern(0),4'hF);settle();read_(0,pattern(0));settle();
  // A lone high halfword must land before this later read. The VM write
  // waits behind the already accepted block; pending capture is a fence.
  block_(64);capture_(1,16'hFACE);
  read_(0,32'hFACE0000|(pattern(0)&32'hFFFF));settle();
  if(capwrites==0)$fatal(1,"NO_SINGLE_CAPTURE_WRITE");
  // A capture pair can post while block words return, but the read must
  // observe the older pair after the ordered write queue drains.
  block_(64);allow_cw=0;capture_(0,16'h1234);capture_(1,16'h5678);
  fork
   read_(0,32'h56781234);
   begin repeat(10)@(negedge clk);allow_cw=1;end
  join
  settle();
  // Posted full/partial CPU writes retain their buffer and drain fences.
  block_(64);write_(0,32'h98765432,4'hF);read_(0,32'h98765432);settle();
  block_(64);write_(2,32'h0000BEEF,4'h3);read_(2,(pattern(2)&32'hFFFF0000)|32'hBEEF);settle();
  // Joint reset cancels the outstanding block and translation owner.
  block_(64);@(negedge clk);rst=1;c_req=0;cap_we=0;
  repeat(3)@(negedge clk);rst=0;read_(0,32'h98765432);settle();
  // Repeated actual payload reads while two ordered blocks share the port.
  for(integer i=0;i<16;i++)begin
   block_(64+(i%8)*8);if(i%3==0)block_(128+(i%8)*8);
   read_(2+(i%6),(i%6==0)?((pattern(2)&32'hFFFF0000)|32'hBEEF):pattern(2+(i%6)));settle();
  end
  if(ge.size()!=0||qa.size()!=0||left_!=0||wa.size()!=0)$fatal(1,"UNFINISHED_WORK");
  if(PF&&hits!=0)$fatal(1,"PF_REGISTERED_HIT_GUARD");
  for(integer reason=0;reason<12;reason++)$display("ELIGIBILITY reason=%0d cycles=%0d",reason,eligibility[reason]);
  $display("RHIT_UNIT_PASS EN=%0d reads=%0d hit_events=%0d block_beats=%0d single_capture_writes=%0d",EN,reads,hits,blocks,capwrites);
  $finish;
 end
 initial begin #1000000;$fatal(1,"RHIT_TIMEOUT");end
endmodule
