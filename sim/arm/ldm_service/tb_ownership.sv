`timescale 1ns/1ps
module tb_ownership;
 logic clk=0,memclk=0,cramclk=0,rst=1;
 always #7.4595 clk=!clk;
 always #4.973 memclk=!memclk;
 always @(memclk)cramclk<=#6.838 memclk;
 logic req=0,we=0,ldm=0;logic[6:0]meta=0;logic[31:0]addr=0,wdata=0,rdata;logic[3:0]be=15;wire ack;
 logic a7_req=0,a7_we=0,dm_req=0,dm_we=0,sn_req=0,sn_we=0;
 logic[31:0]a7_addr=0,a7_wdata=0,dm_addr=0,dm_wdata=0,sn_addr=0,sn_wdata=0;
 wire a7_ack,dm_ack,sn_ack,initialized,idle;wire[79:0]pins;integer reads,writes;
 lane_ownership #(.SERVICE(3)) dut(.clk_sys(clk),.clk_mem(memclk),.clk_cram(cramclk),.rst_sys(rst),.rst_mem(rst),
 .a9_req(req),.a9_we(we),.a9_n8(1'b0),.a9_ldm(ldm),.a9_ldm_meta(meta),.a9_addr(addr),.a9_wdata(wdata),.a9_be(be),.a9_ack(ack),.a9_rvalid(),.a9_rdata(rdata),
 .a7_req,.a7_we,.a7_addr,.a7_wdata,.a7_ack,.dm_req,.dm_we,.dm_addr,.dm_wdata,.dm_ack,.sn_req,.sn_we,.sn_addr,.sn_wdata,.sn_ack,.initialized,.idle,.pins,.reads,.writes);
 logic[31:0]gold[256];integer cycle=0,logical=0,a7time=-1,lasttime=-1;
 always @(posedge clk)begin
  cycle++;
  if(!rst&&req&&ack&&!we)begin
   if(rdata!==gold[addr[9:2]])$fatal(1,"ownership independent DATA mismatch addr%h got%h expected%h",addr,rdata,gold[addr[9:2]]);
   logical++;if(meta[5])lasttime=cycle;
  end
  if(!rst&&a7_req&&a7_ack)a7time=cycle;
 end
 task automatic word(input logic[31:0]a,input logic[6:0]m);
  @(negedge clk);req=1;we=0;ldm=1;be=15;addr=a;meta=m;
  do @(posedge clk);while(!ack);
 endtask
 task automatic drop;
  @(negedge clk);req=0;ldm=0;meta=0;
 endtask
 task automatic group(input logic[31:0]a,input int n);
  for(int k=0;k<n;k++)word(a+32'(4*k),7'(((n-1)<<1)|1|(k==0?64:0)|(k==n-1?32:0)));
  drop();
 endtask
 task automatic other_write(input int owner,input logic[31:0]a,d);
  @(negedge clk);
  case(owner)
   0:begin a7_req=1;a7_we=1;a7_addr=a;a7_wdata=d;end
   1:begin dm_req=1;dm_we=1;dm_addr=a;dm_wdata=d;end
   2:begin sn_req=1;sn_we=1;sn_addr=a;sn_wdata=d;end
  endcase
  do @(posedge clk);while(!(owner==0?a7_ack:owner==1?dm_ack:sn_ack));
  gold[a[9:2]]=d;
  @(negedge clk);a7_req=0;dm_req=0;sn_req=0;
 endtask
 initial begin
  for(int k=0;k<256;k++)gold[k]=32'h13240000+32'(k);
  #1;for(int k=0;k<256;k++)begin dut.chips.m0.mem[32'h4000+k]=gold[k][15:0];dut.chips.m1.mem[32'h4000+k]=gold[k][31:16];end
  repeat(12)@(negedge clk);rst=0;wait(initialized);repeat(8)@(negedge clk);
  group(32'h0241000c,2);
  begin integer oldreads;oldreads=reads;
   repeat(8)group(32'h0241000c,2);
   if(reads!=oldreads||oldreads!=2)$fatal(1,"crossing replay store failed %0d/%0d",oldreads,reads);
  end
  word(32'h0241000c,7'h43);
  fork
   begin word(32'h02410010,7'h23);drop();end
   begin wait(dut.u_fab.ls_end);other_write(0,32'h0281000c,32'ha55aa55a);end
  join
  if(a7time<0||a7time>=lasttime)$fatal(1,"deferred final response locked physical service %0d/%0d",a7time,lasttime);
  $display("OPPOSING_ARM7_PROGRESS a7%0d final%0d",a7time,lasttime);
  group(32'h0241000c,2);
  other_write(1,32'h0241000c,32'h12345678);group(32'h0281000c,2);
  other_write(2,32'h0281000c,32'habcdef01);group(32'h0241000c,2);
  @(negedge clk);req=1;we=1;ldm=0;meta=0;addr=32'h0241000c;wdata=32'h00005500;be=2;
  do @(posedge clk);while(!ack);
  gold[3][15:8]=8'h55;drop();group(32'h0241000c,2);
  group(32'h02410004,8);
  begin integer oldreads;oldreads=reads;repeat(8)group(32'h02410004,8);if(reads!=oldreads)$fatal(1,"three-quad replay eviction");end
  // Cancel an already captured final response; reset must clear its credit,
  // data owner and completed-line validity before a fresh first.
  word(32'h0241000c,7'h43);
  @(negedge clk);req=1;addr=32'h02410010;meta=7'h23;
  wait(dut.u_fab.ls_end);@(negedge clk);rst=1;req=0;ldm=0;
  repeat(8)@(negedge clk);rst=0;
  repeat(8)begin @(posedge clk);if(ack)$fatal(1,"cancelled final response leaked ACK");end
  wait(initialized);group(32'h0241000c,2);repeat(30)@(negedge clk);
  if(dut.chips.m0.errors+ dut.chips.m1.errors)$fatal(1,"chip pin error");
  $display("SERVICE_OWNERSHIP_PASS words%0d reads%0d writes%0d reset/cancel/all-master-poison/byte/mirror",logical,reads,writes);$finish;
 end
 initial begin #1000000;$fatal(1,"ownership timeout");end
endmodule
