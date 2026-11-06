// SPDX-License-Identifier: GPL-3.0-or-later
// nds_cart's AUX SPI save path against a reference copy (run.py: the source
// before the change, module renamed nds_cart_ref): both run the same script of
// SPI accesses, each with its own save memory and driver. The bytes read back
// after every data write and the final memories must be equal.
module tb_cart_spi_eq;
    logic clk = 0, rst = 1;
    always #1 clk = ~clk;
    logic tick = 0;
    always_ff @(posedge clk) tick <= ~tick;

    int unsigned cfg [4];           // save type, ir, sv_loaded bytes, ack latency seed
    logic [15:0] scr [65536];       // op [15:12], data [11:0]
    int unsigned nops;
    bit trace;
    longint cyc = 0;
    always_ff @(posedge clk) cyc <= cyc + 1;
    initial trace = $test$plusargs("trace");
    initial begin
        $readmemh("cfg.hex", cfg);
        $readmemh("script.hex", scr);
        if (!$value$plusargs("nops=%d", nops)) nops = 0;
    end

    localparam int N = 2;
    logic [7:0]  rlog [N][65536];
    int          rn   [N];
    logic [31:0] mem  [N][262144];
    logic        done [N];

    for (genvar k = 0; k < N; k++) begin : g
        logic        io_req, io_we;
        logic [3:0]  io_be;
        logic [2:0]  io_reg;
        logic [31:0] io_wdata, io_rdata;
        logic        sv_req, sv_we, sv_ack;
        logic [19:2] sv_addr;
        logic [3:0]  sv_be;
        logic [31:0] sv_wdata, sv_rdata;
        if (k == 0) begin : g_ref
            nds_cart_ref u (.clk, .rst, .tick, .owner7(1'b1), .raw(1'b0), .ir(cfg[1][0]), .dsi(1'b0),
                .save_type(cfg[0][2:0]), .sv_loaded(cfg[2][20:0]), .rom_size(32'h0100_0000),
                .io_req, .io_cpu(1'b1), .io_we, .io_be, .io_reg, .io_wdata, .io_rdata, .irq(), .drq(),
                .cr_req(), .cr_addr(), .cr_ack(1'b0), .cr_rvalid(1'b0), .cr_rdata(32'd0),
                .sv_req, .sv_we, .sv_addr, .sv_be, .sv_wdata, .sv_ack, .sv_rdata);
        end else begin : g_new
            nds_cart u (.clk, .rst, .tick, .owner7(1'b1), .raw(1'b0), .ir(cfg[1][0]), .dsi(1'b0),
                .save_type(cfg[0][2:0]), .sv_loaded(cfg[2][20:0]), .rom_size(32'h0100_0000),
                .io_req, .io_cpu(1'b1), .io_we, .io_be, .io_reg, .io_wdata, .io_rdata, .irq(), .drq(),
                .cr_req(), .cr_addr(), .cr_ack(1'b0), .cr_rvalid(1'b0), .cr_rdata(32'd0),
                .sv_req, .sv_we, .sv_addr, .sv_be, .sv_wdata, .sv_ack, .sv_rdata);
        end
        // save memory: request n is answered after a latency from an LFSR seeded the same for both
        logic [15:0] lf;
        logic [5:0]  wait_n;
        logic        busy_m;
        always_ff @(posedge clk) begin
            sv_ack <= 1'b0;
            if (rst) begin lf <= cfg[3][15:0] | 16'h1; busy_m <= 1'b0; end
            else if (sv_req && !sv_ack) begin
                if (!busy_m) begin busy_m <= 1'b1; wait_n <= {1'b0, lf[4:0]} + 6'd1; lf <= {lf[14:0], lf[15] ^ lf[13] ^ lf[12] ^ lf[10]}; end
                else if (wait_n != 0) wait_n <= wait_n - 6'd1;
                else begin
                    busy_m <= 1'b0; sv_ack <= 1'b1;
                    if (trace) $display("%0d mem%0d %s %h be %h d %h", cyc, k, sv_we ? "W" : "R", sv_addr, sv_be, sv_wdata);
                    sv_rdata <= mem[k][sv_addr];
                    if (sv_we) for (int b = 0; b < 4; b++) if (sv_be[b]) mem[k][sv_addr][b*8 +: 8] <= sv_wdata[b*8 +: 8];
                end
            end
        end
        // driver: one script op at a time
        typedef enum logic [2:0] { D_OP, D_POLL, D_PRD, D_IDLE, D_END } d_t;
        logic [1:0]  wip;            // op 7: 1 the command byte, 2 status bytes until bit 0 (busy: an erase) clears
        d_t          ds;
        int unsigned pc, idle;
        logic        prd;
        always_ff @(posedge clk) begin
            io_req <= 1'b0;
            if (trace && cyc[20:0] == 0) begin $display("%0d drv%0d pc %0d ds %0d wip %0d idle %0d rd %h", cyc, k, pc, ds, wip, idle, io_rdata); $fflush; end
            if (rst) begin ds <= D_OP; pc <= 0; rn[k] <= 0; done[k] <= 1'b0; prd <= 1'b0; wip <= 2'd0; end
            else case (ds)
                D_OP: if (pc >= nops) begin ds <= D_IDLE; idle <= 400000; end
                else begin
                    logic [3:0] op; logic [11:0] d;
                    op = scr[pc][15:12]; d = scr[pc][11:0]; pc <= pc + 1;
                    case (op)
                        4'd1: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0011;     // AUXSPICNT: SPI mode
                                    io_wdata <= {16'd0, 1'b1, d[3], 1'b1, 6'd0, d[2], 4'd0, d[1:0]}; ds <= D_IDLE; idle <= 3; end
                        4'd2: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0100;     // data byte
                                    io_wdata <= {8'd0, d[7:0], 16'd0}; ds <= D_POLL; idle <= 2; end
                        4'd3: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0111;     // CNT + byte in one write
                                    io_wdata <= {8'd0, d[7:0], 1'b1, d[11], 1'b1, 6'd0, d[10], 4'd0, d[9:8]}; ds <= D_POLL; idle <= 2; end
                        4'd4: begin ds <= D_IDLE; idle <= {d, 4'd0}; end                                   // idle
                        4'd5: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0011;     // ROM mode: releases the chip
                                    io_wdata <= 32'h0000_8000; ds <= D_IDLE; idle <= 3; end
                        4'd7: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0100;     // RDSR (after a held CNT), then poll
                                    io_wdata <= {8'd0, d[0] ? 8'h00 : 8'h05, 16'h0000}; ds <= D_POLL; idle <= 2; wip <= d[0] ? 2'd3 : 2'd1; end   // (d[0]: an IR cart's 0x00 first)
                        4'd6: begin io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0111;     // release and a byte, one write
                                    io_wdata <= {8'd0, d[7:0], 16'h8000}; ds <= D_POLL; idle <= 2; end
                        default: ;
                    endcase
                end
                D_POLL: if (idle != 0) idle <= idle - 1;      // (the fabric's turnaround)
                else if (!prd) begin io_req <= 1'b1; io_we <= 1'b0; io_reg <= 3'd0; io_be <= 4'hF; prd <= 1'b1; idle <= 1; end
                else begin
                    prd <= 1'b0;
                    if (!io_rdata[7] && wip != 2'd0) begin
                        if (wip == 2'd2 && !io_rdata[16]) begin    // not busy: release the chip
                            wip <= 2'd0; io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0011; io_wdata <= 32'h0000_8000;
                            ds <= D_IDLE; idle <= 3;
                        end else if (wip == 2'd3) begin
                            wip <= 2'd1; io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0100; io_wdata <= 32'h0005_0000; idle <= 2;
                        end else begin
                            wip <= 2'd2; io_req <= 1'b1; io_we <= 1'b1; io_reg <= 3'd0; io_be <= 4'b0100; io_wdata <= 32'd0; idle <= 2;
                        end
                    end else if (!io_rdata[7]) begin rlog[k][rn[k]] <= io_rdata[23:16]; rn[k] <= rn[k] + 1; ds <= D_OP; end
                    else idle <= 0;
                end
                D_IDLE: if (idle != 0) idle <= idle - 1; else if (pc >= nops) begin ds <= D_END; done[k] <= 1'b1; end else ds <= D_OP;
                default: ;
            endcase
        end
    end

    initial begin
        int unsigned bad;
        for (int k = 0; k < N; k++) for (int i = 0; i < 262144; i++) mem[k][i] = 32'hA5000000 ^ (i * 32'h9E3779B1);
        repeat (8) @(posedge clk);
        rst = 0;
        // (a driver stuck in a status poll: a busy bit that never clears)
        fork
            wait (done[0] && done[1]);
            begin wait (cyc > 64'd60_000_000); $display("RESULT DIFFER: timeout, driver at %0d / %0d", g[0].pc, g[1].pc); $finish; end
        join_any
        bad = 0;
        if (rn[0] != rn[1]) begin $display("bytes read: ref %0d new %0d", rn[0], rn[1]); bad++; end
        for (int i = 0; i < rn[0] && i < rn[1]; i++)
            if (rlog[0][i] !== rlog[1][i]) begin if (bad < 8) $display("byte %0d: ref %h new %h", i, rlog[0][i], rlog[1][i]); bad++; end
        for (int i = 0; i < 262144; i++)
            if (mem[0][i] !== mem[1][i]) begin if (bad < 8) $display("word %h: ref %h new %h", i, mem[0][i], mem[1][i]); bad++; end
        if (bad == 0) $display("RESULT SAME: %0d bytes, 0 differ", rn[0]); else $display("RESULT DIFFER: %0d bytes, %0d differ", rn[0], bad);
        $finish;
    end
endmodule
