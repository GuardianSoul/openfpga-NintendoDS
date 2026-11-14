`timescale 1ns/1ps
module fpass_order_tb #(
    parameter bit TR3_MODE = 1
);
    logic clk=0;
    always #5 clk=!clk;
    logic rst=1,frame_go=0;
    logic tbl_we=0;
    logic [1:0] tbl_sel=0;
    logic [4:0] tbl_addr=0;
    logic [14:0] tbl_data=0;
    logic [70:0] top_q=0,bot_q=0;
    wire top_needed,fp_clr_req,fp_act,fp_run,frame_done,px_valid;
    wire [9:0] top_raddr,bot_raddr,fp_clr_addr;
    wire [7:0] fp_y,fp_done,px_x,px_y;
    wire [22:0] px_color;
    integer cycle=0,completed=0,cuts=0,first_arbitrary=0;
    integer observed_states[12];
    logic [11:0] cut_states=0;
    wire px_hold=cycle%11<3 || cycle%4096>4032;
    wire fp_clr_ack=fp_clr_req && cycle%7!=2;
    gpu3d_fpass #(.FOG(1),.FOG_SHARE(1),.FOG_DADD8(1),.FPSKIP(1),.FPCLR(1),.TR3(TR3_MODE)) dut (
        .clk,.rst,.dispcnt(16'h00b0),.clear_attr1(32'd0),.clear_depth(15'h7fff),
        .fog_color(21'h155aaa),.fog_offset(15'h1234),.tbl_we,.tbl_sel,.tbl_addr,.tbl_data,
        .frame_go,.lines_done(8'd192),.top_needed,.top_raddr,.bot_raddr,.top_q,.bot_q,
        .fp_clr_req,.fp_clr_addr,.fp_clr_ack,.px_hold,.fp_y,.fp_done,.fp_run,.fp_act,
        .frame_done,.px_valid,.px_x,.px_y,.px_color);
    bit seen=0;
    integer last_row=-1,tag[4];
    logic [3:0] present=0;
    longint tag_checks=0;
    always @(posedge clk)begin
        cycle++;
        if(cycle>20000000)$fatal(1,"FPASS_ORDER_TIMEOUT cuts=%0d completed=%0d",cuts,completed);
        top_q<={24'h3fc40f,24'h123456,23'h5a5543 ^ {13'd0,top_raddr}};
        bot_q<={24'h2fc40f,24'h223456,23'h2aaaaa ^ {13'd0,bot_raddr}};
        if(!rst)observed_states[int'(dut.fst)]++;
        if(rst || frame_go)begin
            seen=0;present=0;
        end else if(px_valid)begin
            if(px_x==0)present[px_y[1:0]]=0;
            if(px_x==255)begin
                if(seen && int'(px_y)!=last_row+1)
                    $fatal(1,"FPASS_COMPLETION_ORDER previous=%0d current=%0d",last_row,px_y);
                if(!seen && px_y!=0)first_arbitrary++;
                seen=1;last_row=int'(px_y);tag[px_y[1:0]]=int'(px_y);present[px_y[1:0]]=1;
                completed++;
            end
            for(integer bank=0;bank<4;bank++)if(present[bank])begin
                if(tag[bank] != ((last_row/4)-(bank>last_row%4))*4+bank)
                    $fatal(1,"FPASS_RECONSTRUCTED_TAG bank=%0d",bank);
                tag_checks++;
            end
        end
    end
    task automatic tick;
        @(negedge clk);
    endtask
    task automatic start_frame;
        frame_go=1;tick();frame_go=0;tick();
    endtask
    task automatic cut_at(input integer target_state,target_x,target_y);
        integer before_count;
        // Each target starts from an idle reset engine. The exercised
        // frame_go below preserves its actual in-flight final-pass phase.
        rst=1;repeat(2)tick();rst=0;
        start_frame();
        while(!(int'(dut.fst)==target_state && int'(fp_y)==target_y &&
                (target_state<3 || int'(dut.fp_x)==target_x)))tick();
        cut_states[target_state]=1;cuts++;
        before_count=completed;
        start_frame();
        while(completed<before_count+(target_y==191 ? 1 : 4))tick();
    endtask
    initial begin
        foreach(observed_states[i])observed_states[i]=0;
        repeat(6)tick();rst=0;
        for(integer table_kind=0;table_kind<2;table_kind++)begin
            tbl_sel=table_kind==0 ? 2'd1 : 2'd2;
            for(integer i=0;i<32;i++)begin
                tbl_we=1;tbl_addr=5'(i);tbl_data=15'(i*3+1);tick();
            end
        end
        tbl_we=0;
        for(integer state_index=0;state_index<12;state_index++)begin
            cut_at(state_index,0,2);
            if(state_index!=0)begin
                cut_at(state_index,127,2);
                cut_at(state_index,255,2);
            end
            cut_at(state_index,255,191);
        end
        start_frame();
        wait(frame_done);tick();tick();
        if(cut_states!=12'hfff || first_arbitrary==0 || tag_checks<100000)
            $fatal(1,"FPASS_ORDER_COVERAGE cuts=%h first_arbitrary=%0d tags=%0d",cut_states,first_arbitrary,tag_checks);
        foreach(observed_states[i])if(observed_states[i]==0)$fatal(1,"FPASS_STATE_UNCOVERED state=%0d",i);
        $display("FPASS_CALLER_ORDER_PASS TR3=%0d cuts=%0d completions=%0d arbitrary_first=%0d tags=%0d cycles=%0d",TR3_MODE,cuts,completed,first_arbitrary,tag_checks,cycle);
        $finish;
    end
endmodule
