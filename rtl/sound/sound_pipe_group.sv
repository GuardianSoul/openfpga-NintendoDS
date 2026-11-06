// Private arithmetic broker: four voice owners and optional parent selector.
// Each retains its original SYS timeline; CLIENTS is four or five.
// A head is issued once per (owner, kind, serial). Final-stage bypass permits
// an E-edge logical retirement to consume a result ending on that same edge.
module sound_pipe_group #(parameter integer CLIENTS=4)(
    input logic clk_2x,ce,rst,
    input logic [CLIENTS-1:0] request,
    input logic [66:0] job[CLIENTS],
    output logic [CLIENTS-1:0] decode_valid,weight_valid,
    output logic [15:0] decode_sample[CLIENTS],
    output logic [6:0] decode_index[CLIENTS],
    output logic signed [27:0] weight_left[CLIENTS],weight_right[CLIENTS],weight_postvol[CLIENTS]
);
    localparam integer CW=$clog2(CLIENTS);
    localparam integer SW=23-CW;
    logic [CLIENTS-1:0] issued,db_valid,wb_valid;
    logic [23:0] issued_tag[CLIENTS];
    logic [SW-1:0] db_serial[CLIENTS],wb_serial[CLIENTS];
    logic [15:0] db_sample[CLIENTS];
    logic [6:0] db_index[CLIENTS];
    logic signed [27:0] wb_left[CLIENTS],wb_right[CLIENTS],wb_postvol[CLIENTS];
    logic found;
    logic [CW-1:0] selected;
    logic [1:0] best;
    logic [23:0] selected_tag;
    always_comb begin
        found=0;selected=0;best=3;
        for(integer n=0;n<CLIENTS;n=n+1)begin
            if(request[n] && (!issued[n] || issued_tag[n]!={CW'(n),job[n][45],job[n][46+:SW]}) &&
               (!found || job[n][44:43]<best))begin
                found=1;selected=CW'(n);best=job[n][44:43];
            end
        end
        selected_tag={selected,job[selected][45],job[selected][46+:SW]};
    end
    logic dn,wn;
    logic [23:0] dtag,wtag;
    logic signed [15:0] ds;
    logic [6:0] di;
    logic signed [27:0] wl,wr,wp;
    sound_job_pipe pipe(.clk(clk_2x),.en(ce),.rst,.valid(found),
        .op(job[selected][45]?2'd1:2'd2),.tag(selected_tag),
        .sample_in(job[selected][42:27]),.index_in(job[selected][26:20]),.nibble_in(job[selected][19:16]),
        .volume_in(job[selected][15:9]),.pan_in(job[selected][8:2]),.divider_in(job[selected][1:0]),
        .pcm_valid(),.pcm_tag(),.pcm_sample(),.decode_valid(),.decode_tag(),.decode_sample(),.decode_index(),
        .weight_valid(),.weight_tag(),.weight_left(),.weight_right(),.weight_postvol(),
        .decode_now(dn),.decode_now_tag(dtag),.decode_now_sample(ds),.decode_now_index(di),
        .weight_now(wn),.weight_now_tag(wtag),.weight_now_left(wl),.weight_now_right(wr),.weight_now_postvol(wp));
    always_ff @(posedge clk_2x)begin
        if(rst)begin issued<=0;db_valid<=0;wb_valid<=0;end
        else if(ce)begin
            for(integer n=0;n<CLIENTS;n=n+1)if(!request[n])issued[n]<=0;
            if(found)begin
                issued[selected]<=1;issued_tag[selected]<=selected_tag;
                db_valid[selected]<=0;wb_valid[selected]<=0;
            end
            if(dn)begin db_valid[dtag[23-:CW]]<=1;db_serial[dtag[23-:CW]]<=dtag[SW-1:0];db_sample[dtag[23-:CW]]<=ds;db_index[dtag[23-:CW]]<=di;end
            if(wn)begin wb_valid[wtag[23-:CW]]<=1;wb_serial[wtag[23-:CW]]<=wtag[SW-1:0];wb_left[wtag[23-:CW]]<=wl;wb_right[wtag[23-:CW]]<=wr;wb_postvol[wtag[23-:CW]]<=wp;end
        end
    end
    always_comb begin
        decode_valid=0;weight_valid=0;
        for(integer n=0;n<CLIENTS;n=n+1)begin
            decode_sample[n]=db_sample[n];decode_index[n]=db_index[n];
            weight_left[n]=wb_left[n];weight_right[n]=wb_right[n];weight_postvol[n]=wb_postvol[n];
            decode_valid[n]=db_valid[n] && db_serial[n]==job[n][46+:SW];
            weight_valid[n]=wb_valid[n] && wb_serial[n]==job[n][46+:SW];
            // Long runs of zero contributions can wrap a short serial without
            // issuing a job. An unissued new head must never see an old match.
            if(request[n] && (!issued[n] || issued_tag[n]!={CW'(n),job[n][45],job[n][46+:SW]}))begin
                decode_valid[n]=0;weight_valid[n]=0;
            end
            if(dn && dtag[23-:CW]==CW'(n) && dtag[SW-1:0]==job[n][46+:SW])begin
                decode_valid[n]=1;decode_sample[n]=ds;decode_index[n]=di;
            end
            if(wn && wtag[23-:CW]==CW'(n) && wtag[SW-1:0]==job[n][46+:SW])begin
                weight_valid[n]=1;weight_left[n]=wl;weight_right[n]=wr;weight_postvol[n]=wp;
            end
        end
    end
endmodule
