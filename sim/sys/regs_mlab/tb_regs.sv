`timescale 1ns/1ps
module tb_regs;
 logic clk=0,we=0;logic[4:0]wa=0,ra=0;logic[7:0]be=0;logic[31:0]wd=0;
 wire[63:0]a,b;logic[63:0]model[0:31],saved[0:31];bit[7:0]valid[0:31];
 integer cycles=0,writes=0,collisions=0,bytechecks=0,imports=0;logic[63:0]expected;bit[7:0]vm;
 sys_ram64be #(.AW(5)) old(.clk,.we,.be,.waddr(wa),.wdata({wd,wd}),.raddr(ra),.rdata(a));
 sys_regs_mlab dut(.clk,.we,.wa,.ra,.be,.wd,.q(b));
 task automatic step;
  begin
   expected=model[ra];vm=valid[ra];#2;clk=1;#1;
   for(integer j=0;j<8;j++)if(vm[j])begin
    assert(a[j*8+:8]===expected[j*8+:8]&&b[j*8+:8]===expected[j*8+:8])else $fatal(1,"REG_OLD_DATA cycle%0d wa%0d ra%0d byte%0d be%h old%h new%h expected%h",cycles,wa,ra,j,be,a,b,expected);bytechecks++;
   end
   if(we)begin
    writes++;if(wa==ra)collisions++;
    for(integer j=0;j<8;j++)if(be[j])begin model[wa][j*8+:8]=wd[(j%4)*8+:8];valid[wa][j]=1;end
   end
   clk=0;#1;cycles++;
  end
 endtask
 integer i,j;logic[31:0]rng=32'h68ac23fd;
 initial begin
  // Establish allbytes through legal duplicated32 low/high writes; no
  // before-RAM initialization is invented for unwritten/X-valued cells.
  for(i=0;i<32;i++)begin
   wa=5'(i);ra=wa;we=1;be=8'h0f;wd=32'h12760000+32'(i);step();
   be=8'hf0;wd=32'habef0000+32'(i);step();
  end
  for(i=0;i<32;i++)for(j=0;j<256;j++)begin
   we=1;wa=5'(i);ra=j[0]?wa:5'(i+1);be=8'(j);wd=32'h9a012300+32'(cycles);step();
  end
  for(i=0;i<4096;i++)begin
   rng=(rng>>1)^((0-(rng&1))&32'hd0000001);wa=rng[4:0];ra=i%3==0?wa:rng[9:5];we=rng[10];be=rng[23:16];wd=rng^32'hcd342187;step();
  end
  we=0;be=0;step();step();
  for(i=0;i<32;i++)saved[i]=old.mem[i];
  // Faithful before capture, poisoned physical target, complete64-bit
  // readback at the first ordinary read of everyrow, no post-restore tick.
`ifdef ALTERA_RESERVED_QIS
  for(i=0;i<32;i++)begin dut.g_byte[0].u_lane.u_ram.mem_data[i]=~saved[i][0+:8];dut.g_byte[0].u_lane.u_ram.mem_data[i]=saved[i][0+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[1].u_lane.u_ram.mem_data[i]=~saved[i][8+:8];dut.g_byte[1].u_lane.u_ram.mem_data[i]=saved[i][8+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[2].u_lane.u_ram.mem_data[i]=~saved[i][16+:8];dut.g_byte[2].u_lane.u_ram.mem_data[i]=saved[i][16+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[3].u_lane.u_ram.mem_data[i]=~saved[i][24+:8];dut.g_byte[3].u_lane.u_ram.mem_data[i]=saved[i][24+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[4].u_lane.u_ram.mem_data[i]=~saved[i][32+:8];dut.g_byte[4].u_lane.u_ram.mem_data[i]=saved[i][32+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[5].u_lane.u_ram.mem_data[i]=~saved[i][40+:8];dut.g_byte[5].u_lane.u_ram.mem_data[i]=saved[i][40+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[6].u_lane.u_ram.mem_data[i]=~saved[i][48+:8];dut.g_byte[6].u_lane.u_ram.mem_data[i]=saved[i][48+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[7].u_lane.u_ram.mem_data[i]=~saved[i][56+:8];dut.g_byte[7].u_lane.u_ram.mem_data[i]=saved[i][56+:8];end
`else
  for(i=0;i<32;i++)begin dut.g_byte[0].u_lane.mem[i]=~saved[i][0+:8];dut.g_byte[0].u_lane.mem[i]=saved[i][0+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[1].u_lane.mem[i]=~saved[i][8+:8];dut.g_byte[1].u_lane.mem[i]=saved[i][8+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[2].u_lane.mem[i]=~saved[i][16+:8];dut.g_byte[2].u_lane.mem[i]=saved[i][16+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[3].u_lane.mem[i]=~saved[i][24+:8];dut.g_byte[3].u_lane.mem[i]=saved[i][24+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[4].u_lane.mem[i]=~saved[i][32+:8];dut.g_byte[4].u_lane.mem[i]=saved[i][32+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[5].u_lane.mem[i]=~saved[i][40+:8];dut.g_byte[5].u_lane.mem[i]=saved[i][40+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[6].u_lane.mem[i]=~saved[i][48+:8];dut.g_byte[6].u_lane.mem[i]=saved[i][48+:8];end
  for(i=0;i<32;i++)begin dut.g_byte[7].u_lane.mem[i]=~saved[i][56+:8];dut.g_byte[7].u_lane.mem[i]=saved[i][56+:8];end
`endif
  imports++;
  for(i=0;i<32;i++)begin ra=5'(i);step();end
  assert(writes>8000&&collisions>4000&&imports==1);
  $display("PASS_REGS cycles%0d writes%0d collisions%0d bytechecks%0d imports%0d",cycles,writes,collisions,bytechecks,imports);$finish;
 end
endmodule
