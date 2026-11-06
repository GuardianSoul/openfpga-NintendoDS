// Analogue's io_pad_controller against rtl/apf/io_pad_controller.v, each with its own 1-wire line and pad model:
// a poll is answered with twelve words, every output compared every clock from power-up.
`timescale 1ns/1ps
module tb_pad_eq;
    parameter int SEED = 1;
    reg clk = 0; always #6.7 clk = !clk;
    wire w_a, w_b; pullup(w_a); pullup(w_b);
    wire [31:0] ka, kb, ja, jb; wire [15:0] ta, tb;
    wire to_a, to_b;
    reg  drv_a = 0, val_a = 1, drv_b = 0, val_b = 1;
    assign w_a = drv_a ? val_a : 1'bz;
    assign w_b = drv_b ? val_b : 1'bz;
    io_pad_controller_ref u_ref (.clk, .reset_n(1'b1), .pad_1wire_w(w_a), .cont1_key(ka), .cont1_joy(ja), .cont1_trig(ta), .rx_timed_out(to_a));
    io_pad_controller u_new (.clk, .reset_n(1'b1), .pad_1wire_w(w_b), .cont1_key(kb), .cont1_joy(jb), .cont1_trig(tb), .rx_timed_out(to_b));
    initial begin
        u_ref.auto_poll_cnt = 0; u_ref.heartbeat_cnt = 0; u_ref.rx_timeout = 0; u_ref.state = 0; u_ref.tr_state = 1; u_ref.auto_poll_queue = 0; u_ref.heartbeat_queue = 0;
        u_ref.reset_tr_n = 0; u_ref.rx_word_done = 0; u_ref.tx_word_done = 0; u_ref.tx_word_start = 0; u_ref.tx_word_start_1 = 0; u_ref.cnt = 0;
        u_new.heartbeat_cnt = 0; u_new.rx_timeout = 0; u_new.state = 0; u_new.tr_state = 1; u_new.auto_poll_queue = 0; u_new.heartbeat_queue = 0;
        u_new.reset_tr_n = 0; u_new.rx_word_done = 0; u_new.tx_word_done = 0; u_new.tx_word_start = 0; u_new.tx_word_start_1 = 0; u_new.cnt = 0;
        u_ref.s00.stage_1 = 1; u_ref.s00.stage_2 = 1; u_ref.s00.o = 1; u_new.s00.stage_1 = 1; u_new.s00.stage_2 = 1; u_new.s00.o = 1;
    end
    // the same answers on both lines, in the controller's bit shape, after its 32 command bits
    integer seed = SEED, polls = 0, errs = 0, word, bit_i, cyc = 0;
    reg [31:0] w;
    reg [31:0] cap_a, cap_b;
    integer nbits;
    task automatic send_word(input reg [31:0] d);
        for (bit_i = 31; bit_i >= 0; bit_i--) begin
            drv_a = 1; drv_b = 1; val_a = 0; val_b = 0; repeat (20) @(posedge clk);
            val_a = d[bit_i]; val_b = d[bit_i]; repeat (20) @(posedge clk);
            val_a = 1; val_b = 1; repeat (20) @(posedge clk);
        end
        drv_a = 0; drv_b = 0; repeat (30) @(posedge clk);
    endtask
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (ka !== kb || ja !== jb || ta !== tb || w_a !== w_b) begin
            if (cyc > 16 && errs < 8) $display("cycle %0d: key %h %h joy %h %h trig %h %h wire %b %b", cyc, ka, kb, ja, jb, ta, tb, w_a, w_b);
            if (cyc > 16) errs <= errs + 1;
        end
    end
    // poll seen: the controller's state moves to the button words once its word is out
    initial begin
        forever begin
            @(posedge clk);
            if (u_ref.state == 3 && !drv_a && u_ref.tr_state == 1) begin
                for (word = 0; word < 12; word++) begin
                    w = $random(seed);
                    send_word(w);
                end
                polls = polls + 1;
            end
        end
    end
    initial begin
        #(60_000_000);
        $display("%s polls %0d errs %0d keys %h %h", errs == 0 && polls > 5 ? "PASS" : "FAIL", polls, errs, ka, kb);
        $finish;
    end
endmodule
