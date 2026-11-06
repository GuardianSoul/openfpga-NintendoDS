// Canonical records on SDRAM, outside MAIN's PSRAM channel. One eight-word
// packet is the existing transport quantum: payload[4], tag, ~tag, format, 0.
// A last scalar-write ACK is publication only after the write FIFO drains.
module nds_g3d_sd_records (
    input logic clk,rst,sp_ready,
    input logic p_req,p_we,
    input logic [22:2] p_addr,
    input logic [31:0] p_wdata,
    output logic p_ack,p_rvalid,p_rdone,
    output logic [31:0] p_rdata,
    output logic sw_req,
    output logic [23:0] sw_addr,
    output logic [31:0] sw_data,
    input logic sw_ack,sw_drained,
    output logic sr_req,
    output logic [23:0] sr_addr,
    input logic sr_ack,sr_valid,
    input logic [31:0] sr_data,
    output logic fault
);
    localparam logic [23:0] BASE_W=24'h1a0000;
    localparam logic [31:0] FORMAT=32'h47335344;
    typedef enum logic[2:0] {S_RESET,S_IDLE,S_COLLECT,S_TX,S_FENCE,S_READ_REQ,S_READ_DATA,S_ERROR} state_t;
    state_t state=S_RESET;
    logic [13:0] record_key;
    logic [1:0] collect_word;
    logic [2:0] wx,rx,quiet;
    logic [31:0] data_q,read_tag,read_inverse,read_format;
    wire [13:0] request_key={p_addr[20],p_addr[16:4]};
    wire [31:0] tag={16'hc4e0,record_key,2'b00};
    wire take_first=state==S_IDLE && p_req && p_we;
    wire take_next=state==S_COLLECT && p_req && p_we;
    wire payload_write=take_first || take_next;
    wire tx_take=sw_req && sw_ack;
    wire [2:0] tx_next=tx_take?wx+3'd1:wx;
    gpu3d_ram #(.W(32),.AW(3),.STYLE("M10K")) payload (
        .clk,.we(payload_write),.waddr({1'b0,take_first?2'd0:collect_word}),.wdata(p_wdata),
        .raddr({1'b0,tx_next[1:0]}),.rdata(data_q));
    assign sw_req=state==S_TX && !rst;
    assign sw_addr=BASE_W+{7'd0,record_key,3'd0}+24'(wx);
    always_comb case(wx)
        3'd4:sw_data=tag;
        3'd5:sw_data=~tag;
        3'd6:sw_data=FORMAT;
        3'd7:sw_data=0;
        default:sw_data=data_q;
    endcase
    assign sr_req=state==S_READ_REQ && !rst;
    assign sr_addr=BASE_W+{7'd0,record_key,3'd0};
    wire read_ok=read_tag==tag && read_inverse==~tag && read_format==FORMAT && sr_data==0;
    assign p_ack=!rst && ((take_first || take_next && collect_word!=2'd3) ||
        state==S_FENCE && quiet>=3'd3 && sw_drained && p_req ||
        sr_req && sr_ack);
    assign p_rvalid=state==S_READ_DATA && sr_valid && rx<3'd4 && !rst;
    assign p_rdata=sr_data;
    assign p_rdone=state==S_READ_DATA && sr_valid && rx==3'd7 && read_ok && !rst;
    always_ff @(posedge clk)begin
        if(rst)begin
            state<=S_RESET;record_key<='0;collect_word<='0;wx<='0;rx<='0;quiet<='0;
            read_tag<='0;read_inverse<='0;read_format<='0;fault<=1'b0;
        end else case(state)
            // Joint reset restarts SDRAM initialization. No new epoch may
            // accept a read until ready and the old FIFO/response path drain.
            S_RESET:begin
                if(!sp_ready || !sw_drained || sr_valid)quiet<='0;
                else if(quiet==3'd3)begin state<=S_IDLE;quiet<='0;end
                else quiet<=quiet+3'd1;
            end
            S_IDLE:if(p_req)begin
                record_key<=request_key;wx<='0;rx<='0;quiet<='0;
                if(p_we)begin collect_word<=2'd1;state<=S_COLLECT;end
                else state<=S_READ_REQ;
            end
            S_COLLECT:if(take_next)begin
                collect_word<=collect_word+2'd1;
                if(collect_word==2'd3)begin state<=S_TX;wx<='0;end
            end
            S_TX:if(tx_take)begin
                wx<=wx+3'd1;if(wx==3'd7)begin state<=S_FENCE;quiet<='0;end
            end
            S_FENCE:begin
                if(!sw_drained)quiet<='0;else if(quiet!=3'd7)quiet<=quiet+3'd1;
                if(p_ack)state<=S_IDLE;
            end
            S_READ_REQ:if(sr_req && sr_ack)begin state<=S_READ_DATA;rx<='0;end
            S_READ_DATA:if(sr_valid)begin
                rx<=rx+3'd1;
                if(rx==3'd4)read_tag<=sr_data;
                if(rx==3'd5)read_inverse<=sr_data;
                if(rx==3'd6)read_format<=sr_data;
                if(rx==3'd7)begin state<=read_ok?S_IDLE:S_ERROR;if(!read_ok)fault<=1'b1;end
            end
            default:state<=S_ERROR;
        endcase
    end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk)if(!rst)begin
        if(payload_write && (p_addr[3:2]!=(take_first?2'd0:collect_word) || take_next && request_key!=record_key))
            $fatal(1,"SD_RECORD_DESCRIPTOR_ORDER");
        if(sr_valid && state==S_READ_DATA && rx==3'd7 && !read_ok)$fatal(1,"SD_RECORD_STALE_OR_CORRUPT_RETURN");
        if(state==S_FENCE && p_req && (!p_we || request_key!=record_key || p_addr[3:2]!=2'd3))
            $fatal(1,"SD_RECORD_WRITE_OWNER_CHANGED");
    end
`endif
endmodule
