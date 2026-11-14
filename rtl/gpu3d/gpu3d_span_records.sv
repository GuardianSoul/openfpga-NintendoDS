// Four immutable records. Existing queue/early/late boundaries own the leases.
module gpu3d_span_records #(
    parameter logic [$bits(gpu3d_pkg::span_t)-1:0] EARLY_MASK='1,
    parameter logic [$bits(gpu3d_pkg::span_t)-1:0] LATE_MASK='1,
    parameter logic [$bits(gpu3d_pkg::span_t)-1:0] TAIL_MASK='1
) (
    input logic clk,rst,publish,load,late_take,tail_take,queued_valid,
    input gpu3d_pkg::span_t publish_data,
    output gpu3d_pkg::span_t early_data,late_data,tail_data,
    output logic queued_lp
);
    localparam int W=$bits(gpu3d_pkg::span_t);
    logic [1:0] next_owner,cur_owner,late_owner,tail_owner;
    logic cur_valid,late_valid,tail_valid;
    logic [3:0] free_mask;
    logic [1:0] free_owner;
    always_comb begin
        for(int i=0;i<4;i++)free_mask[i]=
            !(cur_valid&&cur_owner==2'(i))&&!(late_valid&&late_owner==2'(i))&&
            !(tail_valid&&tail_owner==2'(i))&&!(queued_valid&&next_owner==2'(i));
        free_owner=free_mask[0]?2'd0:free_mask[1]?2'd1:free_mask[2]?2'd2:2'd3;
    end
    wire [1:0] early_owner=load?next_owner:cur_owner;
    // Separate single-read stores use the exact FE0 wrapper that inferred
    // LUTRAM in2189. No multi-read-array inference is required.
    gpu3d_span_view #(.MASK(EARLY_MASK)) u_early(.clk,.we(publish&&!rst),
        .waddr(free_owner),.wdata(publish_data),.raddr(early_owner),
        .read_needed(cur_valid||load),.rdata(early_data));
    gpu3d_span_view #(.MASK(LATE_MASK)) u_late(.clk,.we(publish&&!rst),
        .waddr(free_owner),.wdata(publish_data),.raddr(late_owner),
        .read_needed(late_valid),.rdata(late_data));
    gpu3d_span_view #(.MASK(TAIL_MASK)) u_tail(.clk,.we(publish&&!rst),
        .waddr(free_owner),.wdata(publish_data),.raddr(tail_owner),
        .read_needed(tail_valid),.rdata(tail_data));
    always_ff @(posedge clk)begin
        if(rst)begin
            next_owner<=0;cur_owner<=0;late_owner<=0;tail_owner<=0;
            cur_valid<=0;late_valid<=0;tail_valid<=0;queued_lp<=0;
        end else begin
            if(publish)begin next_owner<=free_owner;queued_lp<=publish_data.lp;end
            if(load)begin cur_owner<=next_owner;cur_valid<=1;end
            if(late_take)begin late_owner<=cur_owner;late_valid<=cur_valid;end
            if(tail_take)begin tail_owner<=late_owner;tail_valid<=late_valid;end
        end
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    always_ff @(posedge clk)if(!rst)begin
        if(publish&&(queued_valid||load||free_mask==0))$fatal(1,"SPAN_RECORD_NO_FREE_OR_PUBLICATION_COLLISION");
        if(load&&!queued_valid)$fatal(1,"SPAN_RECORD_LOAD_WITHOUT_QUEUE");
        if(publish&&((cur_valid&&free_owner==cur_owner)||(late_valid&&free_owner==late_owner)||
                     (tail_valid&&free_owner==tail_owner)))$fatal(1,"SPAN_RECORD_LIVE_OVERWRITE");
    end
    // synthesis translate_on
`endif
endmodule

// Constant wiring projects one view before RAM inference. The physical RAM
// width is explicit, rather than depending on downstream removal of fields.
module gpu3d_span_view #(
    parameter logic [$bits(gpu3d_pkg::span_t)-1:0] MASK='1
) (
    input logic clk,we,
    input logic [1:0] waddr,raddr,
    input gpu3d_pkg::span_t wdata,
    input logic read_needed,
    output gpu3d_pkg::span_t rdata
);
    localparam int SW=$bits(gpu3d_pkg::span_t);
    function automatic integer bits_in(input logic [SW-1:0] m);
        integer n;
        n=0;for(integer b=0;b<SW;b=b+1)if(m[b])n=n+1;
        return n;
    endfunction
    localparam int NB=bits_in(MASK);
    localparam int PW=NB>0?NB:1;
    logic [PW-1:0] packed_data,packed_q;
    logic [SW-1:0] input_bits,output_bits;
    assign input_bits=wdata;
    assign rdata=output_bits;
    function automatic integer before_bit(input integer limit);
        integer n;
        n=0;for(integer b=0;b<SW;b=b+1)if(b<limit&&MASK[b])n=n+1;
        return n;
    endfunction
    genvar b;
    generate for(b=0;b<SW;b=b+1)begin:g_bit
        if(MASK[b])begin:g_keep
            localparam integer P=before_bit(b);
            assign packed_data[P]=input_bits[b];
            assign output_bits[b]=packed_q[P];
        end else begin:g_zero
            assign output_bits[b]=1'b0;
        end
    end
    if(NB==0)begin:g_empty
        assign packed_data='0;
    end endgenerate
`ifdef ALTERA_RESERVED_QIS
    // Explicit LUTRAM prevents a shallow/multiple-view store from silently
    // becoming flops. Same 1W/async-read contract as gpu3d_lram FE0.
    altdpram #(.width(PW),.widthad(2),.numwords(4),.ram_block_type("LUTRAM"),
        .intended_device_family("Cyclone V"),.indata_reg("INCLOCK"),.indata_aclr("OFF"),
        .wraddress_reg("INCLOCK"),.wraddress_aclr("OFF"),.wrcontrol_reg("INCLOCK"),.wrcontrol_aclr("OFF"),
        .rdaddress_reg("UNREGISTERED"),.rdaddress_aclr("OFF"),.rdcontrol_reg("UNREGISTERED"),.rdcontrol_aclr("OFF"),
        .outdata_reg("UNREGISTERED"),.outdata_aclr("OFF"),.lpm_type("altdpram"))u_ram(
        .inclock(clk),.inclocken(1'b1),.outclock(1'b0),.outclocken(1'b1),.wren(we),.rden(1'b1),
        .wraddress(waddr),.rdaddress(raddr),.data(packed_data),.byteena(1'b1),.aclr(1'b0),.sclr(1'b0),
        .wraddressstall(1'b0),.rdaddressstall(1'b0),.q(packed_q));
`else
    gpu3d_lram #(.W(PW),.AW(2),.FE(1'b0)) u_ram(
        .clk,.we,.waddr,.wdata(packed_data),.raddr,.rdata(packed_q));
`endif
`ifndef SYNTHESIS
    // synthesis translate_off
    always_ff @(posedge clk)if(we&&read_needed&&NB!=0&&waddr==raddr)
        $fatal(1,"SPAN_VIEW_QUALIFIED_COLLISION");
    // synthesis translate_on
`endif
endmodule
