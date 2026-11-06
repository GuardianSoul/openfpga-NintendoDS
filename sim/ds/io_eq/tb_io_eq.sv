// nds_io against an earlier revision (old_nds_io, io_eq.sh): random ARM9/ARM7
// accesses, mostly to its own registers (0x130/0x134, 0x204, 0x240-0x248,
// 0x300-0x308, 0x060, 0x600, 0xF00-0xF27), random keys and pen, one access
// every 1-3 clocks. Every clock: io_ack, io_rdata (when acked) and the
// register outputs must match.
`timescale 1ns/1ps
module tb_io_eq;
    logic clk = 0; always #5 clk = !clk;
    logic rst = 1, io_req = 0, io_we = 0, io_cpu = 0;
    logic [3:0] io_be = 4'hF;
    logic [23:2] io_addr = 0;
    logic [31:0] io_wdata = 0;
    logic [11:0] keys = 0; logic pen = 0;
    wire a_n, a_o; wire [31:0] r_n, r_o;
    wire [15:0] p1_n, p1_o, em_n, em_o, bp_n, bp_o, kx_n, kx_o, ky_n, ky_o, ox_n, ox_o, oy_n, oy_o;
    wire [1:0] p2_n, p2_o, wc_n, wc_o; wire [71:0] vc_n, vc_o; wire [31:0] bc_n, bc_o;
    wire h_n, h_o, k9_n, k9_o, k7_n, k7_o;
    `define IO(M, NM, ACK, RD, P1, P2, EM, WC, VC, BP, BC, KX, KY, OX, OY, H, K9, K7) M NM (.clk, .rst, .io_req, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata, \
        .io_ack(ACK), .io_rdata(RD), .sys_req(), .sys_rdata(32'h1111), .disp_req(), .disp_rdata(32'h2222), .cart_req(), .cart_reg(), \
        .cart_rdata(32'h3333), .spi_req(), .spi_rdata(32'h4444), .rtc_req(), .rtc_rdata(32'h5555), .snd_req(), .snd_ack(1'b1), \
        .snd_rdata(32'h6666), .snd_real(1'b1), .gx_req(), .gx_ack(1'b1), .gx_rdata(32'h7777), .gx_real(1'b1), .gx_ovf(1'b0), \
        .wf_req(), .wf_ack(1'b1), .wf_rdata(32'h8888), \
        .disp3dcnt_o(), .keys(keys), .pen_down(pen), .lid_closed(1'b0), .rom_size(32'h0123_4567), .mem_dirty(1'b1), .save_info(8'h5A), \
        .rtc_valid(1'b1), .rtc_date(32'h2026_1030), .rtc_time(32'h0012_3456), \
        .vramstat(2'd2), .powcnt1(P1), .powcnt2(P2), .exmem_o(EM), .wramcnt(WC), .vramcnt(VC), .bootctl(BC), \
        .halt7(H), .irq_key9(K9), .irq_key7(K7), .gx_irq())
    `IO(nds_io,     u_new, a_n, r_n, p1_n, p2_n, em_n, wc_n, vc_n, bp_n, bc_n, kx_n, ky_n, ox_n, oy_n, h_n, k9_n, k7_n);
    `IO(old_nds_io, u_old, a_o, r_o, p1_o, p2_o, em_o, wc_o, vc_o, bp_o, bc_o, kx_o, ky_o, ox_o, oy_o, h_o, k9_o, k7_o);

    // vramcnt_chg: high in the clock after vramcnt changed (what a compare against a copy gave)
    logic [71:0] vc_q = '0;
    integer chg_bad = 0;
    always @(posedge clk) begin
        vc_q <= vc_n;
        if (!rst && (vc_n != vc_q) != u_new.vramcnt_chg) begin chg_bad++; if (chg_bad <= 3) $display("cycle %0t: vramcnt_chg %b, %h -> %h", $time, u_new.vramcnt_chg, vc_q, vc_n); end
    end
    static int words [] = '{12'h04C, 12'h04D, 12'h081, 12'h090, 12'h091, 12'h092, 12'h0C0, 12'h0C1, 12'h0C2,
                            12'h018, 12'h180, 12'h3C0, 12'h3C1, 12'h3C2, 12'h3C3, 12'h3C4, 12'h3C5, 12'h3C6,
                            12'h3C7, 12'h3C8, 12'h3C9, 12'h3CA, 12'h000, 12'h070};
    static logic [3:0] bes [] = '{4'hF, 4'hF, 4'h3, 4'hC, 4'h1, 4'h2, 4'h4, 4'h8, 4'h7, 4'hE};
    longint n = 0, bad = 0, reads = 0;
    initial begin
        int cycles;
        if (!$value$plusargs("cycles=%d", cycles)) cycles = 2000000;
        void'($urandom($test$plusargs("seed2") ? 2 : 1));
        repeat (3) @(negedge clk); rst = 0;
        repeat (cycles) begin
            @(negedge clk);
            if ($urandom_range(0, 99) == 0) keys = 12'($urandom);
            if ($urandom_range(0, 199) == 0) pen = !pen;
            if (!io_req && !a_n && $urandom_range(0, 2) == 0) begin
                io_req = 1; io_we = $urandom_range(0, 1); io_cpu = $urandom_range(0, 1);
                io_addr = {10'd0, 12'(words[$urandom_range(0, words.size() - 1)])};
                io_be = bes[$urandom_range(0, bes.size() - 1)]; io_wdata = $urandom;
            end else io_req = 0;
        end
        $display("%s: %0d cycles, %0d reads, %0d differing, vramcnt_chg wrong %0d", bad == 0 && chg_bad == 0 ? "EQUIVALENT" : "DIFFER", n, reads, bad, chg_bad);
        $finish;
    end
    always @(posedge clk) if (!rst) begin
        n++;
        if (a_n && !io_we) reads++;
        if (a_n !== a_o || (a_n && r_n !== r_o) || p1_n !== p1_o || p2_n !== p2_o || em_n !== em_o || wc_n !== wc_o ||
            vc_n !== vc_o || bp_n !== bp_o || bc_n !== bc_o || kx_n !== kx_o || ky_n !== ky_o || ox_n !== ox_o || oy_n !== oy_o ||
            h_n !== h_o || k9_n !== k9_o || k7_n !== k7_o) begin
            bad++;
            if (bad < 5) $display("cycle %0d: ack %b/%b rdata %08x/%08x addr %03x cpu %b", n, a_n, a_o, r_n, r_o, io_addr[13:2], io_cpu);
        end
    end
endmodule
