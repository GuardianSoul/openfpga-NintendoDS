// Experimental complete logical write queue. Payloads leave the bounded
// ingress through the existing SDRAM block transport, then retire only at
// the fourth durable scalar write to the canonical PSRAM record address.
module nds_g3d_journal (
    input logic clk, rst,
    input logic po_valid, po_type,
    input logic [10:0] po_index,
    input logic po_wv,
    input logic [1:0] po_wk,
    input logic [31:0] po_wd,
    input logic so_done,
    output logic po_ready, wb,
    output logic [14:0] queued, publish_left, publication,
    output logic [14:0] committed_tail,
    output logic [12:0] next_vertex,
    output logic wr_req, wr_last,
    output logic [22:2] wr_addr,
    output logic [31:0] wr_data,
    input logic wr_ack,
    output logic jw_req,
    output logic [23:0] jw_addr,
    output logic [31:0] jw_data,
    input logic jw_ack, jw_drained,
    output logic jr_req,
    output logic [23:0] jr_addr,
    input logic jr_ack, jr_valid,
    input logic [31:0] jr_data,
    output logic early_stall
);
    localparam logic [23:0] BASE_W = 24'h180000;
    localparam logic [31:0] FORMAT = 32'h4e445357;
    logic [14:0] tail, copied, sent, safe, head;
    logic [12:0] vptr;
    logic [1:0] sealed;
    logic [27:0] construction_meta [2];
    logic copy_on;
    logic [1:0] copy_word;
    wire commit = po_valid && po_ready;
    wire retire = wr_req && wr_last && wr_ack;
    assign queued = tail - head;
    assign committed_tail = tail;
    assign next_vertex = vptr;
    wire [14:0] ingress_used = tail - sent;
    wire logical_credit = queued < 15'd16382;
    assign po_ready = !rst && logical_credit && ingress_used < 15'd1024 && !copy_on &&
                      !sealed[tail[0]] && !sealed[!tail[0]];
    assign early_stall = po_valid && logical_credit && !po_ready && !rst;
    wire [12:0] record_key = po_type ? vptr : {2'd0, po_index};
    wire [27:0] meta_in = {wb, po_type, record_key, vptr};
    wire copy_start = commit && !copy_on;
    wire copy_we = copy_on || copy_start;
    wire [1:0] copy_index = copy_on ? copy_word : 2'd0;
    wire [1:0] copy_next = copy_on ? copy_word + 2'd1 : copy_start ? 2'd1 : 2'd0;
    wire [1:0] logical_next = {copy_next[1], copy_next[1] ^ copy_next[0]};
    wire construction_read_bank = copy_on && copy_word == 2'd3 ? !copied[0] : copied[0];
    logic [31:0] construction_q;
    gpu3d_ram #(.W(32), .AW(3), .STYLE("M10K")) u_construct (
        .clk, .we(po_wv), .waddr({tail[0],po_wk}), .wdata(po_wd),
        .raddr({construction_read_bank,logical_next}), .rdata(construction_q));
    wire [27:0] copy_meta = construction_meta[copied[0]];
    wire [31:0] copy_data = copy_index == 2'd2 && !copy_meta[26]
                         ? {copy_meta[12:0],7'd0,construction_q[11:0]} : construction_q;
    wire copy_last = copy_on && copy_word == 2'd3;
    logic tx_on;
    logic [2:0] tx_word;
    wire tx_advance = jw_req && jw_ack;
    wire tx_last = tx_advance && tx_word == 3'd7;
    wire [2:0] tx_next = tx_advance ? tx_word + 3'd1 : tx_word;
    logic [31:0] ingress_q;
    logic [27:0] ingress_meta;
    gpu3d_ram #(.W(32), .AW(12), .STYLE("M10K")) u_ingress (
        .clk, .we(copy_we), .waddr({copied[9:0],copy_index}), .wdata(copy_data),
        .raddr({sent[9:0],tx_next[1:0]}), .rdata(ingress_q));
    gpu3d_ram #(.W(28), .AW(10), .STYLE("M10K")) u_metadata (
        .clk, .we(copy_last), .waddr(copied[9:0]), .wdata(copy_meta),
        .raddr(sent[9:0]), .rdata(ingress_meta));
    wire [31:0] tx_tag = {1'b0,sent,ingress_meta[27:26],ingress_meta[25:13],1'b0};
    assign jw_req = tx_on && !rst;
    assign jw_addr = BASE_W + {7'd0,sent[13:0],3'd0} + {21'd0,tx_word};
    always_comb begin
        case (tx_word)
            3'd4: jw_data = tx_tag;
            3'd5: jw_data = ~tx_tag;
            3'd6: jw_data = FORMAT;
            3'd7: jw_data = 32'd0;
            default: jw_data = ingress_q;
        endcase
    end
    // A block accepted into the shared write transport is not durable.
    // Stop after seven unsafe blocks, then wait for an observed empty path
    // with no journal word in flight and a complete quiet crossing window.
    logic [2:0] quiet;
    wire [14:0] unsafe_blocks = sent - safe;
    logic rx_request, rx_active, replay;
    logic [2:0] rx_word;
    logic [31:0] rx_tag, rx_inverse, rx_format;
    logic [1:0] write_word;
    wire [1:0] write_next = wr_ack && wr_req ? write_word + 2'd1 : write_word;
    logic [31:0] replay_q;
    gpu3d_ram #(.W(32), .AW(4), .STYLE("M10K")) u_replay (
        .clk, .we(rx_active && jr_valid), .waddr({1'b0,rx_word}), .wdata(jr_data),
        .raddr({2'd0,write_next}), .rdata(replay_q));
    assign jr_req = rx_request && !rst;
    assign jr_addr = BASE_W + {7'd0,head[13:0],3'd0};
    assign wr_req = replay && !rst;
    assign wr_last = write_word == 2'd3;
    wire [12:0] replay_key = rx_tag[13:1];
    wire [12:0] canonical_index = rx_tag[14] ? 13'h0800 + replay_key : replay_key;
    assign wr_addr = {2'b10,rx_tag[15],3'd0,canonical_index,write_word};
    assign wr_data = replay_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            tail <= '0; copied <= '0; sent <= '0; safe <= '0; head <= '0;
            wb <= 1'b0; vptr <= '0; sealed <= '0; copy_on <= 1'b0; copy_word <= '0;
            tx_on <= 1'b0; tx_word <= '0; quiet <= '0;
            rx_request <= 1'b0; rx_active <= 1'b0; rx_word <= '0; replay <= 1'b0; write_word <= '0;
            rx_tag <= '0; rx_inverse <= '0; rx_format <= '0; publish_left <= '0; publication <= '0;
        end else begin
            if (commit) begin
                construction_meta[tail[0]] <= meta_in;
                sealed[tail[0]] <= 1'b1;
                tail <= tail + 15'd1;
                if (po_type) vptr <= vptr + 13'd1;
            end
            if (!copy_on) begin
                copy_word <= '0;
                if (copy_start) begin copy_on <= 1'b1; copy_word <= 2'd1; end
            end else begin
                copy_word <= copy_word + 2'd1;
                if (copy_last) begin
                    copy_on <= 1'b0; copied <= copied + 15'd1; sealed[copied[0]] <= 1'b0;
                end
            end
            if (!tx_on) begin
                tx_word <= '0;
                if (sent != copied && unsafe_blocks < 15'd7) tx_on <= 1'b1;
            end else if (tx_advance) begin
                tx_word <= tx_word + 3'd1;
                if (tx_last) begin tx_on <= 1'b0; sent <= sent + 15'd1; end
            end
            if (jw_req || !jw_drained) quiet <= '0;
            else if (quiet != 3'd7) quiet <= quiet + 3'd1;
            if (!tx_on && jw_drained && quiet >= 3'd3) safe <= sent;
            if (!rx_request && !rx_active && !replay && head != safe) rx_request <= 1'b1;
            if (jr_req && jr_ack) begin rx_request <= 1'b0; rx_active <= 1'b1; rx_word <= '0; end
            if (rx_active && jr_valid) begin
                rx_word <= rx_word + 3'd1;
                if (rx_word == 3'd4) rx_tag <= jr_data;
                if (rx_word == 3'd5) rx_inverse <= jr_data;
                if (rx_word == 3'd6) rx_format <= jr_data;
                if (rx_word == 3'd7) begin rx_active <= 1'b0; replay <= 1'b1; write_word <= '0; end
            end
            if (wr_req && wr_ack) begin
                write_word <= write_word + 2'd1;
                if (wr_last) begin replay <= 1'b0; head <= head + 15'd1; end
            end
            if (so_done) begin
                wb <= !wb; vptr <= '0; publication <= tail + 15'(commit);
                publish_left <= queued + 15'(commit) - 15'(retire);
            end else if (retire && publish_left != 0) publish_left <= publish_left - 15'd1;
        end
    end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if (!rst) begin
        if (po_wv && sealed[tail[0]]) $fatal(1,"pair journal: construction bank overwritten");
        if (queued > 15'd16382 || ingress_used > 15'd1024 || unsafe_blocks > 15'd7)
            $fatal(1,"pair journal: logical/physical credit overflow");
        if (rx_active && jr_valid && rx_word == 3'd7 &&
            (rx_tag[30:16] != head || rx_tag[31] || rx_tag[0] || rx_inverse != ~rx_tag || rx_format != FORMAT || jr_data != 0))
            $fatal(1,"pair journal: stale/corrupt descriptor at sequence %0d",head);
    end
`endif
endmodule
