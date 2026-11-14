// W2 bus census (docs/plan-next.md, simulation only): +buscensus=FILE. At each DS line start one row of
// cumulative counters (the reader takes differences):
//   L,<clk_sys cycle>,<vcount>,<clk_mem cycle>, then per SDRAM client class (BC_N of them) busy,act,rd,wr,wait,
//   then the write chain's words by source (ring, capture/posted VRAM, bottom screen), then CPU/DMA VRAM units
//   (count and clk_sys clocks from nds_vram's c_req to its c_ack, the VRAM side of a unit only: ARM9 read, ARM9 write, DMA read, DMA write, ARM7 read, ARM7 write),
//   then PSRAM (requests: word read, block read, write; clk_sys clocks waiting for the ack; read-word clocks).
// SDRAM classes: 0 bottom-screen reads (port 0), 1 bridge (1), 2 VRAM 2D block, 3 VRAM 3D texel/palette block,
// 4 VRAM CPU/DMA read, 5 VRAM CPU/DMA single write, 6 ROM cache (3), 7 BIOS (4), 8 save (5), 9 ring reads (6),
// 10 the write chain, 11 diag (7), 12 refresh and all-bank precharge.
// busy: clk_mem clocks the controller is out of S_IDLE for that owner (the granted port's class, or the chain in
// S_CH); act/rd/wr: commands on the pins; wait: clocks a port's request waited for its grant (VRAM: by the class of
// nds_vram's request then).
`define BC_N 13
    integer bc_fd = 0;
    initial begin string fn; if ($value$plusargs("buscensus=%s", fn)) bc_fd = $fopen(fn, "w"); end
    longint bc_busy [`BC_N], bc_act [`BC_N], bc_rd [`BC_N], bc_wr [`BC_N], bc_wait [`BC_N];
    longint bc_mcyc = 0, bc_scyc = 0;
    longint bc_chw [3], bc_vu_n [6], bc_vu_c [6], bc_ps [5];
    integer bc_own = 12;
    // the VRAM port's request as x_vram holds it until the controller takes it (b_hot: vm_tex at its acceptance)
    function automatic integer bc_vclass();
        if (dut.x_vram.b_we) return 5;
        if (dut.x_vram.b_quad) return dut.x_vram.b_hot ? 3 : 2;
        return 4;
    endfunction
    function automatic integer bc_pclass(input integer p);
        case (p)
            0: return 0; 1: return 1; 2: return bc_vclass(); 3: return 6; 4: return 7; 5: return 8; 6: return 9;
            default: return 11;
        endcase
    endfunction
    initial foreach (bc_busy[i]) begin bc_busy[i] = 0; bc_act[i] = 0; bc_rd[i] = 0; bc_wr[i] = 0; bc_wait[i] = 0; end
    initial begin foreach (bc_chw[i]) bc_chw[i] = 0; foreach (bc_vu_n[i]) begin bc_vu_n[i] = 0; bc_vu_c[i] = 0; end foreach (bc_ps[i]) bc_ps[i] = 0; end
    always @(posedge dut.clk_mem) if (bc_fd != 0) begin
        logic [2:0] c;
        integer o;
        bc_mcyc++;
        if (dut.sdram.g_v) bc_own = bc_pclass(int'(dut.sdram.g));
        o = dut.sdram.mc.st == 3'd4 ? 10 : bc_own;
        c = {dut.sdram.SDRAM_nRAS, dut.sdram.SDRAM_nCAS, dut.sdram.SDRAM_nWE};
        if (dut.sdram.mc.st != 3'd1 && dut.sdram.mc.st != 3'd0) bc_busy[o]++;
        case (c)
            3'b011: bc_act[o]++;
            3'b101: bc_rd[o]++;
            3'b100: bc_wr[o]++;
            3'b001, 3'b010: if (dut.sdram.mc.st == 3'd1) bc_busy[12]++;
            default: ;
        endcase
        for (int p = 0; p < $bits(dut.sdram.m_valid); p++)
            if (dut.sdram.m_valid[p] && !dut.sdram.m_take[p] && !(dut.sdram.g_v && int'(dut.sdram.g) == p)) bc_wait[bc_pclass(p)]++;
    end
    integer bc_vc = -1;
    bit bc_vin = 0; integer bc_vk = 0; longint bc_vt = 0;
    always @(posedge dut.clk_sys) if (bc_fd != 0) begin
        bc_scyc++;
        if (dut.rg_go) bc_chw[0]++;
        if (dut.cw_go) bc_chw[1]++;
        if (dut.vw_ack) bc_chw[2]++;
        // a CPU/DMA VRAM unit: request until ack
        if (dut.ds.u_vram.c_req && !dut.ds.u_vram.c_ack) begin
            if (!bc_vin) begin bc_vin = 1; bc_vt = bc_scyc;
                bc_vk = dut.ds.u_vram.c_cpu ? 4 + int'(dut.ds.u_vram.c_we) : (dut.ds.u_vram.c_dma ? 2 : 0) + int'(dut.ds.u_vram.c_we); end
        end
        if (bc_vin && dut.ds.u_vram.c_ack) begin bc_vin = 0; bc_vu_n[bc_vk]++; bc_vu_c[bc_vk] += bc_scyc - bc_vt + 1; end
        if (dut.psram.s_req && dut.psram.s_ack) begin if (dut.psram.s_we) bc_ps[2]++; else if (dut.psram.s_n8) bc_ps[1]++; else bc_ps[0]++; end
        if (dut.psram.s_req && !dut.psram.s_ack) bc_ps[3]++;
        if (dut.psram.s_rvalid) bc_ps[4]++;
        if (int'(dut.vcount) != bc_vc) begin
            string r;
            bc_vc = int'(dut.vcount);
            r = $sformatf("L,%0d,%0d,%0d", bc_scyc, bc_vc, bc_mcyc);
            for (int i = 0; i < `BC_N; i++) r = {r, $sformatf(",%0d,%0d,%0d,%0d,%0d", bc_busy[i], bc_act[i], bc_rd[i], bc_wr[i], bc_wait[i])};
            for (int i = 0; i < 3; i++) r = {r, $sformatf(",%0d", bc_chw[i])};
            for (int i = 0; i < 6; i++) r = {r, $sformatf(",%0d,%0d", bc_vu_n[i], bc_vu_c[i])};
            for (int i = 0; i < 5; i++) r = {r, $sformatf(",%0d", bc_ps[i])};
            $fdisplay(bc_fd, "%s", r);
        end
    end
// +bustrace=FILE: the requests themselves, for W2's replay model (clk_mem cycles; the census's classes):
//   Q,<cyc>,<port>,<class>,<word address hex>,<words>,<we>   a port's request arrives (m_valid rises)
//   G,<cyc>,<port>                                            the arbiter grants it
//   T,<cyc>,<port>                                            the controller takes it
//   D,<cyc>                                                   a read's last word returns (reads complete in order)
//   W,<cyc>,<word address hex>                                a write-chain word drained (its source by
//                                                             address: ring, VRAM, bottom-screen regions)
//   H,<cyc>,<vcount>                                          a DS line starts (clk_sys event, clk_mem time)
    integer bt_fd = 0;
    initial begin string fn; if ($value$plusargs("bustrace=%s", fn)) bt_fd = $fopen(fn, "w"); end
    logic [7:0] bt_mv = 0;
    integer bt_own [$];
    logic bt_gv = 0;
    integer bt_vc = -1;
    always @(posedge dut.clk_mem) if (bt_fd != 0) begin
        for (int p = 0; p < $bits(dut.sdram.m_valid); p++) begin
            if (dut.sdram.m_valid[p] && !bt_mv[p])
                $fdisplay(bt_fd, "Q,%0d,%0d,%0d,%06x,%0d,%0d", bc_mcyc, p, bc_pclass(p), dut.sdram.m_addr[p*24 +: 24],
                          dut.sdram.m_n[p*4 +: 4], dut.sdram.m_we[p]);
            if (dut.sdram.m_take[p]) $fdisplay(bt_fd, "T,%0d,%0d", bc_mcyc, p);
        end
        bt_mv = 8'(dut.sdram.m_valid);
        if (dut.sdram.g_v && !bt_gv) $fdisplay(bt_fd, "G,%0d,%0d", bc_mcyc, dut.sdram.g);
        bt_gv = dut.sdram.g_v;
        if (dut.sdram.mc.r_valid && dut.sdram.mc.r_last) $fdisplay(bt_fd, "D,%0d", bc_mcyc);
        if (dut.sdram.bw_read) $fdisplay(bt_fd, "W,%0d,%06x", bc_mcyc, dut.sdram.bw_addr);
        if (int'(dut.vcount) != bt_vc) begin bt_vc = int'(dut.vcount); $fdisplay(bt_fd, "H,%0d,%0d", bc_mcyc, bt_vc); end
    end
