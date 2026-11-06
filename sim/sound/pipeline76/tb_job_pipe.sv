`timescale 1ns/1ps
module tb_job_pipe;
    logic clk=0,en=1,rst=1,valid=0;
    logic [1:0] op=0,owner=0;
    logic [23:0] tag=0;
    logic signed [15:0] sample_in;
    logic [6:0] index_in,volume_in,pan_in;
    logic [3:0] nibble_in;
    logic [1:0] divider_in;
    logic pv,dv,wv;
    logic [23:0] pt,dt,wt;
    logic signed [15:0] ps,ds;
    logic [6:0] di;
    logic signed [27:0] wl,wr,wp;
    sound_job_pipe dut(.clk,.en,.rst,.valid,.op,.tag,.sample_in,.index_in,.nibble_in,
        .volume_in,.pan_in,.divider_in,.pcm_valid(pv),.pcm_tag(pt),.pcm_sample(ps),
        .decode_valid(dv),.decode_tag(dt),.decode_sample(ds),.decode_index(di),
        .weight_valid(wv),.weight_tag(wt),.weight_left(wl),.weight_right(wr),.weight_postvol(wp));

    logic signed [15:0] samples[4];
    logic [6:0] indices[4],volumes[4],pans[4];
    logic [3:0] nibbles[4];
    logic [1:0] dividers[4];
    wire [15:0] gold_sample[4];
    wire [6:0] gold_index[4];
    wire signed [27:0] gold_left[4],gold_right[4],gold_postvol[4];
    assign sample_in=samples[owner];assign index_in=indices[owner];
    assign nibble_in=nibbles[owner];assign volume_in=volumes[owner];
    assign pan_in=pans[owner];assign divider_in=dividers[owner];
    // Actual original owned-worker arithmetic, frozen CE: no copied oracle.
    // Only its working set/read operands are deposited; its expressions,
    // signed widths, step table, clamps and volume/pan paths remain original.
    genvar g;
    generate for(g=0;g<4;g=g+1)begin:reference
        sound_worker #(.EVENT_MODE(1),.EVENT_FAST(1),.MEM_QUAD(1),.WORKER_ID(g),.TIMER_DIV(4)) old(
            .clk,.ce(1'b0),.rst(1'b0),.tick(1'b0),.power(1'b1),
            .reg_req(1'b0),.reg_we(1'b0),.reg_addr(9'd0),.reg_size(2'd0),.reg_wdata(32'd0),
            .mem_ack(1'b0),.mem_rvalid(1'b0),.mem_rdata(32'd0),
            .worker_kick(1'b0),.worker_due_mask(18'd0),.worker_refresh_mask(18'd0));
        wire [14:0] step_word=old.u_fifo.adpcm_step(indices[g]);
        always_comb begin
            force old.w0={9'd0,pans[g],6'd0,dividers[g],1'b0,volumes[g]};
            force old.w4={8'd0,samples[g],16'd0};
            force old.w6={3'd0,4'd0,nibbles[g],29'd0};
            force old.w7={17'd0,indices[g],samples[g]};
            force old.ff_q={17'd0,step_word};
            force old.rom_ra_q={indices[g],nibbles[g][2:0]};
        end
        assign gold_sample[g]=old.vnew;assign gold_index[g]=old.inew;
        assign gold_left[g]=old.fast_left;assign gold_right[g]=old.fast_right;
        assign gold_postvol[g]=28'(old.postvol_product>>>3);
    end endgenerate

    typedef struct packed{
        logic [23:0] tag;
        logic [15:0] sample_value;
        logic [6:0] index_value;
        logic [27:0] left_value,right_value,postvol_value;
        integer accepted;
    } expected_t;
    expected_t dq[$],wq[$],x,y;
    integer edge_count=0,nd=0,nw=0,np=0,nreset=0,npaused=0;
    logic [31:0] random_state=32'h40c1a761;
    function automatic logic [31:0] next_random(input logic [31:0] r);
        logic [31:0] t;
        t=r^(r<<13);t=t^(t>>17);next_random=t^(t<<5);
    endfunction
    always #2 clk=~clk;
    always @(posedge clk)begin
        if(rst)begin dq.delete();wq.delete();nreset++;end
        else if(en)begin
            edge_count++;
            if(valid)begin
                x='0;x.tag=tag;x.accepted=edge_count;
                if(op==0)begin
                    assert(pv && pt===tag && ps===sample_in)else $fatal(1,"PCM accepting-edge mismatch");np++;
                end
                if(op==1)begin
                    x.sample_value=gold_sample[owner];x.index_value=gold_index[owner];dq.push_back(x);
                end
                if(op==2)begin
                    x.left_value=gold_left[owner];x.right_value=gold_right[owner];x.postvol_value=gold_postvol[owner];wq.push_back(x);
                end
            end
            #0.1;
            if(dv)begin
                assert(dq.size()!=0)else $fatal(1,"orphan decode");y=dq.pop_front();
                assert(dt===y.tag && ds===y.sample_value && di===y.index_value && edge_count-y.accepted==2)
                    else $fatal(1,"DECODE wrong context/value/edge tag=%h expected=%h sample=%h/%h index=%h/%h age=%0d",dt,y.tag,ds,y.sample_value,di,y.index_value,edge_count-y.accepted);
                nd++;
            end
            if(wv)begin
                assert(wq.size()!=0)else $fatal(1,"orphan weight");y=wq.pop_front();
                assert(wt===y.tag && wl===y.left_value && wr===y.right_value && wp===y.postvol_value && edge_count-y.accepted==2)
                    else $fatal(1,"WEIGHT wrong context/value/edge tag=%h/%h L=%h/%h R=%h/%h P=%h/%h",wt,y.tag,wl,y.left_value,wr,y.right_value,wp,y.postvol_value);
                nw++;
            end
        end else npaused++;
    end
    initial begin
        for(integer n=0;n<4;n++)begin samples[n]=0;indices[n]=0;nibbles[n]=0;volumes[n]=0;pans[n]=0;dividers[n]=0;end
        repeat(3)@(negedge clk);
        for(integer c=0;c<100000;c++)begin
            @(negedge clk);
            random_state=next_random(random_state);
            rst=c%1009==1008;en=random_state[0] || random_state[1];valid=c<99990 && random_state[2:1]!=0;
            op=2'(c%3);owner=2'(c%4);tag={owner,22'(c)};
            for(integer n=0;n<4;n++)begin
                random_state=next_random(random_state);samples[n]=16'(random_state);
                indices[n]=7'(c+n);nibbles[n]=4'(c/128+n);
                volumes[n]=7'(c/3+n*43);pans[n]=7'(c/384+n*37);dividers[n]=2'(c/7+n);
                if(c%17==0)samples[n]=16'h8000;
                if(c%19==0)samples[n]=16'h7fff;
            end
        end
        @(negedge clk);rst=0;valid=0;en=1;
        repeat(5)@(negedge clk);
        assert(dq.size()==0 && wq.size()==0 && nd>10000 && nw>10000 && np>10000 && nreset>90 && npaused>10000)
            else $fatal(1,"coverage/queue completion missing %0d/%0d/%0d",nd,nw,np);
        $display("JOB_PIPE_ARITH_PASS original4workers decode=%0d weight=%0d PCM=%0d reset=%0d paused=%0d",nd,nw,np,nreset,npaused);
        $finish;
    end
endmodule
