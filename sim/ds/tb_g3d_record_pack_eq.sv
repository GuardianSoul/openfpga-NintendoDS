// Actual registered RAM primitive and service: full address/data oracle,
// four-response ownership, held writes, consecutive writes, reset in flight.
module tb_g3d_record_ram;
    logic clk=0; always #5 clk=!clk;
    logic rst=1,p_req=0,p_we=0,p_ack,p_rvalid;
    logic [22:2] p_addr=0;
    logic [31:0] p_wdata=0,p_rdata;
    nds_g3d_record_ram #(.PACK(1)) dut(.*);
    logic ref_ack,ref_rvalid;logic[31:0]ref_rdata;
    nds_g3d_record_ram_before reference(.clk,.rst,.p_req,.p_we,.p_addr,.p_wdata,
        .p_ack(ref_ack),.p_rvalid(ref_rvalid),.p_rdata(ref_rdata));
    always @(posedge clk) if(!rst)begin
        if(p_ack!==ref_ack || p_rvalid!==ref_rvalid)$fatal(1,"packing changed protocol cycle");
        if(p_rvalid && p_rdata!==ref_rdata)$fatal(1,"packing differs from previous RTL data");
    end
    integer cycles=0,writes=0,reads=0,beats=0,phase=0;
    logic [31:0] expected[0:65535];
    bit known[0:65535];
    integer read_left=0,read_index=0;
    function automatic [22:2] physical(input integer index);
        physical=21'('h100000+(index>=32768?'h40000:0)+(index%32768));
    endfunction
    function automatic [31:0] word_value(input integer index,input integer epoch);
        word_value=32'h1234a5c6^(32'(index)*32'h10201)^(32'(epoch)*32'hbca98765);
        // This is the private producer's existing record contract, not a
        // truncated expected value: every retained bit varies over all slots.
        if(index%4==2)begin
            if((index&24576)==0)word_value={word_value[24:12],7'd0,word_value[11:0]};
            else word_value[31:20]=12'd0;
        end
    endfunction
    task automatic step; @(posedge clk);#1; endtask
    task automatic accept_request;
        bit taken; taken=0;
        while(!taken)begin @(posedge clk);taken=p_ack;#1;end
    endtask
    task automatic write_word(input integer index,input integer epoch);
        @(negedge clk);p_req=1;p_we=1;p_addr=physical(index);p_wdata=word_value(index,epoch);
        accept_request();@(negedge clk);p_req=0;
    endtask
    task automatic read_record(input integer index,input bit pending_write);
        @(negedge clk);p_req=1;p_we=0;p_addr=physical(index);
        accept_request();@(negedge clk);p_req=0;
        if(pending_write)begin
            p_req=1;p_we=1;p_addr=physical(index^32768);p_wdata=word_value(index^32768,2);
            accept_request();@(negedge clk);p_req=0;
        end else while(read_left!=0)step();
    endtask
    always @(posedge clk)begin
        integer index;
        cycles++;
        if(cycles>600000)$fatal(1,"record RAM cycle bound");
        if(rst)read_left=0;
        else begin
            if(p_rvalid)begin
                if(read_left==0 || !known[read_index] || p_rdata!==expected[read_index])
                    $fatal(1,"record RAM response payload/order mismatch index%0d",read_index);
                if(p_ack)$fatal(1,"record RAM released owner before last response consumed");
                read_left--;read_index++;beats++;
            end
            if(p_req && p_ack)begin
                index=(p_addr>=physical(32768)?32768:0)+32'(p_addr[16:2]);
                if(read_left!=0)$fatal(1,"record RAM accepted request while responses outstanding");
                if(p_we)begin expected[index]=p_wdata;known[index]=1;writes++;end
                else begin
                    if(p_addr[3:2]!=0)$fatal(1,"record RAM read alignment");
                    read_left=4;read_index=index;reads++;
                end
            end
        end
    end
    initial begin
        for(integer i=0;i<65536;i++)begin known[i]=0;expected[i]=0;end
        repeat(4)step();@(negedge clk);rst=0;
        // One accepted write per clock, including the physical bank boundary.
        @(negedge clk);p_req=1;p_we=1;
        for(integer i=0;i<65536;i++)begin
            p_addr=physical(i);p_wdata=word_value(i,0);step();
            if(!p_ack)$fatal(1,"consecutive record write unexpectedly stalled");
            @(negedge clk);
        end
        p_req=0;
        for(integer i=0;i<65536;i+=4)read_record(i,0);
        // Keep the next write asserted throughout each four-word response.
        for(integer i=0;i<64;i+=4)begin read_record(i,1);read_record(i^32768,0);end
        // Reset after two consumed responses: no stale response may escape.
        @(negedge clk);p_req=1;p_we=0;p_addr=physical(32768);step();
        @(negedge clk);p_req=0;repeat(2)step();@(negedge clk);rst=1;
        repeat(3)step();@(negedge clk);rst=0;step();
        if(p_rvalid || read_left!=0)$fatal(1,"stale response after reset");
        write_word(65535,3);read_record(65532,0);
        if(writes!=65553 || reads!=16418 || beats!=65670)
            $fatal(1,"record RAM final counts writes%0d reads%0d beats%0d",writes,reads,beats);
        $display("PASS_RECORD_RAM cycles%0d writes%0d reads%0d beats%0d fullwords65536 reset-midread1 held-write16",cycles,writes,reads,beats);
        $finish;
    end
endmodule
