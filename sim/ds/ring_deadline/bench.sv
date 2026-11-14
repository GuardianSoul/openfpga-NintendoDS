module ring_deadline_tb;
    logic clk=0;
    always #5 clk=!clk;
    logic rst=1, frame_go=0, l3d_go=0, l3d_done=0;
    logic [7:0] l3d_line=0,l3d_raddr=0;
    wire [22:0] l3d_rdata;
    wire l3d_have;
    wire [8:0] y_lim;
    wire [3:0] st_busy;
    logic [8:0] r_go=0;
    logic [7:0] fp_line=0;
    logic fp_act=0;
    wire ll_rd;
    wire [1:0] ll_slot;
    wire [7:0] ll_x;
    wire ll_ack;
    logic [22:0] ll_q=0;
    logic px_valid=0;
    logic [7:0] px_x=0,px_y=0;
    logic [22:0] px_color=0;
    wire rg_wreq,rg_rreq,rg_hurry;
    wire [23:0] rg_waddr,rg_raddr;
    wire [31:0] rg_wdata;
    logic rg_rack=0,rg_rvalid=0;
    logic [31:0] rg_rdata=0;
    integer cyc=0,wr_count=0,pop_count=0,pop_q1=0,pop_q2=0,head=0,tail=0,gen=1;
    assign ll_ack=ll_rd && cyc%4!=1;
    integer read_count=0,read_beats=0,write_count=0,checks=0;
    integer phase=0;
    integer row_end[192];
    integer seen_ordered=0;
    bit job_live=0;
    logic force_write_hold=0,force_read_hold=0,force_return_hold=0;
    integer direct_return_overlap=0,full_skid_cycles=0,aborted_offers=0;
    integer abort_read_beats=0,abort_write_beats=0;
    wire [6:0] rg_wpcnt=7'(pop_q2);
    wire [6:0] rg_wfill=7'(wr_count-pop_q2);
    wire rg_wack=rg_wreq && !force_write_hold && wr_count-pop_count<62 && cyc%5!=2;
    logic [23:0] q_addr[256];
    logic [31:0] q_data[256];
    logic [31:0] mem[49152];
    logic [22:0] expected_stage[1024];
    integer rmode=0,rcount=0,rbeat=0;
    logic [23:0] raddr=0;
    integer pending_commit=0;
    logic [23:0] pending_addr;
    logic [31:0] pending_data;
    wire due_valid=1;
    wire [7:0] due_line=l3d_line+8'd1;
    wire [13:0] due_sys=0;
    nds_g3d_ring_deadline #(.LEAD(192),.YLAG(2),.LLR(1),.LC_AT(48),.RH_AT(32)) dut (.*);

    function automatic [22:0] pixel(input integer g,input integer y,input integer x);
        return 23'h510000 ^ (23'(g)<<16) ^ (23'(y)<<8) ^ 23'(x);
    endfunction
    function automatic [22:0] late_pixel(input integer x);
        return x<137 ? pixel(gen,2,x) : 23'h2a5a5a;
    endfunction

    always @(posedge clk) begin
        cyc=cyc+1;
        if(dut.direct_we && (rg_rvalid || dut.skid_count!=0))direct_return_overlap++;
        if(dut.skid_count==8)full_skid_cycles++;
        if(frame_go && dut.rs==dut.R_REQ)aborted_offers++;
        if(cyc>650000) $fatal(1,"DEADLINE_TIMEOUT phase=%0d",phase);
        if(ll_ack) ll_q<=late_pixel(int'(ll_x));
        rg_rack<=0;rg_rvalid<=0;
        if(px_valid) expected_stage[{px_y[1:0],px_x}]=px_color;
        if(rg_wreq && rg_wack) begin
            if(rg_wdata[22:0]!==expected_stage[rg_waddr[9:0]])
                $fatal(1,"POSTED_WORD phase=%0d addr=%h got=%h expected=%h",phase,rg_waddr,rg_wdata,expected_stage[rg_waddr[9:0]]);
            q_addr[tail%256]=rg_waddr;q_data[tail%256]=rg_wdata;
            tail=tail+1;wr_count=wr_count+1;write_count=write_count+1;
            if(rg_waddr[7:0]==255 && !dut.w_drop && !frame_go)
                row_end[rg_waddr[15:8]]=wr_count;
        end
        // One pop per SYS at most; the high half lands one edge later.
        // Reads share the controller and wait through that final half.
        if(pending_commit!=0) begin
            pending_commit=pending_commit-1;
            if(pending_commit==0) mem[pending_addr-24'h080000]=pending_data;
        end
        if(head<tail && pending_commit==0 && rmode!=2 && cyc%3==0) begin
            pending_addr=q_addr[head%256];pending_data=q_data[head%256];
            pending_commit=1;head=head+1;pop_count=pop_count+1;
        end
        pop_q2<=pop_q1;pop_q1<=pop_count;
        if(rst) begin rmode=0;rg_rack<=0;end
        else case(rmode)
            0: if(rg_rreq && !rg_rack) begin
                raddr=rg_raddr;rcount=3;rmode=1;
            end
            1: if(!force_read_hold) begin
                if(rg_raddr!==raddr || !rg_rreq) $fatal(1,"READ_OFFER_CHANGED");
                if(rcount>0) rcount=rcount-1;
                else begin rg_rack<=1; rmode=2;rbeat=0;rcount=5;read_count=read_count+1;end
            end
            2: if(rcount>0 || pending_commit!=0 || force_return_hold) begin if(rcount>0) rcount=rcount-1;end
               else if(cyc%4!=0) begin
                   rg_rvalid<=1;rg_rdata<=mem[raddr-24'h080000+24'(rbeat)];
                   read_beats=read_beats+1;
                   if(rbeat==7) rmode=0;else rbeat=rbeat+1;
               end
            default: $fatal(1,"MODEL_STATE");
        endcase
    end
    always @(negedge clk) if(!rst) begin
        if(frame_go)seen_ordered=0;
        else if(int'(dut.ordered)>seen_ordered)begin
            if(row_end[int'(dut.ordered)-1]<0 || row_end[int'(dut.ordered)-1]>pop_q2)
                $fatal(1,"POST_ORDER_EARLY row=%0d end=%0d pop=%0d",dut.ordered-1,row_end[int'(dut.ordered)-1],pop_q2);
            seen_ordered=int'(dut.ordered);
        end
        if(job_live && !dut.consumer_valid && !l3d_done)
            $fatal(1,"FINAL_CONSUMER_RELEASE_EARLY");
    end

    task automatic tick(input integer n=1);
        repeat(n) @(negedge clk);
    endtask
    task automatic start_frame;
        tick();frame_go=1;tick();frame_go=0;tick(4);
    endtask
    task automatic produce(input integer y);
        integer timeout;
        timeout=0;
        while(st_busy[y%4]) begin tick();timeout++;if(timeout>20000)$fatal(1,"STAGING_PROGRESS row=%0d",y);end
        fp_line=8'(y);fp_act=1;
        for(integer x=0;x<256;x++) begin
            px_valid=1;px_y=8'(y);px_x=8'(x);px_color=pixel(gen,y,x);tick();
        end
        px_valid=0;fp_act=0;tick();
    endtask
    task automatic wait_row(input integer y,input bit partial=0);
        integer timeout;
        bit found;
        timeout=0;found=0;
        while(!found) begin
            tick();timeout++;
            for(integer i=0;i<3;i++)
                if(dut.row[i]==y && dut.slot_epoch[i]==dut.epoch &&
                   (dut.state[i]==dut.FULL || (partial && dut.state[i]==dut.PARTIAL))) found=1;
            if(timeout>18000)$fatal(1,"ROW_NOT_READY phase=%0d row=%0d",phase,y);
        end
    endtask
    task automatic open_job(input integer y,input bit require_ready=1);
        tick();l3d_go=1;tick();l3d_go=0;l3d_line=8'(y);
        if(!l3d_have) begin tick(0);end
        tick();
        if(require_ready && !l3d_have)$fatal(1,"SNAPSHOT_MISSING row=%0d",y);
        job_live=l3d_have;
    endtask
    task automatic sweep(input integer y,input bit partial=0);
        logic [22:0] expected;
        for(integer x=0;x<256;x++) begin
            l3d_raddr=8'(x);tick();
            expected=partial ? late_pixel(x) : pixel(gen,y,x);
            if(l3d_rdata!==expected)$fatal(1,"ROW_WORD phase=%0d row=%0d x=%0d got=%h expected=%h",phase,y,x,l3d_rdata,expected);
            checks=checks+1;
        end
    endtask
    task automatic release_job;
        job_live=0;l3d_done=1;tick();l3d_done=0;tick();
    endtask
    task automatic consume(input integer y,input bit partial=0);
        wait_row(y,partial);open_job(y);sweep(y,partial);
        // Address255 held after the earlier layer pass is not lease release.
        tick(73);sweep(y,partial);release_job();
    endtask

    initial begin
        for(integer i=0;i<49152;i++)mem[i]=32'hdeadbeef;
        for(integer i=0;i<1024;i++)expected_stage[i]=23'h777777;
        for(integer i=0;i<192;i++)row_end[i]=-1;
        tick(4);rst=0;start_frame();
        phase=1;
        produce(0);produce(1);wait_row(0);open_job(0);
        // Fill both future slots before releasing the first consumer.
        produce(2);wait_row(2);sweep(0);tick(80);sweep(0);release_job();
        consume(1);consume(2);
        phase=2;
        // Complete rows run ahead and wrap the physical staging/parity slots.
        for(integer y=3;y<18;y++)produce(y);
        for(integer y=3;y<18;y++)consume(y);
        if(write_count<256*14 || read_count==0)$fatal(1,"NO_SERVICE_COVERAGE");

        // Hold the first offer across frame abort; old accepted beats must
        // drain without publishing into new descriptors or a pinned slot.
        phase=3;start_frame();gen=2;
        for(integer y=0;y<7;y++)produce(y);
        while(dut.posted<7 || head<tail || pending_commit!=0)tick();
        force_return_hold=1;
        consume(0);open_job(1);
        while(dut.rs!=dut.R_DATA)tick();
        sweep(1);release_job();
        open_job(6,0);
        force_return_hold=0;produce(7);
        release_job();consume(7);
        if(direct_return_overlap<200 || full_skid_cycles<100)$fatal(1,"MISSING_DIRECT_RETURN_OVERLAP");

        start_frame();gen=3;
        for(integer y=0;y<7;y++)produce(y);
        while(dut.posted<7 || head<tail || pending_commit!=0)tick();
        consume(0);force_read_hold=1;consume(1);
        while(dut.rs!=dut.R_REQ)tick();
        start_frame();gen=4;force_read_hold=0;
        tick(100);produce(0);produce(1);consume(0);consume(1);
        if(aborted_offers==0)$fatal(1,"MISSING_ABORTED_OFFER");

        phase=4;
        // LLR: no finalized row2 exists. It is new enough in its raster slot
        // and outside the final pass's neighbours; copy its drawn prefix.
        start_frame();gen=6;produce(0);produce(1);consume(0);
        r_go=4;fp_line=0;fp_act=0;
        consume(1);consume(2,1);
        r_go=0;
        phase=5;
        // Abort on each exact accepted read beat, including the final one.
        for(integer cut=0;cut<8;cut++)begin
            start_frame();gen=10+cut;
            for(integer y=0;y<7;y++)produce(y);
            while(dut.posted<7 || head<tail || pending_commit!=0)tick();
            consume(0);force_return_hold=1;open_job(1);
            while(dut.rs!=dut.R_DATA)tick();
            sweep(1);release_job();force_return_hold=0;
            while(!(dut.rs==dut.R_DATA && int'(dut.r_in)==cut && rg_rvalid))tick();
            frame_go=1;tick();frame_go=0;gen=30+cut;abort_read_beats++;
            while(dut.rs!=dut.R_IDLE)tick();
            produce(0);produce(1);consume(0);consume(1);
        end
        phase=6;
        // A presented write keeps its row/address/data until all8 words end.
        for(integer cut=0;cut<8;cut++)begin
            start_frame();gen=50+cut;produce(0);
            while(!(dut.w_active && int'(dut.w_x[2:0])==cut && rg_wack))tick();
            frame_go=1;tick();frame_go=0;gen=70+cut;abort_write_beats++;
            produce(0);produce(1);consume(0);consume(1);
        end
        if(checks<20*512)$fatal(1,"INSUFFICIENT_DATA_CHECKS");
        $display("RING_DEADLINE_PASS checks=%0d posted=%0d blocks=%0d beats=%0d directoverlap=%0d fullskid=%0d abortedoffers=%0d readcuts=%0d writecuts=%0d SYS=%0d",checks,write_count,read_count,read_beats,direct_return_overlap,full_skid_cycles,aborted_offers,abort_read_beats,abort_write_beats,cyc);
        $finish;
    end
endmodule
