// space-cg item 5: gpu3d_gxlight (new) against gpu3d_gxlight_old (669c40c9) cycle for cycle, random
// register-file writes into the snooped state, random NORMAL starts, holds and aborts
module tb_light;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    logic        we, start, hold, abort;
    logic [10:0] wa;
    logic [31:0] wd;
    logic [29:0] nrm;
    logic        busy_o, busy_n, cw_o, cw_n;
    logic [29:0] nr_o, nr_n;
    logic [10:0] cwa_o, cwa_n;
    logic [31:0] cwd_o, cwd_n;
    gpu3d_gxlight_old u_o (.clk, .rst, .we, .wa, .wd, .start, .nrm, .hold, .abort, .busy(busy_o), .nr(nr_o),
                           .cw(cw_o), .cwa(cwa_o), .cwd(cwd_o));
    gpu3d_gxlight     u_n (.clk, .rst, .we, .wa, .wd, .start, .nrm, .hold, .abort, .busy(busy_n), .nr(nr_n),
                           .cw(cw_n), .cwa(cwa_n), .cwd(cwd_n));
    longint cyc = 0, starts = 0, writes = 0, bad = 0, nz = 0, lal = 0, pr = 0;
    int n_cyc;
    function automatic logic [31:0] rnd_wd();
        int r = $urandom_range(0, 9);
        if (r < 2) return 32'd0;
        if (r < 4) return $urandom & 32'h3FF;
        if (r < 5) return 32'h3FF;
        return $urandom;
    endfunction
    function automatic logic [10:0] rnd_wa();
        case ($urandom_range(0, 9))
            0, 1, 2: return 11'h100 + 11'($urandom_range(0, 63));   // light blocks
            3:       return 11'h180 + 11'($urandom_range(0, 127));  // shininess table
            4:       return 11'h161 + 11'($urandom_range(0, 2));    // MEMI
            5:       return 11'h020 + 11'($urandom_range(0, 15));   // VEC
            6:       return 11'h0D3;                                  // CATTR
            7:       return 11'h0E1;                                  // USETAB
            default: return 11'($urandom);
        endcase
    endfunction
    initial begin
        if (!$value$plusargs("cycles=%d", n_cyc)) n_cyc = 2000000;
        we = 0; start = 0; hold = 0; abort = 0; wa = 0; wd = 0; nrm = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        while (cyc < n_cyc) begin
            @(negedge clk);
            // writes while busy in half the time (the engine does not write the snooped state then)
            we = (cyc % 4096 < 2048) ? ($urandom_range(0, 99) < 40) : (!busy_n && $urandom_range(0, 99) < 40);
            wa = rnd_wa(); wd = rnd_wd();
            start = !busy_n && $urandom_range(0, 99) < 10;
            nrm = $urandom;
            hold = $urandom_range(0, 99) < 10;
            abort = busy_n && $urandom_range(0, 999) < 2;
            @(posedge clk); #1;
            cyc++;
            if (start) starts++;
            if (cw_n) writes++;
            if (cw_n && cwd_n[16:12] != 5'd0) nz++;
            lal += $countones(u_n.vb_al); pr += $countones(u_n.vb_pr);
            if ({busy_o, nr_o, cw_o, cwa_o, cwd_o} != {busy_n, nr_n, cw_n, cwa_n, cwd_n}) begin
                bad++;
                if (bad < 10) $display("MISMATCH cyc %0d: old busy %b cw %b %03x %08x  new busy %b cw %b %03x %08x", cyc,
                                       busy_o, cw_o, cwa_o, cwd_o, busy_n, cw_n, cwa_n, cwd_n);
            end
        end
        $display("%0d cycles, %0d starts, %0d CURCOL writes (%0d non-zero), %0d LAL adds, %0d DIFF/SPEC adds, %0d mismatches",
                 cyc, starts, writes, nz, lal, pr, bad);
        if (bad == 0) $display("LIGHT EQUIVALENT"); else $display("LIGHT DIFFERENT");
        $finish;
    end
endmodule
