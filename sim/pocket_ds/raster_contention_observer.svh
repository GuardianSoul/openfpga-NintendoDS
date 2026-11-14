// Passive service measurement. No force, assignment to DUT, or scheduling change.
// SYS samples are pre-NBA; intervals are [start,end). Independent cycle/gen
// counters avoid another always block's blocking-update order.
`define RS_G dut.ds.g_3d.u_gpu3d
`define RS_R `RS_G.u_raster
`define RS_F `RS_R.u_fpass
`define RS_Q `RS_G.g_ring.u_ringx
`define RS_S `RS_G.g_ext.u_store
    integer rs_fd=0;
    string rs_path;
    longint rs_cycle=0,rs_gen=0,rs_samples=0;
    bit rs_live=0,rs_block_live=0,rs_gate_live=0,rs_raw_live=0;
    longint rs_begin=0,rs_block_begin=0,rs_gate_begin=0,rs_raw_begin=0;
    logic [79:0] rs_key=0;
    logic [63:0] rs_block_key=0,rs_gate_key=0,rs_raw_key=0;
    longint rs_key_gen=0,rs_block_gen=0,rs_gate_gen=0,rs_raw_gen=0;
    // Per completed finalpass row: all F5 cycles partition into advance,
    // stage only, clear only, both. Histograms partition stage stalls by engine.
    longint rs_f5[192],rs_advance[192],rs_stage[192],rs_clear[192],rs_both[192];
    longint rs_calc[192],rs_hist[192][7],rs_joint[4];
    longint rs_work_n=0,rs_work_hash=64'h14650fb0739d0383;
    longint rs_tex_n=0,rs_tex_hash=64'h14650fb0739d0383,rs_pal_n=0,rs_pal_hash=64'h14650fb0739d0383;
    bit rs_started=0;
    logic [9:0] rs_frame_key=0;
    initial begin
        foreach(rs_f5[i])begin
            rs_f5[i]=0;rs_advance[i]=0;rs_stage[i]=0;rs_clear[i]=0;rs_both[i]=0;rs_calc[i]=0;
            for(integer j=0;j<7;j++)rs_hist[i][j]=0;
        end
        foreach(rs_joint[i])rs_joint[i]=0;
        if($value$plusargs("rcontention=%s",rs_path))begin
            rs_fd=$fopen(rs_path,"w");if(!rs_fd)$fatal(1,"RSERVICE_OPEN");
            $fdisplay(rs_fd,"# RSERVICE1 preNBA SYS; [begin,end); raw service keys decoded by raster_service_report.py; production unchanged");
            $fdisplay(rs_fd,"CONFIG,F5,%0d,FPCLR,%0d,NX2,%0d,RPRI,%0d,LEAD,%0d,YLAG,%0d",`RS_F.F_5,`RS_F.FPCLR,`RS_Q.NX2,`RS_Q.RPRI,`RS_Q.LEAD,`RS_Q.YLAG);
        end
    end
    task automatic rs_end_intervals(input longint end_cycle);
        if(rs_live)$fdisplay(rs_fd,"SERVICE,%0d,%0d,%0d,%h",rs_begin,end_cycle,rs_key_gen,rs_key);
        if(rs_block_live)$fdisplay(rs_fd,"BLOCK,%0d,%0d,%0d,%h",rs_block_begin,end_cycle,rs_block_gen,rs_block_key);
        if(rs_gate_live)$fdisplay(rs_fd,"GATE,%0d,%0d,%0d,%h",rs_gate_begin,end_cycle,rs_gate_gen,rs_gate_key);
        if(rs_raw_live)$fdisplay(rs_fd,"FPHOLD,%0d,%0d,%0d,%h",rs_raw_begin,end_cycle,rs_raw_gen,rs_raw_key);
        rs_live=0;rs_block_live=0;rs_gate_live=0;rs_raw_live=0;
    endtask
    task automatic rs_summary;
        $fdisplay(rs_fd,"INPUT,%0d,%0d,%0d,%h,%0d,%h,%0d,%h",rs_cycle,rs_gen,rs_work_n,rs_work_hash,rs_tex_n,rs_tex_hash,rs_pal_n,rs_pal_hash);
        for(integer i=0;i<192;i++)if(rs_f5[i]!=0 || rs_calc[i]!=0)begin
            $fdisplay(rs_fd,"GENROW,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,i,rs_f5[i],rs_advance[i],rs_stage[i],rs_clear[i],rs_both[i],rs_calc[i]);
            for(integer j=0;j<7;j++)$fdisplay(rs_fd,"GENHIST,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,i,j,rs_hist[i][j]);
        end
        for(integer j=0;j<4;j++)$fdisplay(rs_fd,"JOINT,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,j,rs_joint[j]);
    endtask
    always @(posedge dut.clk_sys)begin : rs_sample
        logic [79:0] key;
        logic [63:0] bkey,gkey,rawkey;
        logic [7:0] service_y;
        logic [9:0] fwkey;
        bit active,five,stage,clear_ok,store_y_only,store_y_any;
        integer y,mask;
        logic [127:0] data;
        rs_cycle++;
        if(rs_fd && ro_enable!=0)begin
            // Keep the absolute generation count even before observer release.
            if(`RS_G.frame_go)begin
                if(rs_started)begin rs_end_intervals(rs_cycle);rs_summary();end
                rs_gen++;
                foreach(rs_f5[i])begin
                    rs_f5[i]=0;rs_advance[i]=0;rs_stage[i]=0;rs_clear[i]=0;rs_both[i]=0;rs_calc[i]=0;
                    for(integer j=0;j<7;j++)rs_hist[i][j]=0;
                end
                foreach(rs_joint[i])rs_joint[i]=0;
                rs_work_n=0;rs_work_hash=64'h14650fb0739d0383;
                rs_tex_n=0;rs_tex_hash=64'h14650fb0739d0383;rs_pal_n=0;rs_pal_hash=64'h14650fb0739d0383;
            end
            // Begin at the same stable import-release condition as the old observer,
            // sampled independently rather than reading its mutable start flag.
            if(imp_frame>=0)rs_started=1;
            if(rs_started)begin
                rs_samples++;
                active=!`RS_F.rst && !`RS_F.frame_go && !`RS_G.frame_go;
                five=active && `RS_F.fst==`RS_F.F_5;
                stage=`RS_F.px_hold;
                clear_ok=`RS_F.FPCLR ? (!`RS_F.clr_p || `RS_F.fp_clr_ack) : `RS_F.fp_clr_ack;
                store_y_any=!`RS_S.rst && !`RS_S.abort && !`RS_G.frame_go && `RS_S.fst==`RS_S.F_WAIT && `RS_S.ready && {1'b0,`RS_S.fy}>`RS_G.y_lim;
                // This is the exact F_WAIT exit guard with only y_lim removed.
                store_y_only=store_y_any && !`RS_S.l_re && `RS_S.lgo &&
                    (`RS_S.l_through || `RS_S.ly>{1'b0,`RS_S.fy} || `RS_S.STREAM && `RS_S.ly=={1'b0,`RS_S.fy});
                mask=(five&&stage?1:0)|(store_y_only?2:0);rs_joint[mask]++;
                y=int'(`RS_F.fp_y);
                if(y<192 && active && `RS_F.fp_act)begin
                    if(five)begin
                        rs_f5[y]++;
                        if(stage)begin
                            if(clear_ok)rs_stage[y]++;else rs_both[y]++;
                            rs_hist[y][int'(`RS_Q.est)]++;
                        end else if(!clear_ok)rs_clear[y]++;else rs_advance[y]++;
                    end else rs_calc[y]++;
                end
                // SERVICE key, low to high: est3, rd_y8, rblk5, need8,
                // tgt8, st_full4, wdone9, rd_on1, drop1, nx2_on1,
                // cp_ok1, rd_ok1, wr_pick1, lc_ok1, lc_pend1, wsafe9, owner_y8, cp_ab1, lc_ab1, spare8.
                service_y=(`RS_Q.est==`RS_Q.E_WDAT) ? `RS_Q.st_y[`RS_Q.w_slot] :
                    (`RS_Q.est==`RS_Q.E_COPY) ? `RS_Q.cp_y : (`RS_Q.est==`RS_Q.E_LCOPY) ? `RS_Q.lc_y : `RS_Q.rd_y;
                key={8'd0,`RS_Q.lc_ab,`RS_Q.cp_ab,service_y,`RS_Q.wsafe,`RS_Q.lc_pend,`RS_Q.lc_ok,`RS_Q.wr_pick,`RS_Q.rd_ok,`RS_Q.cp_ok,
                    `RS_Q.nx2_on,`RS_Q.drop,`RS_Q.rd_on,`RS_Q.wdone,`RS_Q.st_full,`RS_Q.tgt,`RS_Q.need,`RS_Q.rblk,`RS_Q.rd_y,`RS_Q.est};
                if(rs_live && (key!=rs_key || rs_key_gen!=rs_gen))begin
                    $fdisplay(rs_fd,"SERVICE,%0d,%0d,%0d,%h",rs_begin,rs_cycle,rs_key_gen,rs_key);rs_live=0;
                end
                if(!rs_live)begin rs_live=1;rs_begin=rs_cycle;rs_key=key;rs_key_gen=rs_gen;end
                // BLOCK key low to high: final y8,x8,clear_ready1,engine3,
                // need8,rd_y8,wdone9,st_full4,rd_on1,drop1,nx2_on1,spare12.
                bkey={12'd0,`RS_Q.nx2_on,`RS_Q.drop,`RS_Q.rd_on,`RS_Q.st_full,`RS_Q.wdone,
                    `RS_Q.rd_y,`RS_Q.need,`RS_Q.est,clear_ok,`RS_F.fp_x,`RS_F.fp_y};
                if(rs_block_live && (!(five&&stage) || bkey!=rs_block_key || rs_block_gen!=rs_gen))begin
                    $fdisplay(rs_fd,"BLOCK,%0d,%0d,%0d,%h",rs_block_begin,rs_cycle,rs_block_gen,rs_block_key);rs_block_live=0;
                end
                if(five&&stage&&!rs_block_live)begin rs_block_live=1;rs_block_begin=rs_cycle;rs_block_key=bkey;rs_block_gen=rs_gen;end
                // Unqualified raw hold samples provide a separate check of the
                // F5-only measurement, including idle/calculation holds. Low to
                // high: fst4,y8,x8,ack1,clr_p1,FPCLR1,act1,rst1,
                // fp_frame1,global_frame1,engine3,spare34; px_hold is implicit.
                rawkey={34'd0,`RS_Q.est,`RS_G.frame_go,`RS_F.frame_go,`RS_F.rst,`RS_F.fp_act,
                    `RS_F.FPCLR,`RS_F.clr_p,`RS_F.fp_clr_ack,`RS_F.fp_x,`RS_F.fp_y,`RS_F.fst};
                if(rs_raw_live && (!stage || rawkey!=rs_raw_key || rs_raw_gen!=rs_gen))begin
                    $fdisplay(rs_fd,"FPHOLD,%0d,%0d,%0d,%h",rs_raw_begin,rs_cycle,rs_raw_gen,rs_raw_key);rs_raw_live=0;
                end
                if(stage&&!rs_raw_live)begin rs_raw_live=1;rs_raw_begin=rs_cycle;rs_raw_key=rawkey;rs_raw_gen=rs_gen;end
                // GATE records all actual F_WAIT y-limit gaps; bit4 says the
                // other exit conditions are met (sole y-limit blocker).
                gkey={33'd0,`RS_G.y_lim,`RS_S.fy,`RS_S.ly,store_y_only,store_y_any,`RS_S.l_re,`RS_S.lgo,`RS_S.ready};
                if(rs_gate_live && (!store_y_any || gkey!=rs_gate_key || rs_gate_gen!=rs_gen))begin
                    $fdisplay(rs_fd,"GATE,%0d,%0d,%0d,%h",rs_gate_begin,rs_cycle,rs_gate_gen,rs_gate_key);rs_gate_live=0;
                end
                if(store_y_any&&!rs_gate_live)begin rs_gate_live=1;rs_gate_begin=rs_cycle;rs_gate_key=gkey;rs_gate_gen=rs_gen;end
                if(`RS_G.frame_go)$fdisplay(rs_fd,"FRAME,%0d,%0d,%0d,%h,%h,%h,%h",rs_cycle,rs_gen,dut.vcount,`RS_G.r_dispcnt,`RS_G.r_alpharef,`RS_G.r_clear_attr1,`RS_G.r_fog_color);
                // Raw source of the delayed frame-start guard, on changes only.
                // Existing FRAME timestamps stay the authority for cohort joins.
                fwkey={`RS_G.fg_req,`RS_G.fg_hold,`RS_G.sw_busy,`RS_G.st_bld,`RS_G.sw_hok,`RS_G.r_busy,`RS_G.so_done,`RS_G.fg_simhold,`RS_G.rend_en,`RS_G.geom_en};
                if(fwkey!=rs_frame_key || `RS_G.line215 || `RS_G.frame_go)
                    $fdisplay(rs_fd,"FRAMEWAIT,%0d,%0d,%0d,%h,%0d,%0d",rs_cycle,rs_gen,dut.vcount,fwkey,`RS_G.line215,`RS_G.frame_go);
                rs_frame_key=fwkey;
                if(`RS_G.r_abort || `RS_F.rst || `RS_F.frame_go || `RS_G.frame_go)
                    if(`RS_G.r_abort || `RS_F.frame_go || `RS_G.frame_go)
                        $fdisplay(rs_fd,"BOUNDARY,%0d,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,`RS_G.r_abort,`RS_F.rst,`RS_F.frame_go,`RS_G.frame_go);
                if(!`RS_G.rst && !`RS_G.r_abort && !`RS_G.frame_go && `RS_G.ps_valid && `RS_G.ps_ready)begin
                    data=`RS_G.ps_type==2'd3 ? 128'd0 : `RS_G.ps_data;
                    $fdisplay(rs_fd,"WORK,%0d,%0d,%0d,%0d,%h",rs_cycle,rs_gen,`RS_S.fy,`RS_G.ps_type,data);
                    rs_work_hash=(rs_work_hash^64'(`RS_G.ps_type))*64'h100000001b3;
                    rs_work_hash=(rs_work_hash^data[63:0])*64'h100000001b3;
                    rs_work_hash=(rs_work_hash^data[127:64])*64'h100000001b3;rs_work_n++;
                end
                if(`RS_G.tex_req)begin rs_tex_hash=(rs_tex_hash^64'(`RS_G.tex_addr))*64'h100000001b3;rs_tex_n++;end
                if(`RS_G.tex_valid)rs_tex_hash=(rs_tex_hash^64'(`RS_G.tex_data))*64'h100000001b3;
                if(`RS_G.pal_req)begin rs_pal_hash=(rs_pal_hash^64'(`RS_G.pal_addr))*64'h100000001b3;rs_pal_n++;end
                if(`RS_G.pal_valid)rs_pal_hash=(rs_pal_hash^64'(`RS_G.pal_data))*64'h100000001b3;
                if(`RS_Q.rg_wreq && `RS_Q.rg_wack && (`RS_Q.w==0 || `RS_Q.w==7))
                    $fdisplay(rs_fd,"WRITE,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,`RS_Q.st_y[`RS_Q.w_slot],`RS_Q.blk,`RS_Q.w);
                if(`RS_Q.rg_rreq && `RS_Q.rg_rack)$fdisplay(rs_fd,"READ,%0d,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,`RS_Q.rd_y,`RS_Q.rblk,`RS_Q.need,`RS_Q.nx2_on);
                if(`RS_Q.rg_rvalid && (`RS_Q.rk==0 || `RS_Q.rk==7))$fdisplay(rs_fd,"RETURN,%0d,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,`RS_Q.rd_y,`RS_Q.rblk,`RS_Q.rk,`RS_Q.drop);
                if(`RS_G.sm_req && `RS_G.sm_ack)$fdisplay(rs_fd,"STORE,%0d,%0d,%0d,%h",rs_cycle,rs_gen,`RS_G.sm_we,`RS_G.sm_addr);
                if(`RS_G.tc_req && `RS_G.tc_ack)$fdisplay(rs_fd,"TEXBLOCK,%0d,%0d,%h",rs_cycle,rs_gen,`RS_G.tc_blk);
                if(`RS_G.pc_req && `RS_G.pc_ack)$fdisplay(rs_fd,"PALBLOCK,%0d,%0d,%h",rs_cycle,rs_gen,`RS_G.pc_blk);
                if(`RS_G.px_valid && `RS_G.px_x==255)begin
                    y=int'(`RS_G.px_y);
                    $fdisplay(rs_fd,"FINAL,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,y,rs_f5[y],rs_advance[y],rs_stage[y],rs_clear[y],rs_both[y],rs_calc[y]);
                    for(integer j=0;j<7;j++)$fdisplay(rs_fd,"HIST,%0d,%0d,%0d,%0d,%0d",rs_cycle,rs_gen,y,j,rs_hist[y][j]);
                end
            end
        end
    end
    always @(negedge dut.clk_sys)if(rs_started && rs_fd && ro_enable!=0)begin
        if(rs_cycle!=ro_cycle || rs_gen!=ro_gen)$fatal(1,"RSERVICE_CLOCK_OR_GENERATION");
        if($ftell(rs_fd)>402653184)$fatal(1,"RSERVICE_OUTPUT_CAP");
    end
    final if(rs_fd)begin
        rs_end_intervals(rs_cycle+1);rs_summary();$fdisplay(rs_fd,"END,%0d,%0d,%0d",rs_cycle,rs_gen,rs_samples);$fclose(rs_fd);
    end
`undef RS_G
`undef RS_R
`undef RS_F
`undef RS_Q
`undef RS_S
