// nds_spi against an earlier revision: the same random SPICNT / SPIDATA traffic to both, each with its
// own firmware memory port (same contents, random latency up to LAT clocks), each byte waited for on
// both. Every read of SPIDATA and SPICNT with busy low must agree, and the transfer's busy time must be
// the same while the new one's firmware fetch is inside it (LAT < 64). The reference runs with the
// calibration the boot program now writes: k = 16.0 (0x1000), o = 8, the new raw = pixel * 16 + 8.
// Touch samples are taken with the pen and cursor held; `move` steps them between transfers.
module tb_spi_eq #(parameter int SEED = 1, parameter int OPS = 200000, parameter int LAT = 40);
    logic clk = 1'b0;
    always #5 clk = !clk;
    logic rst = 1'b1, tick = 1'b0;
    logic io_req = 1'b0, io_we = 1'b0;
    logic [3:0] io_be = 4'd0;
    logic [31:0] io_wdata = 32'd0;
    logic [31:0] rd_a, rd_b;
    logic irq_a, irq_b, off_a, off_b, pd_a, pd_b;
    logic freq_a, freq_b, fack_a = 1'b0, fack_b = 1'b0;
    logic [17:2] fa_a, fa_b;
    logic [31:0] fd_a = 32'd0, fd_b = 32'd0;
    logic pen = 1'b0;
    logic [7:0] tx = 8'd0, ty = 8'd0;
    nds_spi_ref u_ref (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata, .io_rdata(rd_a), .irq(irq_a), .pwr_off(off_a),
        .fw_req(freq_a), .fw_addr(fa_a), .fw_ack(fack_a), .fw_rdata(fd_a), .pen, .tx, .ty,
        .kx(16'h1000), .ky(16'h1000), .ox(16'd8), .oy(16'd8), .pen_down(pd_a));
    nds_spi u_new (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata, .io_rdata(rd_b), .irq(irq_b), .pwr_off(off_b),
        .fw_req(freq_b), .fw_addr(fa_b), .fw_ack(fack_b), .fw_rdata(fd_b), .pen, .tx, .ty, .pen_down(pd_b));
    function automatic logic [31:0] fw_word(input logic [17:2] a);
        return {a, a[7:0], 8'h5A} ^ ({a, a} * 32'h9E3779B1);
    endfunction
    // memories: a request is answered after a random delay
    int la = 0, lb = 0;
    int unsigned rng = 32'(SEED) * 2654435761 + 1;
    function automatic int unsigned rnd();
        rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
        return rng;
    endfunction
    always_ff @(posedge clk) begin
        fack_a <= 1'b0; fack_b <= 1'b0;
        if (freq_a && !fack_a) begin
            if (la == 0) begin fack_a <= 1'b1; fd_a <= fw_word(fa_a); la <= int'(rnd() % LAT); end else la <= la - 1;
        end
        if (freq_b && !fack_b) begin
            if (lb == 0) begin fack_b <= 1'b1; fd_b <= fw_word(fa_b); lb <= int'(rnd() % LAT); end else lb <= lb - 1;
        end
    end
    // tick every second clock, as the DS bus
    always_ff @(posedge clk) tick <= !tick;
    // the traffic: one process, its own state in blocking assignments
    typedef enum logic [1:0] { T_RST, T_NEXT, T_READ, T_CHECK } t_t;
    t_t ts = T_RST;
    int ops = 0, bytes_left = 0, errs = 0, reads = 0, cyc = 0, wt = 0, seq = 0, seqn = 0;
    logic [1:0] cdev = 2'd0, baud = 2'd0;
    logic [7:0] seqb [4];
    logic was_diff = 1'b0;
    function automatic void pick();
        int k = int'(rnd() % 8), a = int'(rnd() % 262144);
        cdev = rnd() % 8 < 6 ? 2'd1 : 2'(rnd() % 3);
        seqn = 1;
        if (cdev == 2'd1) begin
            case (k)
                0, 1, 2: begin seqb[0] = 8'h03; seqn = 4; end
                3: begin seqb[0] = 8'h0B; seqn = 4; end
                4: seqb[0] = 8'h05;
                5: seqb[0] = 8'h9F;
                6: seqb[0] = rnd() % 2 == 0 ? 8'h06 : 8'h04;
                default: seqb[0] = 8'(rnd());
            endcase
            seqb[1] = 8'(a >> 16); seqb[2] = 8'(a >> 8); seqb[3] = 8'(a);
        end else if (cdev == 2'd0) seqb[0] = 8'(rnd()) & 8'h87;
        else seqb[0] = 8'h80 | 8'(rnd() & 32'h78);
        bytes_left = int'(rnd() % 12);
        seq = 0;
    endfunction
    always @(posedge clk) begin
        cyc++;
        io_req <= 1'b0;
        if (irq_a != irq_b) begin $display("FAIL irq at op %0d", ops); errs++; end
        if (off_a != off_b) begin $display("FAIL pwr_off at op %0d", ops); errs++; end
        case (ts)
            T_RST: if (cyc == 8) begin rst <= 1'b0; pick(); ts = T_NEXT; wt = 4; end
            T_NEXT: if (wt != 0) wt--; else begin
                if (ops >= OPS) begin
                    $display("%s ops %0d reads %0d errs %0d", errs == 0 ? "PASS" : "FAIL", ops, reads, errs);
                    $finish;
                end
                if (seq >= seqn && bytes_left == 0) begin
                    // the bus off between commands: chip select released
                    io_req <= 1'b1; io_we <= 1'b1; io_be <= 4'b0011; io_wdata <= 32'd0;
                    pick();
                    baud = 2'(rnd() % 2);
                    pen <= rnd() % 4 != 0; tx <= 8'(rnd()); ty <= 8'(rnd() % 192);
                    wt = 3;
                end else begin
                    logic [7:0] b;
                    if (seq < seqn) begin b = seqb[seq]; seq++; end
                    else begin
                        b = cdev == 2'd2 && rnd() % 3 == 0 ? 8'h80 | 8'(rnd() & 32'h78) : 8'(rnd() & 32'h7F);
                        bytes_left--;
                    end
                    io_req <= 1'b1; io_we <= 1'b1; io_be <= 4'b0111;
                    io_wdata <= {8'd0, b, 1'b1, 1'b0, 2'd0, 1'b1, 1'b0, cdev, 6'd0, baud};
                    ops++;
                    ts = T_READ; wt = 2;
                end
            end
            T_READ: if (wt != 0) wt--; else begin
                io_req <= 1'b1; io_we <= 1'b0; io_be <= 4'b1111; ts = T_CHECK; wt = 1;
            end
            T_CHECK: if (wt != 0) wt--; else begin
                if (rd_a[7] != rd_b[7]) begin
                    // the new one's fetch can only lengthen the transfer past the reference's if LAT is above its time
                    if (!was_diff) begin $display("FAIL busy at op %0d: %h %h dev %0d", ops, rd_a, rd_b, cdev); errs++; end
                    was_diff = 1'b1;
                end else was_diff = 1'b0;
                if (rd_a[7] || rd_b[7]) begin io_req <= 1'b1; io_we <= 1'b0; io_be <= 4'b1111; wt = 1; end
                else begin
                    reads++;
                    if (rd_a != rd_b) begin $display("FAIL read at op %0d: %h %h dev %0d seq %0d cmd %h", ops, rd_a, rd_b, cdev, seq, seqb[0]); errs++; end
                    ts = T_NEXT; wt = int'(rnd() % 4);
                end
            end
        endcase
        if (errs > 20) begin $display("FAIL too many"); $finish; end
    end
endmodule
