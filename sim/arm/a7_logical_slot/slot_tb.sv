`timescale 1ps/1ps
`default_nettype none
`ifndef ALTERA_RESERVED_QIS
module slot_tb;
    logic clk=0, clk_mem=0, clk_cram=0, rst=1;
    always #4973 clk_mem=~clk_mem;
    initial begin #14919; forever begin clk=1; #7460; clk=0; #7459; end end
    always @(clk_mem) clk_cram<=#6838 clk_mem;
    logic i_req=0, i_seq=0, i_consume=0, redirect=0, cpu_reset=0;
    logic [31:0] i_addr=32'h02000000, i_data;
    logic i_ok, commit_valid=0, commit_accept;
    logic [31:0] commit_addr=0, saved_word;
    wire cancel=redirect || cpu_reset;
    logic fr, fn, fw, ack, rv, fseq;
    logic [1:0] fgen, fword;
    logic [31:0] fa, fd, fq;
    logic [3:0] fb;
    logic a9_req=0, a9_ack, a9_rvalid;
    logic [31:0] a9_addr=32'h02010000, a9_data;
    logic initialized, idle;
    wire [79:0] pins;
    integer preads, pwrites, cycle=0, accepts=0, wait_edges=0, turns=0, a9_returns=0;
    integer scenario=0, pressure=0, edgefd=0, pinfd=0, datafd=0;
    bit held_packet=0, done=0;
    logic [37:0] descriptor;
    string out;

    nds_arm7_port_slot_trial #(.WRAM_M10K(1), .MAIN_IF_EARLY(1),
        .MAIN_IF_QUAD(1), .MAIN_IF_FLOW(1), .MAIN_IF_REJOIN(1), .MAIN_STORE_TURN(1)) p7 (
        .clk, .rst, .wramcnt(2'd3), .biosprot(16'd0),
        .i_req, .i_addr, .i_seq, .i_arm(1'b1), .i_redirect(cancel), .i_consume,
        .i_rdata(i_data), .i_ok, .i_commit_valid(commit_valid),
        .i_commit_addr(commit_addr), .i_commit_accept(commit_accept),
        .d_req(1'b0), .d_we(1'b0), .d_be(4'hF), .d_addr(32'd0), .d_wdata(32'd0), .d_rdata(), .d_ok(),
        .w_req(), .w_we(), .w_addr(), .w_be(), .w_wdata(), .w_ok(1'b0), .w_rdata(32'd0),
        .ib_addr(), .i_boot_q(32'd0), .db_addr(), .d_boot(), .d_boot_q(32'd0),
        .x_req(), .x_we(), .x_addr(), .x_be(), .x_wdata(), .x_stores(), .x_done(1'b0), .x_rdata(32'd0),
        .inv(1'b0), .inv_addr(16'd0), .wr_mon(1'b0), .wr_addr(32'd0),
        .f_req(fr), .f_n4(fn), .f_ifseq(fseq), .f_ifgen(fgen), .f_ifword(fword),
        .f_we(fw), .f_addr(fa), .f_be(fb), .f_wdata(fd), .f_ack(ack), .f_rvalid(rv), .f_rdata(fq));
    physical_before #(.IF_STREAM(1), .FAB_FLOW(1)) transport (
        .clk_sys(clk), .clk_mem, .clk_cram, .rst_sys(rst), .rst_mem(rst),
        .a9_req, .a9_we(1'b0), .a9_n8(1'b0), .a9_ldm(1'b0), .a9_addr,
        .a9_wdata(32'd0), .a9_be(4'hF), .a9_ack, .a9_rvalid, .a9_rdata(a9_data),
        .a7_req(fr), .a7_we(fw), .a7_n4(fn), .a7_ifseq(fseq), .a7_ifgen(fgen), .a7_ifword(fword),
        .a7_addr(fa), .a7_wdata(fd), .a7_ack(ack), .a7_rvalid(rv), .a7_rdata(fq),
        .initialized, .idle, .pins, .reads(preads), .writes(pwrites));

    always @(posedge clk) begin
        cycle<=cycle+1;
        if (!rst) begin
            if (commit_accept) begin accepts++; if (p7.flow_v) turns++; end
            if (commit_valid && !commit_accept && !cancel) wait_edges++;
            if (cancel) assert (!commit_accept) else $fatal(1,"accept on cancellation");
            if (held_packet)
                assert (fr && {fa,fseq,fgen,fword,fn}==descriptor)
                    else $fatal(1,"fixture old physical owner changed before actual ACK");
            held_packet=fr && fn && !ack;
            if (fr && fn) descriptor={fa,fseq,fgen,fword,fn};
        end else held_packet=0;
        if (edgefd) $fdisplay(edgefd,"%0d %b %h %b %b %b %h %b %h %b %b %h %b %b %h %b %h %0d",
            cycle,i_req,i_addr,i_seq,i_consume,i_ok,i_data,fr,fa,fn,ack,fq,rv,commit_accept,
            commit_addr,p7.flow_v,{p7.flow_a,2'b0},p7.flow_left);
    end
    always @(posedge clk_mem) if (pinfd) $fdisplay(pinfd,"%0t %h",$time,pins);

    task automatic start_fetch(input logic [31:0] address);
        @(negedge clk); i_addr=address; i_seq=0; i_req=1;
    endtask
    task automatic sample_word;
        do @(posedge clk); while (!i_ok);
        saved_word=i_data;
        assert (i_data==(32'ha5000000 | ((i_addr&32'h003fffff)>>2)))
            else $fatal(1,"P7 slot payload %h got%h",i_addr,i_data);
        $fdisplay(datafd,"%h %h",i_addr,i_data);
    endtask
    task automatic consume_only;
        @(negedge clk); i_req=0; i_consume=1;
        @(negedge clk); i_consume=0;
    endtask

    initial begin : pressure_worker
        wait (!rst && initialized);
        if (pressure) for (int j=0;j<32;j++) begin
            @(negedge clk); a9_addr=32'h02010000+32'(j*4); a9_req=1;
            do @(posedge clk); while (!a9_ack);
            assert (a9_data==(32'hc9000000|32'(j))) else $fatal(1,"A9 value/order");
            a9_returns++;
            @(negedge clk); a9_req=0;
            repeat(2) @(negedge clk);
        end
    end
    initial begin
        assert ($value$plusargs("out=%s",out)) else $fatal(1,"missing out");
        void'($value$plusargs("scenario=%d",scenario));
        void'($value$plusargs("pressure=%d",pressure));
        for (int j=0;j<4096;j++) begin
            transport.chips.m0.mem[j]=16'(j);
            transport.chips.m1.mem[j]=16'ha500;
        end
        for (int j=0;j<32;j++) begin
            transport.chips.m0.mem[32'h10000/4+j]=16'(j);
            transport.chips.m1.mem[32'h10000/4+j]=16'hc900;
        end
        edgefd=$fopen({out,".edge"},"w"); pinfd=$fopen({out,".pins"},"w");
        datafd=$fopen({out,".data"},"w");
        repeat(8) @(negedge clk); rst=0; wait(initialized); repeat(8) @(negedge clk);
        start_fetch(32'h02000000);
        if (scenario==0 || scenario==3) begin
            // This receiver-only offer deliberately arrives before its old
            // slot is free. It does not assert any CPU preparation timing.
            @(negedge clk); commit_addr=32'h02000004; commit_valid=1;
            sample_word();
            @(negedge clk); i_req=0;
            repeat(8) begin
                assert (!commit_accept && p7.flow_v) else $fatal(1,"occupied slot accepted twice");
                @(negedge clk);
            end
            i_consume=1; #1;
            assert (commit_accept) else $fatal(1,"matching finished consume did not free slot");
            @(negedge clk); i_consume=0; commit_valid=0; i_addr=32'h02000004; i_seq=1;
            if (scenario==3) repeat(8) @(negedge clk);
            i_req=1; sample_word(); consume_only();
            assert (accepts==1 && turns==1 && wait_edges>=8) else $fatal(1,"accept/backpressure coverage");
        end else if (scenario==1 || scenario==2) begin
            wait(fr && fn && transport.u_arb.own==1 && transport.u_phy.busy
                && transport.u_fab.mst==2 && !ack);
            @(negedge clk); i_req=0; commit_addr=32'h02000004; commit_valid=1;
            assert (!commit_accept) else $fatal(1,"unconsumed old owner accepted");
            @(negedge clk); commit_valid=0;
            if (scenario==1) redirect=1; else cpu_reset=1;
            assert (!rst && fr && fn) else $fatal(1,"CPU cancel lost actual old packet");
            repeat(4) @(negedge clk); redirect=0; cpu_reset=0;
            wait(!fr && idle); repeat(2) @(negedge clk);
            assert (!p7.flow_v && accepts==0) else $fatal(1,"cancelled logical slot survived");
            start_fetch(32'h02002000); sample_word(); consume_only();
        end else begin
            // valid0 is the literal preceding-source equivalence lane.
            sample_word(); consume_only();
            start_fetch(32'h02000100); sample_word(); consume_only();
            assert (accepts==0) else $fatal(1,"legacy accepted an explicit commit");
        end
        wait(!fr && idle);
        if (pressure) wait(a9_returns==32);
        repeat(3) @(negedge clk);
        assert (pwrites==0) else $fatal(1,"unexpected physical write");
        $display("P7_SLOT_PASS scenario%0d pressure%0d accepts%0d waits%0d turns%0d A9returns%0d reads%0d",
            scenario,pressure,accepts,wait_edges,turns,a9_returns,preads);
        $fclose(edgefd); $fclose(pinfd); $fclose(datafd); done=1; $finish;
    end
    initial begin #2000000000; $fatal(1,"P7 slot bounded fixture timeout"); end
endmodule
`endif
