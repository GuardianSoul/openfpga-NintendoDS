// Analogue's io_bridge_peripheral against rtl/apf/io_bridge_peripheral.v, each with its own bus wires: random
// writes and reads (the bus master drives both lanes on spiclk), every output compared every clock.
`timescale 1ns/1ps
module tb_bridge_eq;
    parameter int SEED = 1;
    reg clk = 0; always #6.7 clk = !clk;
    wire mo_a, mi_a, ck_a, mo_b, mi_b, ck_b;
    pullup(mo_a); pullup(mi_a); pullup(ck_a); pullup(mo_b); pullup(mi_b); pullup(ck_b);
    reg ss = 1, drv = 0, ckv = 1, mov = 1, miv = 1, ckdrv = 0;
    assign mo_a = drv ? mov : 1'bz; assign mi_a = drv ? miv : 1'bz; assign ck_a = ckdrv ? ckv : 1'bz;
    assign mo_b = drv ? mov : 1'bz; assign mi_b = drv ? miv : 1'bz; assign ck_b = ckdrv ? ckv : 1'bz;
    wire [31:0] aa, ab, wa, wb; wire va, vb, ra, rb, wea, web;
    reg [31:0] rd_data = 32'h12345678;
    io_bridge_peripheral_ref u_ref (.clk, .reset_n(1'b1), .endian_little(1'b1), .pmp_addr(aa), .pmp_addr_valid(va), .pmp_rd(ra),
        .pmp_rd_data(rd_data), .pmp_wr(wea), .pmp_wr_data(wa), .phy_spimosi_w(mo_a), .phy_spimiso_w(mi_a), .phy_spiclk_w(ck_a), .phy_spiss(ss));
    io_bridge_peripheral u_new (.clk, .reset_n(1'b1), .endian_little(1'b1), .pmp_addr(ab), .pmp_addr_valid(vb), .pmp_rd(rb),
        .pmp_rd_data(rd_data), .pmp_wr(web), .pmp_wr_data(wb), .phy_spimosi_w(mo_b), .phy_spimiso_w(mi_b), .phy_spiclk_w(ck_b), .phy_spiss(ss));
    integer seed = SEED, n = 0, errs = 0, cyc = 0, i, reads = 0, writes = 0, bits;
    reg [31:0] x, got_a, got_b;
    task automatic pair(input [1:0] d);
        mov = d[1]; miv = d[0]; ckv = 0; repeat (2) @(posedge clk);
        ckv = 1; repeat (2) @(posedge clk);
    endtask
    task automatic word(input [31:0] d);
        for (i = 30; i >= 0; i -= 2) pair(d[i +: 2]);
    endtask
    always @(posedge clk) begin
        cyc <= cyc + 1;
        // (the address and data outputs mean something from valid on, or with the strobe)
        if (cyc > 20 && (va !== vb || ra !== rb || wea !== web || (va === 1'b1 && aa !== ab) || (wea === 1'b1 && wa !== wb) ||
                         mo_a !== mo_b || mi_a !== mi_b || ck_a !== ck_b)) begin
            if (errs < 8) $display("cycle %0d: valid %b %b rd %b %b wr %b %b addr %h %h data %h %h lines %b%b%b %b%b%b", cyc, va, vb, ra, rb, wea, web, aa, ab, wa, wb, mo_a, mi_a, ck_a, mo_b, mi_b, ck_b);
            errs <= errs + 1;
        end
    end
    initial begin
        u_ref.state = 0; u_ref.spis = 1; u_ref.pmp_wr = 0; u_ref.pmp_rd = 0; u_ref.pmp_addr_valid = 0; u_ref.spis_done = 0; u_ref.spis_tx = 0;
        u_new.state = 0; u_new.spis = 1; u_new.pmp_wr = 0; u_new.pmp_rd = 0; u_new.pmp_addr_valid = 0; u_new.spis_done = 0; u_new.spis_tx = 0;
        repeat (20) @(posedge clk);
        for (n = 0; n < 4000; n++) begin
            x = $random(seed);
            rd_data = $random(seed);
            ss = 0; repeat (6) @(posedge clk);
            drv = 1; ckdrv = 1;
            word({x[31:2], 1'b0, x[0]});            // the address; bit 0 says write
            if (x[0]) begin
                word($random(seed));
                writes = writes + 1;
                repeat (10) @(posedge clk);
                drv = 0; ckdrv = 0;
            end else begin
                reads = reads + 1;
                drv = 0; ckdrv = 0;
                // the slave answers on the same pins
                repeat (140) @(posedge clk);
            end
            ss = 1; repeat (12) @(posedge clk);
        end
        $display("%s reads %0d writes %0d errs %0d", errs == 0 ? "PASS" : "FAIL", reads, writes, errs);
        $finish;
    end
endmodule
