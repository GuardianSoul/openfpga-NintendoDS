`timescale 1ns/1ps
module tag_case #(parameter integer AW=5, W=24)(input logic clk, output logic done);
  localparam integer L=5, N=1<<AW, B=L*W;
  logic [AW-1:0] aa=0, ba=0;
  logic [L-1:0] we=0;
  logic [B-1:0] data=0;
  wire [B-1:0] olda,oldb,newa,newb;
  logic [B-1:0] model [0:N-1];
  logic [31:0] rng=32'h3e701acb+AW;
  integer cycles=0, reads=0;
  arm9_ram #(.AW(AW),.LANES(L),.LANE_W(W),.FOLD(1)) dut
    (.clk,.a_addr(aa),.a_we(we),.a_d(data),.a_q(newa),.b_addr(ba),.b_q(newb));
  arm9_ram_ref #(.AW(AW),.LANES(L),.LANE_W(W),.FOLD(1)) refdut
    (.clk,.a_addr(aa),.a_we(we),.a_d(data),.a_q(olda),.b_addr(ba),.b_q(oldb));
  task automatic next_random;
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
  endtask
  task automatic step(input integer a,b,m,input logic [B-1:0] d);
    logic [B-1:0] ea,eb,merged;
    logic carea,careb;
    begin
      @(negedge clk);aa=AW'(a);ba=AW'(b);we=L'(m);data=d;
      ea=model[a];eb=model[b];merged=ea;
      for(integer l=0;l<L;l=l+1) if(we[l]) merged[l*W+:W]=data[l*W+:W];
      // FOLD's physical counter is exactly its low8 bits, upper bits zero.
      merged[(L-1)*W+8+:W-8]='0;
      ea=merged;
      @(posedge clk);#1;
      for(integer l=0;l<L;l=l+1) begin
        carea=!((l==0 && we[L-1] && !we[0]) || (l==L-1 && we[0] && !we[L-1]));
        careb=!(a==b && (we[l] || ((l==0 || l==L-1) && (we[0] || we[L-1]))));
        if(carea) begin
          if(olda[l*W+:W]!==ea[l*W+:W]) $fatal(1,"REFERENCE_A AW%0d cycle%0d lane%0d",AW,cycles,l);
          if(newa[l*W+:W]!==ea[l*W+:W]) $fatal(1,"CANDIDATE_A AW%0d cycle%0d lane%0d expected%h got%h",AW,cycles,l,ea[l*W+:W],newa[l*W+:W]);
          reads=reads+1;
        end
        if(careb) begin
          if(oldb[l*W+:W]!==eb[l*W+:W]) $fatal(1,"REFERENCE_B AW%0d cycle%0d lane%0d",AW,cycles,l);
          if(newb[l*W+:W]!==eb[l*W+:W]) $fatal(1,"CANDIDATE_B AW%0d cycle%0d lane%0d expected%h got%h",AW,cycles,l,eb[l*W+:W],newb[l*W+:W]);
          reads=reads+1;
        end
      end
      if(|we)model[a]=merged;
      cycles=cycles+1;
    end
  endtask
  logic [B-1:0] d;
  initial begin
    done=0;for(integer a=0;a<N;a=a+1)model[a]='0;
    // Power-up and every bit at every address, including the folded counter.
    for(integer a=0;a<N;a=a+1) step(a,(a+1)%N,0,'0);
    for(integer a=0;a<N;a=a+1) for(integer l=0;l<L;l=l+1)
      for(integer bitno=0;bitno<(l==L-1?8:W);bitno=bitno+1) begin
        d='0;d[l*W+bitno]=1;step(a,(a+1)%N,1<<l,d);step((a+1)%N,a,0,'0);
      end
    $display("WALK_DONE AW=%0d cycles=%0d",AW,cycles);
    // Every independent write mask at every address, both with and without
    // a B collision; every address pair below is also checked separately.
    for(integer a=0;a<N;a=a+1)for(integer bmatch=0;bmatch<2;bmatch=bmatch+1)for(integer m=0;m<32;m=m+1)begin
      for(integer l=0;l<L;l=l+1)begin next_random();d[l*W+:W]=W'(rng);end
      d[(L-1)*W+8+:W-8]='0;step(a,bmatch?a:(a+1)%N,m,d);
    end
    for(integer a=0;a<N;a=a+1)for(integer b=0;b<N;b=b+1)begin
      for(integer l=0;l<L;l=l+1)begin next_random();d[l*W+:W]=W'(rng);end
      d[(L-1)*W+8+:W-8]='0;step(a,b,(a+b)%32,d);
    end
    // Adversarial back-to-back owners, masks, aliases and high-bit changes.
    for(integer i=0;i<8192;i=i+1)begin
      integer a,b,m;
      next_random();a=int'(rng&(N-1));next_random();b=int'(rng&(N-1));next_random();m=int'(rng&31);
      for(integer l=0;l<L;l=l+1)begin next_random();d[l*W+:W]=W'(rng);end
      d[(L-1)*W+8+:W-8]='0;step(a,b,m,d);
    end
    $display("PASS_TAG AW=%0d W=%0d cycles=%0d defined_lane_reads=%0d",AW,W,cycles,reads);done=1;
  end
endmodule
module tb;
  logic clk=0;
  always #5 clk=~clk;
  wire d0,d1;
  tag_case #(.AW(5),.W(24)) dc(clk,d0);
  tag_case #(.AW(6),.W(22)) ic(clk,d1);
  initial begin wait(d0&&d1);$display("PASS_BOTH_TAGS");$finish;end
  initial begin #5000000;$fatal(1,"TIMEOUT");end
endmodule
