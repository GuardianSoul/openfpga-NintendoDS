// Actual poster/FIFO/xport/arbiter/controller/chip under continuous contention.
`timescale 1ns/1ps
module ring_service_tb;
    logic clk=0,memclk=0;
    integer phase_ps=0;
    initial begin
        if(!$value$plusargs("phase_ps=%d",phase_ps))phase_ps=0;
        #(real'(phase_ps)/1000.0);
        forever #7.4595 clk=!clk;
    end
    always #4.973 memclk=!memclk;
    logic rst=1,init=1,frame_go=0,l3d_go=0,l3d_done=0;
    logic [7:0] l3d_line=0,l3d_raddr=0,fp_line=0;
    wire [22:0] l3d_rdata;
    wire [8:0] y_lim;
    wire l3d_have;
    wire [3:0] st_busy;
    logic fp_act=0,px_valid=0;
    logic [7:0] px_x=0,px_y=0;
    logic [22:0] px_color=0;
    wire ll_rd;
    wire [1:0] ll_slot;
    wire [7:0] ll_x;
    wire rg_wreq,rg_wack,rg_rreq,rg_rack,rg_rvalid,rg_hurry;
    wire [23:0] rg_waddr,rg_raddr;
    wire [31:0] rg_wdata,rg_rdata;
    wire [6:0] rg_wfill,rg_wpcnt;
    logic [7:0] due_line=0;
    logic [13:0] due_sys=0;
    nds_g3d_ring_deadline #(.LEAD(192),.YLAG(2),.RH_AT(32)) ring (
        .clk,.rst,.frame_go,.l3d_go,.l3d_done,.l3d_line,.l3d_raddr,.l3d_rdata,.y_lim,.l3d_have,.st_busy,
        .r_go(9'd0),.fp_line,.fp_act,.ll_rd,.ll_slot,.ll_x,.ll_ack(1'b0),.ll_q(23'd0),
        .px_valid,.px_x,.px_y,.px_color,.rg_wreq,.rg_waddr,.rg_wdata,.rg_wack,
        .rg_rreq,.rg_hurry,.rg_raddr,.rg_rack,.rg_rvalid,.rg_rdata,.rg_wfill,.rg_wpcnt,
        .due_valid(1'b1),.due_line,.due_sys);

    logic load=0,read_streams=0;
    integer video_words=0,capture_words=0,syscycles=0,memcycles=0;
    wire video_req=load && video_words<2000;
    wire capture_req=load && capture_words<2000;
    wire video_ack,capture_ack;
    wire full,empty,bw_valid,bw_read,overflow;
    wire [57:0] bw_q;
    wire [23:0] video_addr=24'h380000+24'(video_words);
    wire [31:0] video_data=32'h715a0000^32'(video_words);
    wire [23:0] capture_addr=24'h200000+24'(capture_words/2);
    wire [31:0] capture_data=32'h93c50000^32'(capture_words);
    wire [1:0] capture_he=capture_words[0]?2'b10:2'b01;
    nds_ring_post_arb posters (.clk,.reset(rst),.video_req,.ring_req(rg_wreq),.capture_req,
        .ring_last(1'b0),.full,.video_ack,.ring_ack(rg_wack),.capture_ack);
    wire [57:0] posted_word=rg_wack?{2'b11,rg_waddr,rg_wdata}:
                                     capture_ack?{capture_he,capture_addr,capture_data}:{2'b11,video_addr,video_data};
    nds_dcfifo #(.W(58),.A(6)) fifo (.wclk(clk),.wreset(rst),
        .wr(rg_wack||capture_ack||video_ack),.wdata(posted_word),.full,.wempty(empty),
        .wfill(rg_wfill),.wpcnt(rg_wpcnt),.overflow,
        .rclk(memclk),.rd(bw_read),.valid(bw_valid),.rdata(bw_q));
    always @(posedge clk)begin
        syscycles++;
        if(video_ack)video_words<=video_words+1;
        if(capture_ack)capture_words<=capture_words+1;
        if(due_sys!=0)due_sys<=due_sys-14'd1;
        if(overflow)$fatal(1,"POST_FIFO_OVERFLOW");
    end

    logic [6:0] p_valid=0,p_we=0;
    logic [167:0] p_addr=0;
    logic [27:0] p_n=0,p_be=0;
    logic [223:0] p_wdata=0;
    wire [6:0] p_take,p_w;
    wire [31:0] p_wd;
    wire ready,ref_late;
    logic [1:0] hurry_sync=0;
    always @(posedge memclk)hurry_sync<={hurry_sync[0],rg_hurry};
    wire [6:0] p_hurry={hurry_sync[1],3'b000,1'b1,2'b00};
    wire [15:0] dq;
    wire [12:0] a;
    wire [1:0] ba,dqm;
    wire nwe,nras,ncas,cke,sclk;
    nds_sdram_bus #(.N(7),.OPEN(1),.OUT_REG(1),.HURRY(1),.BOUNDED(1)) bus (
        .m_hurry(p_hurry),.clk(memclk),.init,.ready,.m_valid(p_valid),.m_we(p_we),.m_addr(p_addr),
        .m_n(p_n),.m_wdata(p_wdata),.m_be(p_be),.m_take(p_take),.w_valid(p_w),.w_data(p_wd),
        .ref_late,.bw_valid,.bw_addr(bw_q[55:32]),.bw_data(bw_q[31:0]),.bw_he(bw_q[57:56]),.bw_read,
        .SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_DQML(dqm[0]),.SDRAM_DQMH(dqm[1]),
        .SDRAM_nWE(nwe),.SDRAM_nRAS(nras),.SDRAM_nCAS(ncas),.SDRAM_CKE(cke),.SDRAM_CLK(sclk));
    wire #2.0 chip_clk=sclk;
    sdram_chip_model #(.CAS(3),.T_AC(6.0),.T_OH(2.5),.T_RET(2.0)) chip (
        .clk(chip_clk),.cke,.ncs(1'b0),.nras,.ncas,.nwe,.a,.ba,.dqm,.dq);
    wire [6:0] ws_v;
    wire [31:0] ws_d;
    nds_sdram_words #(.N(7),.SEL(7'b1010101),.A(4)) words (
        .clk_mem(memclk),.w_valid(p_w),.w_data(p_wd),.rclk(clk),.o_valid(ws_v),.o_data(ws_d));
    nds_sdram_xport #(.QW(8),.SHARED(1)) crossing (
        .clk_sys(clk),.clk_mem(memclk),.reset(rst),.s_req(rg_rreq),.s_we(1'b0),.s_quad(1'b1),
        .s_addr(rg_raddr),.s_wdata(32'd0),.s_be(4'hf),.s_ack(rg_rack),.s_rvalid(rg_rvalid),.s_rdata(rg_rdata),
        .m_valid(p_valid[6]),.m_we(p_we[6]),.m_addr(p_addr[167:144]),.m_n(p_n[27:24]),
        .m_wdata(p_wdata[223:192]),.m_be(p_be[27:24]),.m_take(p_take[6]),.w_valid(ws_v[6]),.w_data(ws_d));

    logic [31:0] gold[int];
    logic [3:0] known[int];
    logic [31:0] expected[7][64];
    integer wp[7],rp[7],takes[7],wait_since[7],max_wait[7];
    integer transactions[6],fifo_grants=0,fifo_pops=0,grant_words=0,refreshes=0,last_refresh=0;
    integer data_checks=0,raw_checks=0;
    task automatic write_gold(input logic [23:0] addr,input logic[31:0] data,input logic[3:0] be);
        logic [31:0] v;
        logic [3:0] k;
        v=gold.exists(int'(addr))?gold[int'(addr)]:0;
        k=known.exists(int'(addr))?known[int'(addr)]:0;
        for(integer j=0;j<4;j++)if(be[j])begin v[j*8+:8]=data[j*8+:8];k[j]=1;end
        gold[int'(addr)]=v;known[int'(addr)]=k;
    endtask
    always @(posedge memclk)begin
        memcycles++;
        if(memcycles>800000)$fatal(1,"SERVICE_TIMEOUT");
        if(bus.mc.bw_start)begin grant_words=0;fifo_grants++;end
        if(bw_read)begin
            grant_words++;fifo_pops++;
            write_gold(bw_q[55:32],bw_q[31:0],{{2{bw_q[57]}},{2{bw_q[56]}}});
        end
        if(bus.mc.bw_done && (grant_words<1||grant_words>8))$fatal(1,"FIFO_QUANTUM words=%0d",grant_words);
        if({nras,ncas,nwe}==3'b001)begin refreshes++;last_refresh=memcycles;end
        if(ready && memcycles-last_refresh>2048)$fatal(1,"REFRESH_STARVED");
        for(integer i=0;i<7;i++)begin
            if(p_valid[i]&&!p_take[i]&&ready)begin
                if(wait_since[i]==0)wait_since[i]=memcycles;
                if(memcycles-wait_since[i]>2048)$fatal(1,"CLIENT_STARVED port=%0d",i);
            end
            if(p_take[i])begin
                if(memcycles-wait_since[i]>max_wait[i]&&wait_since[i]!=0)max_wait[i]=memcycles-wait_since[i];
                wait_since[i]=0;takes[i]++;
                if(p_we[i])write_gold(p_addr[i*24+:24],p_wdata[i*32+:32],p_be[i*4+:4]);
                else for(integer k=0;k<int'(p_n[i*4+:4]);k++)begin
                    if(!known.exists(int'(p_addr[i*24+:24])+k)||known[int'(p_addr[i*24+:24])+k]!=15)
                        $fatal(1,"UNKNOWN_READ port=%0d addr=%h",i,p_addr[i*24+:24]+24'(k));
                    expected[i][wp[i]%64]=gold[int'(p_addr[i*24+:24])+k];wp[i]++;
                    if(wp[i]-rp[i]>32)$fatal(1,"EXCESS_OUTSTANDING");
                end
            end
            if(p_w[i])begin
                if(rp[i]==wp[i]||p_wd!==expected[i][rp[i]%64])
                    $fatal(1,"NATIVE_DATA port=%0d got=%h expected=%h",i,p_wd,expected[i][rp[i]%64]);
                rp[i]++;data_checks++;
            end
        end
        if(words.words.overflow)$fatal(1,"SHARED_RETURN_OVERFLOW");
    end
    always @(negedge memclk)if(read_streams)begin
        for(integer i=0;i<6;i++)begin
            if(p_take[i])p_valid[i]=0;
            else if(!p_valid[i])begin
                transactions[i]++;p_valid[i]=1;p_be[i*4+:4]=15;
                p_we[i]=i==1;
                p_n[i*4+:4]=i==0||i==3?4:(i==4||i==5||i==1?1:8);
                p_addr[i*24+:24]=i==1 ? 24'h300000+24'(transactions[i]%64) : 24'h001000+24'(i*1024);
                p_wdata[i*32+:32]=32'hb1a00000^32'(transactions[i]);
            end
        end
    end
    else for(integer i=0;i<6;i++)if(p_take[i])p_valid[i]=0;

    task automatic native(input bit we,input logic[23:0] addr,input logic[31:0] data);
        @(negedge memclk);p_valid[1]=1;p_we[1]=we;p_addr[47:24]=addr;p_n[7:4]=1;p_be[7:4]=15;p_wdata[63:32]=data;
        do @(posedge memclk);while(!p_take[1]);
        @(negedge memclk);p_valid[1]=0;
        if(!we)wait(wp[1]==rp[1]);
        else repeat(20)@(negedge memclk);
    endtask
    function automatic [22:0] pixel(input integer y,input integer x);
        return 23'h610000 ^ (23'(y)<<8) ^ 23'(x);
    endfunction
    task automatic tick(input integer n=1);repeat(n)@(negedge clk);endtask
    task automatic produce(input integer y);
        while(st_busy[y%4])tick();
        fp_act=1;fp_line=8'(y);
        for(integer x=0;x<256;x++)begin px_valid=1;px_y=8'(y);px_x=8'(x);px_color=pixel(y,x);tick();end
        px_valid=0;fp_act=0;tick();
    endtask
    task automatic sweep(input integer y);
        for(integer x=0;x<256;x++)begin
            l3d_raddr=8'(x);tick();
            if(l3d_rdata!==pixel(y,x))$fatal(1,"RAW_DATA row=%0d x=%0d got=%h expected=%h",y,x,l3d_rdata,pixel(y,x));
            raw_checks++;
        end
    endtask
    initial begin
        for(integer i=0;i<7;i++)begin wp[i]=0;rp[i]=0;takes[i]=0;wait_since[i]=0;max_wait[i]=0;end
        for(integer i=0;i<6;i++)transactions[i]=0;
        repeat(6)@(negedge memclk);init=0;
        wait(ready);tick(4);rst=0;
        for(integer i=0;i<6;i++)if(i!=1)for(integer k=0;k<8;k++)
            native(1,24'h001000+24'(i*1024+k),32'hc05e0000^32'(i*1024+k));
        tick(20);load=1;read_streams=1;frame_go=1;tick();frame_go=0;
        for(integer y=0;y<20;y++)produce(y);
        // Every other line is the next real job. The final raw sample is
        // held until shortly before that snapshot; third-slot prefetch must
        // already have made the skipped-line successor ready.
        for(integer y=0;y<20;y+=2)begin
            l3d_go=1;tick();l3d_go=0;l3d_line=8'(y);tick();
            if(!l3d_have)$fatal(1,"DELIVERY_DEADLINE row=%0d SYS=%0d",y,syscycles);
            due_line=8'(y+2);due_sys=4260;
            sweep(y);
            tick(3500);
            sweep(y);l3d_done=1;tick();l3d_done=0;
            tick(245);
        end
        read_streams=0;
        wait(p_valid[5:0]==0);wait(video_words==2000&&capture_words==2000&&empty&&ring.posted==20);
        repeat(80)@(negedge memclk);
        foreach(gold[address])if(known[address]==15)native(0,24'(address),0);
        if(chip.errors!=0||fifo_grants<100||refreshes<20||raw_checks!=5120)$fatal(1,"SERVICE_COVERAGE_OR_CHIP");
        for(integer i=0;i<7;i++)if(takes[i]<100)$fatal(1,"NO_CLIENT_COVERAGE port=%0d takes=%0d",i,takes[i]);
        $display("RING_SERVICE_PASS data=%0d raw=%0d FIFOwords=%0d grants=%0d refresh=%0d waits=%0d,%0d,%0d,%0d,%0d,%0d,%0d SYS=%0d MEM=%0d",data_checks,raw_checks,fifo_pops,fifo_grants,refreshes,max_wait[0],max_wait[1],max_wait[2],max_wait[3],max_wait[4],max_wait[5],max_wait[6],syscycles,memcycles);
        $finish;
    end
endmodule
