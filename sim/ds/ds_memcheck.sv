// Simulation-only check (sim/ds, `+memcheck`): a shadow of DS main RAM as the
// ARM9 should see it. ARM9 stores and the other masters' main-RAM writes
// (fabric write monitor) update it; every ARM9 load from main RAM that
// arm9_mem answers must match it. A mismatch is either a memory-system bug or
// a stale cache line the software did not maintain; the first ones are
// printed with their cycle. Bound into nds_top by sim/ds/ds.mk.
module ds_memcheck (input logic clk);
    logic [7:0] sh [0:(1<<22)-1];
    bit en;
    int bad = 0;
    longint cyc = 0;
    initial begin
        en = $test$plusargs("memcheck");
        for (int i = 0; i < (1<<22); i++) sh[i] = 8'd0;
    end
    always @(posedge clk) begin
        cyc++;
        if (en) begin
            // other masters' main-RAM writes
            if (nds_top.mon_we && nds_top.mon_master != 2'd1 && nds_top.mon_addr[31:24] == 8'h02)
                for (int b = 0; b < 4; b++) if (nds_top.mon_be[b])
                    sh[{nds_top.mon_addr[21:2], 2'(b)}] = nds_top.mon_wdata[b*8 +: 8];
            // the ARM9's own accesses, in arm9_mem's answer cycle
            if (nds_top.u_cpud.u_cpu.u_mem9.w_req && nds_top.u_cpud.u_cpu.u_mem9.d_ok && !nds_top.u_cpud.u_cpu.u_mem9.d_abort &&
                !nds_top.u_cpud.u_cpu.u_mem9.w_cp &&
                !nds_top.u_cpud.u_cpu.u_mem9.wd_itcm && !nds_top.u_cpud.u_cpu.u_mem9.wd_dtcm &&
                nds_top.u_cpud.u_cpu.u_mem9.w_addr[31:24] == 8'h02) begin
                logic [31:0] a;
                a = nds_top.u_cpud.u_cpu.u_mem9.w_addr;
                if (nds_top.u_cpud.u_cpu.u_mem9.w_we) begin
                    for (int b = 0; b < 4; b++) if (nds_top.u_cpud.u_cpu.u_mem9.w_be[b])
                        sh[{a[21:2], 2'(b)}] = nds_top.u_cpud.u_cpu.u_mem9.w_wdata[b*8 +: 8];
                end else begin
                    logic [31:0] want, got;
                    want = {sh[{a[21:2], 2'd3}], sh[{a[21:2], 2'd2}], sh[{a[21:2], 2'd1}], sh[{a[21:2], 2'd0}]};
                    got = nds_top.u_cpud.u_cpu.u_mem9.d_rdata_f;
                    for (int b = 0; b < 4; b++) if (!nds_top.u_cpud.u_cpu.u_mem9.w_be[b]) begin
                        want[b*8 +: 8] = 8'd0; got[b*8 +: 8] = 8'd0;
                    end
                    if (want != got) begin
                        bad++;
                        if (bad <= 20)
                            $display("%0d memcheck: ARM9 load %08x be %h got %08x shadow %08x (cached %0d hit %0d)", cyc, a,
                                     nds_top.u_cpud.u_cpu.u_mem9.w_be, got, want,
                                     nds_top.u_cpud.u_cpu.u_mem9.wd_cach, nds_top.u_cpud.u_cpu.u_mem9.wd_hit);
                    end
                end
            end
        end
    end
endmodule
bind nds_top ds_memcheck u_memcheck (.clk(clk));
