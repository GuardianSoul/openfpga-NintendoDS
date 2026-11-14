// Directed test of nds_sdram_bport's request-stability check behind nds_bport_share, as bp_cache is wired
// (core_top_ds): client A (the ROM cache: writes with byte enables) and client B (the save reader: single
// reads) on one port. B's read owns the port while A raises a write with other byte enables, so c_be
// changes under B's pending read (the cold-boot message). The words must reach the right client with the
// right data, and A's write must reach the port with its own byte enables. +mut: B moves its address while
// its read is pending (a real contract fault: the check must report it).
`timescale 1ns/1ps
module tb_bport_stab;
    logic clk_bus = 0, clk_mem = 0, reset = 1;
    always #6.7 clk_bus = !clk_bus;
    always #5 clk_mem = !clk_mem;
    logic a_valid = 0, a_write = 0, a_quad = 0, b_valid = 0;
    logic [23:0] a_addr = 0, b_addr = 0;
    logic [31:0] a_wdata = 0;
    logic [3:0] a_be = 0;
    wire a_ready, a_rvalid, b_ready, b_rvalid;
    wire sh_valid, sh_write, sh_quad, sh_ready, sh_rvalid;
    wire [23:0] sh_addr;
    wire [31:0] sh_wdata, r_data;
    wire [3:0] sh_be;
    nds_bport_share x_share (.clk(clk_bus), .reset, .a_valid, .a_write, .a_quad, .a_addr, .a_wdata, .a_be,
        .a_ready, .a_rvalid, .b_valid, .b_addr, .b_ready, .b_rvalid,
        .c_valid(sh_valid), .c_write(sh_write), .c_quad(sh_quad), .c_addr(sh_addr), .c_wdata(sh_wdata), .c_be(sh_be),
        .c_ready(sh_ready), .r_valid(sh_rvalid));
    wire m_valid, m_we;
    wire [23:0] m_addr;
    wire [3:0] m_n, m_be;
    wire [31:0] m_wdata;
    logic m_take = 0, w_valid = 0;
    logic [31:0] w_data = 0;
    nds_sdram_bport #(.SHARED(1)) bp (.clk_bus, .clk_mem, .reset, .c_valid(sh_valid), .c_write(sh_write),
        .c_quad(sh_quad), .c_addr(sh_addr), .c_wdata(sh_wdata), .c_be(sh_be), .c_ready(sh_ready), .r_valid(sh_rvalid),
        .r_data, .m_valid, .m_we, .m_addr, .m_n, .m_wdata, .m_be, .m_take, .w_valid, .w_data);
    // the controller: takes a request 6 clk_mem after m_valid (a slow grant), latching its fields at the take
    // as nds_sdram_mc does; a read's words ({addr, k}) follow 4 clocks later
    integer errors = 0, wait_n = 0, words = 0;
    logic [23:0] t_addr; logic t_we; logic [3:0] t_be, t_n; logic [31:0] t_wd;
    logic [23:0] wr_addr [$]; logic [3:0] wr_be [$]; logic [31:0] wr_d [$];
    task automatic err(input string m); errors++; $display("ERROR %0t %s", $time, m); endtask
    integer rd_at = -1, rd_k = 0, now = 0;
    always @(posedge clk_mem) begin
        now <= now + 1;
        m_take <= 0; w_valid <= 0;
        if (m_valid && !m_take && rd_at < 0) begin
            wait_n <= wait_n + 1;
            if (wait_n == 6) begin
                m_take <= 1; wait_n <= 0; t_addr = m_addr; t_we = m_we; t_be = m_be; t_n = m_n; t_wd = m_wdata;
                if (t_we) begin wr_addr.push_back(t_addr); wr_be.push_back(t_be); wr_d.push_back(t_wd); end
                else begin rd_at <= now + 4; rd_k <= 0; end
            end
        end
        if (rd_at >= 0 && now >= rd_at) begin
            w_valid <= 1; w_data <= {t_addr, 8'(rd_k)}; rd_k <= rd_k + 1;
            if (rd_k + 1 == t_n) rd_at <= -1;
        end
    end
    // B's word: its address on the port
    logic [31:0] b_word; logic b_got = 0;
    always @(posedge clk_bus) if (b_rvalid) begin b_word <= r_data; b_got <= 1; end
    always @(posedge clk_bus) if (a_rvalid) err("A got a word for a request it never made");
    bit mut;
    initial begin
        mut = $test$plusargs("mut");
        repeat (5) @(posedge clk_bus); reset <= 0; repeat (3) @(posedge clk_bus);
        // A: a full-word write (be f)
        a_valid <= 1; a_write <= 1; a_addr <= 24'h000100; a_wdata <= 32'h1111_1111; a_be <= 4'hF;
        do @(posedge clk_bus); while (!a_ready);
        a_valid <= 0;
        repeat (3) @(posedge clk_bus);
        // B: a single read; once the port is B's, A asks for a halfword write (be 3) while B's read is pending
        b_valid <= 1; b_addr <= 24'h040061;
        do @(posedge clk_bus); while (!x_share.own_b);
        @(posedge clk_bus);
        a_valid <= 1; a_write <= 1; a_addr <= 24'h000104; a_wdata <= 32'h0000_2222; a_be <= 4'h3;
        if (mut) begin repeat (2) @(posedge clk_bus); b_addr <= 24'h040062; end
        do @(posedge clk_bus); while (!b_ready);
        b_valid <= 0;
        do @(posedge clk_bus); while (!a_ready);
        a_valid <= 0;
        repeat (40) @(posedge clk_bus);
        if (!b_got) err("B got no word");
        else if (!mut && b_word !== {24'h040061, 8'd0}) err($sformatf("B word %h", b_word));
        if (wr_addr.size() != 2) err($sformatf("%0d writes reached the controller", wr_addr.size()));
        else begin
            if (wr_addr[0] !== 24'h000100 || wr_be[0] !== 4'hF || wr_d[0] !== 32'h1111_1111) err("first write");
            if (wr_addr[1] !== 24'h000104 || wr_be[1] !== 4'h3 || wr_d[1] !== 32'h0000_2222) err("second write");
        end
        $display("%s errors %0d", errors == 0 ? "PASS" : "FAIL", errors);
        $finish;
    end
endmodule
