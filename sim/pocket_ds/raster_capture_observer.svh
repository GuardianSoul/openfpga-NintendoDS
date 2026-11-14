// Capture and affine-state extension for the observed captured-image path.
// No design drivers except +ro_fault=3's actual capture-address witness.
`define RC_B dut.ds.u_disp.u_gpu2d.u_bg
`define RC_U dut.ds.u_disp.u_gpu2d
    integer rc_fd=0;
    string rc_path;
    logic [17:0] rc_fault_address;
    longint rc_digest=64'h14650fb0739d0383,rc_words=0,rc_wait=0;
    longint rc_row_count[4][256];
    integer rc_last_frame=-1;
    longint rc_fog_eligible=0,rc_fog_changed=0;
    integer rc_fog_min=129,rc_fog_max=-1;
    // Independent completed-pixel oracle, not the read buffer's own write
    // ports. Only compare reads requested while a matching FULL row is valid.
    // This separates semantic data errors from provenance tags at a boundary.
    longint rc_gen=0,rc_full_checks=0,rc_full_errors=0,rc_cons_checks=0,rc_cons_errors=0;
    longint rc_final_gen[49152];
    logic [22:0] rc_final_pixel[49152];
    logic [22:0] rc_expect_pixel=0;
    bit rc_expect_valid=0;
    integer rc_expect_y=0,rc_expect_x=0;
    initial foreach(rc_final_gen[i])rc_final_gen[i]=-1;
    task automatic rc_mix(input logic [63:0] v);
        rc_digest=(rc_digest^v)*64'h100000001b3;
        rc_digest=(rc_digest^64'(ro_cycle))*64'h100000001b3;
    endtask
    function automatic logic [17:0] rc_expected_address;
        integer width_,offset_,pixel_;
        width_=int'(`RC_B.c_capw);
        offset_=int'(`RC_B.capcnt[19:18])*16384;
        pixel_=offset_+int'(`RC_B.j_line)*width_+int'(`RC_B.s6.x);
        return {`RC_B.capcnt[17:16],16'(pixel_)};
    endfunction
    initial if($value$plusargs("rcap=%s",rc_path))begin
        rc_fd=$fopen(rc_path,"w");if(!rc_fd)$fatal(1,"RCAP_OPEN");
        $fdisplay(rc_fd,"# RCAP1 CAP=accepted halfword; JOB=effective state; AFF=loaded per-pass affine accumulators; IO=observed write");
    end
    initial begin
        wait(ro_started);
        forever begin
            @(negedge dut.clk_sys);
            if(!ro_fault_fired && ro_fault==3 && dut.ds.cap_we && dut.ds.cap_ready && `RC_B.j_line>=8)begin
                rc_fault_address=dut.ds.cap_addr ^ 18'h100;
                force dut.ds.cap_addr=rc_fault_address;
                ro_fault_fired=1;
                $display("ROBS_INJECT actual=cap_addr bit=8 cycle=%0d",ro_cycle);
                @(posedge dut.clk_sys);#1;release dut.ds.cap_addr;
            end
        end
    end
    always @(posedge dut.clk_sys)if(ro_started)begin
        // This digest remains active with detailed observation disabled.
        if(dut.ds.cap_we && dut.ds.cap_ready)begin
            rc_mix({8'd1,22'd0,dut.ds.cap_addr,dut.ds.cap_data});rc_words++;
            if(ro_enable!=0)begin
                if(dut.ds.cap_addr!==rc_expected_address())ro_bad($sformatf("capture_address got=%h expected=%h",dut.ds.cap_addr,rc_expected_address()));
                rc_row_count[dut.ds.cap_addr[17:16]][dut.ds.cap_addr[15:8]]++;
                $fdisplay(rc_fd,"CAP,%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%0d,%0d",ro_cycle,v_frames,ro_gen,
                    `RC_B.j_line,`RC_B.s6.x,dut.ds.cap_addr,dut.ds.cap_data,`RC_B.capcnt,`RC_B.c_capw,`RC_B.c_cap3d);
            end
        end
        rc_wait+=longint'(dut.ds.cap_we && !dut.ds.cap_ready);
        if(ro_enable!=0)begin
            if(`RC_U.ld_go)$fdisplay(rc_fd,"JOB,%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%h,%h,%h",ro_cycle,v_frames,ro_gen,
                `RC_U.ld_eng,`RC_U.ld_line,`RC_U.wst.dispcnt,`RC_U.wst.xref,`RC_U.wst.yref,`RC_U.wst.rota,`RC_U.wst.rotc,`RC_U.capcnt);
            // WST_RF loads affine values via n_x/n_y, so observe the actual
            // post-load registers rather than assuming wst retains those words.
            if(`RC_B.js==`RC_B.J_SETUP)$fdisplay(rc_fd,"AFF,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%h,%h,%h",ro_cycle,v_frames,ro_gen,
                `RC_B.j_eng,`RC_B.j_line,`RC_B.c_kind,`RC_B.rx,`RC_B.ry,`RC_B.ra,`RC_B.rc,`RC_B.c_map);
            if(dut.ds.io_req && dut.ds.io_we && !dut.ds.io_cpu && dut.ds.io_addr[23:14]==0 &&
               (dut.ds.io_addr[13:2]<=12'h01c || (dut.ds.io_addr[13:2]>=12'h400 && dut.ds.io_addr[13:2]<=12'h41c) ||
                (dut.ds.io_addr[13:2]>=12'h090 && dut.ds.io_addr[13:2]<=12'h092) || dut.ds.io_addr[13:2]==12'h0c1))
                $fdisplay(rc_fd,"IO,%0d,%0d,%0d,%h,%h,%h",ro_cycle,v_frames,ro_gen,{dut.ds.io_addr,2'b00},dut.ds.io_be,dut.ds.io_wdata);
            if(v_frames!=rc_last_frame)begin
                $fdisplay(rc_fd,"DISPLAY,%0d,%0d,%0d,%h,%h,%h,%0d",ro_cycle,v_frames,ro_gen,dut.ds.powcnt1,
                    dut.ds.u_disp.capcnt,dut.ds.vramcnt,dut.stat_late);
                rc_last_frame=v_frames;
            end
            if(dut.ds.g_3d.u_gpu3d.frame_go)$fdisplay(rc_fd,"FOGSTATE,%0d,%0d,%h,%h,%h,%0d,%0d",ro_cycle,v_frames,
                dut.ds.g_3d.u_gpu3d.r_dispcnt,dut.ds.g_3d.u_gpu3d.r_fog_color,dut.ds.g_3d.u_gpu3d.r_fog_offset,
                dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.FOG_SHARE,dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.FOG_DADD8);
            if(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fst==dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.F_FT &&
                dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.FOG && dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.dispcnt[7] &&
                dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fp_attr[15])begin
                rc_fog_eligible++;
                rc_fog_changed+=longint'(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fog_out!=dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fp_ecol);
                if(int'(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fog_dt)<rc_fog_min)rc_fog_min=int'(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fog_dt);
                if(int'(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fog_dt)>rc_fog_max)rc_fog_max=int'(dut.ds.g_3d.u_gpu3d.u_raster.u_fpass.fog_dt);
            end
            if(rc_fd && $ftell(rc_fd)>536870912)$fatal(1,"RCAP_OUTPUT_CAP");
        end
    end
    always @(posedge dut.clk_sys)begin : rc_completed_pixel_oracle
        integer index_;
        if(ro_started && ro_enable!=0)begin
            if(!`RC_B.stall && `RC_B.s2.v && `RC_B.c_3d && dut.ds.g_3d.u_gpu3d.ring_have &&
                !dut.ds.g_3d.u_gpu3d.g_ring.u_ringx.rb_p[dut.ds.g_3d.u_gpu3d.l3d_line[0]] &&
                !dut.ds.g_3d.u_gpu3d.l3d_rear && dut.ds.g_3d.u_xscroll.in_q)begin
                index_=int'(dut.ds.g_3d.u_gpu3d.l3d_line)*256+rc_expect_x;
                if(rc_final_gen[index_]==rc_gen)begin
                    rc_cons_checks++;
                    if(dut.ds.g_3d.u_gpu3d.ring_q!==rc_final_pixel[index_])begin
                        rc_cons_errors++;
                        if(rc_cons_errors<=32)$fdisplay(rc_fd,"CONSUMEDFULL,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h",ro_cycle,v_frames,rc_gen,
                            dut.ds.g_3d.u_gpu3d.l3d_line,`RC_B.s2.x,rc_expect_y,rc_expect_x,
                            dut.ds.g_3d.u_gpu3d.ring_q,rc_final_pixel[index_]);
                    end
                end
            end
            if(rc_expect_valid)begin
                rc_full_checks++;
                if(dut.ds.g_3d.u_gpu3d.ring_q!==rc_expect_pixel)begin
                    rc_full_errors++;
                    if(rc_full_errors<=32)$fdisplay(rc_fd,"FULLDATA,%0d,%0d,%0d,%0d,%0d,%h,%h",ro_cycle,v_frames,rc_gen,rc_expect_y,rc_expect_x,
                        dut.ds.g_3d.u_gpu3d.ring_q,rc_expect_pixel);
                end
            end
            index_=int'(dut.ds.g_3d.u_gpu3d.l3d_line)*256+int'(dut.ds.g_3d.u_gpu3d.l3d_raddr);
            rc_expect_valid=(!dut.ds.g_3d.u_gpu3d.frame_go && dut.ds.g_3d.u_gpu3d.ring_have &&
                !dut.ds.g_3d.u_gpu3d.g_ring.u_ringx.rb_p[dut.ds.g_3d.u_gpu3d.l3d_line[0]] && rc_final_gen[index_]==rc_gen);
            rc_expect_pixel=rc_final_pixel[index_];
            rc_expect_y=int'(dut.ds.g_3d.u_gpu3d.l3d_line);rc_expect_x=int'(dut.ds.g_3d.u_gpu3d.l3d_raddr);
            if(dut.ds.g_3d.u_gpu3d.px_valid)begin
                index_=int'(dut.ds.g_3d.u_gpu3d.px_y)*256+int'(dut.ds.g_3d.u_gpu3d.px_x);
                rc_final_gen[index_]=rc_gen;rc_final_pixel[index_]=dut.ds.g_3d.u_gpu3d.px_color;
            end
        end
        if(dut.ds.g_3d.u_gpu3d.frame_go)rc_gen<=rc_gen+1;
    end
    final begin
        if(rc_fd)begin
            for(integer b=0;b<4;b++)for(integer y=0;y<256;y++)if(rc_row_count[b][y])
                $fdisplay(rc_fd,"BANKROW,%0d,%0d,%0d",b,y,rc_row_count[b][y]);
            $fdisplay(rc_fd,"TOTAL,%0d,%0d,%h",rc_words,rc_wait,rc_digest);$fclose(rc_fd);
        end
        $display("RCAP_DIGEST %h words=%0d wait=%0d",rc_digest,rc_words,rc_wait);
        $display("RCAP_FULLDATA checks=%0d errors=%0d",rc_full_checks,rc_full_errors);
        $display("RCAP_CONSUMEDFULL checks=%0d errors=%0d",rc_cons_checks,rc_cons_errors);
        $display("RCAP_FOG eligible=%0d changed=%0d density_min=%0d density_max=%0d",rc_fog_eligible,rc_fog_changed,rc_fog_min,rc_fog_max);
    end
`undef RC_B
`undef RC_U
