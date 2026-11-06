`timescale 1ns/1ps
module pack75_cache_case(input logic clk,output logic done);
    logic rst=1,cancel=0,f_req=0,l_req=0,f_bank=0,l_bank=0,inv_valid=0,inv_bank=0;
    logic [12:0] f_id=0,l_id=0,inv_id=0;
    logic [14:0] f_gen=0,l_gen=0;
    wire fh[3],lt[3],lv[3],lh[3],req[3];
    wire [127:0] fd[3],ld[3];
    wire [22:2] addr[3];
    logic mutate;
    logic ack,valid,complete,on=0,finishing=0;
    logic [31:0] data,rng=32'h75cace01;
    logic [22:2] held;
    integer delay_n=0,word_n=0,drain_n=0;
    integer cycles=0,requests=0,words=0,hits=0,collisions=0,cancels=0,owned_resets=0;
    logic [3:0] ways_seen=0;
    longint digest=64'hcbf29ce484222325;
    pack75_before #(.SET_BITS(7),.ID_BITS(11),.VERTEX(0)) before_dut (
        .clk,.rst,.cancel,.f_req,.f_bank,.f_id,.f_gen,.f_hit(fh[0]),.f_data(fd[0]),
        .l_req,.l_bank,.l_id,.l_gen,.l_take(lt[0]),.l_valid(lv[0]),.l_hit(lh[0]),.l_data(ld[0]),
        .inv_valid,.inv_bank,.inv_id,.m_req(req[0]),.m_addr(addr[0]),.m_ack(ack),
        .m_valid(valid),.m_done(complete),.m_data(data));
    nds_g3d_pair_cache #(.SET_BITS(7),.ID_BITS(11),.VERTEX(0)) after_dut (
        .clk,.rst,.cancel,.f_req,.f_bank,.f_id,.f_gen,.f_hit(fh[1]),.f_data(fd[1]),
        .l_req,.l_bank,.l_id,.l_gen,.l_take(lt[1]),.l_valid(lv[1]),.l_hit(lh[1]),.l_data(ld[1]),
        .inv_valid,.inv_bank,.inv_id,.m_req(req[1]),.m_addr(addr[1]),.m_ack(ack),
        .m_valid(valid),.m_done(complete),.m_data(data));
    pack75_mutant #(.SET_BITS(7),.ID_BITS(11),.VERTEX(0)) mutant_dut (
        .clk,.rst(rst || !mutate),.cancel,.f_req,.f_bank,.f_id,.f_gen,.f_hit(fh[2]),.f_data(fd[2]),
        .l_req,.l_bank,.l_id,.l_gen,.l_take(lt[2]),.l_valid(lv[2]),.l_hit(lh[2]),.l_data(ld[2]),
        .inv_valid,.inv_bank,.inv_id,.m_req(req[2]),.m_addr(addr[2]),.m_ack(ack && mutate),
        .m_valid(valid && mutate),.m_done(complete && mutate),.m_data(data));
    function automatic [31:0] payload(input logic bank,input logic[12:0] id,input int beat);
        return {bank,3'd0,id,15'd0} ^ 32'h35827a19 ^ (32'(beat)*32'h1a5de037);
    endfunction
    function automatic [127:0] expected(input logic bank,input logic[12:0] id);
        logic [31:0] p2;
        p2=payload(bank,id,2);
        return {p2[31:19],7'd0,p2[11:0],payload(bank,id,3),payload(bank,id,1),payload(bank,id,0)};
    endfunction
    assign ack=req[0] && !on && !finishing && !rst && rng[2:0]!=0;
    assign valid=on && delay_n==0 && !rst && rng[5:3]!=0;
    assign complete=finishing && drain_n==0 && !rst;
    assign data=payload(held[20],held[16:4],word_n);
    always @(posedge clk) begin
        cycles<=cycles+1;rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(rst)begin on<=0;finishing<=0;delay_n<=0;word_n<=0;drain_n<=0;end
        else begin
            if(ack)begin on<=1;held<=addr[0];delay_n<=int'(rng[10:7]);word_n<=0;requests<=requests+1;end
            if(on && delay_n!=0)delay_n<=delay_n-1;
            if(valid)begin
                words<=words+1;
                if(word_n==3)begin on<=0;finishing<=1;drain_n<=int'(rng[13:11])+1;end
                else begin word_n<=word_n+1;delay_n<=int'(rng[17:15]);end
            end
            if(finishing && drain_n!=0)drain_n<=drain_n-1;
            if(complete)finishing<=0;
            if(cancel)cancels<=cancels+1;
            if({fh[0],lt[0],lv[0],lh[0],req[0],addr[0]} !==
               {fh[1],lt[1],lv[1],lh[1],req[1],addr[1]})$fatal(1,"PACK75_PUBLIC_CYCLE");
            if(fh[0])begin
                if(fd[0]!==fd[1])$fatal(1,"PACK75_PUBLIC_FETCH_DATA");
                hits<=hits+1;digest<=(digest^64'(fd[1])^64'(fd[1]>>64))*64'h100000001b3;
            end
            if(lv[0] && lh[0] && ld[0]!==ld[1])$fatal(1,"PACK75_PUBLIC_LOADER_DATA");
            if(after_dut.g_header_pack.u_data.we) begin
                ways_seen[after_dut.miss_way]<=1;
                if(after_dut.query && after_dut.query_row==after_dut.miss_row)collisions<=collisions+1;
            end
            if(mutate && ({fh[0],lt[0],lv[0],lh[0],req[0],addr[0]} !==
                          {fh[2],lt[2],lv[2],lh[2],req[2],addr[2]} ||
                         (fh[0] && fd[0]!==fd[2]) || (lv[0] && lh[0] && ld[0]!==ld[2])))
                $fatal(1,"PACK75_ACTUAL_WAY_MUTANT_CAUGHT public response differs");
        end
    end
    task automatic fetch(input logic bank,input logic[12:0] id,input logic[14:0] generation);
        integer timeout_n;
        @(negedge clk);f_req=1;f_bank=bank;f_id=id;f_gen=generation;l_req=0;
        timeout_n=0;
        do begin @(negedge clk);timeout_n++;
            if(timeout_n>2000)$fatal(1,"PACK75_FETCH_TIMEOUT id%0d",id);
        end while(!fh[1]);
        if(fd[1]!==expected(bank,id))$fatal(1,"PACK75_INDEPENDENT_HEADER id%0d got%h expected%h",id,fd[1],expected(bank,id));
        @(negedge clk);f_req=0;repeat(3)@(negedge clk);
    endtask
    initial begin
        integer seed;seed=75;void'($value$plusargs("seed=%d",seed));rng^=32'(seed);
        mutate=$test$plusargs("mutant");done=0;
        repeat(8)@(negedge clk);rst=0;repeat(132)@(negedge clk);
        // Every physical set and way is filled at full advertised capacity.
        for(int row=0;row<128;row++)for(int way=0;way<4;way++)fetch(0,13'(row+way*128),15'd1);
        for(int row=0;row<128;row++)for(int way=0;way<4;way++)fetch(0,13'(row+way*128),15'd1);
        // Keep a non-victim way hot while a fifth same-row record fills.
        // Its query overlaps the shared masked write without another port.
        fetch(0,13'd384,15'd1);
        @(negedge clk);f_req=1;f_id=13'd512;f_bank=0;f_gen=1;
        do @(negedge clk);while(!ack);
        f_id=13'd384;
        repeat(120)@(negedge clk);
        fetch(0,13'd512,15'd1);
        // Gen and bank reuse, cancellation during a real owned packet,
        // invalidation on a queued/query address, and joint reset in read.
        for(int j=0;j<64;j++)fetch(j[0],13'(j*17),15'(2+j/16));
        @(negedge clk);f_req=1;f_bank=1;f_id=13'd1999;f_gen=9;
        do @(negedge clk);while(!on);
        cancel=1;@(negedge clk);cancel=0;f_req=0;
        while(on || finishing)@(negedge clk);repeat(12)@(negedge clk);
        @(negedge clk);f_req=1;f_bank=1;f_id=13'd1998;f_gen=9;
        do @(negedge clk);while(!on);
        rst=1;owned_resets++;repeat(8)@(negedge clk);rst=0;f_req=0;
        repeat(132)@(negedge clk);
        for(int j=0;j<50000;j++)begin
            @(negedge clk);f_req=rng[0];l_req=rng[1];f_bank=rng[2];l_bank=rng[3];
            f_id=13'(((int'(rng[18:15])%8)<<7)|(int'(rng[10:7])%8));
            l_id=13'(((int'(rng[26:23])%8)<<7)|(int'(rng[14:11])%8));
            f_gen=15'(rng[4]);l_gen=15'(rng[5]);
            inv_valid=j%31==0;inv_bank=f_bank;inv_id=f_id;cancel=j%1024==0;
        end
        @(negedge clk);f_req=0;l_req=0;inv_valid=0;cancel=0;
        repeat(200)@(negedge clk);
        if(ways_seen!=15 || requests<600 || collisions<1 || owned_resets!=1 || cancels<2)$fatal(1,"PACK75_COVERAGE");
        $display("PACK75_CACHE_PASS cycles=%0d requests=%0d words=%0d hits=%0d collisions=%0d ways=%h cancels=%0d owned_resets=%0d hash=%h",cycles,requests,words,hits,collisions,ways_seen,cancels,owned_resets,digest);
        done=1;
    end
endmodule

module pack75_data_case(input logic clk,output logic done);
    logic we=0;logic[1:0]way=0;logic[6:0]waddr=0,raddr=0;
    logic[120:0]wdata=0;wire[519:0]rdata;
    logic[519:0]shadow[128];logic[519:0]old_q;
    logic[31:0]rng=32'h501dc075;integer cycles=0,checks=0,collisions=0;
    logic ready=0;
    nds_g3d_header_data dut(.*);
    always @(posedge clk)begin
        old_q=shadow[raddr];
        if(we)shadow[waddr][int'(way)*130+:130]={9'd0,wdata};
        cycles++;rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(ready && we && waddr==raddr)collisions++;
    end
    always @(negedge clk)if(ready)begin
        if(rdata!==old_q)$fatal(1,"PACK75_MASK_OLD_DATA");checks++;
    end
    initial begin
        done=0;
        for(int row=0;row<128;row++)begin
            shadow[row]=0;
            for(int w=0;w<4;w++)begin
                @(negedge clk);we=1;waddr=7'(row);way=2'(w);wdata=121'((row*17+w)^32'h431d0475);
            end
        end
        @(negedge clk);we=0;repeat(2)@(negedge clk);ready=1;
        for(int j=0;j<20000;j++)begin
            @(negedge clk);we=rng[0];way=rng[2:1];waddr=rng[9:3];
            raddr=rng[10]?waddr:rng[17:11];wdata={rng,rng^32'h57a927ea,~rng,25'(rng>>3)};
        end
        @(negedge clk);we=0;repeat(2)@(negedge clk);
        if(checks<20000 || collisions<4000)$fatal(1,"PACK75_MASK_COVERAGE");
        $display("PACK75_DATA_PASS checks=%0d collision_checks=%0d",checks,collisions);done=1;
    end
endmodule

module tb_pack75;
    logic clk=0;always #7.4595 clk=!clk;wire a,b;
    pack75_cache_case cache(.clk,.done(a));
    pack75_data_case payload(.clk,.done(b));
    initial begin wait(a&&b);if($test$plusargs("mutant"))$fatal(1,"PACK75_MUTANT_ESCAPED");$display("PACK75_PASS");$finish;end
    initial begin repeat(500000)@(negedge clk);$fatal(1,"PACK75_TIMEOUT");end
endmodule
