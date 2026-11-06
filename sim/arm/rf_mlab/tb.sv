`timescale 1ns/1ps
module tb;
  logic clk=0, ce=0, we=0, we2=0;
  logic [5:0] wa=0,wa2=0,ra0=0,ra1=0,ra2=0;
  logic [31:0] wd=0,wd2=0;
  wire [31:0] rd0,rd1,rd2,old0,old1,old2;
  arm_regfile #(.DUAL_WRITE(1)) dut(.*);
  arm_regfile_before #(.DUAL_WRITE(1)) prior(
    .clk,.ce,.we,.we2,.wa,.wa2,.wd,.wd2,.ra0,.ra1,.ra2,
    .rd0(old0),.rd1(old1),.rd2(old2));
  logic [31:0] model[0:63];
  logic [31:0] expected0=0,expected1=0,expected2=0;
  logic [31:0] random_state=32'h9af4b17d;
  integer cycles=0,holds=0,dual=0,collisions=0,read_collisions=0,imports=0,fd;
  string tracefile;
  function automatic logic[31:0] random_word();
    random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;
    return random_state;
  endfunction
  task automatic tick();
    #4;
    if(ce)begin
      expected0=model[ra0];expected1=model[ra1];expected2=model[ra2];
      if(we2)model[wa2]=wd2;
      if(we)model[wa]=wd;
      if(we&&we2)dual++;
      if(we&&we2&&wa==wa2)collisions++;
      if((we&&(ra0==wa||ra1==wa||ra2==wa))||
         (we2&&(ra0==wa2||ra1==wa2||ra2==wa2)))read_collisions++;
    end else holds++;
    clk=1;#1;cycles++;
    assert(rd0===expected0&&rd1===expected1&&rd2===expected2)
      else $fatal(1,"RF_READ_OR_OLD_DATA cycle%0d actual%h/%h/%h expected%h/%h/%h",cycles,rd0,rd1,rd2,expected0,expected1,expected2);
    assert(rd0===old0&&rd1===old1&&rd2===old2)else $fatal(1,"RF_PRIOR_READ_EQUIVALENCE");
    for(int i=0;i<64;i++)begin
      assert(dut.g_dual.regs[i]===model[i])else $fatal(1,"RF_LOGICAL_OWNER_OR_PRIORITY cycle%0d address%0d",cycles,i);
      assert(dut.g_dual.regs[i]===prior.g_dual.regs[i])else $fatal(1,"RF_PRIOR_STATE_EQUIVALENCE");
    end
    if(fd)$fwrite(fd,"%0d,%b,%b,%02h,%08h,%b,%02h,%08h,%02h,%02h,%02h,%08h,%08h,%08h\n",cycles,ce,we,wa,wd,we2,wa2,wd2,ra0,ra1,ra2,rd0,rd1,rd2);
    #5;clk=0;
  endtask
  initial begin
    if($value$plusargs("trace=%s",tracefile))fd=$fopen(tracefile,"w");
    for(int i=0;i<64;i++)model[i]=0;
    // Actual clocked writes establish every address through both owners.
    ce=1;we=1;we2=1;
    for(int i=0;i<64;i++)begin
      wa=6'(i);wa2=6'(i+1);wd=random_word();wd2=random_word();
      ra0=wa;ra1=wa2;ra2=6'(i+31);tick();
    end
    for(int n=0;n<40000;n++)begin
      ce=(random_word()&7)!=0;we=(random_word()&3)!=0;we2=(random_word()&3)!=0;
      wa=6'(random_word());wa2=(n%4==0)?wa:6'(random_word());
      wd=random_word();wd2=random_word();
      ra0=(n%3==0)?wa:6'(random_word());
      ra1=(n%3==1)?wa2:6'(random_word());
      ra2=(n%8==0)?wa:6'(random_word());tick();
    end
    // Checkpoint ABI scope only: clock stopped, all replicas seeded through
    // the task. Architectural CPU executions in the broad gate use no seeds.
    ce=0;we=0;we2=0;
    for(int i=0;i<64;i++)begin
      wd=random_word();dut.g_dual.import_phys(6'(i),wd);
      prior.g_dual.regs[i]=wd;model[i]=wd;imports++;
    end
    ce=1;
    for(int i=0;i<64;i++)begin ra0=6'(i);ra1=6'(i+1);ra2=6'(i+2);tick();end
    assert(holds>4000&&dual>10000&&collisions>4000&&read_collisions>10000&&imports==64)
      else $fatal(1,"RF_COVERAGE");
    $display("RF_EQUIVALENCE_PASS cycles%0d holds%0d dual%0d priority%0d oldread%0d imports%0d",cycles,holds,dual,collisions,read_collisions,imports);
    if(fd)$fclose(fd);$finish;
  end
endmodule
