`timescale 1ps/1ps
module tb_wram;
  reg clk=0,clk2=0,rst=1;
  initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
  initial begin #14919;forever begin clk2=1;#3730;clk2=0;#3730;clk2=1;#3730;clk2=0;#3729;end end
  reg a_req=0,a_we=0,b_req=0,b_we=0;
  reg[17:2] a_addr=0,b_addr=0;
  reg[3:0]a_be=0,b_be=0;
  reg[31:0]a_wdata=0,b_wdata=0;
  wire ao,bo,an,bn;
  wire[31:0]aqo,bqo,aqn,bqn;
  arm7_wram dut(.clk,.clk2,.rst,.a_req,.a_we,.a_addr,.a_be,.a_wdata,.a_ok(an),.a_rdata(aqn),
    .b_req,.b_we,.b_addr,.b_be,.b_wdata,.b_done(bn),.b_rdata(bqn));
  arm7_wram_before old(.clk,.rst,.a_req,.a_we,.a_addr,.a_be,.a_wdata,.a_ok(ao),.a_rdata(aqo),
    .b_req,.b_we,.b_addr,.b_be,.b_wdata,.b_done(bo),.b_rdata(bqo));
  reg[31:0] private_gold[0:16383],shared_gold[0:8191];
  reg[31:0] seed=32'h317ab91d;
  integer n,k,x,y,ba,bb,cycles=0,reads=0,writes=0,collisions=0,late_resets=0,shared_cells=0;
  reg late_reset=0,late_inputs=0;
  function[31:0]random32;
    begin seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);random32=seed;end
  endfunction
  function[31:0]mask32(input[3:0]be);
    mask32={{8{be[3]}},{8{be[2]}},{8{be[1]}},{8{be[0]}}};
  endfunction
  function[31:0]gold(input[17:2]address);
    gold=address[16]?shared_gold[address[14:2]]:private_gold[address[15:2]];
  endfunction
  task put(input[17:2]address,input[31:0]value);
    if(address[16])shared_gold[address[14:2]]=value;else private_gold[address[15:2]]=value;
  endtask
  task cycle;
    reg at,bt,save_reset,aw,bw;
    reg[31:0]ea,eb,am,bm;
    begin
      @(posedge clk);
      bt=b_req&&!bo&&!rst;
      at=a_req&&!(bt&&a_req&&a_addr==b_addr&&(a_we||b_we))&&!rst;
      aw=a_we;bw=b_we;
      am=at&&a_we?mask32(a_be):0;bm=bt&&b_we?mask32(b_be):0;
      ea=(gold(a_addr)&~am)|(a_wdata&am);
      eb=(gold(b_addr)&~bm)|(b_wdata&bm);
      if(|am)begin put(a_addr,ea);writes=writes+1;end
      if(|bm)begin put(b_addr,eb);writes=writes+1;end
      if(bt&&a_req&&!at&&!rst)collisions=collisions+1;
      if(at&&bt&&a_we&&b_we&&!a_addr[16]&&!b_addr[16]&&a_addr!=b_addr&&a_addr/5==b_addr/5)
        shared_cells=shared_cells+1;
      #1;
      if({ao,bo,an,bn}!=={at,bt,at,bt})$fatal(1,"ACK mismatch cycle%0d",cycles);
      check_data(at,bt,aw,bw,ea,eb,am,bm);
      save_reset=rst;
      if(late_inputs)begin
        #2;a_req=0;b_req=0;a_we=0;b_we=0;a_be=0;b_be=0;
        a_addr=16'(random32());b_addr=16'(random32());
        a_wdata=~a_wdata;b_wdata=~b_wdata;
      end
      if(late_reset)begin #1000;rst=1;late_resets=late_resets+1;end
      @(posedge clk2);#1;
      check_data(at,bt,aw,bw,ea,eb,am,bm);
      @(negedge clk2);#1;
      check_data(at,bt,aw,bw,ea,eb,am,bm);
      rst=save_reset;cycles=cycles+1;
    end
  endtask
  task check_data(input at,bt,aw,bw,input[31:0]ea,eb,am,bm);
    begin
      if(at&&!aw)begin
        if(aqo!==ea||aqn!==ea)$fatal(1,"A read/publication mismatch cycle%0d addr%04x old%08x new%08x want%08x",cycles,a_addr,aqo,aqn,ea);
        reads=reads+1;
      end
      if(bt&&!bw)begin
        if(bqo!==eb||bqn!==eb)$fatal(1,"B read/publication mismatch cycle%0d addr%04x old%08x new%08x want%08x",cycles,b_addr,bqo,bqn,eb);
        reads=reads+1;
      end
      // The original vendor primitive leaves unwritten byte outputs
      // undefined on a partial write; compare only its defined bytes.
      if(at&&aw&&((aqo&am)!==(ea&am)||(aqn&am)!==(ea&am)))$fatal(1,"A own NEW_DATA mismatch");
      if(bt&&bw&&((bqo&bm)!==(eb&bm)||(bqn&bm)!==(eb&bm)))$fatal(1,"B own NEW_DATA mismatch");
    end
  endtask
  initial begin
    for(k=0;k<16384;k=k+1)private_gold[k]=0;
    for(k=0;k<8192;k=k+1)shared_gold[k]=0;
    cycle();cycle();rst=0;
    if($test$plusargs("late-only"))begin
      for(n=0;n<512;n=n+1)begin
        // Every byte mask and both halves of shared-cell ownership.
        a_req=0;b_req=0;cycle();
        a_req=1;b_req=1;a_we=1;b_we=1;
        a_addr=16'(5*(n*3)+(n%4));b_addr=16'(5*(n*3)+4);
        a_be=4'(n);b_be=4'(n>>4);a_wdata=random32();b_wdata=random32();
        late_inputs=1;late_reset=n[0];cycle();late_inputs=0;late_reset=0;
        a_req=0;b_req=0;cycle(); // rearm B after its accepted write
        a_req=1;b_req=1;a_we=0;b_we=0;
        a_addr=16'(5*(n*3)+(n%4));b_addr=16'(5*(n*3)+4);
        late_inputs=1;cycle();late_inputs=0;
      end
      $display("PASS_WRAM_LATE cycles%0d readSamples%0d writes%0d sharedCellPairs%0d lateResets%0d acceptedmetadata survives E+3ps retag/reset before M",cycles,reads,writes,shared_cells,late_resets);
      $finish;
    end
    // Full capacity, including the incomplete final5-word group.
    for(n=0;n<16384;n=n+1)begin
      a_req=1;a_we=1;a_be=15;a_addr=16'(n);a_wdata=random32();
      b_req=1;b_we=0;b_addr=16'(16383-n);cycle();
    end
    for(n=0;n<16384;n=n+1)begin
      a_req=1;a_we=0;a_addr=16'(n);b_req=1;b_we=0;b_addr=16'(16383-n);cycle();
    end
    // All slot/byte-mask pairs, including disjoint words sharing a cell.
    for(x=0;x<5;x=x+1)for(y=0;y<5;y=y+1)
      for(ba=0;ba<16;ba=ba+1)for(bb=0;bb<16;bb=bb+1)begin
        b_req=0;a_req=0;cycle();
        a_addr=16'(5*((ba*197+bb*53+x*31+y)%3276)+x);
        b_addr=16'(5*((ba*197+bb*53+x*31+y)%3276)+y);
        a_req=1;b_req=1;a_we=1;b_we=1;a_be=4'(ba);b_be=4'(bb);
        a_wdata=random32();b_wdata=random32();late_reset=(cycles%97==0);cycle();late_reset=0;
      end
    // Shared storage stays on the original primitive, concurrent with
    // private traffic. Also exercise B held-request suppression and reset.
    for(n=0;n<8192;n=n+1)begin
      a_req=1;a_we=1;a_be=4'(n);a_addr=16'h4000|16'(n);a_wdata=random32();
      b_req=1;b_we=1;b_be=4'(n>>4);b_addr=16'(random32());b_addr[17:16]=0;
      b_wdata=random32();rst=(n%89==0);late_reset=(n%67==0);cycle();rst=0;late_reset=0;
    end
    for(n=0;n<16384;n=n+1)begin
      a_req=1;a_we=0;a_addr=16'(n);b_req=1;b_we=0;
      b_addr=16'h4000|16'(n&8191);cycle();
    end
    // Same-word read/write conflict is B-wins CPU retry, not an added
    // conflict for all different words that happen to share native cells.
    for(n=0;n<128;n=n+1)begin
      a_req=1;b_req=1;a_we=n[0];b_we=!n[0];a_be=15;b_be=15;
      a_addr=16'(n);b_addr=16'(n);a_wdata=random32();b_wdata=random32();cycle();
    end
    $display("PASS_WRAM_NATIVE cycles%0d readSamples%0d writes%0d logicalConflicts%0d sharedCellPairs%0d lateResets%0d full64KiB+32KiB E/M/late publication",cycles,reads,writes,collisions,shared_cells,late_resets);
    $finish;
  end
  initial begin #2000000000;$fatal(1,"timeout");end
endmodule
