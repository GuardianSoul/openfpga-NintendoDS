// nds_sdram_mc against the SDRAM chip model (sim/phase1/sdram_chip_model.sv,
// AS4C32M16 timing, CL3): random reads of 1, 4 or 8 words, single writes with
// random byte enables and write-chain bursts, all checked against a golden
// copy. Prints the clocks from an 8-word read's request to its last word.
// Run by sim/pocket_ds/sdram_mc_test.py (also with planted bugs).
`timescale 1ns/1ps
`default_nettype none
module tb_sdram_mc;
    reg clk = 0;
    always #4.973 clk = !clk;                 // 100.54 MHz
    reg init = 1;
    wire ready;
    reg c_valid = 0, c_we = 0;
    reg [23:0] c_addr = 0;
    reg [3:0] c_n = 0, c_be = 0;
    reg [31:0] c_wdata = 0;
    wire c_ready, r_valid, r_last;
    wire [31:0] r_data;
    // write-chain FIFO (first word fall through)
    reg [55:0] bq [0:255];
    integer bq_r = 0, bq_w = 0;
    wire bw_valid = bq_r != bq_w;
    wire [55:0] bw_head = bq[bq_r & 255];
    wire bw_read;
    // the ordering contract (nds_sdram_mc serves a waiting port before the
    // chain): a client never reads or writes a word while a chain write to it
    // is pending, as the system's clients keep it by distance (tb_ds_pocket
    // checks that). Requests here wait for their words' chain writes.
    int pend [int];
    integer held = 0;
    always @(posedge clk) if (bw_read) begin
        bq_r <= bq_r + 1;
        if (pend[int'(bw_head[55:32])] <= 1) pend.delete(int'(bw_head[55:32]));
        else pend[int'(bw_head[55:32])] = pend[int'(bw_head[55:32])] - 1;
    end
    function automatic bit pending(input [23:0] wa, input [3:0] n);
        pending = 0;
        for (int k = 0; k < n; k++) if (pend.exists(int'(wa) + k)) pending = 1;
    endfunction

    wire [15:0] dq; wire [12:0] a; wire [1:0] ba, dqm; wire nwe, nras, ncas, cke, sclk;
    nds_sdram_mc #(.POWERUP_CYCLES(400)) dut (.clk, .init, .ready,
        .c_valid, .c_hurry(1'b0), .c_we, .c_addr, .c_rb(c_addr[22:8]), .c_n, .c_wdata, .c_be, .c_ready, .r_valid, .r_data, .r_last,
        .bw_valid, .bw_addr(bw_head[55:32]), .bw_data(bw_head[31:0]), .bw_read,
        .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba), .SDRAM_DQML(dqm[0]), .SDRAM_DQMH(dqm[1]),
        .SDRAM_nWE(nwe), .SDRAM_nRAS(nras), .SDRAM_nCAS(ncas), .SDRAM_CKE(cke), .SDRAM_CLK(sclk));
    // board timing as in tb_ds_pocket: the chip clock arrives 2 ns late, data 2 ns back
    wire #2.0 chip_clk = sclk;
    sdram_chip_model #(.CAS(3), .T_AC(6.0), .T_OH(2.5), .T_RET(2.0)) chip (.clk(chip_clk), .cke, .ncs(1'b0), .nras, .ncas, .nwe, .a, .ba, .dqm, .dq);

    // golden copy of the words written so far
    reg [31:0] gold [int];
    integer errors = 0, reads = 0, writes = 0, chained = 0;
    // reads in flight: expected words in order
    reg [23:0] exp_addr [$];
    reg [32:0] exp_val [$];                   // {known, value} when the read was accepted
    always @(posedge clk) if (r_valid && $test$plusargs("directed")) $display("word %08x last %0d", r_data, r_last);
    always @(posedge clk) if (r_valid) begin
        reg [23:0] wa;
        if (exp_addr.size() == 0) begin errors++; $display("ERROR: word with no read pending"); end
        else begin
            reg [32:0] ev;
            wa = exp_addr.pop_front();
            ev = exp_val.pop_front();
            if (ev[32] && r_data !== ev[31:0]) begin
                errors++;
                if (errors < 8) $display("ERROR: word %06x read %08x, expected %08x", wa, r_data, ev[31:0]);
            end
        end
    end
    // the region: 4 banks x 4 rows x 256 words, so reads find written words
    function automatic [23:0] rnd_addr(input integer align);
        reg [23:0] w;
        w = {1'b0, 2'($urandom), 11'd0, 2'($urandom), 8'($urandom)};   // bank [22:21], row [9:8] of [20:8], word [7:0]
        rnd_addr = w & ~24'(align - 1);
    endfunction
    task automatic request(input we, input [23:0] wa, input [3:0] n, input [31:0] d, input [3:0] be);
        @(negedge clk);
        if (pending(wa, n)) begin held++; do @(negedge clk); while (pending(wa, n)); end
        c_valid = 1; c_we = we; c_addr = wa; c_n = n; c_wdata = d; c_be = be;
        do @(posedge clk); while (!c_ready);
        if (we) begin
            reg [31:0] g;
            g = gold.exists(wa) ? gold[wa] : 32'h0;
            for (int b = 0; b < 4; b++) if (be[b]) g[b*8 +: 8] = d[b*8 +: 8];
            if (gold.exists(wa) || be == 4'hF) gold[wa] = g;
            writes++;
        end else begin
            for (int k = 0; k < n; k++) begin
                exp_addr.push_back(wa + k);
                exp_val.push_back(gold.exists(wa + 24'(k)) ? {1'b1, gold[wa + 24'(k)]} : 33'd0);
            end
            reads++;
        end
        @(negedge clk); c_valid = 0;
    endtask
    task automatic chain(input [23:0] wa, input integer n);
        for (int k = 0; k < n; k++) begin
            reg [31:0] d;
            while (bq_w - bq_r >= 250) @(posedge clk);
            d = $urandom;
            bq[bq_w & 255] = {wa + 24'(k), d};
            gold[wa + 24'(k)] = d;
            pend[int'(wa) + k] = pend.exists(int'(wa) + k) ? pend[int'(wa) + k] + 1 : 1;
            bq_w = bq_w + 1;
        end
        chained += n;
    endtask
    realtime t0; integer lat8 = 0;
    initial begin
        repeat (5) @(posedge clk); init = 0;
        wait (ready);
        if ($test$plusargs("directed")) begin
            for (int k = 0; k < 16; k++) begin bq[bq_w & 255] = {24'h000040 + 24'(k), 32'h11110000 + 32'(k)}; bq_w = bq_w + 1; end
            wait (!bw_valid); repeat (20) @(posedge clk);
            request(0, 24'h000040, 4'd8, 0, 0);
            repeat (60) @(posedge clk);
            request(1, 24'h000050, 4'd1, 32'hAABBCCDD, 4'hF);
            repeat (20) @(posedge clk);
            request(0, 24'h000050, 4'd1, 0, 0);
            repeat (60) @(posedge clk);
            $finish;
        end
        // fill the region with whole words first
        for (int bank = 0; bank < 4; bank++) for (int row = 0; row < 4; row++)
            for (int w = 0; w < 256; w += 64) chain({1'b0, 2'(bank), 11'd0, 2'(row), 8'(w)}, 64);
        wait (!bw_valid);
        repeat (20) @(posedge clk);
        // the latency of an 8-word read, the SDRAM alone
        @(negedge clk); t0 = $realtime;
        request(0, 24'h000040, 4'd8, 0, 0);
        wait (exp_addr.size() == 0);
        lat8 = int'(($realtime - t0) / 9.946);
        repeat (20) @(posedge clk);
        // random traffic
        for (int i = 0; i < 4000; i++) begin
            int r;
            r = $urandom_range(0, 9);
            if (r < 4) request(0, rnd_addr(8), 4'd8, 0, 0);
            else if (r < 6) request(0, rnd_addr(4), 4'd4, 0, 0);
            else if (r < 7) request(0, rnd_addr(1), 4'd1, 0, 0);
            else if (r < 9) request(1, rnd_addr(1), 4'd1, $urandom, 4'($urandom_range(1, 15)));
            else if (bq_w - bq_r < 128) chain(rnd_addr(128), $urandom_range(1, 64) & ~0);
        end
        wait (exp_addr.size() == 0 && !bw_valid);
        repeat (40) @(posedge clk);
        $display("reads %0d, writes %0d, chained words %0d, chip errors %0d, 8-word read %0d clk_mem (%0d requests held for their chain writes)",
                 reads, writes, chained, chip.errors, lat8, held);
        if (errors == 0 && chip.errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d data, %0d chip)", errors, chip.errors);
        $finish;
    end
    initial begin #20ms; $display("TEST FAILED (timeout)"); $finish; end
endmodule
`default_nettype wire
