// nds_disp_refs against the eight registers it replaces (nds_disp before:
// a CPU write and the sequencer's write in one clock, the sequencer's
// assigned last), compared every cycle on both read ports. Stimulus: the
// sequencer's Q_POST bursts (eight read-modify-writes on consecutive clocks)
// and Q_PRE reads, CPU writes at random (one in CPU_GAP clocks at most),
// often of the reference the sequencer writes in the same clock; resets,
// each followed by the owner's clear (z_we for 8 clocks, no other access).
//   +cycles=N  +seed=S  +gap=CPU_GAP
module tb_disp_refs;
    logic clk = 0;
    always #5 clk = !clk;
    logic        rst = 1;
    logic [2:0]  c_a = 0, s_a = 0, p_a = 0;
    logic        c_we = 0, p_we = 0, z_we = 0;
    logic [2:0]  z_a = 0;
    int          zc = 8;              // clear clocks left after a reset
    logic [31:0] c_wd = 0, p_wd = 0;
    logic [31:0] c_q, s_q;
    nds_disp_refs dut (.*);

    logic [31:0] r [8];                 // the registers
    int unsigned seed = 1;
    longint cycles = 1000000, cyc = 0, errs = 0, n_c = 0, n_coll = 0, n_p = 0;
    int     gap = 2, since = 0, pk = 0;
    initial begin
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("gap=%d", gap));
        void'($urandom(seed));
        for (int k = 0; k < 8; k++) r[k] = 32'd0;
        repeat (2) @(posedge clk);
        rst = 0;
        while (cyc < cycles) begin
            @(negedge clk);
            // compare (the value now, before this edge's writes)
            if (!rst && zc == 0) begin
                if (c_q !== r[c_a]) begin errs++; if (errs < 8) $display("cycle %0d: c_q[%0d] %h, the register %h", cyc, c_a, c_q, r[c_a]); end
                if (s_q !== r[s_a]) begin errs++; if (errs < 8) $display("cycle %0d: s_q[%0d] %h, the register %h", cyc, s_a, s_q, r[s_a]); end
            end
            // the sequencer: a Q_POST burst now and then, else Q_PRE-like reads
            p_we = 0;
            if (pk == 0 && $urandom % 300 == 0) pk = 1;
            if (pk != 0) begin
                p_a = 3'(pk - 1); s_a = p_a;
                p_we = $urandom % 8 != 0;           // a disabled layer skips
                p_wd = ($urandom % 4 == 0) ? $urandom : r[p_a] + 32'($signed(16'($urandom)));
                if (p_we) n_p++;
                pk = pk == 8 ? 0 : pk + 1;
            end else s_a = 3'($urandom);
            // the CPU: a write at most every `gap` clocks, often of the
            // reference the sequencer writes now
            c_we = 0; since++;
            c_a = 3'($urandom);
            if (since >= gap && $urandom % 3 == 0) begin
                c_we = 1; since = 0; n_c++;
                if (p_we && $urandom % 2) c_a = p_a;
                c_wd = $urandom;
                if (p_we && c_a == p_a) n_coll++;
            end
            // after a reset the owner clears every entry before any other access
            if (rst) zc = 8;
            z_we = zc != 0; z_a = 3'(zc);
            if (zc != 0) begin p_we = 0; c_we = 0; pk = 0; zc--; end
            if ($urandom % 100000 == 0) rst = 1; else rst = 0;
            @(posedge clk);
            cyc++;
            // the registers, as nds_disp's always block
            if (rst) for (int k = 0; k < 8; k++) r[k] = 32'd0;
            else begin
                if (c_we) r[c_a] = c_wd;
                if (p_we) r[p_a] = p_wd;
            end
        end
        $display("disp_refs: %0d cycles, %0d CPU writes (%0d in the clock of a sequencer write of the same reference), %0d sequencer writes: %0d errors",
                 cyc, n_c, n_coll, n_p, errs);
        if (errs || n_coll == 0) begin $display("FAIL"); $fatal(1); end
        $display("PASS");
        $finish;
    end
endmodule
