// Passive pre-NBA SYS timeline. Raw simultaneous counters are not a partition.
`define TP_D dut.ds.u_sys.u_dma
`define TP_G dut.ds.g_3d.u_gpu3d
`define TP_C dut.ds.u_cpud.g_one.u_cpu
    integer tp_fd=0,tp_bin=0;
    longint tp_c[32];
    integer tp_lastframe=-1,tp_runprev=0;
    bit tp_rbprev=0;
    longint tp_admit[8],tp_start[8],tp_units[8];
    logic [31:0]tp_pc9=0,tp_pc7=0;
    initial begin foreach(tp_c[i])tp_c[i]=0;foreach(tp_admit[i])begin tp_admit[i]=-1;tp_start[i]=-1;tp_units[i]=0;end end
    always @(posedge dut.clk_sys)if(ro_started && ro_enable!=0)begin
        if(!tp_fd)begin tp_fd=$fopen({ro_path,".pacing.csv"},"w");if(!tp_fd)$fatal(1,"TP_OPEN");
            $fdisplay(tp_fd,"# TP1 cycle,vframe,vcount preNBA SYS; BIN counters overlap; DMA modes from actual regs; repeated running trigger = coalesced, not assumed lost");end
        tp_c[0]++;
        tp_c[1]+=longint'(`TP_C.c_dbg_retire);tp_c[2]+=longint'(`TP_C.g_a7ds.l_ret);
        if(`TP_C.c_dbg_retire)tp_pc9=`TP_C.c_dbg_pc;
        if(`TP_C.g_a7ds.l_ret)tp_pc7=`TP_C.g_a7ds.l_pc;
        tp_c[3]+=longint'(dut.ds.b9_req&&!dut.ds.b9_ack);
        tp_c[4]+=longint'(dut.ds.dg_wait&&dut.ds.dg_mr);
        tp_c[5]+=longint'(dut.ds.dg_wait&&dut.ds.dg_gx);
        tp_c[6]+=longint'(dut.ds.dma_busy[0]);tp_c[7]+=longint'(`TP_C.c_dbg_halt[0]);
        tp_c[8]+=longint'(`TP_G.g_busy);tp_c[9]+=longint'(dut.ds.gx_req&&!dut.ds.gx_ack);
        tp_c[10]+=longint'(dut.ds.gx_req&&dut.ds.gx_ack&&dut.ds.io_we);
        tp_c[11]+=longint'(`TP_G.dx_valid&&`TP_G.dx_ready);
        tp_c[12]+=longint'(`TP_G.r_busy);tp_c[13]+=longint'(`TP_G.fp_hold);
        tp_c[14]+=longint'(`TP_G.px_valid);tp_c[15]+=longint'(dut.ds.cap_we&&dut.ds.cap_ready);
        tp_c[16]+=longint'(dut.ds.cap_we&&!dut.ds.cap_ready);
        for(integer k=0;k<8;k++)tp_c[17+k]+=longint'(`TP_G.diag_g_ev[k]);
        tp_c[25]+=longint'(`TP_C.m9_ireq&&!`TP_C.m_i_ok);
        tp_c[26]+=longint'(`TP_C.m9_dreq&&!`TP_C.m_d_ok);
        tp_c[27]+=longint'(dut.ds.gx_req&&!dut.ds.io_we&&dut.ds.gx_ack);
        tp_bin++;
        if(tp_bin==4096 || v_frames!=tp_lastframe)begin
            $fwrite(tp_fd,"BIN,%0d,%0d,%0d,%h,%h",ro_cycle,v_frames,dut.vcount,tp_pc9,tp_pc7);
            for(integer k=0;k<28;k++)begin $fwrite(tp_fd,",%0d",tp_c[k]);tp_c[k]=0;end
            $fwrite(tp_fd,"\n");tp_bin=0;tp_lastframe=v_frames;
        end
        if(dut.ds.dma_hbl)begin
            for(integer k=0;k<4;k++)if(`TP_D.en[k]&&`TP_D.mode[k]==2)begin
                $fdisplay(tp_fd,"HB,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%0d",ro_cycle,v_frames,dut.vcount,k,`TP_D.run[k],`TP_D.inprog[k],`TP_D.est,`TP_D.ek,`TP_D.e_src,`TP_D.e_dst,`TP_D.e_rem);
                if(!`TP_D.run[k])tp_admit[k]=ro_cycle;
            end
        end
        for(integer k=0;k<8;k++)begin
            if(`TP_D.run[k]&&!tp_runprev[k])begin
                tp_start[k]=ro_cycle;tp_units[k]=0;
                $fdisplay(tp_fd,"DSTART,%0d,%0d,%0d,%0d,%0d,%0d",ro_cycle,v_frames,dut.vcount,k,`TP_D.mode[k],tp_admit[k]);
            end
        end
        if(`TP_D.est==`TP_D.E_SETUP && `TP_D.rtag==0)
            $fdisplay(tp_fd,"DLOAD,%0d,%0d,%0d,%0d,%h,%h,%h,%0d,%0d,%0d",ro_cycle,v_frames,dut.vcount,`TP_D.ek,`TP_D.e_src,`TP_D.e_dst,`TP_D.e_cnt,`TP_D.e_rem,`TP_D.unit,`TP_D.e_res);
        if(`TP_D.m_req&&`TP_D.m_ack&&(`TP_D.m_unit||`TP_D.m_we))tp_units[`TP_D.ek]++;
        if(`TP_D.save_go)
            $fdisplay(tp_fd,"DSAVE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h",ro_cycle,v_frames,dut.vcount,`TP_D.ek,`TP_D.e_why,tp_start[`TP_D.ek],tp_units[`TP_D.ek],`TP_D.e_rem,`TP_D.e_src,`TP_D.e_dst);
        tp_runprev=int'(`TP_D.run);
        if(`TP_G.ev_swtake || `TP_G.ev_swdone || `TP_G.frame_go || `TP_G.r_abort || (tp_rbprev&&!`TP_G.r_busy))
            $fdisplay(tp_fd,"GXFRAME,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",ro_cycle,v_frames,dut.vcount,`TP_G.ev_swtake,`TP_G.ev_swdone,`TP_G.frame_go,`TP_G.r_abort,`TP_G.r_busy,`TP_G.sw_busy,`TP_G.st_bld,`TP_G.diag_g_val);
        tp_rbprev=`TP_G.r_busy;
        if(`TP_G.px_valid&&`TP_G.px_x==255)
            $fdisplay(tp_fd,"RROW,%0d,%0d,%0d,%0d",ro_cycle,v_frames,dut.vcount,`TP_G.px_y);
        if(dut.ds.cap_we&&dut.ds.cap_ready&&dut.ds.u_disp.u_gpu2d.u_bg.s6.x==255)
            $fdisplay(tp_fd,"CAPROW,%0d,%0d,%0d,%0d,%h",ro_cycle,v_frames,dut.vcount,dut.ds.u_disp.u_gpu2d.u_bg.j_line,dut.ds.cap_addr);
        if($ftell(tp_fd)>536870912)$fatal(1,"TP_OUTPUT_CAP");
    end
    final if(tp_fd)$fclose(tp_fd);
`undef TP_D
`undef TP_G
`undef TP_C
