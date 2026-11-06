// nds_fifo_drain against REF: the same FIFO contents through each one's own FIFO (nds_dcfifo) to its own port model; both
// must give the same writes in the same order, with every marker after the writes before it. Timing may differ by a clock.
`timescale 1ns/1ps
module tb_drain_eq;
    logic wclk = 0, clk = 0; always #6.7 wclk = !wclk; always #14.9 clk = !clk;
    int unsigned rs = 32'd777;
    function automatic int rnd(int m); rs = rs * 32'd1664525 + 32'd1013904223; return (rs >> 8) % m; endfunction
    logic wr = 0; logic [56:0] wdata = 0;
    `define S(X, M) \
        wire f_v_``X, f_rd_``X, full_``X, m_v_``X, mk_v_``X; wire [56:0] f_q_``X; wire [23:0] m_a_``X; wire [31:0] m_d_``X; wire [2:0] mk_e_``X; \
        logic rdy_``X = 0; \
        nds_dcfifo #(.W(57), .A(6)) ff_``X (.wclk, .wreset(1'b0), .wr(wr), .wdata, .full(full_``X), .wempty(), .wfill(), .overflow(), .rclk(clk), .rd(f_rd_``X), .valid(f_v_``X), .rdata(f_q_``X)); \
        M d_``X (.clk, .f_valid(f_v_``X), .f_data(f_q_``X), .f_rd(f_rd_``X), .mk_valid(mk_v_``X), .mk_err(mk_e_``X), .m_valid(m_v_``X), .m_addr(m_a_``X), .m_wdata(m_d_``X), .m_ready(rdy_``X));
    `S(n, nds_fifo_drain)
    `S(r, nds_fifo_drain_ref)
    // the port: c_ready a clock after c_valid at the earliest, as the bus's
    always @(posedge clk) begin rdy_n <= m_v_n && !rdy_n && rnd(3) != 0; rdy_r <= m_v_r && !rdy_r && rnd(3) != 0; end
    logic [63:0] log_n [$], log_r [$];
    always @(posedge clk) begin
        if (m_v_n && rdy_n) log_n.push_back({8'h00, m_a_n, m_d_n});
        if (mk_v_n) log_n.push_back({8'hFF, 21'd0, mk_e_n, 32'd0});
        if (m_v_r && rdy_r) log_r.push_back({8'h00, m_a_r, m_d_r});
        if (mk_v_r) log_r.push_back({8'hFF, 21'd0, mk_e_r, 32'd0});
    end
    longint nw = 0, nm = 0, bad = 0, same = 0;
    always @(negedge wclk) begin
        wr <= 1'b0;
        if (!full_n && !full_r && nw + nm < 400000 && rnd(4) != 0) begin
            wr <= 1'b1;
            if (rnd(50) == 0) begin wdata <= {1'b1, 53'd0, 3'(rnd(8))}; nm++; end
            else begin wdata <= {1'b0, 24'(rnd(1 << 24)), 16'(rnd(65536)), 16'(rnd(65536))}; nw++; end
        end
    end
    initial begin
        wait (nw + nm >= 400000);
        repeat (2000) @(posedge clk);
        if (log_n.size() != log_r.size()) bad++;
        for (int i = 0; i < log_n.size() && i < log_r.size(); i++) begin
            if (log_n[i] !== log_r[i]) begin bad++; if (bad < 4) $display("entry %0d: %h / %h", i, log_n[i], log_r[i]); end else same++;
        end
        $display("%s: %0d writes, %0d markers put; %0d/%0d entries, %0d same, %0d wrong", bad == 0 && same == nw + nm ? "EQUIVALENT" : "DIFFER", nw, nm, log_n.size(), log_r.size(), same, bad);
        $finish;
    end
endmodule
