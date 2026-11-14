// Passive wait-cause attribution on corrected 1d90 RTL. No DUT drivers.
// Independent SYS timestamp; all logic samples pre-NBA. MEM events carry $time.
`define TW_D dut.ds.u_sys.u_dma
`define TW_V dut.ds.u_vram
`define TW_F dut.ds.u_fab
`define TW_P dut.psram
    integer tw_fd=0,tw_reason=0,tw_wreason=0;
    longint tw_cycle=0,tw_rid=0,tw_wid=0,tw_rt=0,tw_wt=0;
    longint tw_rc[18],tw_wc[8];
    bit tw_read=0,tw_write=0,tw_reqprev=0;
    logic [31:0]tw_ra=0,tw_wa=0;
    bit tw_mem_prev=0;
    initial begin foreach(tw_rc[i])tw_rc[i]=0;foreach(tw_wc[i])tw_wc[i]=0;end
    always @(posedge dut.clk_sys)begin
        tw_cycle++;
        if(ro_started && ro_enable!=0)begin
            if(!tw_fd)begin
                tw_fd=$fopen({ro_path,".waits.csv"},"w");if(!tw_fd)$fatal(1,"TW_OPEN");
                $fdisplay(tw_fd,"# TW1 SYS preNBA independent cycle; M records use absolute simulation ps; R/W exclusive reasons include first offer and final ACK");
            end
            if(`TW_V.st==`TW_V.S_IDLE && `TW_V.bw_left!=0 && `TW_V.c_req &&
               !`TW_V.c_ack && !`TW_V.c_we && `TW_V.c_dma && !`TW_V.c_cpu)begin
                integer why;
                if(`TW_V.g_req)why=1;
                else if(`TW_V.wb_v)why=2;
                else if(!`TW_V.c_res_owned)why=3;
                else if(!`TW_V.res_q[20])why=4;
                else if(!`TW_V.lhit[0])why=5;
                else if(`TW_V.post_p)why=6;
                else if(`TW_V.cap_v)why=7;
                else if(`TW_V.cap_p)why=8;
                else if(`TW_V.cap_we)why=9;
                else if(`TW_V.sv_req&&`TW_V.sv_we)why=10;
                else why=0;
                $fdisplay(tw_fd,"E,%0d,%0d,%0d,%0d,%h,%h",tw_cycle,v_frames,why,`TW_V.rhit,`TW_V.c_addr,`TW_V.res_q);
            end
            if(!tw_read && `TW_D.ek==3 && `TW_D.m_req && !`TW_D.m_we && `TW_D.m_addr[31:24]==6)begin
                tw_read=1;tw_rid++;tw_rt=tw_cycle;tw_ra=`TW_D.m_addr;
                foreach(tw_rc[i])tw_rc[i]=0;
            end
            if(tw_read)begin
                tw_reason=0;
                if(`TW_D.m_ack)tw_reason=14;
                else if(`TW_V.c_req && `TW_V.c_dma && !`TW_V.c_we)begin
                    if(`TW_V.c_ack)tw_reason=15;
                    else if(`TW_V.rhit)tw_reason=17;
                    else case(`TW_V.st)
                        `TW_V.S_IDLE:
                            if(`TW_V.g_req)tw_reason=1;
                            else if(`TW_V.wb_v)tw_reason=2;
                            else if(`TW_V.bw_left!=0)tw_reason=3;
                            else if(`TW_V.cap_v&&!`TW_V.cw_pair)tw_reason=4;
                            else tw_reason=5;
                        `TW_V.S_CRES:
                            if(!`TW_V.res_q[20])tw_reason=16;
                            else if(|`TW_V.lhit)tw_reason=6;
                            else if(`TW_V.post_p)tw_reason=7;
                            else tw_reason=8;
                        `TW_V.S_RBLK:tw_reason=9;
                        `TW_V.S_RFIL:tw_reason=10;
                        `TW_V.S_GRES:tw_reason=11;
                        `TW_V.S_GBLK:tw_reason=12;
                        default:tw_reason=13;
                    endcase
                end
                tw_rc[tw_reason]++;
                if(`TW_D.m_ack)begin
                    $fwrite(tw_fd,"R,%0d,%0d,%0d,%0d,%h",tw_cycle,v_frames,tw_rid,tw_cycle-tw_rt+1,tw_ra);
                    foreach(tw_rc[i])$fwrite(tw_fd,",%0d",tw_rc[i]);$fwrite(tw_fd,"\n");
                    tw_read=0;
                end
            end
            if(!tw_write && `TW_D.ek==3 && `TW_D.m_req && `TW_D.m_we && `TW_D.m_addr[31:24]==2)begin
                tw_write=1;tw_wid++;tw_wt=tw_cycle;tw_wa=`TW_D.m_addr;
                foreach(tw_wc[i])tw_wc[i]=0;
            end
            if(tw_write)begin
                tw_wreason=0;
                if(`TW_D.m_ack)tw_wreason=1;
                else if(`TW_F.st==`TW_F.S_GO && `TW_F.pw_v)tw_wreason=2;
                else if(`TW_F.pw_take)tw_wreason=3;
                else if(`TW_F.st==`TW_F.S_MAIN)tw_wreason=4;
                else if(`TW_F.st==`TW_F.S_IDLE)tw_wreason=5;
                else tw_wreason=6;
                tw_wc[tw_wreason]++;
                if(`TW_D.m_ack)begin
                    $fwrite(tw_fd,"W,%0d,%0d,%0d,%0d,%h",tw_cycle,v_frames,tw_wid,tw_cycle-tw_wt+1,tw_wa);
                    foreach(tw_wc[i])$fwrite(tw_fd,",%0d",tw_wc[i]);$fwrite(tw_fd,"\n");tw_write=0;
                end
            end
            // Physical write sources can coexist; retain both addresses.
            if(`TW_V.any_w)$fdisplay(tw_fd,"I,%0d,%0d,%0d,%0d,%0d,%h,%0d,%h,%0d,%h,%0d,%0d,%0d",tw_cycle,v_frames,tw_read,
                `TW_V.st,`TW_V.lv[0],`TW_V.lt[0],`TW_V.cw_valid&&`TW_V.cw_ack,`TW_V.cw_addr,
                `TW_V.vm_req&&`TW_V.vm_ack&&`TW_V.vwe,`TW_V.vm_addr,`TW_V.res_q[19:5],`TW_V.rb_inv,`TW_D.ek);
            if(`TW_V.c_req&&`TW_V.c_dma&&!`TW_V.c_we&&`TW_V.st==`TW_V.S_CRES&&!(|`TW_V.lhit)&&!`TW_V.post_p)
                $fdisplay(tw_fd,"FILL,%0d,%0d,%h,%0d,%0d",tw_cycle,tw_rid,`TW_V.res_q,`TW_V.rb_inv,`TW_V.lv[0]);
            if(`TW_V.st==`TW_V.S_RFIL&&`TW_V.vm_rvalid&&`TW_V.rb_w==7)
                $fdisplay(tw_fd,"FEND,%0d,%0d,%h,%0d",tw_cycle,tw_rid,`TW_V.res_q,`TW_V.rb_inv);
            if(`TW_V.vm_req&&`TW_V.vm_ack)
                $fdisplay(tw_fd,"V,%0d,%0t,%0d,%h,%0d,%0d,%0d",tw_cycle,$time,`TW_V.st,`TW_V.vm_addr,`TW_V.vm_we,`TW_V.vm_blk,tw_rid);
            if(`TW_V.vm_rvalid && (`TW_V.st==`TW_V.S_RFIL))
                $fdisplay(tw_fd,"D,%0d,%0t,%0d,%h",tw_cycle,$time,`TW_V.rb_w,`TW_V.vm_rdata);
            if(`TW_F.pw_take)$fdisplay(tw_fd,"P,%0d,%h,%h,%0d",tw_cycle,`TW_F.addr,`TW_F.wdata,`TW_D.ek);
            if(`TW_F.pw_v)$fdisplay(tw_fd,"Q,%0d,%h,%0d,%0d,%0d,%0d",tw_cycle,`TW_F.pw_a,dut.ds.u_mrarb.own,`TW_P.busy,`TW_F.pw_on,`TW_F.mr_ack);
            if(`TW_P.req_t!=tw_reqprev)$fdisplay(tw_fd,"PS,%0d,%0t,%h,%0d",tw_cycle,$time,`TW_P.b_word,`TW_P.b_write);
            tw_reqprev=`TW_P.req_t;
            if(`TW_P.busy&&`TW_P.done_t!=`TW_P.done_seen)$fdisplay(tw_fd,"PE,%0d,%0t,%h,%0d",tw_cycle,$time,`TW_P.b_word,`TW_P.b_write);
            if(`TW_D.save_go||(`TW_D.est==`TW_D.E_SETUP&&`TW_D.rtag==0))
                $fdisplay(tw_fd,"DMA,%0d,%0d,%0d,%0d,%h,%h,%0d,%0d",tw_cycle,v_frames,`TW_D.ek,`TW_D.save_go,`TW_D.e_src,`TW_D.e_dst,`TW_D.e_rem,`TW_D.e_why);
            if(dut.ds.cap_we&&dut.ds.cap_ready&&dut.ds.u_disp.u_gpu2d.u_bg.s6.x==255)
                $fdisplay(tw_fd,"CAP,%0d,%0d,%0d,%h",tw_cycle,v_frames,dut.ds.u_disp.u_gpu2d.u_bg.j_line,dut.ds.cap_addr);
            if($ftell(tw_fd)>450000000)$fatal(1,"TW_OUTPUT_CAP");
        end
    end
    // The raw MEM event stream joins the ordered V request stream by port2 FIFO order.
    always @(posedge dut.clk_mem)if(ro_started&&ro_enable!=0&&tw_fd)begin
        if(dut.p_valid[2]&&!tw_mem_prev)$fdisplay(tw_fd,"MO,%0t,%h,%0d,%0d,%0d,%0d",$time,dut.p_addr[71:48],dut.sdram.g_v,dut.sdram.g,dut.sdram.mc.st,dut.sdram.mc.ref_owed);
        if(dut.p_take[2])$fdisplay(tw_fd,"MT,%0t,%h",$time,dut.p_addr[71:48]);
        tw_mem_prev=dut.p_valid[2];
    end
    always @(negedge dut.clk_sys)if(ro_started&&ro_enable!=0)
        if(tw_cycle!=ro_cycle)ro_bad("wait observer SYS counter alignment");
    final if(tw_fd)$fclose(tw_fd);
`undef TW_D
`undef TW_V
`undef TW_F
`undef TW_P
