// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_overlay;
    reg osc=0,advance=1;always #1 osc=~osc;
    wire clk=osc&&advance;
    reg mode=0,rst=1,wreq=0,rreq=0;
    reg[8:0]wa=0,ra=0;reg[1:0]wd=0;reg we=0,re=0;
    wire[8:0]iwa,ira;wire[1:0]iwd;wire iwe,ire,ready;
    wire[8:0]waddr=mode?iwa:wa,raddr=mode?ira:ra;
    wire[1:0]wdata=mode?iwd:wd;wire wen=mode?iwe:we,ren=mode?ire:re;
    wire[1:0]q,pq,mq,oq;
    wire d0,d1;
    serv_rf_ram_if #(.width(2),.W(1),.csr_regs(0),.reset_strategy("MINI")) rfif(
        .i_clk(clk),.i_rst(rst),.i_wreq(wreq),.i_rreq(rreq),.o_ready(ready),
        .i_wreg0(5'd3),.i_wreg1(5'd7),.i_wen0(1'b1),.i_wen1(1'b1),
        .i_wdata0(osc),.i_wdata1(!osc),.i_rreg0(5'd3),.i_rreg1(5'd7),
        .o_rdata0(d0),.o_rdata1(d1),.o_waddr(iwa),.o_wdata(iwd),.o_wen(iwe),
        .o_raddr(ira),.o_ren(ire),.i_rdata(q));
`define PORTS .i_clk(clk),.i_waddr(waddr),.i_raddr(raddr),.i_wdata(wdata),.i_wen(wen),.i_ren(ren)
    native_mlab_rf #(.width(2),.csr_regs(0)) n(`PORTS,.o_rdata(q));
    production_rf #(.width(2),.csr_regs(0)) p(`PORTS,.o_rdata(pq));
    original_rf #(.width(2),.csr_regs(0)) o(`PORTS,.o_rdata(oq));
    native_m10k_rf m(`PORTS,.o_rdata(mq));
`undef PORTS
    integer clocks=0,imports=0,pauses=0,warm_pending=0,warm_if_pending=0,if_reads=0,if_writes=0;
    integer current_coll=0,prior_coll=0;reg[1:0]logical_word;
    // Intel altdpram's no-MIF model initializes0 unconditionally. The actual
    // source contract is unknown-start: deposit that fixture state after its
    // initial block, before the first clock. Vendor code remains unmodified.
    initial begin
        #0.002;
        for(integer a=0;a<512;a=a+1)n.physical.mem_data[a]=2'bxx;
    end
    always @(posedge clk)begin
        clocks=clocks+1;
        if(rst&&p.pending_wen)warm_pending=warm_pending+1;
        if(mode&&rst&&p.pending_wen)warm_if_pending=warm_if_pending+1;
        if(mode&&ren)if_reads=if_reads+1;
        if(mode&&wen)if_writes=if_writes+1;
        if(ren&&wen&&raddr==waddr)current_coll=current_coll+1;
        if(ren&&p.pending_wen&&raddr==p.pending_addr)prior_coll=prior_coll+1;
        #0.001;
        if(mode&&rst&&{rfif.rgate,rfif.rgnt,rfif.rreq_r,rfif.rcnt}!==8'd0)
            $fatal(1,"RF36_MINI interface state not reset");
        if(q!==oq || pq!==oq || mq!==oq)
            $fatal(1,"RF36_PUBLIC cycle=%0d ren=%b ra=%h nativeMLAB=%h production=%h nativeM10K=%h prior=%h",clocks,ren,raddr,q,pq,mq,oq);
        for(integer a=0;a<512;a=a+1)begin
            logical_word=(p.pending_wen&&p.pending_addr==a)?p.pending_data:p.memory[a];
            if(logical_word!==o.memory[a])$fatal(1,"RF36_STATE production %0d",a);
            logical_word=(n.pending_wen&&n.pending_addr==a)?n.pending_data:n.physical.mem_data[a];
            if(logical_word!==o.memory[a])$fatal(1,"RF36_STATE nativeMLAB %0d",a);
        end
    end
    task automatic paused_import;
        reg[1:0]saved_q,saved_pending;
        begin
            @(negedge clk);we=0;re=0;advance=0;
            saved_q=q;saved_pending=p.pending_data;
            #7;
            if(q!==saved_q || p.pending_data!==saved_pending)$fatal(1,"RF36_STOPPED changed withoutclock");
            pauses=pauses+1;
            // Restore one checkpoint's physical arrays and pending overlay.
            // Baseline memory receives its logical image, including pending.
            for(integer a=0;a<512;a=a+1)begin
                p.memory[a]=(a*3+2)&3;n.physical.mem_data[a]=(a*3+2)&3;
                o.memory[a]=(a==37)?2'd3:((a*3+2)&3);
                m.physical.m_default.altsyncram_inst.mem_data[a]=o.memory[a];
                m.physical.m_default.altsyncram_inst.mem_data_b[a]=o.memory[a];
            end
            p.pending_wen=1;p.pending_addr=37;p.pending_data=3;
            n.pending_wen=1;n.pending_addr=37;n.pending_data=3;
            p.regzero=1;n.regzero=1;o.regzero=1;m.regzero=1;
            #5;
            if(!p.pending_wen || !n.pending_wen)$fatal(1,"RF36_IMPORT pending lost in stoppedclock");
            imports=imports+1;
            // MINI reset applies to actual RF interface, never the RF RAM.
            rst=1;ra=37;wa=37;wd=1;re=1;we=1;
            advance=1;
            repeat(3)@(negedge clk);
            we=0;rst=0;
        end
    endtask
    initial begin
        // Short adapter qualification, not the closed13,027-edge old suite.
        for(integer a=0;a<512;a=a+1)begin
            @(negedge clk);we=1;wa=a;wd=(a*3+1)&3;re=1;ra=a;
        end
        @(negedge clk);we=0;re=1;
        for(integer a=0;a<512;a=a+1)begin ra=a;@(negedge clk);end
        paused_import();
        for(integer k=0;k<192;k=k+1)begin
            @(negedge clk);ra=(k%2)?wa:p.pending_addr;wa=32+k%16;
            wd=k&3;we=(k%3!=0);re=(k%7!=0);
        end
        @(negedge clk);we=0;re=1;
        paused_import();
        @(negedge clk);mode=1;rst=1;
        repeat(3)@(negedge clk);rst=0;
        for(integer k=0;k<2048;k=k+1)begin
            @(negedge clk);wreq=(k%113==0);rreq=(k%79==0);
            rst=(k%257==0);
            if(k%389==0)begin
                advance=0;#9;pauses=pauses+1;advance=1;
            end
        end
        @(negedge clk);
        if(imports!=2 || pauses<5 || warm_pending<2 || warm_if_pending<1 || if_reads<100 || if_writes<100 ||
           current_coll<100 || prior_coll<20)$fatal(1,"RF36_COVERAGE imports%0d pauses%0d warm%0d reads%0d writes%0d cc%0d pc%0d",imports,pauses,warm_pending,if_reads,if_writes,current_coll,prior_coll);
        $display("RF36_OVERLAY_PASS clocks=%0d imports=%0d pauses=%0d reset_pending=%0d actualMINI_warm_pending=%0d actualMINI_reads=%0d writes=%0d currentcoll=%0d priorcoll=%0d",clocks,imports,pauses,warm_pending,warm_if_pending,if_reads,if_writes,current_coll,prior_coll);
        $finish;
    end
    initial begin #20000;$fatal(1,"RF36_TIMEOUT");end
endmodule
