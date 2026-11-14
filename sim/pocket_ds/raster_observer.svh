// Passive symptom observer, IMPORT/NODEBUG compact Pocket profile.
// +robs=FILE [+ro_enable=0] +ro_frames=16; no design driver except explicit
// +ro_fault=1 (actual hint address) /2 (actual ring read data) witnesses.
`define RO_G dut.ds.g_3d.u_gpu3d
`define RO_R `RO_G.u_raster
`define RO_Q `RO_G.g_ring.u_ringx
`define RO_C `RO_G.g_c2.u_tc
`define RO_B dut.ds.u_disp.u_gpu2d.u_bg
    integer ro_fd=0, ro_enable=1, ro_frames=16, ro_fault=0;
    string ro_path;
    longint ro_cycle=0, ro_gen=0, ro_lines=0, ro_errors=0;
    longint ro_digest=64'h14650fb0739d0383, ro_events=0;
    bit ro_started=0, ro_fault_fired=0;
    logic [18:0] ro_fault_pf;
    logic [22:0] ro_fault_px;
    longint ro_done[192], ro_ready[192], ro_partial[192];
    longint ro_wait17[192], ro_wait19[192], ro_ll20[192], ro_issue[192];
    longint ro_stage_gen[1024], ro_stage_row[1024];
    longint ro_sd_gen[49152], ro_sd_row[49152];
    logic [22:0] ro_sd_data[49152];
    integer ro_sd_base=0, ro_sd_beat=0;
    longint ro_buf_gen[512], ro_buf_row[512];
    logic [22:0] ro_buf[512];
    bit ro_buf_v[512];
    longint ro_sq_gen=-1, ro_sq_row=-1, ro_lq_gen=-1, ro_lq_row=-1;
    longint ro_slot_gen[4], ro_slot_row[4];
    longint ro_read_gen=-1, ro_read_row=-1;
    logic [22:0] ro_read_data=0;
    bit ro_read_valid=0;
    integer ro_old_go=0, ro_rb_v=0, ro_rb_p=0;
    integer ro_rb_y[2];
    longint ro_pf_offer=0, ro_pf_admit=0, ro_pf_drop=0, ro_pf_scan=0;
    longint ro_pf_launch=0, ro_q_launch=0, ro_head_launch=0;
    longint ro_ll_reads=0, ro_ll_denied=0, ro_ll_copies=0;
    longint ro_tex_req=0, ro_tex_ret=0, ro_pal_req=0, ro_pal_ret=0;
    longint ro_tex_block=0, ro_pal_block=0, ro_2d_blocked=0;
    longint ro_ring_blocked=0, ro_fp_hold=0, ro_two_d_late=0;
    longint ro_wrong_row=0, ro_wrong_gen=0, ro_unknown_owner=0;
    longint ro_masks[1024];
    bit ro_scan_hint=0, ro_scan_hint2=0;
    logic [15:0] ro_sleft=0, ro_tleft=0;
    logic [18:0] ro_exp0=0, ro_exp1=0;
    bit ro_ev0=0, ro_ev1=0;

    task automatic ro_mix(input logic [63:0] value);
        ro_digest=(ro_digest ^ value)*64'h100000001b3;
        ro_digest=(ro_digest ^ 64'(ro_cycle))*64'h100000001b3;
        ro_events++;
    endtask
    task automatic ro_bad(input string why);
        ro_errors++;
        $display("ROBS_ACTUAL_FAULT_OR_DATA_ERROR cycle=%0d gen=%0d %s",ro_cycle,ro_gen,why);
        $fatal(1,"ROBS_CHECK_FAILED");
    endtask
    task automatic ro_check_import;
        for(integer w=0;w<(1<<20);w++)
            if({cram1.peek(w),cram0.peek(w)}!==imp_main[w])ro_bad("initial MAIN image readback");
        for(integer w=0;w<32'h29000;w++)
            if(sd_peek32(w)!==imp_vram[w])ro_bad("initial VRAM image readback");
        for(integer w=0;w<32'h6000;w++)
            if({u_sram.mem[2*w+1],u_sram.mem[2*w]}!==imp_sram[w])ro_bad("initial WRAM image readback");
        $display("ROBS_IMPORT_MEMORY_PASS MAIN=1048576 VRAM=167936 WRAM=24576 words; CPU restore uses retained stub contract, not a new equality claim");
    endtask
    function automatic integer ro_coord(input logic [15:0] left_,input integer size_,input bit repeat_,flip_);
        integer v,w,c;
        v=$signed(left_);v=v>>>4;w=8<<size_;
        if(repeat_)begin c=v&(w-1);if(flip_ && ((v&w)!=0))c=w-1-c;end
        else c=v<0?0:v>=w?w-1:v;
        return c;
    endfunction
    function automatic logic [18:0] ro_first(input logic [31:0] t,input logic[15:0] s_,v_);
        integer s,v,w,o;
        s=ro_coord(s_,int'(t[22:20]),t[16],t[18]);
        v=ro_coord(v_,int'(t[25:23]),t[17],t[19]);w=8<<t[22:20];
        case(t[28:26])
            2:o=(v*w+s)/4;
            3:o=(v*w+s)/2;
            7:o=(v*w+s)*2;
            5:o=(v/4)*w+(s/4)*4+(v%4);
            default:o=v*w+s;
        endcase
        return 19'((int'(t[15:0])*8)+o);
    endfunction
    initial begin
        void'($value$plusargs("ro_enable=%d",ro_enable));
        void'($value$plusargs("ro_frames=%d",ro_frames));
        void'($value$plusargs("ro_fault=%d",ro_fault));
        if($value$plusargs("robs=%s",ro_path))begin
            ro_fd=$fopen(ro_path,"w");if(!ro_fd)$fatal(1,"ROBS_OPEN");
            $fdisplay(ro_fd,"# ROBS1 preNBA SYS handshakes; READY visible on following SYS edge; generation starts frame_go");
        end
        foreach(ro_stage_gen[i])begin ro_stage_gen[i]=-1;ro_stage_row[i]=-1;end
        foreach(ro_sd_gen[i])begin ro_sd_gen[i]=-1;ro_sd_row[i]=-1;end
        foreach(ro_buf_gen[i])begin ro_buf_gen[i]=-1;ro_buf_row[i]=-1;end
        foreach(ro_slot_gen[i])begin ro_slot_gen[i]=-1;ro_slot_row[i]=-1;end
        foreach(ro_done[i])begin ro_done[i]=-1;ro_ready[i]=-1;ro_partial[i]=-1;end
        wait(imp_frame>=0);
        // Change only this testbench's finish target: exactly N display frames
        // after the fixed import release, including transition frames.
        frames=imp_frame+ro_frames;
        ro_started=1;
        $display("ROBS_WINDOW release=%0d target=%0d frames=%0d enable=%0d fault=%0d",imp_frame,frames,ro_frames,ro_enable,ro_fault);
    end

    // Faults alter actual DUT interfaces, never the observer's expected data.
    // The checker terminates on the first exercised discrepancy.
    initial begin
        wait(ro_started);
        forever begin
            @(negedge dut.clk_sys);
            if(!ro_fault_fired && ro_fault==1 && `RO_G.tpf_v)begin
                ro_fault_pf=`RO_G.tpf_a ^ 19'h20;
                force `RO_G.tpf_a=ro_fault_pf;
                ro_fault_fired=1;
                $display("ROBS_INJECT actual=tpf_a bit=5 cycle=%0d",ro_cycle);
                @(posedge dut.clk_sys);#1;release `RO_G.tpf_a;
            end
            if(!ro_fault_fired && ro_fault==2 && ro_read_valid && `RO_B.c_3d && `RO_B.s2.v && !`RO_B.stall)begin
                ro_fault_px=`RO_G.ring_q ^ 23'd1;
                force `RO_G.ring_q=ro_fault_px;
                ro_fault_fired=1;
                $display("ROBS_INJECT actual=ring_q bit=0 cycle=%0d",ro_cycle);
                @(posedge dut.clk_sys);#1;release `RO_G.ring_q;
            end
        end
    end

    always @(posedge dut.clk_sys) begin : ro_sample
        integer y,a,sd,mask,slot,wy;
        longint wg,wr,consume_gen,consume_row;
        ro_cycle++;
        // Independent first-address oracle; inputs precede the real serial
        // coordinate registers, so a faulty pf_a is not its own oracle.
        if(`RO_R.ar_we && `RO_R.ar_wk==3)ro_sleft=`RO_R.ar_left;
        if(`RO_R.ar_we && `RO_R.ar_wk==4)ro_tleft=`RO_R.ar_left;
        if(ro_started && ro_enable!=0 && `RO_G.tpf_v)
            if(!ro_ev1 || `RO_G.tpf_a!==ro_exp1)ro_bad($sformatf("hint got=%h expected=%h valid=%0d",`RO_G.tpf_a,ro_exp1,ro_ev1));
        ro_exp1<=ro_exp0;
        ro_ev1<=ro_ev0 && !(`RO_R.fe_wr && `RO_R.s_textured(`RO_R.fe_desc)) && !`RO_R.rst && !`RO_R.frame_go;
        ro_ev0<=`RO_R.fe_wr && `RO_R.s_textured(`RO_R.fe_desc) && !`RO_R.rst && !`RO_R.frame_go;
        if(`RO_R.fe_wr && `RO_R.s_textured(`RO_R.fe_desc))
            ro_exp0<=ro_first(`RO_R.fe_desc.texparam,ro_sleft,ro_tleft);

        // Functional digest is ALWAYS active in both observer inverse modes.
        // It uses actual events, not NODEBUG's zero-valued log macros.
        if(ro_started)begin
            if(dut.dbg_retire)ro_mix({7'd1,dut.dbg_tid,24'd0,dut.dbg_pc});
            if(`RO_G.tex_req)ro_mix({8'd2,37'd0,`RO_G.tex_addr});
            if(`RO_G.tex_valid)ro_mix({8'd3,40'd0,`RO_G.tex_data});
            if(`RO_G.pal_req)ro_mix({8'd4,39'd0,`RO_G.pal_addr});
            if(`RO_G.pal_valid)ro_mix({8'd5,40'd0,`RO_G.pal_data});
            if(dut.ds.vm_req && dut.ds.vm_ack)begin
                ro_mix({8'd6,7'd0,dut.ds.vm_we,24'(dut.ds.vm_addr),24'd0});ro_mix({32'd0,dut.ds.vm_wdata});
            end
            if(dut.ds.vm_rvalid)ro_mix({8'd11,24'd0,dut.ds.vm_rdata});
            if(`RO_G.px_valid)ro_mix({8'd7,17'd0,`RO_G.px_y,`RO_G.px_x,`RO_G.px_color});
            if(dut.px_valid)ro_mix({8'd8,21'd0,dut.px_eng,dut.px_line,dut.px_x,dut.px_rgb});
            if(dut.aud_pre)ro_mix({8'd9,24'd0,dut.aud_l,dut.aud_r});
            if(`RO_G.frame_go)ro_mix({8'd10,24'd0,32'(ro_cycle)});
        end

        // Word provenance crosses staging, posted SDRAM writes and read buffer.
        // Read before write mirrors gpu3d_ram's OLD_DATA semantics.
        if(ro_started && ro_enable!=0)begin
            consume_gen=ro_read_gen;consume_row=ro_read_row;
            if(ro_read_valid && `RO_G.ring_q!==ro_read_data)
                ro_bad($sformatf("ring_read got=%h expected=%h row=%0d gen=%0d",`RO_G.ring_q,ro_read_data,ro_read_row,ro_read_gen));
            a=int'(`RO_Q.u_rbuf.raddr);
            ro_read_data=ro_buf[a];ro_read_valid=ro_buf_v[a];
            ro_read_gen=ro_buf_gen[a];ro_read_row=ro_buf_row[a];
            if(`RO_Q.u_rbuf.we)begin
                a=int'(`RO_Q.u_rbuf.waddr);wg=ro_gen;wr=-1;
                if(`RO_Q.rb_we_px)wr=int'(`RO_G.px_y);
                else if(`RO_Q.cp_we)begin wg=ro_sq_gen;wr=ro_sq_row;end
                else if(`RO_Q.lc_we)begin wg=ro_lq_gen;wr=ro_lq_row;end
                else begin
                    sd=ro_sd_base+ro_sd_beat;
                    if(sd<0 || sd>=49152)ro_bad("ring read outside retained ring storage");
                    if(ro_sd_gen[sd]>=0 && `RO_Q.rg_rdata[22:0]!==ro_sd_data[sd])ro_bad("SDRAM ring payload differs from posted source word");
                    wg=ro_sd_gen[sd];wr=ro_sd_row[sd];
                end
                ro_buf[a]=`RO_Q.u_rbuf.wdata;ro_buf_v[a]=1;
                ro_buf_gen[a]=wg;ro_buf_row[a]=wr;
            end
            if(`RO_Q.rg_wreq && `RO_Q.rg_wack)begin
                sd=int'(`RO_Q.rg_waddr-`RO_Q.BASEW);
                if(sd>=0 && sd<49152)begin ro_sd_gen[sd]=ro_sq_gen;ro_sd_row[sd]=ro_sq_row;ro_sd_data[sd]=`RO_Q.rg_wdata[22:0];end
            end
            if(`RO_Q.rg_rvalid)ro_sd_beat++;
            if(`RO_Q.rg_rreq && `RO_Q.rg_rack)begin ro_sd_base=int'(`RO_Q.rg_raddr-`RO_Q.BASEW);ro_sd_beat=0;end
            a=int'(`RO_Q.u_stage.raddr);ro_sq_gen=ro_stage_gen[a];ro_sq_row=ro_stage_row[a];
            if(`RO_G.px_valid)begin
                a=int'(`RO_Q.u_stage.waddr);ro_stage_gen[a]=ro_gen;ro_stage_row[a]=longint'(`RO_G.px_y);
            end
            if(`RO_G.ll_rd && `RO_G.ll_ack)begin
                slot=int'(`RO_G.ll_slot);ro_lq_gen=ro_slot_gen[slot];ro_lq_row=ro_slot_row[slot];
                ro_ll_reads++;
                if(ro_lq_gen>=0 && (ro_lq_gen!=ro_gen || ro_lq_row!=longint'(`RO_Q.lc_y)))ro_bad("LLR wrong slot/generation");
            end else if(`RO_G.ll_rd)ro_ll_denied++;
            if(int'(`RO_G.r_front_go)!=ro_old_go)begin
                ro_old_go=int'(`RO_G.r_front_go);
                if(ro_old_go>0)begin y=ro_old_go-1;slot=`RO_Q.TR3?y%3:y%4;ro_slot_gen[slot]=ro_gen;ro_slot_row[slot]=y;end
            end

            y=int'(`RO_R.y);
            if(y<192)begin
                ro_wait17[y]+=longint'(`RO_R.wait17);ro_wait19[y]+=longint'(`RO_R.wait19);
                ro_ll20[y]+=longint'(`RO_R.ll20);ro_issue[y]+=longint'(`RO_R.dbg_pixel);
            end
            mask=int'({`RO_R.lin_hold,(`RO_R.AREA && !`RO_R.hr_t),`RO_R.hold15,`RO_R.wait17,`RO_R.take17,`RO_R.hold17,`RO_R.wait19,`RO_R.take19,`RO_R.hz20,`RO_R.ll20});
            ro_masks[mask]++;
            ro_pf_offer+=longint'(`RO_G.tpf_v);
            ro_pf_admit+=longint'(`RO_G.tpf_v && (`RO_C.pq_n==0 || `RO_C.p_go));
            ro_pf_drop+=longint'(`RO_G.tpf_v && `RO_C.pq_n!=0 && !`RO_C.p_go);
            ro_pf_scan+=longint'(`RO_C.p_go);
            if(`RO_C.s_req)begin if(ro_scan_hint2)ro_pf_launch++;else ro_q_launch++;end
            if((`RO_C.st==`RO_C.C_LOOK && !`RO_C.hit && !`RO_C.onway(`RO_C.hb) && !`RO_C.r_v && `RO_C.slot) ||
               (`RO_C.st==`RO_C.C_NEED && !`RO_C.onway(`RO_C.hb) && !`RO_C.r_v && `RO_C.slot))ro_head_launch++;
            ro_scan_hint2=ro_scan_hint;ro_scan_hint=`RO_C.p_go;
            ro_tex_req+=longint'(`RO_G.tex_req);ro_tex_ret+=longint'(`RO_G.tex_valid);
            ro_pal_req+=longint'(`RO_G.pal_req);ro_pal_ret+=longint'(`RO_G.pal_valid);
            ro_tex_block+=longint'(`RO_G.tc_req && `RO_G.tc_ack);ro_pal_block+=longint'(`RO_G.pc_req && `RO_G.pc_ack);
            ro_2d_blocked+=longint'(dut.ds.t_req && dut.ds.d_req);
            ro_ring_blocked+=longint'(`RO_Q.rg_rreq && !`RO_Q.rg_rack);
            ro_fp_hold+=longint'(`RO_G.fp_hold);ro_two_d_late+=longint'(dut.stat_late);
            if(`RO_G.px_valid && `RO_G.px_x==255)begin
                y=int'(`RO_G.px_y);ro_done[y]=ro_cycle;
                $fdisplay(ro_fd,"DONE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",ro_cycle,v_frames,ro_gen,y,ro_wait17[y],ro_wait19[y],ro_ll20[y],ro_issue[y]);
            end
            if(`RO_G.lv_go)begin
                y=int'(`RO_G.l3d_line);ro_lines++;
                $fdisplay(ro_fd,"ROW,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",ro_cycle,v_frames,ro_gen,y,
                    `RO_G.ring_have,`RO_Q.rb_p[y%2],`RO_G.lv_late,`RO_G.lv_under,`RO_G.lv_fin,`RO_G.r_front_go,
                    ro_done[y],ro_ready[y],ro_partial[y],dut.ds.powcnt1[15],dut.stat_late);
            end
            if(!`RO_B.stall && `RO_B.s2.v && `RO_B.c_3d)begin
                if(`RO_G.ring_have && !`RO_G.l3d_rear && dut.ds.g_3d.u_xscroll.in_q)begin
                    if(consume_gen<0)ro_unknown_owner++;
                    else begin ro_wrong_row+=longint'(consume_row!=longint'(`RO_G.l3d_line));ro_wrong_gen+=longint'(consume_gen!=ro_gen);end
                end
                $fdisplay(ro_fd,"PIX,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d,%0d",ro_cycle,v_frames,ro_gen,`RO_G.l3d_line,`RO_B.s2.x,`RO_B.l3d_rdata,`RO_G.l3d_rear,consume_row,consume_gen);
            end
        end
        if(`RO_G.frame_go)begin
            ro_gen++;ro_old_go=0;
            foreach(ro_slot_gen[i])begin ro_slot_gen[i]=-1;ro_slot_row[i]=-1;end
            foreach(ro_done[i])begin ro_done[i]=-1;ro_ready[i]=-1;ro_partial[i]=-1;ro_wait17[i]=0;ro_wait19[i]=0;ro_ll20[i]=0;ro_issue[i]=0;end
            if(ro_started && ro_enable!=0)$fdisplay(ro_fd,"FRAME,%0d,%0d,%0d,%0d,%0d",ro_cycle,v_frames,ro_gen,dut.vcount,`RO_G.r_abort);
        end
    end
    // Publication after NBA becomes available to the NEXT SYS sampling edge.
    always @(negedge dut.clk_sys)if(ro_started && ro_enable!=0)begin
        for(integer k=0;k<2;k++)begin
            if(`RO_Q.rb_v[k] && (!ro_rb_v[k] || ro_rb_y[k]!=int'(`RO_Q.rb_y[k]) || ro_rb_p[k]!=`RO_Q.rb_p[k]))begin
                if(`RO_Q.rb_p[k])begin ro_partial[`RO_Q.rb_y[k]]=ro_cycle+1;ro_ll_copies++;end
                else ro_ready[`RO_Q.rb_y[k]]=ro_cycle+1;
                $fdisplay(ro_fd,"READY,%0d,%0d,%0d,%0d,%0d",ro_cycle+1,v_frames,ro_gen,`RO_Q.rb_y[k],`RO_Q.rb_p[k]);
            end
            ro_rb_y[k]=int'(`RO_Q.rb_y[k]);
        end
        ro_rb_v=int'(`RO_Q.rb_v);ro_rb_p=int'(`RO_Q.rb_p);
        if(ro_fd && $ftell(ro_fd)>536870912)$fatal(1,"ROBS_OUTPUT_CAP");
    end
    final begin
        if(ro_fd)begin
            $fdisplay(ro_fd,"TOTAL,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",ro_cycle,ro_gen,ro_lines,ro_pf_offer,ro_pf_admit,ro_pf_drop,ro_pf_scan,ro_pf_launch,ro_q_launch,ro_head_launch,ro_ll_reads,ro_ll_denied,ro_ll_copies,ro_tex_req,ro_tex_ret,ro_pal_req,ro_pal_ret,ro_tex_block,ro_pal_block,ro_2d_blocked,ro_ring_blocked,ro_fp_hold,ro_two_d_late);
            for(integer k=0;k<1024;k++)if(ro_masks[k])$fdisplay(ro_fd,"MASK,%0d,%0d",k,ro_masks[k]);
            $fdisplay(ro_fd,"OWNERS,%0d,%0d,%0d",ro_wrong_row,ro_wrong_gen,ro_unknown_owner);
            $fclose(ro_fd);
        end
        $display("ROBS_DIGEST %h events=%0d errors=%0d fault_fired=%0d",ro_digest,ro_events,ro_errors,ro_fault_fired);
    end
`undef RO_G
`undef RO_R
`undef RO_Q
`undef RO_C
`undef RO_B
