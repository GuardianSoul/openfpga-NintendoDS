`timescale 1ns/1ps
module tb_tags #(parameter int XI=1, parameter int OPT=1711268835);
logic clk=0,rst=1,i_req=0,i_priv=1,i_half_hi=0,d_req=0,d_we=0,d_priv=1,d_kill=0,cp_req=0,cp_we=0;
logic[31:0]i_addr=0,d_addr=0,d_wdata=0,cp_wdata=0;logic[3:0]d_be=15;logic[15:0]cp_op=0;
logic b_ack=0,b_wnext=0;logic[31:0]b_rdata=0;
wire[31:0]ir[0:1],dr[0:1],ba[0:1],bw[0:1];wire[15:0]ih[0:1];wire io[0:1],iab[0:1],dok[0:1],dab[0:1],dw[0:1],hv[0:1],bn[0:1],br[0:1],bwe[0:1];wire[3:0]bbe[0:1],bt[0:1];wire[1:0]dg[0:1];
`define PARAM .WAYS(2),.BURST(1),.SLOW(1),.EVB(1),.EVBW(0),.EARLYD(1),.XD(2),.XI(XI),.OPT(OPT)
`define PORT(N) .clk(clk),.rst(rst),.i_req(i_req),.i_priv(i_priv),.i_addr(i_addr),.i_rdata(ir[N]),.i_half(ih[N]),.i_half_hi(i_half_hi),.i_ok(io[N]),.i_abort(iab[N]),.d_req(d_req),.d_we(d_we),.d_priv(d_priv),.d_be(d_be),.d_addr(d_addr),.d_wdata(d_wdata),.d_kill(d_kill),.cp_req(cp_req),.cp_we(cp_we),.cp_op(cp_op),.cp_wdata(cp_wdata),.d_rdata_f(dr[N]),.d_ok(dok[N]),.d_abort(dab[N]),.d_wait(dw[N]),.hivecs(hv[N]),.b_n8(bn[N]),.b_wnext(b_wnext),.dg_fill(dg[N]),.b_req(br[N]),.b_we(bwe[N]),.b_addr(ba[N]),.b_wdata(bw[N]),.b_be(bbe[N]),.b_tmr(bt[N]),.b_ack(b_ack),.b_rdata(b_rdata)
arm9_mem_before #(`PARAM)old_dut(`PORT(0));
arm9_mem_after #(`PARAM)new_dut(`PORT(1));
logic[31:0]memory[0:1048575];
integer cycles=0,phase=0,seed=1,rounds=256,overlap_iw_ds=0,kill_count=0,tcms=0;
integer omit_known_i_setway=0;
logic[31:0]rng=1;logic bg=0;logic[31:0]bg_addr=32'h02018000;
function automatic[31:0]next_rng(input[31:0]v);logic[31:0]x;begin x=v^(v<<13);x=x^(x>>17);next_rng=x^(x<<5);end endfunction
task automatic compare;
 if(!rst)begin
  if({io[0],iab[0],dok[0],dab[0],dw[0],hv[0],br[0],dg[0]}!=={io[1],iab[1],dok[1],dab[1],dw[1],hv[1],br[1],dg[1]})
   $fatal(1,"CONTROL_MISMATCH phase=%0d cycle=%0d addr=%h st=%0d/%0d dok=%b/%b iok=%b/%b",phase,cycles,d_addr,old_dut.st,new_dut.st,dok[0],dok[1],io[0],io[1]);
  if(old_dut.st!==new_dut.st||old_dut.dp_v!==new_dut.dp_v||old_dut.ip_v!==new_dut.ip_v)$fatal(1,"STATE_PENDING_MISMATCH");
  if(br[0]&&({ba[0],bwe[0],bn[0],bbe[0],bt[0]}!=={ba[1],bwe[1],bn[1],bbe[1],bt[1]}))$fatal(1,"BUS_MISMATCH");
  if(br[0]&&bwe[0]&&bw[0]!==bw[1])$fatal(1,"BUS_WRITE_DATA_MISMATCH");
  if(old_dut.f_req&&io[0]&&!iab[0]&&(ir[0]!==ir[1]||ih[0]!==ih[1]))$fatal(1,"FETCH_DATA_MISMATCH");
  if((old_dut.wq_e||old_dut.wcp_e)&&dok[0]&&!dab[0]&&dr[0]!==dr[1])$fatal(1,"DATA_REPLY_MISMATCH");
 end
endtask
task automatic tick;
 clk=0;#4;
 if(bg)begin i_req=1;i_addr=bg_addr;end
 i_half_hi=cycles[0];
 compare();
 b_ack=br[0]&&((cycles+seed)%4==0);b_rdata=memory[ba[0][21:2]];
 if(b_ack&&bwe[0])for(int b=0;b<4;b++)if(bbe[0][b])memory[ba[0][21:2]][b*8+:8]=bw[0][b*8+:8];
 if(!rst&&old_dut.st==11&&old_dut.wd_store_cache)overlap_iw_ds++;
 #1;clk=1;#1;cycles++;
 compare();
 if(cycles>150000)$fatal(1,"FIXTURE_TIMEOUT phase=%0d st=%0d cp=%h req=%b wcp=%b done=%b op=%h val=%h dok=%b dp=%b kind=%d busy=%b",phase,old_dut.st,cp_op,cp_req,old_dut.wcp_e,old_dut.cmo_done,old_dut.cmo_op,old_dut.cmo_val,dok[0],old_dut.dp_v,old_dut.dp_kind,old_dut.busy_d);
endtask
task automatic idle(input integer n);repeat(n)tick();endtask
task automatic cpwrite(input integer crn,crm,opc,input[31:0]v);
 $display("CP_BEGIN cycle=%0d c%0d c%0d %0d v=%h",cycles,crn,crm,opc,v);
 cp_req=1;cp_we=1;cp_op=16'((crn<<7)|(crm<<3)|opc);cp_wdata=v;d_req=0;
 tick();while(!dok[0])tick();cp_req=0;tick();
 $display("CP_END cycle=%0d",cycles);
endtask
task automatic data_access(input bit write,input[31:0]address,value,input[3:0]be,input bit full_wait);
 d_req=1;d_we=write;d_addr=address;d_wdata=value;d_be=be;cp_req=0;
 tick();while(!dok[0])tick();
 if(full_wait&&!write)while(old_dut.st!=0||old_dut.col_d)tick();
 d_req=0;tick();
endtask
task automatic fetch(input[31:0]address,input bit full_wait);
 bg=0;i_req=1;i_addr=address;
 tick();while(!io[0])tick();
 if(full_wait)while(old_dut.st!=0||old_dut.col_i)tick();
 i_req=0;tick();
endtask
initial begin
 if($value$plusargs("seed=%d",seed))begin end
 if($value$plusargs("rounds=%d",rounds))begin end
 if($value$plusargs("omit_known_i_setway=%d",omit_known_i_setway))begin end
 rng=32'(seed);
 for(int p=0;p<1048576;p++)memory[p]=(32'(p)*32'h9e3779b9)^32'hdeadbeef;
 idle(4);rst=0;idle(3);
 // Real CP15 setup: region0=4MiB main, cacheable/writeback, I+Dcache enabled.
 cpwrite(6,0,0,32'h0200002b);cpwrite(2,0,0,1);cpwrite(3,0,0,1);cpwrite(1,0,0,32'h0000107d);idle(3);
 phase=1;
 data_access(0,32'h02000000,0,15,1);
 data_access(0,32'h02002000,0,15,1);
 data_access(0,32'h02004000,0,15,1);
 data_access(0,32'h02002000,0,15,1); // retained way1 after actual way0/RR commit
 phase=2;
 data_access(1,32'h02002000,32'h11223344,15,0);
 data_access(1,32'h02002004,32'habcd9876,5,0);
 data_access(0,32'h02006000,0,15,1); // dirty eviction into real EVB
 data_access(0,32'h02000020,0,15,1);
 data_access(0,32'h02008000,0,15,0); // early restart
 data_access(0,32'h02000020,0,15,0); // read hit under in-flight fill
 idle(100);
 fetch(32'h02010000,1);fetch(32'h02410000,1);fetch(32'h02010000,1);
 // I tag commit concurrent with a D-cache store to another set.
 bg=0;i_req=1;i_addr=32'h02018000;
 while(!(old_dut.st==10&&old_dut.k==7))tick();
 d_req=1;d_we=1;d_addr=32'h02000020;d_wdata=32'hf00d1234;d_be=15;
 while(old_dut.st!=11)tick();tick();d_req=0;i_req=0;idle(10);
 phase=3;
 // Outside-prefix MVA must not acquire a low-tag alias; set/way sweeps retain dates.
 cpwrite(7,6,1,32'h03002000);data_access(0,32'h02002000,0,15,1);
 cpwrite(7,5,1,32'h03010000);fetch(32'h02010000,1);
 cpwrite(7,10,1,32'h02002000);cpwrite(7,14,1,32'h02000020);
 cpwrite(7,6,2,32'h40000000);
 if(!omit_known_i_setway)cpwrite(7,5,2,32'h80000000);
 else $display("SCOPE_OMISSION parent_I_setway_XI1_nontermination retained separately");
 cpwrite(7,6,0,0);cpwrite(7,5,0,0);
 if(!omit_known_i_setway)begin
  // A valid way0 at each physical alias must be cleared by one CP operation.
  fetch(32'h02030000,1);
  if(XI==1)fetch(32'h02031000,1);
  for(int al=0;al<(1<<XI);al++)begin
   i_addr=32'h02030000+(32'(al)<<12);idle(3);
   if(!old_dut.it_bq[old_dut.ITW]||!new_dut.it_bq[new_dut.ITW])$fatal(1,"ALIAS_NOT_PRIMED alias=%0d",al);
  end
  cpwrite(7,5,2,0);
  for(int al=0;al<(1<<XI);al++)begin
   i_addr=32'h02030000+(32'(al)<<12);idle(3);
   if(old_dut.it_bq[old_dut.ITW]||new_dut.it_bq[new_dut.ITW])$fatal(1,"ALIAS_NOT_INVALIDATED alias=%0d",al);
  end
  $display("I_SETWAY_ALL_ALIASES_INVALIDATED XI=%0d count=%0d",XI,1<<XI);
 end
 phase=4;bg=1;bg_addr=32'h02024000;
 for(int n=0;n<rounds;n++)begin
  rng=next_rng(rng);
  if(n%17==0)begin bg_addr=32'h02020000+{17'd0,rng[9:3],8'd0};end
  if(n%41==0)begin
   cpwrite(7,6,2,{rng[1:0],30'd0});
  end else if(n%47==0)begin
   cpwrite(7,5,1,32'h03000000|{8'd0,rng[20:0],3'd0});
  end else if(n%19==0)begin
   // Squashed requests must not mutate rows or queue a miss.
   d_req=1;d_we=rng[0];d_addr=32'h02000000|{10'd0,rng[18:0],3'd0};d_wdata=rng;d_kill=1;tick();tick();d_req=0;tick();d_kill=0;kill_count++;
  end else data_access(rng[0],32'h02000000|{10'd0,rng[18:0],3'd0},rng,rng[7:4]|4'b1,0);
  if(n%13==0)idle(10);
 end
 bg=0;i_req=0;d_req=0;idle(120);
 phase=5;
 cpwrite(9,1,0,32'h027c000a);cpwrite(9,1,1,32'h0000000c);cpwrite(1,0,0,32'h0005107d);
 data_access(1,32'h027c0020,32'h76543210,15,0);data_access(0,32'h027c0020,0,15,0);tcms++;
 bg=1;bg_addr=32'h00000020;data_access(1,32'h00000020,32'h89abcdef,15,0);idle(5);bg=0;i_req=0;fetch(32'h00000020,0);tcms++;
 cpwrite(1,0,0,32'h0000107d);cpwrite(7,10,4,0);idle(120);
 $display("NONCONTINUATION_PASS XI=%0d OPT=%0d seed=%0d cycles=%0d",XI,OPT,seed,cycles);$finish;
end
endmodule
