// nds_cart against nds_cart_ref (its version at a git ref, cart_eq.sh), clock by clock on
// random register traffic: AUXSPI bytes from a command alphabet (reads, writes, page
// program, erases, status, write enable/disable, ID; IR carts), ROM transfers of every
// size, random ROM sizes, save types and loaded save sizes. The ROM cache and the save
// memory answer the reference's requests with random delays; every output of the two
// must agree in every clock (the save request's fields while it is raised).
`timescale 1ns/1ps
module tb_cart_eq;
    logic clk = 0, rst = 1, tick = 0;
    always #5 clk = !clk;
    int unsigned seed, ops;
    logic        owner7, raw, ir;
    logic [2:0]  save_type = 0, type_set;
    logic [20:0] sv_loaded;
    logic [31:0] rom_size;
    logic        io_req = 0, io_cpu = 0, io_we = 0;
    logic [3:0]  io_be = 0;
    logic [2:0]  io_reg = 0;
    logic [31:0] io_wdata = 0;
    logic        cr_ack = 0, cr_rvalid = 0, sv_ack = 0;
    logic [31:0] cr_rdata = 0, sv_rdata = 0;

    wire [31:0] rd_a, rd_b, sd_a, sd_b;
    wire irq_a, irq_b, drq_a, drq_b, crq_a, crq_b, sreq_a, sreq_b, swe_a, swe_b;
    wire [31:4] cra_a, cra_b;
    wire [19:2] sa_a, sa_b;
    wire [3:0]  sb_a, sb_b;
    nds_cart dut (.clk, .rst, .tick, .owner7, .raw, .ir, .save_type, .sv_loaded, .rom_size,
        .io_req, .io_cpu, .io_we, .io_be, .io_reg, .io_wdata, .io_rdata(rd_a), .irq(irq_a), .drq(drq_a),
        .cr_req(crq_a), .cr_addr(cra_a), .cr_ack, .cr_rvalid, .cr_rdata,
        .sv_req(sreq_a), .sv_we(swe_a), .sv_addr(sa_a), .sv_be(sb_a), .sv_wdata(sd_a), .sv_ack, .sv_rdata);
    nds_cart_ref ref_ (.clk, .rst, .tick, .owner7, .raw, .ir, .save_type, .sv_loaded, .rom_size,
        .io_req, .io_cpu, .io_we, .io_be, .io_reg, .io_wdata, .io_rdata(rd_b), .irq(irq_b), .drq(drq_b),
        .cr_req(crq_b), .cr_addr(cra_b), .cr_ack, .cr_rvalid, .cr_rdata,
        .sv_req(sreq_b), .sv_we(swe_b), .sv_addr(sa_b), .sv_be(sb_b), .sv_wdata(sd_b), .sv_ack, .sv_rdata);

    // save memory (the reference's requests), ROM cache
    logic [31:0] mem [0:262143];
    int sv_wait = -1;
    logic [31:4] cr_line;
    int unsigned errors = 0, cycles = 0, sv_n = 0, cr_lines = 0, spi_n = 0;
    always @(posedge clk) begin
        tick <= !tick;
        sv_ack <= 0;
        if (sreq_b && !sv_ack) begin
            if (sv_wait < 0) sv_wait <= $urandom % 12;
            else if (sv_wait == 0) begin
                sv_ack <= 1; sv_wait <= -1; sv_n++;
                if (swe_b) begin
                    for (int b = 0; b < 4; b++) if (sb_b[b]) mem[sa_b][b*8 +: 8] <= sd_b[b*8 +: 8];
                end else sv_rdata <= mem[sa_b];
            end else sv_wait <= sv_wait - 1;
        end
    end
    // ROM cache: request seen, a random delay, the ack, a clock for the cart to take it, four words
    int cst = 0, cdel = 0, cn = 0;
    bit go;
    always @(posedge clk) begin
        cr_ack <= 0; cr_rvalid <= 0;
        case (cst)
            0: if (crq_b) begin cst <= 1; cdel <= $urandom % 8; end
            1: if (cdel == 0) begin cr_ack <= 1; cst <= 2; cr_line <= cra_b; cr_lines++; end else cdel <= cdel - 1;
            2: begin cst <= 3; cn <= 0; end
            default: begin
                go = ($urandom % 2) != 0;
                if (go) begin
                    cr_rvalid <= 1; cr_rdata <= {cr_line[23:4], 4'(cn), 8'h5A} ^ 32'h9E37_79B9;
                    if (cn == 3) cst <= 0; else cn <= cn + 1;
                end
            end
        endcase
    end
    // compare
    always @(negedge clk) if (!rst) begin
        cycles++;
        if (rd_a !== rd_b || irq_a !== irq_b || drq_a !== drq_b || crq_a !== crq_b || (crq_b && cra_a !== cra_b) ||
            sreq_a !== sreq_b || (sreq_b && (swe_a !== swe_b || sa_a !== sa_b || sb_a !== sb_b ||
                                             (swe_b && sd_a !== sd_b)))) begin
            errors++;
            if (errors <= 5) $display("ERROR cycle %0d: rdata %h/%h irq %b/%b drq %b/%b cr %b %h/%b %h sv %b %b %h %h %h / %b %b %h %h %h",
                cycles, rd_a, rd_b, irq_a, irq_b, drq_a, drq_b, crq_a, cra_a, crq_b, cra_b,
                sreq_a, swe_a, sa_a, sb_a, sd_a, sreq_b, swe_b, sa_b, sb_b, sd_b);
        end
    end

    logic [31:0] last;          // the reference's answer to the last read
    task automatic io(input logic we, input logic [2:0] r, input logic [3:0] be, input logic [31:0] d);
        @(posedge clk); io_req <= 1; io_we <= we; io_reg <= r; io_be <= be; io_wdata <= d;
        io_cpu <= ($urandom % 16) == 0 ? !owner7 : owner7;
        @(posedge clk); io_req <= 0;
        @(negedge clk); last = rd_b;
        repeat ($urandom % 4) @(posedge clk);
    endtask
    // an AUXSPI byte: wait until not busy, write it, sometimes read AUXSPIDATA back
    task automatic spi(input logic [7:0] b, input logic hold);
        do io(0, 3'd0, 4'h3, 0); while (last[7] && io_cpu == owner7);
        io(1, 3'd0, 4'h3, {16'd0, 1'b1, 1'b0, 1'b1, 6'd0, hold, 4'd0, 2'($urandom % 2)});
        io(1, 3'd0, 4'h4, {8'd0, b, 16'd0});
        spi_n++;
        if ($urandom % 2) io(0, 3'd0, 4'hF, 0);
    endtask
    function automatic logic [7:0] cmd_byte();
        logic [7:0] c [12] = '{8'h03, 8'h02, 8'h0A, 8'h0B, 8'h05, 8'h06, 8'h04, 8'h01, 8'hD8, 8'hDB, 8'h9F, 8'h08};
        return ($urandom % 10) == 0 ? 8'($urandom) : c[$urandom % 12];
    endfunction

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("ops=%d", ops)) ops = 2000;
        void'($urandom(seed));
        for (int i = 0; i < 262144; i++) mem[i] = $urandom;
        owner7 = $urandom % 2; raw = $urandom % 2; ir = $urandom % 2;
        case ($urandom % 5)
            0: rom_size = 32'h0080_0000;
            4: rom_size = 32'h2000_0000 - ($urandom % 32'h1000_0000);   // 256-512 MiB: card addresses use bit 28
            1: rom_size = 32'h0000_9000 + ($urandom % 32'h0010_0000);
            2: rom_size = $urandom % 32'h2000_0001;          // any size up to 512 MiB, the largest DS ROM (nds_cart's raddr)
            default: rom_size = 32'h2000_0000 >> ($urandom % 13);   // 512 MiB down to 128 KiB
        endcase
        type_set = 3'($urandom % 8);
        sv_loaded = 21'($urandom % 32'h0012_0000);
        if ($urandom % 3 == 0) sv_loaded = 0;
        repeat (8) @(posedge clk);
        rst <= 0;
        repeat (20) @(posedge clk);
        save_type <= type_set;          // once, as BOOTCTL
        for (int n = 0; n < ops; n++) begin
            case ($urandom % 10)
                0, 1: begin     // a ROM transfer (ROMCTRL cleared first: bit 31 stays set when none starts)
                    io(1, 3'd1, 4'hF, 0);
                    io(1, 3'd2, 4'hF, {$urandom, ($urandom % 3) == 0 ? 8'hB8 : ($urandom % 4) == 0 ? 8'($urandom) : 8'hB7});
                    io(1, 3'd3, 4'hF, $urandom);
                    io(1, 3'd0, 4'h3, 32'h0000_8000 | 32'($urandom % 2) << 14);
                    io(1, 3'd1, 4'hF, 32'h8000_0000 | 32'($urandom % 8) << 24 | ($urandom & 32'h0000_7FFF));
                    for (int w = 0; w < 6000; w++) begin
                        io(0, 3'd1, 4'hF, 0);
                        if (io_cpu == owner7 && !last[31]) break;
                        if (drq_b) io(0, 3'd4, 4'hF, 0);
                        if (w == 5999) $display("stuck: rs %0d left %0d kind %0d raddr %h fw %0d cst %0d crq %b", ref_.rs, ref_.left, ref_.kind, ref_.raddr, ref_.fw, cst, crq_b);
                    end
                end
                2: io(0, 3'(($urandom % 2) ? 1 : 4), 4'hF, 0);
                default: begin  // a save command: command byte, then up to 11 more, chip select held
                    int len;
                    logic [7:0] c0;
                    len = $urandom % 16;
                    // an IR cart: byte 0 is the IR command (0x00 passes the rest to the save chip)
                    // often a write enable first (its own command), and mostly reads, writes, page programs
                    if ($urandom % 3 == 0) begin if (ir) spi(8'h00, 1); spi(8'h06, 0); end
                    c0 = ($urandom % 2) ? cmd_byte() : (($urandom % 2) ? 8'h03 : (($urandom % 2) ? 8'h02 : 8'h0A));
                    if (ir) begin spi(($urandom % 4) == 0 ? cmd_byte() : 8'h00, 1); end
                    spi(c0, len != 0);
                    for (int k = 0; k < len; k++) spi(($urandom % 4) == 0 ? cmd_byte() : 8'($urandom), k != len - 1);
                    if ($urandom % 4 == 0) repeat ($urandom % 3000) @(posedge clk);    // erases run on
                end
            endcase
        end
        repeat (200) @(posedge clk);
        $display("%s seed %0d: %0d cycles, %0d SPI bytes, %0d save accesses, %0d ROM lines, %0d errors (type %0d, ir %b, rom_size %h)",
                 errors == 0 ? "PASS" : "FAIL", seed, cycles, spi_n, sv_n, cr_lines, errors, type_set, ir, rom_size);
        $finish;
    end
endmodule
