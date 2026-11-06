`timescale 1ns/1ps
module tb_audio_interp_equiv;
    reg clk=0;
    always #5 clk=~clk;
    reg in_valid=0;
    reg signed [15:0] in_l=0,in_r=0;
    wire signed [15:0] old_l,old_r,new_l,new_r;
    nds_audio_interp_before gold(.clk,.in_valid,.in_l,.in_r,.out_l(old_l),.out_r(old_r));
    nds_audio_interp dut(.clk,.in_valid,.in_l,.in_r,.out_l(new_l),.out_r(new_r));
    int cycles=0, negative_steps=0, saturated=0, sample_edges=0, invariant_faults=0;
    bit mutant;
    initial mutant=$test$plusargs("expect_mutant");
    always @(negedge clk) begin : compare_every_cycle
        longint signed expected_l,expected_r;
        cycles++;
        expected_l=$signed(gold.p_l)*64'sd2048+$signed(gold.d_l)*$signed({1'b0,gold.ph});
        expected_r=$signed(gold.p_r)*64'sd2048+$signed(gold.d_r)*$signed({1'b0,gold.ph});
        if ({new_l,new_r} !== {old_l,old_r})
            $fatal(1,"AUDIO_EQ_OUTPUT cycle%0d phase%0d old%0d/%0d new%0d/%0d",cycles,gold.ph,old_l,old_r,new_l,new_r);
        if(dut.acc_l !== expected_l[26:0] || dut.acc_r !== expected_r[26:0] ||
           dut.delta_l !== gold.d_l || dut.delta_r !== gold.d_r ||
           dut.ph !== gold.ph || dut.c_l !== gold.c_l || dut.c_r !== gold.c_r || dut.v_d !== gold.v_d) begin
            invariant_faults++;
            // In the fault run, require an actual OUTPUT witness too.
            if(!mutant)$fatal(1,"AUDIO_EQ_INVARIANT cycle%0d",cycles);
        end
        if(gold.ph>0 && gold.ph<2048 && (gold.d_l<0 || gold.d_r<0))negative_steps++;
        if(gold.ph==2048)saturated++;
    end
    task automatic step(input bit valid,input logic[15:0] left,right);
        @(negedge clk);
        in_valid=valid;in_l=left;in_r=right;
        @(posedge clk);#1;
    endtask
    task automatic sample(input logic[15:0] left,right,input int high_cycles);
        step(0,left,right);
        step(1,left,right);sample_edges++;
        for(int k=1;k<high_cycles;k++)step(1,left^16'(k*137),right^16'(k*313));
        step(0,left,right);
    endtask
    reg signed[15:0] endpoints[0:6];
    int gaps[0:10];
    int seed=32'h42513719;
    initial begin
        endpoints[0]=-32768;endpoints[1]=-32767;endpoints[2]=-1;
        endpoints[3]=0;endpoints[4]=1;endpoints[5]=32766;endpoints[6]=32767;
        gaps[0]=0;gaps[1]=1;gaps[2]=2;gaps[3]=17;gaps[4]=1023;
        gaps[5]=1024;gaps[6]=2046;gaps[7]=2047;gaps[8]=2048;gaps[9]=2049;gaps[10]=4096;
        repeat(4100)step(0,0,0);
        for(int a=0;a<7;a++)for(int b=0;b<7;b++)begin
            sample(endpoints[a],endpoints[6-a],1+(a%3));
            repeat(2050)step(0,0,0);
            sample(endpoints[b],endpoints[6-b],1+(b%5));
            repeat(2050)step(0,0,0);
        end
        for(int g=0;g<11;g++)for(int k=0;k<4;k++)begin
            sample(k[0]?16'h8000:16'h7fff,k[1]?16'hffff:16'h0001,1+g);
            repeat(gaps[g])step(0,0,0);
        end
        for(int k=0;k<80;k++)begin
            sample(16'($urandom(seed)),16'($urandom(seed)),1+($urandom(seed)%17));
            repeat($urandom(seed)%4100)step(0,16'($urandom(seed)),16'($urandom(seed)));
        end
        repeat(8192)step(0,16'h1234,16'habcd);
        @(negedge clk);#1;
        if(negative_steps<10000 || saturated<1000 || sample_edges<200 || invariant_faults!=0)
            $fatal(1,"AUDIO_EQ_COVERAGE cycles%0d neg%0d hold%0d samples%0d inv%0d",cycles,negative_steps,saturated,sample_edges,invariant_faults);
        $display("PASS AUDIO_EQ cycles%0d negative%0d saturated%0d sampleedges%0d",cycles,negative_steps,saturated,sample_edges);
        $finish;
    end
endmodule
