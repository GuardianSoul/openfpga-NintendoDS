// core_bridge_cmd_lean equivalence: this tree's handler against REF's on the APF's legal traffic (random host
// commands with parameters, target commands answered "bu" then "ok" + an error code, reads of every register and the
// data table). Everything the core uses and every read answer is compared each clock; the RTC's words once valid.
`timescale 1ns/1ps
module tb_cmd_eq;
    reg clk = 0; always #5 clk = !clk;
    reg [31:0] addr = 0, wdata = 0;
    reg rd = 0, wr = 0;
    reg boot_done = 1, setup_done = 0, running = 0, rq_ack = 0, rq_ok = 1, wq_ack = 0, wq_ok = 1, tgt_read = 0;
    reg [31:0] tgt_off = 0, tgt_bridge = 0, tgt_len = 0;
    reg [9:0] dt_addr = 0; reg dt_wren = 0; reg [31:0] dt_data = 0;
    `define SIDE(S, M) \
        wire [31:0] rdata_``S, dtq_``S, date_``S, time_``S; \
        wire rst_``S, rq_``S, rtc_``S, allc_``S, upd_``S, ack_``S, done_``S, menu_``S; \
        wire [15:0] rqid_``S, updid_``S; wire [2:0] err_``S; \
        M u_``S (.clk(clk), .reset_n(rst_``S), .bridge_endian_little(1'b0), .bridge_addr(addr), .bridge_rd(rd), .bridge_rd_data(rdata_``S), \
            .bridge_wr(wr), .bridge_wr_data(wdata), .status_boot_done(boot_done), .status_setup_done(setup_done), .status_running(running), \
            .dataslot_requestread(rq_``S), .dataslot_requestread_id(rqid_``S), .dataslot_requestread_ack(rq_ack), .dataslot_requestread_ok(rq_ok), \
            .dataslot_requestwrite(), .dataslot_requestwrite_id(), .dataslot_requestwrite_size(), .dataslot_requestwrite_ack(wq_ack), .dataslot_requestwrite_ok(wq_ok), \
            .dataslot_update(upd_``S), .dataslot_update_id(updid_``S), .dataslot_update_size(), .dataslot_allcomplete(allc_``S), \
            .rtc_epoch_seconds(), .rtc_date_bcd(date_``S), .rtc_time_bcd(time_``S), .rtc_valid(rtc_``S), \
            .savestate_supported(1'b0), .savestate_addr(32'b0), .savestate_size(32'b0), .savestate_maxloadsize(32'b0), .osnotify_inmenu(menu_``S), \
            .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0), \
            .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0), \
            .target_dataslot_read(tgt_read), .target_dataslot_write(1'b0), .target_dataslot_getfile(1'b0), .target_dataslot_openfile(1'b0), \
            .target_dataslot_ack(ack_``S), .target_dataslot_done(done_``S), .target_dataslot_err(err_``S), .target_dataslot_id(16'd1), \
            .target_dataslot_slotoffset(tgt_off), .target_dataslot_bridgeaddr(tgt_bridge), .target_dataslot_length(tgt_len), \
            .target_buffer_param_struct(32'b0), .target_buffer_resp_struct(32'b0), \
            .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dtq_``S));
    `SIDE(n, core_bridge_cmd_lean)
    `SIDE(r, core_bridge_cmd_lean_ref)
    integer bad = 0, seed = 1, n_cmd = 0, n_tgt = 0, n_rd = 0;
    reg started = 0;
    wire [147:0] on = {rst_n, rq_n, rqid_n, allc_n, upd_n, updid_n, rtc_n, ack_n, done_n, err_n, menu_n, rdata_n, dtq_n, rtc_n ? {date_n, time_n} : 64'd0};
    wire [147:0] or_ = {rst_r, rq_r, rqid_r, allc_r, upd_r, updid_r, rtc_r, ack_r, done_r, err_r, menu_r, rdata_r, dtq_r, rtc_r ? {date_r, time_r} : 64'd0};
    always @(negedge clk) if (started && on !== or_) begin
        bad = bad + 1;
        if (bad <= 5) $display("%0t: differ new %h ref %h (addr %h)", $time, on, or_, addr);
    end
    task automatic write(input [31:0] a, input [31:0] d);
        @(negedge clk); addr = a; wdata = d; wr = 1; @(negedge clk); wr = 0;
    endtask
    task automatic read(input [31:0] a);
        @(negedge clk); addr = a; rd = 1; @(negedge clk); rd = 0; n_rd = n_rd + 1; @(negedge clk);
    endtask
    function automatic [31:0] pick(); pick = $random(seed); endfunction
    task automatic host(input [15:0] c);
        write(32'hF800_0020, pick() & (c == 16'h00A0 || c == 16'h00A4 ? 32'hFFFFFFFE : 32'hFFFFFFFF)); write(32'hF800_0024, pick()); write(32'hF800_0028, pick()); write(32'hF800_002C, pick());
        write(32'hF800_0000, {16'h434D, c});
        read(32'hF800_0000);
        if (c == 16'h0080 || c == 16'h0082) begin
            repeat (pick() % 16) @(negedge clk);
            read(32'hF800_0000);
            rq_ok = pick(); wq_ok = rq_ok; rq_ack = 1; wq_ack = 1; repeat (6) @(negedge clk); rq_ack = 0; wq_ack = 0;
        end
        begin : poll
            forever begin read(32'hF800_0000); if (rdata_r[31:16] == 16'h4F4B) disable poll; end
        end
        n_cmd = n_cmd + 1;
    endtask
    // the APF answering a target command: it polls for "cm", reads the parameters, "bu", then "ok" + a code
    task automatic answer();
        reg [2:0] code;
        begin : poll
            forever begin read(32'hF800_1000); if (rdata_r[31:16] == 16'h636D) disable poll; end
        end
        read(32'hF800_1004); read(32'hF800_1008); read(32'hF800_1020); read(32'hF800_1024); read(32'hF800_1028); read(32'hF800_102C);
        write(32'hF800_1000, 32'h6275_0000); repeat (pick() % 8) @(negedge clk); read(32'hF800_1000);
        code = pick();
        write(32'hF800_1000, {16'h6F6B, 13'd0, code}); read(32'hF800_1000); n_tgt = n_tgt + 1;
    endtask
    static reg [15:0] cmds [0:11] = '{16'h0000, 16'h0010, 16'h0011, 16'h0080, 16'h0082, 16'h008A, 16'h008F, 16'h0090, 16'h00A0, 16'h00A4, 16'h00B0, 16'h1234};
    initial begin #400ms; $display("FAIL: timeout, %0d host, %0d target, %0d differing", n_cmd, n_tgt, bad); $finish; end
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        repeat (10) @(negedge clk);
        host(16'h0000); write(32'hF800_1000, 32'h6F6B_0000);
        started = 1;
        setup_done = 1; answer(); setup_done = 0;
        repeat (3000) begin
            case (pick() % 8)
                0, 1, 2, 3: host(cmds[pick() % 12]);
                4: begin tgt_off = pick(); tgt_bridge = pick(); tgt_len = pick(); tgt_read = 1; repeat (2) @(negedge clk); tgt_read = 0; answer(); end
                5: begin read(32'hF800_0000 | ((pick() % 20) << 2)); read(32'hF800_1000 | ((pick() % 20) << 2)); end
                6: begin write(32'hF800_2000 | ((pick() % 256) << 2), pick()); read(32'hF800_2000 | ((pick() % 256) << 2)); end
                7: begin boot_done = pick(); running = pick(); setup_done = 0; dt_addr = pick(); dt_data = pick(); dt_wren = pick(); @(negedge clk); dt_wren = 0; end
            endcase
        end
        repeat (10) @(negedge clk);
        $display("%s: %0d host commands, %0d target commands, %0d reads, %0d differing clocks", bad ? "FAIL" : "PASS", n_cmd, n_tgt, n_rd, bad);
        $finish;
    end
endmodule
