`timescale 1ns/1ps
module tb_caller89;
 logic clk=0,clk_2x=1,rst=1,tick=0;always #2 clk=~clk;always #1 clk_2x=~clk_2x;
 logic a7_req=0,a7_we=0,a9_req=0,a9_we=0,dm_req=0,dm_we=0;
 logic [31:0] a7_addr=0,a7_wdata=0,a9_addr=0,a9_wdata=0,dm_addr=0,dm_wdata=0;
 logic [3:0] a7_be=15,a9_be=15;
 logic [1:0] a7_ack,a9_ack,dm_ack,mr_req,mr_we,mr_n8,sn_req,sn_we,aud_valid,overrun,io_req,io_we;
 logic [31:0] a7_rdata[2],a9_rdata[2],dm_rdata[2],mr_wdata[2],sn_addr[2],sn_wdata[2],snd_late[2];
 logic [21:2] mr_addr[2];logic [3:0] mr_be[2];logic [767:0] observed[2];
 logic [15:0] aud_l[2],aud_r[2],wait_max[2];logic [23:2] io_addr[2];
 logic mr_ack=0,mr_rvalid=0;logic [31:0] mr_rdata=0;
 genvar n;
 generate for(n=0;n<2;n++)begin : pair
 caller89_endpoint #(.OLD(n==1)) dut(.clk,.clk_2x,.rst,.tick,
 .a7_req,.a7_we,.a7_addr,.a7_wdata,.a7_be,.a9_req,.a9_we,.a9_addr,.a9_wdata,.a9_be,
 .dm_req,.dm_we,.dm_addr,.dm_wdata,.a7_ack(a7_ack[n]),.a9_ack(a9_ack[n]),.dm_ack(dm_ack[n]),
 .a7_rdata(a7_rdata[n]),.a9_rdata(a9_rdata[n]),.dm_rdata(dm_rdata[n]),
 .mr_req(mr_req[n]),.mr_we(mr_we[n]),.mr_n8(mr_n8[n]),.mr_addr(mr_addr[n]),.mr_be(mr_be[n]),.mr_wdata(mr_wdata[n]),
 .mr_ack,.mr_rvalid,.mr_rdata,.observed(observed[n]),.sn_req(sn_req[n]),.sn_we(sn_we[n]),.sn_addr(sn_addr[n]),.sn_wdata(sn_wdata[n]),
 .aud_valid(aud_valid[n]),.aud_l(aud_l[n]),.aud_r(aud_r[n]),.snd_late(snd_late[n]),.engine_overrun(overrun[n]),
 .io_req(io_req[n]),.io_we(io_we[n]),.io_addr(io_addr[n]),.snd_wait_max(wait_max[n]));
 end endgenerate
 int cyc=0,timer=128,phase=0,cpu_done=0,cpu_reads=0,cpu_writes=0,a9_count=0,dma_count=0;
 int sound_reads=0,sound_writes=0,outputs=0,nonzero=0,max_cpu_latency=0,cpu_overlap=0,main_overlap=0,capture0=0,capture1=0;
 int memory_state=0,delay_count=0,beat=0;logic [14:0] held_addr;logic held_we;logic [31:0] held_data;logic [3:0] held_be;
 logic [31:0] ram[32768];
 function automatic logic [31:0] pattern(input logic [31:0] a);
  logic [31:0] b;b=(a^32'h25a31cb7)*32'h9e3779b1;return b^(b>>13);
 endfunction
 initial begin
  for(int k=0;k<32768;k++)ram[k]=pattern(32'(k));
  void'($value$plusargs("timer=%d",timer));
  repeat(8)@(negedge clk);rst=0;
 end
 always @(negedge clk)begin
  cyc++;tick=!tick;
  if(!rst && observed[0]!==observed[1])begin
   $display("CALLER89_DIFF c%0d CPUack%b/%b data%h/%h SN%b:%h/%b:%h OUT%b:%h:%h/%b:%h:%h late%0d/%0d over%b/%b",cyc,a7_ack[0],a7_ack[1],a7_rdata[0],a7_rdata[1],sn_req[0],sn_addr[0],sn_req[1],sn_addr[1],aud_valid[0],aud_l[0],aud_r[0],aud_valid[1],aud_l[1],aud_r[1],snd_late[0],snd_late[1],overrun[0],overrun[1]);
   $fatal(1,"CALLER89_PUBLIC_MISMATCH cycle%0d",cyc);
  end
  if(!rst)begin
   if(a7_req && sn_req[0])cpu_overlap++;
   if((a9_req || dm_req) && sn_req[0])main_overlap++;
   if(aud_valid[0])begin outputs++;if(aud_l[0]!=16'h8000 || aud_r[0]!=16'h8000)nonzero++;end
   if(pair[0].dut.sn_req && pair[0].dut.sn_ack)begin
    if(sn_we[0])begin sound_writes++;if(sn_addr[0]>=32'h02010000 && sn_addr[0]<32'h02011000)capture0++;if(sn_addr[0]>=32'h02011000 && sn_addr[0]<32'h02012000)capture1++;end
    else sound_reads++;
   end
  end
 end
 // The same endpoint model supplies both compared real fabrics. Read data is
 // sampled at each physical completion; writes update byte lanes at ACK.
 always @(posedge clk)begin
  mr_ack<=0;mr_rvalid<=0;
  if(rst)memory_state<=0;
  else case(memory_state)
   0:if(mr_req[0] && !mr_ack)begin
    if(mr_n8[0])$fatal(1,"fixture scalar traffic unexpectedly requested n8");
    held_addr<=mr_we[0]?mr_addr[0][16:2]:{mr_addr[0][16:4],2'd0};held_we<=mr_we[0];held_data<=mr_wdata[0];held_be<=mr_be[0];
    delay_count<=2+cyc%4;memory_state<=1;
   end
   1:if(delay_count!=0)delay_count<=delay_count-1;
    else begin
     mr_ack<=1;beat<=0;delay_count<=1;memory_state<=held_we?3:2;
     if(held_we)for(int b=0;b<4;b++)if(held_be[b])ram[held_addr][8*b+:8]<=held_data[8*b+:8];
    end
   2:if(delay_count!=0)delay_count<=delay_count-1;
    else begin mr_rvalid<=1;mr_rdata<=ram[held_addr+15'(beat)];beat<=beat+1;delay_count<=cyc%3;if(beat==3)memory_state<=3;end
   3:memory_state<=0;
  endcase
 end
 task automatic cpu(input logic we,input logic [31:0] addr,data,input logic [3:0] be=15);
  int start;
  @(negedge clk);a7_req=1;a7_we=we;a7_addr=addr;a7_wdata=data;a7_be=be;start=cyc;
  do begin @(posedge clk);if(cyc-start>8000)$fatal(1,"CALLER89_CPU_TIMEOUT addr%h cycle%0d",addr,cyc);end while(!a7_ack[0]);
  if(cyc-start>max_cpu_latency)max_cpu_latency=cyc-start;
  if(we)cpu_writes++;else cpu_reads++;
  @(negedge clk);a7_req=0;
  repeat(2)@(negedge clk);
 endtask
 initial begin
  wait(!rst);cpu(1,32'h04000304,1,1);
  for(int c=0;c<16;c++)begin
   cpu(1,32'h04000404+32'(c*16),32'h02001000+32'(c*128));
   cpu(1,32'h04000408+32'(c*16),32'h00010000|32'(16'(-timer)));
   cpu(1,32'h0400040c+32'(c*16),32'd16);
   cpu(1,32'h04000400+32'(c*16),32'hc800007f|32'(c*8)<<16);
  end
  cpu(1,32'h04000500,32'h0000807f,3);
  cpu(1,32'h04000510,32'h02010000);cpu(1,32'h04000514,128);
  cpu(1,32'h04000518,32'h02011000);cpu(1,32'h0400051c,128);
  cpu(1,32'h04000508,32'h00008080,3);phase=1;
  for(int k=0;k<400;k++)begin
   repeat(40+k%11)@(negedge clk);
   case(k%8)
    0:cpu(0,32'h04000400+32'((k%16)*16),0);
    1:cpu(0,32'h04000408+32'((k%16)*16),0);
    2:cpu(1,32'h04000401+32'((k%16)*16),32'h00000200,2);
    3:cpu(1,32'h02001000+32'((k%128)*4),pattern(32'(k)));
    4:cpu(0,32'h04000508,0);
    5:cpu(1,32'h04000402+32'((k%16)*16),32'h00400000,4);
    6:cpu(0,32'h04000500,0);
    7:cpu(0,32'h02001000+32'((k%128)*4),0);
   endcase
  end
  cpu_done=1;
 end
 initial begin
  wait(phase==1);
  for(int k=0;k<400;k++)begin
   repeat(45+k%13)@(negedge clk);a9_req=1;a9_we=(k%5==0);a9_addr=32'h02018000+32'((k%512)*4);a9_wdata=pattern(32'(k+100));
   do @(posedge clk);while(!a9_ack[0]);a9_count++;
   @(negedge clk);a9_req=0;
  end
 end
 initial begin
  wait(phase==1);
  for(int k=0;k<180;k++)begin
   repeat(160+k%19)@(negedge clk);dm_req=1;dm_we=(k%3==0);dm_addr=32'h0201c000+32'((k%512)*4);dm_wdata=pattern(32'(k+500));
   do @(posedge clk);while(!dm_ack[0]);dma_count++;
   @(negedge clk);dm_req=0;
  end
 end
 initial begin
  wait(cyc>=200000);@(negedge clk);
  if(!cpu_done || cpu_reads<100 || cpu_writes<150 || a9_count!=400 || dma_count!=180 || sound_reads<100 || sound_writes<20 || capture0<10 || capture1<10 || outputs<50 || nonzero<20 || cpu_overlap<20 || main_overlap<20)
   $fatal(1,"CALLER89_COVERAGE cpu%0d/%0d done%0d A9%0d DMA%0d SN%0d/%0d CAP%0d/%0d OUT%0d nonzero%0d overlap%0d/%0d",cpu_reads,cpu_writes,cpu_done,a9_count,dma_count,sound_reads,sound_writes,capture0,capture1,outputs,nonzero,cpu_overlap,main_overlap);
  $display("CALLER89_PAIRED_PASS timer%0d cycles%0d CPUreads%0d writes%0d maxACK%0d A9%0d DMA%0d SNreads%0d writes%0d CAP%0d/%0d OUT%0d nonzero%0d overlap%0d/%0d retained_late%0d overrun%0d waitmax%0d",timer,cyc,cpu_reads,cpu_writes,max_cpu_latency,a9_count,dma_count,sound_reads,sound_writes,capture0,capture1,outputs,nonzero,cpu_overlap,main_overlap,snd_late[0],overrun[0],wait_max[0]);$finish;
 end
 initial begin #900000;$fatal(1,"CALLER89_TIMEOUT");end
endmodule
