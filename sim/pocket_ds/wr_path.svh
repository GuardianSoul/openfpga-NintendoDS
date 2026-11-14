// +wrpath: the SDRAM write chain (clk_mem): what nds_sdram_mc does while core_top's write FIFO is full (bw_full),
// and the chains' lengths (words a row opening) over the run
`define WP_M dut.sdram.mc
    bit wp_on; initial wp_on = $test$plusargs("wrpath");
    longint wp_full = 0, wp_f_ch = 0, wp_f_rd = 0, wp_f_wr = 0, wp_f_iw = 0, wp_f_ig = 0, wp_f_ir = 0, wp_f_io = 0;
    longint wp_ch = 0, wp_w = 0, wp_clk = 0, wp_ch1 = 0, wp_ch2 = 0, wp_ch8 = 0, wp_chl = 0;
    longint wp_cur = 0; bit wp_in = 0;
    always @(posedge dut.clk_mem) if (wp_on && !dut.rst_sys) begin
        wp_clk++;
        if (dut.bw_full) begin
            wp_full++;
            case (`WP_M.st)
                3'd4: wp_f_ch++;
                3'd2: wp_f_rd++;
                3'd3: wp_f_wr++;
                3'd1: if (`WP_M.gap != 0) wp_f_ig++; else if (`WP_M.ref_owed != 0) wp_f_ir++; else if (`WP_M.c_valid) wp_f_iw++; else wp_f_io++;
                default: wp_f_io++;
            endcase
        end
        if (`WP_M.bw_read) begin wp_w++; wp_cur++; end
        if (`WP_M.st == 3'd4) wp_in = 1;
        else if (wp_in) begin
            wp_in = 0; wp_ch++;
            if (wp_cur <= 1) wp_ch1++; else if (wp_cur == 2) wp_ch2++; else if (wp_cur <= 8) wp_ch8++; else wp_chl++;
            wp_cur = 0;
        end
    end
    final if (wp_on && wp_clk != 0) begin
        $display("wrpath write FIFO full: %0d clk_mem (%.1f %%): chain %0d, read %0d, single write %0d, idle: gap %0d, refresh %0d, a read waiting %0d, other %0d",
            wp_full, 100.0 * wp_full / wp_clk, wp_f_ch, wp_f_rd, wp_f_wr, wp_f_ig, wp_f_ir, wp_f_iw, wp_f_io);
        $display("wrpath chains: %0d, %0d words (%.2f a chain); 1 word %0d, 2 %0d, 3-8 %0d, 9+ %0d",
            wp_ch, wp_w, wp_ch ? real'(wp_w) / wp_ch : 0.0, wp_ch1, wp_ch2, wp_ch8, wp_chl);
    end
// +wrpath: why each write chain ends (the first reason that holds, in nds_sdram_mc's order), and whether the next
// chain opens the row the last one closed (its ACT + tRCD and the last one's tWR + tRP could have been saved)
    longint wp_e[8]; logic [14:0] wp_lrow; logic [2:0] wp_pst = 0; bit wp_lv = 0; longint wp_same = 0, wp_rdh = 0, wp_rdn = 0;
    always @(posedge dut.clk_mem) if (wp_on && !dut.rst_sys) begin
        if (`WP_M.st == 3'd4 && `WP_M.stn && `WP_M.ch_hi && (!`WP_M.bw_valid || !`WP_M.q_row || `WP_M.bw_addr != {`WP_M.q_addr[23:8], `WP_M.q_inc}
              || `WP_M.chain_n == 6'd31 || `WP_M.ref_owed != 0 || `WP_M.c_hurry || (`WP_M.SOFT_MIN != 0 && `WP_M.c_soft && `WP_M.chain_n >= 6'(`WP_M.SOFT_MIN - 1)))) begin
            if (!`WP_M.bw_valid) wp_e[0]++;
            else if (!`WP_M.q_row) wp_e[1]++;
            else if (`WP_M.bw_addr != {`WP_M.q_addr[23:8], `WP_M.q_inc}) wp_e[2]++;
            else if (`WP_M.chain_n == 6'd31) wp_e[3]++;
            else if (`WP_M.ref_owed != 0) wp_e[4]++;
            else if (`WP_M.c_hurry) wp_e[5]++;
            else wp_e[6]++;
            wp_lrow = `WP_M.q_addr[22:8]; wp_lv = 1;
        end
        // a chain's ACTIVE (S_IDLE -> S_CH): same bank and row as the last chain's
        if (`WP_M.st == 3'd4 && wp_pst != 3'd4 && wp_lv && `WP_M.q_addr[22:8] == wp_lrow) wp_same++;
        wp_pst = `WP_M.st;
    end
    final if (wp_on && wp_ch != 0)
        $display("wrpath chain ends: FIFO empty %0d, row end %0d, next word elsewhere %0d, 32 words %0d, refresh %0d, hurry %0d, soft %0d; next chain in the same row %0d",
            wp_e[0], wp_e[1], wp_e[2], wp_e[3], wp_e[4], wp_e[5], wp_e[6], wp_same);
