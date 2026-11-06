// SPDX-License-Identifier: GPL-3.0-or-later
// Runs rtl/pocket/nds_cart_cache.sv's start-up scan (header, ARM9/ARM7, FAT)
// on a real ROM and writes the read-ahead table it builds, to compare with
// the plugin's .ndt (tests/check_roms.py). SDRAM is a word map that answers
// at once; an APF fetch copies the ROM's bytes into the slots and returns
// its marker a few clocks later.
//   +rom=<path> +size=<bytes> +out=<table file>
`default_nettype none
module tb_cart_table;
    localparam [23:0] TABLE_W = 24'h30_0000, CACHE_W = 24'h40_0000;
    reg clk = 0, reset = 1, start = 0;
    always #5 clk = ~clk;
    reg [31:0] rom_size;
    integer rom_fd, out_fd;
    string rom_path, out_path;

    wire ready, fail, init_capped, c_ready, r_valid, fc_send, m_valid, m_write, m_quad;
    wire [31:0] r_data, m_wdata;
    wire [119:0] fc_data;
    wire [23:0] m_addr;
    wire [3:0] m_be;
    reg m_ready = 0, m_rvalid = 0, mk_valid = 0;
    reg [31:0] m_rdata = 0;
    wire [31:0] st_lookups, st_fast, st_cmds, st_blocks, st_evict, st_wait, st_spans, st_marks;
    wire [15:0] st_errors;

    nds_cart_cache #(.TABLE_W(TABLE_W), .CACHE_W(CACHE_W)) dut (
        .clk(clk), .reset(reset), .start(start), .rom_size(rom_size), .ready(ready), .fail(fail), .init_capped(init_capped),
        .c_valid(1'b0), .c_addr(32'h0), .c_ready(c_ready), .r_valid(r_valid), .r_data(r_data),
        .fc_send(fc_send), .fc_data(fc_data), .fc_busy(1'b0), .mk_valid(mk_valid), .mk_err(3'd0),
        .m_valid(m_valid), .m_write(m_write), .m_quad(m_quad), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be),
        .m_ready(m_ready), .m_rvalid(m_rvalid), .m_rdata(m_rdata),
        .stat_clear(1'b0), .tick_ms(1'b0), .st_lookups(st_lookups), .st_fast(st_fast), .st_cmds(st_cmds),
        .st_blocks(st_blocks), .st_evict(st_evict), .st_wait(st_wait), .st_errors(st_errors),
        .st_spans(st_spans), .st_marks(st_marks));

    reg [31:0] mem [int];
    function automatic [31:0] rd(input int a);
        rd = mem.exists(a) ? mem[a] : 32'h0;
    endfunction

    // SDRAM: accept one access per request, then answer its words
    int pend_a, pend_n;
    always @(posedge clk) begin
        m_ready <= 0; m_rvalid <= 0;
        if (pend_n > 0) begin
            m_rvalid <= 1; m_rdata <= rd(pend_a); pend_a <= pend_a + 1; pend_n <= pend_n - 1;
        end else if (m_valid && !m_ready) begin
            m_ready <= 1;
            if (m_write) begin
                automatic reg [31:0] w = rd(m_addr);
                for (int i = 0; i < 4; i++) if (m_be[i]) w[8*i +: 8] = m_wdata[8*i +: 8];
                mem[m_addr] = w;
            end else begin
                pend_a <= m_addr; pend_n <= m_quad ? 4 : 1;
            end
        end
    end

    // APF fetch: {length[14:0], offset[31:0], blocks[2:0], slot4..slot0[13:0]}
    int mk_delay = 0;
    always @(posedge clk) begin
        mk_valid <= 0;
        if (mk_delay > 0) begin
            mk_delay <= mk_delay - 1;
            if (mk_delay == 1) mk_valid <= 1;
        end
        if (fc_send) begin
            automatic int len = fc_data[119:105], off = fc_data[104:73], n = fc_data[72:70];
            for (int k = 0; k < n; k++) begin
                automatic int slot = fc_data[14*k +: 14];
                void'($fseek(rom_fd, off + 4096 * k, 0));
                for (int w = 0; w < 1024 && 4096 * k + 4 * w < len; w++) begin
                    automatic reg [31:0] v = 0;
                    for (int b = 0; b < 4; b++) begin
                        automatic int c = $fgetc(rom_fd);
                        v[8*b +: 8] = c < 0 ? 8'h0 : c[7:0];
                    end
                    mem[CACHE_W + 1024 * slot + w] = v;
                end
            end
            mk_delay <= 4;
        end
    end

    initial begin
        if (!$value$plusargs("rom=%s", rom_path) || !$value$plusargs("size=%d", rom_size) || !$value$plusargs("out=%s", out_path)) $fatal(1, "usage");
        rom_fd = $fopen(rom_path, "rb");
        if (rom_fd == 0) $fatal(1, "can't open the ROM");
        repeat (4) @(posedge clk);
        reset <= 0; start <= 1;
        wait (ready);
        @(posedge clk);
        out_fd = $fopen(out_path, "w");
        $fwrite(out_fd, "capped %0d spans %0d marks %0d fail %0d\n", init_capped, st_spans, st_marks, fail);
        for (int b = 0; b < (rom_size + 4095) / 4096; b++) $fwrite(out_fd, "%0d\n", rd(TABLE_W + b) >> 29);
        $fclose(out_fd);
        $finish;
    end
endmodule
`default_nettype wire
