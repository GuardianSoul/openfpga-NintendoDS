// Independent accepted-interface queues. This code drives no DUT signal.
logic[31:0]gold[int];logic[3:0]known[int];
integer native_checks=0,pixel_checks=0,consumer_checks=0,refreshes=0;
integer cancel_cache_seen=0,cancel_read_seen=0;
integer capture_pairs=0,cpu_posts=0,lone_halves=0;
integer obs_sys=0,pin_memory_checks=0,video_read_words=0,max_video_write_backlog=0,max_video_read_backlog=0,max_capture_backlog=0;
integer d_return_blocks=0,max_2d_backlog=0,cpu_wait_cycles=0,max_cpu_wait=0;
bit measure_traffic_deadlines=0;integer traffic_misses[4]='{0,0,0,0},last_miss_period[4]='{-1,-1,-1,-1};
initial measure_traffic_deadlines=$test$plusargs("measure_traffic_deadlines");
task automatic traffic_miss(input integer kind,input integer period,input integer cycle,input integer backlog);
 if(last_miss_period[kind]!=period)begin
  last_miss_period[kind]=period;traffic_misses[kind]++;
  if(fd)$fdisplay(fd,"TRAFFIC_DEADLINE_MISS,%0d,%0d,%0d,%0d,%0d,%h,%h,%0d",kind,period,cycle,backlog,vram.pr_hit,vram.pr_lo,vram.pr_hi,rg_wfill);
 end
 if(!measure_traffic_deadlines)$fatal(1,"TRAFFIC_DEADLINE kind=%0d backlog=%0d",kind,backlog);
endtask
logic[22:0]ref_pixels[4][49152];bit ref_valid[4][49152];
logic[22:0]actual_pixels[4][49152];bit actual_valid[4][49152];integer actual_pixel_count=0;
integer classes[3]='{0,0,0},owner_blocks[3]='{0,0,0};
integer fd=0;string trace_path;bit trace_capped=0;
initial if($value$plusargs("trace=%s",trace_path))begin fd=$fopen(trace_path,"w");$fdisplay(fd,"# COMPLETE_CONE1 SYS/MEM preNBA; accepted request owners, not current arbitration snapshots");end
task automatic cap_trace;
 if(fd && $ftell(fd)>48*1024*1024)begin $fdisplay(fd,"TRACE_CAP_REACHED");$fclose(fd);fd=0;trace_capped=1;end
endtask
task automatic seed(input logic[23:0]w);
 logic[31:0]v;integer ix;
 v=image_word(w);ix=chip_index(w);chip.mem[ix]=v[15:0];chip.mem[ix+1]=v[31:16];gold[int'(w)]=v;known[int'(w)]=15;
endtask
task automatic put_gold(input logic[23:0]w,input logic[31:0]v,input logic[3:0]be);
 logic[31:0]q;logic[3:0]k;
 q=gold.exists(int'(w))?gold[int'(w)]:0;k=known.exists(int'(w))?known[int'(w)]:0;
 for(integer b=0;b<4;b++)if(be[b])begin q[b*8+:8]=v[b*8+:8];k[b]=1;end
 gold[int'(w)]=q;known[int'(w)]=k;
endtask
// Native queue is derived at controller acceptance, independently of bus.own.
integer nwp=0,nrp=0,nbeat=0,n_owner[32],n_len[32];logic[23:0]n_addr[32];logic[31:0]n_expected[32][8];
bit routed_valid=0;integer routed_owner;logic[31:0]routed_data;
integer lastrefresh=0,fifo_words=0,fifo_quanta=0,quantum_words=0;
logic lastgv=0,lastbw=0;
always @(posedge memclk)begin
 memcycles++;
 if(p_w[0])video_read_words++;
 if(load)begin
  integer backlog;backlog=128*(1+(memcycles-traffic_mem_at)/2100)-video_read_words;
  if(backlog>max_video_read_backlog)max_video_read_backlog=backlog;
  if(backlog>128)traffic_miss(0,(memcycles-traffic_mem_at)/2100,memcycles,backlog);
 end
 if(p_w!=0)begin
  if(!routed_valid||p_w!==(7'b1<<routed_owner)||p_wd!==routed_data)$fatal(1,"NATIVE_RETURN_OWNER_OR_VALUE owner=%0d mask=%b",routed_owner,p_w);
  native_checks++;
 end else if(routed_valid)$fatal(1,"NATIVE_RETURN_LOST");
 routed_valid=0;
 if(bw_read)begin quantum_words++;fifo_words++;put_gold(bw_q[55:32],bw_q[31:0],{{2{bw_q[57]}},{2{bw_q[56]}}});end
 if(bus.mc.bw_start)begin quantum_words=0;fifo_quanta++;if(fd)$fdisplay(fd,"FIFO_START,%0d,%0t,%h,%0d",memcycles,$time,bw_q[55:32],bus.fifo_age);end
 if(bus.mc.bw_done)begin
  if(quantum_words<1||quantum_words>8)$fatal(1,"WRITE_QUANTUM");
  if(fd)$fdisplay(fd,"FIFO_DONE,%0d,%0t,%0d",memcycles,$time,quantum_words);
 end
 if(!init&&!bus.c_ready&&!bus.g_v&&!bus.bw_grant&&bus.fair_any&&fd)$fdisplay(fd,"GRANT_SELECTED,%0d,%0t,%0d,%0d,%0d,%0d,%b,%b",memcycles,$time,bus.fair_pick,bus.fair_hot,bus.urgent_count,bus.fifo_age,p_valid,bus.m_hurry);
 lastgv=bus.g_v;
 if(bus.c_ready)begin
  integer p,wc;p=int'(bus.g);wc=int'(p_n[p*4+:4]);
  if(fd)$fdisplay(fd,"NATIVE_ACCEPT,%0d,%0t,%0d,%h,%0d,%0d,%0d",memcycles,$time,p,p_addr[p*24+:24],wc,p_we[p],nwp);
  if(p_we[p])put_gold(p_addr[p*24+:24],p_wdata[p*32+:32],p_be[p*4+:4]);
  else begin
   if(nwp-nrp>=31)$fatal(1,"NATIVE_QUEUE_OVERFLOW");
   n_owner[nwp%32]=p;n_len[nwp%32]=wc;n_addr[nwp%32]=p_addr[p*24+:24];
   for(integer j=0;j<wc;j++)begin
    integer a;a=int'(p_addr[p*24+:24])+j;
    if(!known.exists(a)||known[a]!=15)$fatal(1,"UNKNOWN_NATIVE_READ port=%0d addr=%h",p,a);
    n_expected[nwp%32][j]=gold[a];
   end
   nwp++;
  end
 end
 if(bus.mc.r_valid)begin
  if(nrp==nwp||bus.mc.r_data!==n_expected[nrp%32][nbeat]||bus.mc.r_last!==(nbeat==n_len[nrp%32]-1))$fatal(1,"NATIVE_ACTIVE_OWNER_OR_DATA q=%0d beat=%0d",nrp,nbeat);
  if(fd && (nbeat==0||bus.mc.r_last))$fdisplay(fd,"NATIVE_BEAT,%0d,%0t,%0d,%0d,%h,%0d,%0d,%h",memcycles,$time,nrp,n_owner[nrp%32],n_addr[nrp%32],nbeat,bus.mc.r_last,bus.mc.r_data);
  routed_valid=1;routed_owner=n_owner[nrp%32];routed_data=bus.mc.r_data;
  if(nbeat==n_len[nrp%32]-1)begin nrp++;nbeat=0;end else nbeat++;
 end
 if({nras,ncas,nwe}==3'b001)begin refreshes++;lastrefresh=memcycles;if(fd)$fdisplay(fd,"REFRESH,%0d,%0t",memcycles,$time);end
 if(ready&&memcycles-lastrefresh>2048)$fatal(1,"REFRESH_DEADLINE");
 cap_trace();
end
// Block owners are captured at the original early g_ack, before native V.
integer gwp=0,grp=0,gbeat=0,vp=0;integer gowner[128];logic[23:0]gaddr[128];
logic[17:0]gblock[128];integer gclass[128];
integer tex_class=0,pal_class=0;logic hint1=0,hint2=0;
logic[15:0]tex_expected[64],pal_expected[64];integer twp=0,trp=0,pwp=0,prp=0;
logic[3:0]last_stage=0;bit last_hold=0;logic[2:0]last_rb_v=0,last_rb_p=0;logic[7:0]last_rb_y[3];
integer last_go=0;
integer service_epoch=0,completed_rows=0;
logic[47:0]last_dependency=0;
bit previous_job=0;
bit c_wait=0,d_wait=0,cap_wait=0,ring_wait=0;
logic[23:2]held_cpu_addr;logic[31:0]held_cpu_data;logic[3:0]held_cpu_be;bit held_cpu_we;
blk_t held_d_blk;logic[17:0]held_cap_addr;logic[15:0]held_cap_data;logic[23:0]held_ring_addr;
always @(posedge clk)begin
 obs_sys++;
 if(!rst)begin
 if(load)begin
  integer backlog;backlog=128*(1+(obs_sys-traffic_at)/4260)-video_words;
  if(backlog>max_video_write_backlog)max_video_write_backlog=backlog;
  if(backlog>256)traffic_miss(1,(obs_sys-traffic_at)/4260,obs_sys,backlog);
  backlog=256*(1+(obs_sys-traffic_at)/4260)-cap_halves;
  if(backlog>max_capture_backlog)max_capture_backlog=backlog;
  if(backlog>256)traffic_miss(2,(obs_sys-traffic_at)/4260,obs_sys,backlog);
  backlog=64*(1+(obs_sys-traffic_at)/4260)-d_return_blocks;
  if(backlog>max_2d_backlog)max_2d_backlog=backlog;
  if(backlog>64)traffic_miss(3,(obs_sys-traffic_at)/4260,obs_sys,backlog);
 end
 if(c_req&&!c_ack)cpu_wait_cycles++;
 if(c_ack)begin if(cpu_wait_cycles>max_cpu_wait)max_cpu_wait=cpu_wait_cycles;cpu_wait_cycles=0;end
 if(cw_valid&&cw_ack)begin
  if(vram.cw_pair)capture_pairs++;else cpu_posts++;
  if(fd)$fdisplay(fd,"SYS_POST,%0d,%0d,%h,%h,%b",obs_sys,vram.cw_pair,cw_addr,cw_data,cw_he);
 end
 if(dut.frame_go)begin service_epoch<=int'(generation);completed_rows<=0;end
 else if(px_valid&&px_x==255)completed_rows<=int'(px_y)+1;
 if({dut.u_raster.y,dut.u_raster.wait17,dut.u_raster.wait19,dut.g_c2.u_tc.hb,dut.g_c2.u_pc.hb,dut.g_c2.u_tc.st,dut.g_c2.u_pc.st,dut.g_c2.u_tc.f_v,dut.g_c2.u_pc.f_v,dut.g_c2.u_tc.r_v,dut.g_c2.u_pc.r_v}!==last_dependency)begin
  if(fd)$fdisplay(fd,"DEPENDENCY,%0d,%0d,%0d,%0d,%0d,%0d,%h,%h,%0d,%0d,%b,%b,%0d,%0d,%0d,%0d,%0d",obs_sys,service_epoch,dut.u_raster.y,completed_rows,dut.u_raster.wait17,dut.u_raster.wait19,dut.g_c2.u_tc.hb,dut.g_c2.u_pc.hb,dut.g_c2.u_tc.st,dut.g_c2.u_pc.st,dut.g_c2.u_tc.f_v,dut.g_c2.u_pc.f_v,dut.g_c2.u_tc.r_v,dut.g_c2.u_pc.r_v,ring_due_valid,ring_due_line,ring_due_sys);
  last_dependency={dut.u_raster.y,dut.u_raster.wait17,dut.u_raster.wait19,dut.g_c2.u_tc.hb,dut.g_c2.u_pc.hb,dut.g_c2.u_tc.st,dut.g_c2.u_pc.st,dut.g_c2.u_tc.f_v,dut.g_c2.u_pc.f_v,dut.g_c2.u_tc.r_v,dut.g_c2.u_pc.r_v};
 end
 if(c_wait&&!c_ack&&(!c_req||{c_we,c_addr,c_be,c_wdata}!=={held_cpu_we,held_cpu_addr,held_cpu_be,held_cpu_data}))$fatal(1,"FIXTURE_CPU_WITHDREW_OFFER");
 if(d_wait&&!d_ack&&(!d_req||d_blk!==held_d_blk))$fatal(1,"FIXTURE_2D_WITHDREW_OFFER");
 if(cap_wait&&!cap_ready&&(!cap_we||{cap_addr,cap_data}!=={held_cap_addr,held_cap_data}))$fatal(1,"FIXTURE_CAPTURE_WITHDREW_OFFER");
 if(ring_wait&&!rg_rack&&(!rg_rreq||rg_raddr!==held_ring_addr))$fatal(1,"RING_READ_WITHDREW_OFFER");
 c_wait=c_req&&!c_ack;held_cpu_addr=c_addr;held_cpu_data=c_wdata;held_cpu_we=c_we;held_cpu_be=c_be;
 d_wait=d_req&&!d_ack;held_d_blk=d_blk;cap_wait=cap_we&&!cap_ready;held_cap_addr=cap_addr;held_cap_data=cap_data;
 ring_wait=rg_rreq&&!rg_rack;held_ring_addr=rg_raddr;
 previous_job<=l3d_go;
 if(previous_job&&!dut.frame_go&&fd)$fdisplay(fd,"SNAPSHOT,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,l3d_line,l3d_have,dut.u_service.hit_slot,dut.fp_line,dut.r_front_go,dut.u_service.ordered);
 if(previous_job&&!dut.frame_go&&!l3d_have)$fatal(1,"DELIVERY_DEADLINE actual_readiness_edge row=%0d SYS=%0d",l3d_line,obs_sys);
 hint1<=dut.g_c2.u_tc.p_go;hint2<=hint1;
 if(dut.g_c2.u_tc.s_req)tex_class<=hint2?2:1;
 else if((dut.g_c2.u_tc.st==dut.g_c2.u_tc.C_LOOK&&!dut.g_c2.u_tc.hit&&!dut.g_c2.u_tc.onway(dut.g_c2.u_tc.hb)&&!dut.g_c2.u_tc.r_v&&dut.g_c2.u_tc.slot)||
         (dut.g_c2.u_tc.st==dut.g_c2.u_tc.C_NEED&&!dut.g_c2.u_tc.onway(dut.g_c2.u_tc.hb)&&!dut.g_c2.u_tc.r_v&&dut.g_c2.u_tc.slot))tex_class<=0;
 if(dut.g_c2.u_pc.s_req)pal_class<=1;
 else if((dut.g_c2.u_pc.st==dut.g_c2.u_pc.C_LOOK&&!dut.g_c2.u_pc.hit&&!dut.g_c2.u_pc.onway(dut.g_c2.u_pc.hb)&&!dut.g_c2.u_pc.r_v&&dut.g_c2.u_pc.slot)||
         (dut.g_c2.u_pc.st==dut.g_c2.u_pc.C_NEED&&!dut.g_c2.u_pc.onway(dut.g_c2.u_pc.hb)&&!dut.g_c2.u_pc.r_v&&dut.g_c2.u_pc.slot))pal_class<=0;
 if(tex_req)begin
  if(fd)$fdisplay(fd,"TREQ,%0d,%0d,%0d,%h,%0d,%h,%0d",obs_sys,service_epoch,twp,tex_addr,dut.u_raster.y,dut.g_c2.u_tc.hb,dut.u_raster.wait17);
  tex_expected[twp%64]<={texture_byte(int'(tex_addr&19'h7fffe)+1),texture_byte(int'(tex_addr&19'h7fffe))};twp++;
 end
 if(pal_req)begin
  if(fd)$fdisplay(fd,"PREQ,%0d,%0d,%0d,%h,%0d",obs_sys,service_epoch,pwp,pal_addr,dut.u_raster.y);
  pal_expected[pwp%64]<=palette_half(int'(pal_addr&17'h0fffe));pwp++;
 end
 if(dut.tc_v)begin if(trp==twp||dut.tex_data!==tex_expected[trp%64])$fatal(1,"TEXEL_ORDER_OR_VALUE");if(fd)$fdisplay(fd,"TRET,%0d,%0d,%0d,%0d,%h",obs_sys,generation,trp,dut.t_drop,dut.tex_data);trp++;end
 if(dut.pc_v)begin if(prp==pwp||dut.pal_data!==pal_expected[prp%64])$fatal(1,"PALETTE_ORDER_OR_VALUE");if(fd)$fdisplay(fd,"PRET,%0d,%0d,%0d,%0d,%h",obs_sys,generation,prp,dut.p_drop,dut.pal_data);prp++;end
 if(dut.tpf_v&&fd)$fdisplay(fd,"HINT,%0d,%0d,%h,%0d,%0d",obs_sys,generation,dut.tpf_a,dut.g_c2.u_tc.pq_n,dut.g_c2.u_tc.p_go);
 if(g_ack)begin
  integer own,cl;logic[23:0]wa;
  own=d_req?0:dut.t_pick?2:1;cl=own==0?-1:own==1?tex_class:pal_class;
  wa=own==0?24'h24000+24'(g_blk[13:0]*8):own==1?24'(g_blk[13:0]*8):24'h20000+24'(g_blk[13:0]*8);
  if(gwp-grp>=127)$fatal(1,"BLOCK_QUEUE_OVERFLOW");
  gowner[gwp%128]=own;gaddr[gwp%128]=wa;gblock[gwp%128]=g_blk;gclass[gwp%128]=cl;owner_blocks[own]++;
  if(own!=0)classes[cl]++;
  if(fd)$fdisplay(fd,"BLOCK_ACCEPT,%0d,%0d,%0d,%0d,%0d,%h,%h,%0d,%0d,%0d,%h,%h,%0d,%0d",obs_sys,generation,gwp,own,cl,g_blk,wa,dut.g_c2.u_tc.n,dut.g_c2.u_tc.r_v,dut.g_c2.u_tc.f_v,dut.g_c2.u_tc.hb,dut.g_c2.u_pc.hb,dut.u_raster.y,dut.u_raster.wait17);
  gwp++;
 end
 if(vm_req&&vm_ack)begin
  if(vram.st==vram.S_GBLK)begin
   if(vp==gwp||24'(vm_addr)!==gaddr[vp%128])$fatal(1,"VRAM_ACCEPTED_OWNER_ADDRESS id=%0d got=%h expected=%h",vp,vm_addr,gaddr[vp%128]);
   if(fd)$fdisplay(fd,"VRAM_BLOCK,%0d,%0t,%0d,%0d,%0d,%h",obs_sys,$time,vp,gowner[vp%128],gclass[vp%128],vm_addr);
   vp++;
  end else begin
   if(vram.st==vram.S_CAP)lone_halves++;
   if(fd)$fdisplay(fd,"VRAM_CPU,%0d,%0t,%0d,%h,%0d,%0d",obs_sys,$time,vram.st,vm_addr,vm_we,vm_blk);
  end
 end
 if(g_rvalid)begin
  logic[63:0]expected;
  if(grp==gwp)$fatal(1,"BLOCK_RETURN_WITHOUT_OWNER");
  expected={gold[int'(gaddr[grp%128])+2*gbeat+1],gold[int'(gaddr[grp%128])+2*gbeat]};
  if(g_rdata!==expected || d_rvalid!==(gowner[grp%128]==0) || t_rvalid!==(gowner[grp%128]!=0))$fatal(1,"BLOCK_RETURN_OWNER_OR_VALUE id=%0d owner=%0d",grp,gowner[grp%128]);
  if(fd)$fdisplay(fd,"BLOCK_BEAT,%0d,%0d,%0d,%0d,%h",obs_sys,grp,gowner[grp%128],gbeat,g_rdata);
  if(gbeat==3)begin if(gowner[grp%128]==0)d_return_blocks++;grp++;gbeat=0;end else gbeat++;
 end
 if(ref_px && !reference.frame_go && !reference.r_abort)begin
  integer a;a=int'(ref_y)*256+int'(ref_x);
  if(ref_valid[ref_generation][a])$fatal(1,"DUPLICATE_REFERENCE_PIXEL");
  if(actual_valid[ref_generation][a])begin
   if(actual_pixels[ref_generation][a]!==ref_color)$fatal(1,"PRODUCER_PIXEL late_reference gen=%0d y=%0d x=%0d got=%h expected=%h",ref_generation,ref_y,ref_x,actual_pixels[ref_generation][a],ref_color);
   pixel_checks++;
  end
  ref_pixels[ref_generation][a]=ref_color;ref_valid[ref_generation][a]=1;
 end
 if(px_valid && !dut.frame_go && !dut.r_abort)begin
  integer a;a=int'(px_y)*256+int'(px_x);
  if(actual_valid[generation][a])$fatal(1,"DUPLICATE_PRODUCER_PIXEL");
  if(ref_valid[generation][a])begin
   if(px_color!==ref_pixels[generation][a])$fatal(1,"PRODUCER_PIXEL gen=%0d y=%0d x=%0d got=%h expected=%h",generation,px_y,px_x,px_color,ref_pixels[generation][a]);
   pixel_checks++;
  end
  actual_pixels[generation][a]=px_color;actual_valid[generation][a]=1;actual_pixel_count++;
  if(px_x==255 && fd)$fdisplay(fd,"PRODUCER_DONE,%0d,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,px_y,dut.r_front_go,dut.u_service.posted,dut.u_service.ordered);
 end
 if(dut.frame_go && fd)$fdisplay(fd,"FRAME,%0d,%0d,%0d,%0d",obs_sys,generation,dut.t_drop,dut.p_drop);
 if(dut.r_abort && fd)$fdisplay(fd,"CANCEL,%0d,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,dut.t_out,dut.p_out,dut.u_service.rs,dut.u_service.consumer_valid);
 if(last_stage!=dut.u_service.st_full||last_hold!=dut.fp_hold)begin
  if(fd)$fdisplay(fd,"STAGE,%0d,%0d,%b,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,dut.u_service.st_full,dut.fp_hold,dut.fp_line,dut.r_front_go,dut.u_service.posted,dut.u_service.ordered);
  last_stage=dut.u_service.st_full;last_hold=dut.fp_hold;
 end
 if(l3d_go && fd)$fdisplay(fd,"DUE_JOB,%0d,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,l3d_line,ring_due_line,ring_due_sys,dut.r_front_go);
 if(rg_rreq&&rg_rack && fd)$fdisplay(fd,"RING_ACCEPT,%0d,%0d,%h,%0d,%0d,%0d",obs_sys,generation,rg_raddr,rg_hurry,ring_due_line,ring_due_sys);
 cap_trace();
end
end
always @(negedge clk)if(!rst)begin
 if(obs_sys!=syscycles)$fatal(1,"OBSERVER_CLOCK_COUNT");
 for(integer i=0;i<3;i++)begin
  if(dut.u_service.rb_v[i]&&(!last_rb_v[i]||last_rb_y[i]!=dut.u_service.rb_y[i]||last_rb_p[i]!=dut.u_service.rb_p[i]))
   if(fd)$fdisplay(fd,"PUBLICATION,%0d,%0d,%0d,%0d,%0d",syscycles+1,generation,i,dut.u_service.rb_y[i],dut.u_service.rb_p[i]);
  last_rb_y[i]=dut.u_service.rb_y[i];
 end
 last_rb_v=dut.u_service.rb_v;last_rb_p=dut.u_service.rb_p;
end
final if(fd)begin $fdisplay(fd,"END,%0d,%0d,%0d,%0d,%0d,%0d",syscycles,native_checks,pixel_checks,consumer_checks,nwp,nrp);$fclose(fd);end
