// Four parallel ways. Query port B never competes with tag invalidation or
// fill publication on the true-dual-port A side. Hits have one RAM clock;
// an obsolete miss always drains its physical response without publishing.
module nds_g3d_pair_cache #(
    parameter int SET_BITS = 7,
    parameter int ID_BITS = 11,
    parameter bit VERTEX = 0
) (
    input logic clk, rst, cancel,
    input logic f_req, f_bank,
    input logic [12:0] f_id,
    input logic [14:0] f_gen,
    output logic f_hit,
    output logic [127:0] f_data,
    input logic l_req, l_bank,
    input logic [12:0] l_id,
    input logic [14:0] l_gen,
    output logic l_take, l_valid, l_hit,
    output logic [127:0] l_data,
    input logic inv_valid, inv_bank,
    input logic [12:0] inv_id,
    output logic m_req,
    output logic [22:2] m_addr,
    input logic m_ack, m_valid, m_done,
    input logic [31:0] m_data
);
    localparam int TW = VERTEX ? 20 : 25;
    localparam int IQW = 14;
    localparam int LQW = SET_BITS + 2;
    logic clearing;
    logic [SET_BITS-1:0] clear_row;
    wire query_f = f_req && !clearing;
    assign l_take = l_req && !query_f && !clearing;
    wire query = query_f || l_take;
    wire query_bank = query_f ? f_bank : l_bank;
    wire [12:0] query_id = query_f ? f_id : l_id;
    wire [14:0] query_gen = query_f ? f_gen : l_gen;
    wire [SET_BITS-1:0] query_row = query_id[SET_BITS-1:0];
    logic q_valid, q_f, q_bank;
    logic [12:0] q_id;
    logic [14:0] q_gen;
    logic [SET_BITS-1:0] q_row;
    wire [4:0] q_high = {q_bank,q_id[ID_BITS-1:SET_BITS]};
    logic saved_hit;
    logic [127:0] saved_data;
    logic saved_bank;
    logic [12:0] saved_id;
    logic [83:0] a_q, b_q;
    logic last_tag_write;
    logic [SET_BITS-1:0] last_tag_row;
    logic [83:0] last_tag_data;
    wire [83:0] query_tags=last_tag_write && last_tag_row==q_row?last_tag_data:b_q;
    logic a_we;
    logic [83:0] a_data;
    logic [SET_BITS-1:0] a_addr;
    gpu3d_tdp #(.W(84), .AW(SET_BITS)) u_tags (
        .clk, .a_addr, .a_we, .a_d(a_data), .a_q,
        .b_addr(query_row), .b_q);
    logic [127:0] way_data [4];
    logic [3:0] hits;
    logic [1:0] hit_way;
    logic q_invalid, q_hit;
    logic [127:0] q_data;
    logic [IQW-1:0] inv_queue [4];
    logic [1:0] inv_rp, inv_wp;
    logic [2:0] inv_n;
    wire inv_push=inv_valid && !clearing;
    wire [13:0] inv_head = inv_queue[inv_rp];
    wire [4:0] inv_high = {inv_head[13],inv_head[ID_BITS-1:SET_BITS]};
    integer i;
    always_comb begin
        q_invalid = inv_valid && inv_bank == q_bank && inv_id == q_id;
        for (int k=0;k<4;k=k+1)
            if (3'(k) < inv_n && inv_queue[2'(inv_rp+2'(k))] == {q_bank,q_id}) q_invalid = 1'b1;
        hits = '0;
        for (int k=0;k<4;k=k+1)
            hits[k] = query_tags[k*21+20] && query_tags[k*21+5+:15] == q_gen && query_tags[k*21+:5] == q_high;
        hit_way = hits[0] ? 2'd0 : hits[1] ? 2'd1 : hits[2] ? 2'd2 : 2'd3;
        q_hit = q_valid && |hits && !q_invalid && !clearing;
        q_data = way_data[hit_way];
    end
    assign f_hit = q_valid && q_f ? q_hit : saved_hit;
    assign f_data = q_valid && q_f ? q_data : saved_data;
    assign l_valid = q_valid && !q_f;
    assign l_hit = q_hit;
    assign l_data = q_data;

    // Pairwise recency bits (a<b: one means a is newer than b).
    function automatic [5:0] touch(input logic [5:0] old, input logic [1:0] w);
        integer n;
        begin
            touch=old; n=0;
            for (int a=0;a<4;a=a+1) for (int b=a+1;b<4;b=b+1) begin
                if (w==2'(a)) touch[n]=1'b1;
                else if (w==2'(b)) touch[n]=1'b0;
                n=n+1;
            end
        end
    endfunction
    function automatic [1:0] oldest(input logic [5:0] rank);
        integer n;
        logic [3:0] newer;
        begin
            newer='0; n=0;
            for (int a=0;a<4;a=a+1) for (int b=a+1;b<4;b=b+1) begin
                if (rank[n]) newer[a]=1'b1; else newer[b]=1'b1;
                n=n+1;
            end
            oldest=!newer[0]?2'd0:!newer[1]?2'd1:!newer[2]?2'd2:2'd3;
        end
    endfunction
    logic [LQW-1:0] rank_queue [8];
    logic [2:0] rank_rp,rank_wp;
    logic [3:0] rank_n;
    wire rank_pop=rank_n!=0 && !clearing;
    wire hit_touch=q_hit;
    logic fill_touch;
    logic [5:0] rank_q;
    logic [SET_BITS-1:0] miss_row;
    logic [1:0] miss_way;
    wire [SET_BITS-1:0] rank_row=rank_pop ? rank_queue[rank_rp][LQW-1:2] : miss_row;
    wire [1:0] rank_way=rank_queue[rank_rp][1:0];
    // Only the small replacement state is combinational; tags/data remain
    // registered M10K. A two-push queue serializes hit/fill recency updates.
    gpu3d_lram #(.W(6), .AW(SET_BITS)) u_lru (
        .clk, .we(clearing || rank_pop), .waddr(clearing?clear_row:rank_row),
        .wdata(clearing?6'd0:touch(rank_q,rank_way)), .raddr(rank_row), .rdata(rank_q));

    typedef enum logic [2:0] {C_IDLE,C_SELECT,C_RESERVE,C_REQ,C_FILL,C_DRAIN,C_PUBLISH} cst_t;
    cst_t cst;
    logic miss_bank,wanted;
    logic [12:0] miss_id;
    logic [14:0] miss_gen;
    logic [3:0] miss_invalid;
    logic [1:0] beat;
    wire invalidate_miss=inv_valid && inv_bank==miss_bank && inv_id==miss_id;
    wire publish_wanted=wanted && !invalidate_miss && !cancel;
    wire [4:0] miss_high={miss_bank,miss_id[ID_BITS-1:SET_BITS]};
    wire [12:0] record_index=VERTEX?13'h0800+miss_id:miss_id;
    assign m_addr={2'b10,miss_bank,3'd0,record_index,2'd0};
    assign m_req=cst==C_REQ && !rst;
    genvar w,k;
    generate if (!VERTEX && SET_BITS == 7) begin : g_header_pack
        // A reserved way is invalid before its first payload word arrives.
        // Retain those first 89 useful bits until word 3, then commit the
        // complete 121-bit header on the same last-payload edge as before.
        // Validation/publication still waits for the original m_done path.
        logic [88:0] prefix;
        wire filling = cst == C_FILL && m_valid;
        always_ff @(posedge clk) if (filling) begin
            case (beat)
                2'd0: prefix[31:0] <= m_data;
                2'd1: prefix[63:32] <= m_data;
                2'd2: prefix[88:64] <= {m_data[31:19],m_data[11:0]};
                default: begin end
            endcase
        end
        logic [519:0] packed_q;
        nds_g3d_header_data #(.AW(SET_BITS)) u_data (
            .clk, .we(filling && beat == 2'd3), .way(miss_way),
            .waddr(miss_row), .wdata({m_data,prefix}),
            .raddr(query_row), .rdata(packed_q));
        for (w=0;w<4;w=w+1) begin : g_way
            wire [120:0] header_q = packed_q[w*130 +: 121];
            assign way_data[w] = {header_q[88:76],7'd0,header_q[75:64],
                                  header_q[120:89],header_q[63:0]};
        end
    end else begin : g_separate_data
    for (w=0;w<4;w=w+1) begin : g_way
        logic [31:0] lane [4];
        for (k=0;k<4;k=k+1) begin : g_lane
            if (k==2) begin : g_tail
                logic [TW-1:0] packed_q;
                wire [TW-1:0] packed_d=VERTEX?TW'(m_data[19:0]):TW'({m_data[31:19],m_data[11:0]});
                gpu3d_ram #(.W(TW),.AW(SET_BITS),.STYLE("M10K")) u_data (
                    .clk,.we(cst==C_FILL && m_valid && miss_way==2'(w) && beat==2'(k)),
                    .waddr(miss_row),.wdata(packed_d),.raddr(query_row),.rdata(packed_q));
                if (VERTEX) assign lane[k]={12'd0,packed_q};
                else assign lane[k]={packed_q[24:12],7'd0,packed_q[11:0]};
            end else begin : g_full
                gpu3d_ram #(.W(32),.AW(SET_BITS),.STYLE("M10K")) u_data (
                    .clk,.we(cst==C_FILL && m_valid && miss_way==2'(w) && beat==2'(k)),
                    .waddr(miss_row),.wdata(m_data),.raddr(query_row),.rdata(lane[k]));
            end
        end
        assign way_data[w]={lane[2],lane[3],lane[1],lane[0]};
    end
    end endgenerate
    // Two-clock port-A RMW. The query port sees OLD_DATA on a collision;
    // the direct/current invalidate guard above also excludes that hit.
    typedef enum logic [1:0] {A_IDLE,A_WRITE} ast_t;
    ast_t ast;
    typedef enum logic [1:0] {A_INV,A_RESERVE,A_FILL} aop_t;
    aop_t aop;
    logic [SET_BITS-1:0] a_row;
    logic [4:0] a_high;
    logic [1:0] a_way;
    wire choose_inv=inv_n!=0;
    wire choose_reserve=!choose_inv && cst==C_RESERVE;
    wire choose_fill=!choose_inv && !choose_reserve && cst==C_PUBLISH;
    wire reserve_done=ast==A_WRITE && aop==A_RESERVE && !clearing;
    wire fill_done=ast==A_WRITE && aop==A_FILL && !clearing;
    wire inv_pop=ast==A_WRITE && aop==A_INV && !clearing;
    assign fill_touch=fill_done && publish_wanted;
    always_comb begin
        a_addr=ast==A_WRITE?a_row:choose_inv?inv_head[SET_BITS-1:0]:miss_row;
        a_we=ast==A_WRITE;
        a_data=a_q;
        for (int j=0;j<4;j=j+1) begin
            if (aop==A_INV && a_q[j*21+:5]==a_high) a_data[j*21+20]=1'b0;
            if (aop==A_RESERVE && a_way==2'(j)) a_data[j*21+20]=1'b0;
            if (aop==A_FILL && a_way==2'(j)) a_data[j*21+:21]={publish_wanted,miss_gen,miss_high};
        end
        if (clearing) begin a_addr=clear_row;a_we=1'b1;a_data='0;end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            clearing<=1'b1;clear_row<='0;q_valid<=1'b0;q_f<=1'b0;q_bank<=1'b0;q_id<='0;q_gen<='0;q_row<='0;
            saved_hit<=1'b0;saved_data<='0;saved_bank<=1'b0;saved_id<='0;inv_rp<='0;inv_wp<='0;inv_n<='0;
            rank_rp<='0;rank_wp<='0;rank_n<='0;cst<=C_IDLE;ast<=A_IDLE;aop<=A_INV;
            a_row<='0;a_high<='0;a_way<='0;miss_row<='0;miss_way<='0;miss_bank<=1'b0;
            miss_id<='0;miss_gen<='0;miss_invalid<='0;wanted<=1'b0;beat<='0;
            last_tag_write<=1'b0;last_tag_row<='0;last_tag_data<='0;
        end else begin
            last_tag_write<=a_we;last_tag_row<=a_addr;last_tag_data<=a_data;
            if (clearing) begin clear_row<=clear_row+1'b1;if (&clear_row) clearing<=1'b0;end
            q_valid<=query;q_f<=query_f;q_bank<=query_bank;q_id<=query_id;q_gen<=query_gen;q_row<=query_row;
            if (q_valid && q_f) begin saved_hit<=q_hit;saved_data<=q_data;saved_bank<=q_bank;saved_id<=q_id;end
            if (cancel || (inv_valid && inv_bank==(q_valid && q_f?q_bank:saved_bank) &&
                          inv_id==(q_valid && q_f?q_id:saved_id))) saved_hit<=1'b0;
            if (inv_push) begin inv_queue[inv_wp]<={inv_bank,inv_id};inv_wp<=inv_wp+2'd1;end
            if (inv_pop) inv_rp<=inv_rp+2'd1;
            inv_n<=inv_n+3'(inv_push)-3'(inv_pop);
            if (hit_touch) rank_queue[rank_wp]<={q_row,hit_way};
            if (fill_touch) rank_queue[3'(rank_wp+3'(hit_touch))]<={miss_row,miss_way};
            rank_wp<=rank_wp+3'(hit_touch)+3'(fill_touch);
            if (rank_pop) rank_rp<=rank_rp+3'd1;
            rank_n<=rank_n+4'(hit_touch)+4'(fill_touch)-4'(rank_pop);
            if (cancel || invalidate_miss) wanted<=1'b0;
            if (!clearing) begin
                case (ast)
                    A_IDLE: if (choose_inv || choose_reserve || choose_fill) begin
                        a_row<=choose_inv?inv_head[SET_BITS-1:0]:miss_row;
                        a_high<=inv_high;a_way<=miss_way;
                        aop<=choose_inv?A_INV:choose_reserve?A_RESERVE:A_FILL;ast<=A_WRITE;
                    end
                    default:ast<=A_IDLE;
                endcase
                case (cst)
                    C_IDLE:if (q_valid && !q_hit && !cancel) begin
                        miss_bank<=q_bank;miss_id<=q_id;miss_gen<=q_gen;miss_row<=q_row;
                        for (int j=0;j<4;j=j+1) miss_invalid[j]<=!query_tags[j*21+20];
                        wanted<=!(inv_valid && inv_bank==q_bank && inv_id==q_id);cst<=C_SELECT;
                    end
                    C_SELECT:if (rank_n==0 && !hit_touch && ast==A_IDLE && inv_n==0) begin
                        miss_way<=miss_invalid[0]?2'd0:miss_invalid[1]?2'd1:miss_invalid[2]?2'd2:miss_invalid[3]?2'd3:oldest(rank_q);
                        cst<=C_RESERVE;
                    end
                    C_RESERVE:if (reserve_done)cst<=C_REQ;
                    C_REQ:if(m_ack)begin beat<='0;cst<=C_FILL;end
                    C_FILL:if(m_valid)begin beat<=beat+2'd1;if(beat==2'd3)cst<=m_done?C_PUBLISH:C_DRAIN;end
                    C_DRAIN:if(m_done)cst<=C_PUBLISH;
                    default:if(fill_done)cst<=C_IDLE;
                endcase
            end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if (!rst) begin
        if (inv_n>3'd4 || rank_n>4'd8) $fatal(1,"pair cache: invalidation/recency ownership overflow");
        if (m_valid && cst!=C_FILL) $fatal(1,"pair cache: response without captured owner");
        if (query && !VERTEX && query_id>=13'd2048) $fatal(1,"pair cache: header ID overflow");
    end
`endif
endmodule

// Four 121-bit headers at one query address. Each way occupies thirteen
// native 10-bit bytes, so a whole-way write needs neither a read/modify/write
// nor another memory port. 520 read bits use thirteen x40 M10K columns at
// 128 rows, versus sixteen separately rounded payload lanes. The mixed-port
// OLD_DATA contract also preserves a simultaneous hit in another way.
// Adapted from gpu3d_ram_be2's native byte-enable structure; its DONT_CARE
// collision mode cannot be used for this shared query row.
module nds_g3d_header_data #(
    parameter int AW = 7
) (
    input logic clk, we,
    input logic [1:0] way,
    input logic [AW-1:0] waddr, raddr,
    input logic [120:0] wdata,
    output logic [519:0] rdata
);
    wire [129:0] padded = {9'd0,wdata};
    wire [519:0] data = {4{padded}};
    logic [51:0] mask;
    always_comb begin
        mask = '0;
        for (int j=0;j<4;j=j+1)
            mask[j*13 +: 13] = {13{we && way == 2'(j)}};
    end
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode                     ("DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (520),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (520),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .width_byteena_a                    (52),
        .byte_size                          (10),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .rdcontrol_reg_b                    ("CLOCK0"),
        .address_aclr_b                     ("NONE"),
        .outdata_aclr_b                     ("NONE"),
        .read_during_write_mode_mixed_ports ("OLD_DATA"),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0(clk), .wren_a(we), .address_a(waddr), .data_a(data),
        .byteena_a(mask), .address_b(raddr), .q_b(rdata)
    );
`else
    logic [519:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        for (int j=0;j<52;j=j+1)
            if (mask[j]) mem[waddr][j*10 +: 10] <= data[j*10 +: 10];
        rdata <= mem[raddr];
    end
`endif
endmodule
