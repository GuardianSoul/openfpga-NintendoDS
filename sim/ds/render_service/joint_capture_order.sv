`timescale 1ns/1ps
module joint_capture_order;
    import gpu2d_pkg::*;
    logic clk=0, rst=1;
    always #5 clk=!clk;

    logic [71:0] vramcnt=72'h80808080;
    logic c_req=0,c_we=0;
    logic [21:0] c_addr=0;
    logic [31:0] c_wdata=0;
    wire c_ack;
    wire [31:0] c_rdata;
    logic g_req=0;
    blk_t g_blk='0;
    wire g_ack,g_rvalid;
    wire [63:0] g_rdata;
    logic cap_we=0;
    logic [17:0] cap_addr=0;
    logic [15:0] cap_data=0;
    wire cap_ready,cw_valid,cw_is_capture,capture_dependency;
    wire [23:0] cw_addr;
    wire [31:0] cw_data;
    wire [1:0] cw_he;
    logic allow_enqueue=1,allow_pop=1,allow_returns=1;
    wire cw_ack=cw_valid&&allow_enqueue;
    logic [6:0] cw_pcnt=126,cw_fill=0;
    wire vm_req,vm_we,vm_blk;
    wire [18:0] vm_addr;
    wire [3:0] vm_be;
    wire [31:0] vm_wdata;
    wire vm_ack=vm_req&&!rst;
    logic vm_rvalid=0;
    logic [31:0] vm_rdata=0;

    nds_vram #(.CAP_CHAIN(1),.VR_POST(1),.VR_RDB(1),.VR_PASS(1),.VR_WB(1),
        .VR_CWF(1),.VR_HIT(1),.VR_RHIT(1),.VR_YIELD(1),.VR_PDRAIN(1),.VR_PH(1)) dut (
        .clk,.rst,.joint_capture(1'b1),.cw_is_capture,.capture_dependency,.vramcnt,
        .c_req,.c_cpu(1'b0),.c_dma(1'b1),.c_we,.c_addr,.c_be(4'hf),.c_wdata,.c_ack,.c_rdata,
        .g_req,.g_blk,.g_ack,.g_rvalid,.g_rdata,.cap_we,.cap_addr,.cap_data,.cap_ready,
        .cw_valid,.cw_addr,.cw_data,.cw_he,.cw_ack,.cw_drained(cw_fill==0),.cw_fill,.cw_pcnt,
        .sv_req(1'b0),.sv_we(1'b0),.sv_addr(19'd0),.sv_be(4'd0),.sv_wdata(32'd0),.sv_ack(),.sv_rdata(),
        .vm_req,.vm_we,.vm_blk,.vm_addr,.vm_be,.vm_wdata,.vm_ack,.vm_rvalid,.vm_rdata,.vramstat());

    logic [31:0] mem[0:131071];
    int read_addresses[$], read_lengths[$], write_addresses[$];
    logic [31:0] write_data[$];
    logic [1:0] write_masks[$];
    logic [63:0] expected_beats[$];
    int read_address=0, read_words=0, read_delay=0;
    int checked_beats=0, capture_posts=0, fifo_pops=0, cycles=0;
    logic [2:0] mask_seen=0;
    bit watch_alias=0;
    int watched_word=0;
    logic [31:0] watched_value;

    function automatic logic [31:0] initial_word(input int address);
        return 32'h43567201 ^ (32'(address)*32'h10201);
    endfunction

    always @(posedge clk) begin
        cycles++;
        if(cycles>3000)$fatal(1,"ORDER_TIMEOUT");
        vm_rvalid<=0;
        if(!rst)begin
            if(vm_req&&vm_ack)begin
                if(vm_we)$fatal(1,"UNEXPECTED_NATIVE_WRITE");
                if(watch_alias && int'(vm_addr)==watched_word && mem[watched_word]!==watched_value)
                    $fatal(1,"YOUNGER_ALIAS_OFFER");
                read_addresses.push_back(int'(vm_addr));
                read_lengths.push_back(vm_blk?8:1);
            end
            if(read_words==0&&read_addresses.size()!=0)begin
                read_address=read_addresses.pop_front();
                read_words=read_lengths.pop_front();
                read_delay=3;
            end else if(read_words!=0&&allow_returns)begin
                if(read_delay!=0)read_delay--;
                else begin
                    vm_rvalid<=1;
                    vm_rdata<=mem[read_address];
                    read_address++;
                    read_words--;
                end
            end
            if(g_rvalid)begin
                logic [63:0] expected;
                if(expected_beats.size()==0)$fatal(1,"UNOWNED_BLOCK_RETURN");
                expected=expected_beats.pop_front();
                if(g_rdata!==expected)$fatal(1,"BLOCK_OWNER_OR_DATA got=%h expected=%h",g_rdata,expected);
                checked_beats++;
            end
            if(cw_ack)begin
                write_addresses.push_back(int'(cw_addr));
                write_data.push_back(cw_data);
                write_masks.push_back(cw_he);
                if(cw_is_capture)begin
                    capture_posts++;
                    if(cw_he==0)$fatal(1,"EMPTY_CAPTURE_MASK");
                    mask_seen[cw_he-1]=1;
                end
            end
            if(allow_pop&&write_addresses.size()!=0)begin
                int address;
                logic [31:0] data;
                logic [1:0] mask;
                address=write_addresses.pop_front();
                data=write_data.pop_front();
                mask=write_masks.pop_front();
                if(mask[0])mem[address][15:0]=data[15:0];
                if(mask[1])mem[address][31:16]=data[31:16];
                cw_pcnt<=cw_pcnt+1'b1;
                fifo_pops++;
            end
            cw_fill<=7'(write_addresses.size());
        end
    end

    task automatic block_read(input int address,input logic [31:0] first_word);
        @(negedge clk);
        for(int i=0;i<8;i+=2)
            expected_beats.push_back({initial_word(address+i+1),i==0?first_word:initial_word(address+i)});
        g_req=1;
        g_blk={SP_LCDC,1'b0,14'(address/8)};
        do @(posedge clk);while(!g_ack);
        @(negedge clk);
        g_req=0;
    endtask
    task automatic capture(input int address,input logic [15:0] data);
        @(negedge clk);
        cap_we=1;
        cap_addr=18'(address);
        cap_data=data;
        do @(posedge clk);while(!cap_ready);
        @(negedge clk);
        cap_we=0;
    endtask
    task automatic wait_beats(input int count);
        do @(negedge clk);while(checked_beats<count);
    endtask
    task automatic wait_word(input int address,input logic[31:0] value);
        do @(negedge clk);while(mem[address]!==value);
    endtask

    localparam int A='h20,C='h10020,D='h18020;
    logic [31:0] value;
    initial begin
        for(int i=0;i<131072;i++)mem[i]=initial_word(i);
        repeat(4)@(negedge clk);
        rst=0;

        // Two real accepted owners. A capture on the older line waits for it.
        allow_returns=0;
        block_read(D,initial_word(D));
        block_read(C,initial_word(C));
        capture(D*2,16'h1567);
        capture(D*2+1,16'hf00d);
        repeat(12)begin
            @(negedge clk);
            if(cw_valid&&cw_is_capture)$fatal(1,"OLDER_READ_OWNER");
        end
        allow_returns=1;
        wait_beats(8);
        wait_word(D,32'hf00d1567);

        // A younger physical alias waits through both enqueue and retirement.
        allow_enqueue=0;
        allow_pop=0;
        value=(initial_word(A)&32'hffff0000)|32'h002b;
        capture(A*2,16'h002b);
        watch_alias=1;
        watched_word=A;
        watched_value=value;
        block_read(A,value);
        repeat(10)@(negedge clk);
        allow_enqueue=1;
        repeat(10)@(negedge clk);
        allow_pop=1;
        wait_beats(12);
        watch_alias=0;

        // Matching line offset in a different capture bank does not alias.
        allow_enqueue=0;
        capture(C*2+1,16'h6d19);
        block_read(D,32'hf00d1567);
        wait_beats(16);
        allow_enqueue=1;
        value=(initial_word(C)&32'h0000ffff)|32'h6d190000;
        wait_word(C,value);

        // A CPU word already acknowledged into WB precedes a younger capture.
        @(negedge clk);
        allow_enqueue=0;
        c_addr=22'h200000|22'(A);
        c_we=1;
        c_wdata=32'hcafe4545;
        c_req=1;
        do @(posedge clk);while(!c_ack);
        @(negedge clk);
        c_req=0;
        cap_addr=18'(A*2+1);
        cap_data=16'hbeef;
        cap_we=1;
        repeat(6)begin
            @(posedge clk);
            if(cap_ready)$fatal(1,"OLDER_CPU_WRITE_OWNER");
        end
        @(negedge clk);
        allow_enqueue=1;
        do @(posedge clk);while(!cap_ready);
        @(negedge clk);
        cap_we=0;
        wait_word(A,32'hbeef4545);

        // A CPU read of the posted capture line sees the new word.
        c_we=0;
        c_req=1;
        do @(posedge clk);while(!c_ack);
        if(c_rdata!==32'hbeef4545)$fatal(1,"CPU_CAPTURE_ALIAS");
        @(negedge clk);
        c_req=0;
        if(mask_seen!=3'b111||capture_posts!=4||fifo_pops!=5||checked_beats!=16)
            $fatal(1,"ORDER_COVERAGE masks=%b posts=%0d pops=%0d beats=%0d",mask_seen,capture_posts,fifo_pops,checked_beats);
        $display("JOINT_CAPTURE_ORDER_PASS masks=%b capture=%0d pops=%0d block_beats=%0d",mask_seen,capture_posts,fifo_pops,checked_beats);
        $finish;
    end
endmodule
