// Final-consumer experiment only. Passive events and actual consumed-word
// checks; no signal drivers. Existing v1 observer/digest remain unchanged.
`define RL_G dut.ds.g_3d.u_gpu3d
`define RL_Q `RL_G.g_ring.u_ringx
`define RL_B dut.ds.u_disp.u_gpu2d.u_bg
    bit rl_live=0,rl_released=0,rl_full=0,rl_raw=0,rl_overwrite=0;
    longint rl_cycle=0,rl_sample=-1,rl_checks=0,rl_errors=0,rl_windows=0;
    integer rl_row=0,rl_raddr_q=0;
    // An independent counter increments in this block BEFORE event sampling.
    // Both counters see every SYS edge. Never read another always block's
    // blocking increment to timestamp a pre-NBA sample.
    always @(posedge dut.clk_sys)begin
        rl_cycle++;
        if(ro_started && ro_enable!=0)begin
        // First-word chronology is independent of ring tags and write-port
        // shadows. Compare final producer -> posted SDRAM -> returned block
        // -> real read buffer, across copies that share the staging address.
        if(`RL_G.px_valid && `RL_G.px_x==0)
            $fdisplay(ro_fd,"WPROD,%0d,%0d,%0d,%0d,%h",rl_cycle,v_frames,rc_gen,`RL_G.px_y,`RL_G.px_color);
        if(`RL_Q.rg_wreq && `RL_Q.rg_wack && `RL_Q.rg_waddr[7:0]==0)
            $fdisplay(ro_fd,"WPOST,%0d,%0d,%0d,%0d,%h,%h",rl_cycle,v_frames,rc_gen,`RL_Q.rg_waddr[15:8],`RL_Q.rg_wdata[22:0],`RL_Q.sr_a);
        if(`RL_Q.rg_rvalid && `RL_Q.est==`RL_Q.E_RDAT && `RL_Q.rk==0 && `RL_Q.rblk==0)
            $fdisplay(ro_fd,"WRET,%0d,%0d,%0d,%0d,%h,%0d,%0d",rl_cycle,v_frames,rc_gen,`RL_Q.rd_y,`RL_Q.rg_rdata[22:0],`RL_Q.rd_on,`RL_Q.drop);
        if(`RL_Q.u_rbuf.we && `RL_Q.u_rbuf.waddr[7:0]==0)
            $fdisplay(ro_fd,"WRBUF,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d",rl_cycle,v_frames,rc_gen,`RL_Q.u_rbuf.waddr[8],`RL_Q.u_rbuf.wdata,
                `RL_Q.rb_we_px,`RL_Q.cp_we,`RL_Q.lc_we,`RL_Q.cp_y,`RL_Q.rd_y);
        if(`RL_G.frame_go)begin rl_live=0;rl_released=0;rl_full=0;end
        if(`RL_G.l3d_go)begin
            if(rl_sample>=0)begin
                $fdisplay(ro_fd,"LWIN,%0d,%0d,%0d,%0d,%0d",rl_cycle,v_frames,rl_row,rl_sample,rl_cycle-rl_sample);
                rl_windows++;
            end
            rl_sample=-1;rl_live=!`RL_G.frame_go;rl_released=0;rl_full=0;rl_raw=0;rl_overwrite=0;
        end
        if(`RL_G.lv_go)begin
            rl_row=int'(`RL_G.l3d_line);
            rl_full=`RL_G.ring_have && !`RL_Q.rb_p[`RL_G.l3d_line[0]];
        end
        if(rl_live&&!rl_raw&&`RL_G.l3d_raddr==255)begin
            rl_raw=1;$fdisplay(ro_fd,"LRAW,%0d,%0d,%0d",rl_cycle,v_frames,rl_row);
        end
        if(`RL_G.l3d_done)begin
            if(`RL_B.j_eng || !`RL_B.c_comp || `RL_B.c_kind!=`RL_B.K_COMP || `RL_B.stall || !`RL_B.s4.v || `RL_B.s4.x!=255)
                ro_bad("qualified final-sample token/owner mismatch");
            if(rl_live)begin
                rl_released=1;rl_sample=rl_cycle;
                $fdisplay(ro_fd,"LSAMPLE,%0d,%0d,%0d,%0d,%0d",rl_cycle,v_frames,rl_row,`RL_Q.owner_valid,`RL_Q.d_on);
            end
        end
        // rb_v can clear during a speculative fill. Keep the accepted current
        // job's full status, so clearing a tag cannot hide a live-data error.
        if(rl_live && rl_full && !`RL_B.j_eng && !`RL_B.stall &&
           ((`RL_B.c_3d&&`RL_B.s2.v)||(`RL_B.c_comp&&`RL_B.s4.v)) &&
           !`RL_G.l3d_rear && dut.ds.g_3d.u_xscroll.in_q &&
           rc_final_gen[rl_row*256+rl_raddr_q]==rc_gen)begin
            rl_checks++;
            if(`RL_G.ring_q!==rc_final_pixel[rl_row*256+rl_raddr_q])begin
                $fflush(ro_fd);
                rl_errors++;ro_bad($sformatf("current-job live ring sample row=%0d source_x=%0d K3D=%0d KCOMP=%0d got=%h expected=%h",
                    rl_row,rl_raddr_q,`RL_B.c_3d,`RL_B.c_comp,`RL_G.ring_q,rc_final_pixel[rl_row*256+rl_raddr_q]));
            end
        end
        if(`RL_Q.nx2_on && `RL_Q.u_rbuf.we && `RL_Q.u_rbuf.waddr[8]==`RL_Q.dline[0])begin
            if(!rl_released || !rl_live || `RL_G.frame_go || `RL_G.l3d_go)ro_bad("NX2 overwrites an unreleased current job");
            if(!rl_overwrite)begin
                rl_overwrite=1;$fdisplay(ro_fd,"LWRITE,%0d,%0d,%0d,%0d",rl_cycle,v_frames,rl_row,`RL_Q.tgt);
            end
        end
        rl_raddr_q=int'(`RL_G.l3d_raddr);
    end
    end
    always @(negedge dut.clk_sys)if(ro_started && ro_enable!=0)
        if(rl_cycle!=ro_cycle)ro_bad("lifetime SYS clock counters disagree after edge");
    final $display("RLIFE checks=%0d errors=%0d windows=%0d",rl_checks,rl_errors,rl_windows);
`undef RL_G
`undef RL_Q
`undef RL_B
