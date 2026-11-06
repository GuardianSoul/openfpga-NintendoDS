// Simulation-only, opt-in profile58 HG193 publication API.
// Include INSIDE the frozen tb_ds_pocket, after sd_poke32/sd_peek32.
// Coordinator supplies a proven clocks-held/full-system-drained publication
// hook. No initial block, clock wait, synthetic so_done or default import hook.
`ifdef HG193_SD_PAIR_OPT_IN
`define HG_GPU $root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d
`define HG_GEOM `HG_GPU.u_geom
`define HG_ENG `HG_GEOM.u_eng
`define HG_FRONT `HG_GEOM.u_front
`define HG_FIN `HG_ENG.g_fu.u_fin
`define HG_STORE `HG_GPU.g_ext.g_pair.u_store
`define HG_SD `HG_GPU.g_ext.g_pair.u_canonical
`define HG_JOURNAL `HG_STORE.u_journal
`define HG_RASTER `HG_GPU.u_raster
`define HG_RING `HG_GPU.g_ring.u_ringx
`define RUNTIME_FIN `HG_FIN
`include "runtime_import_finalize_snapshots.svh"
`undef RUNTIME_FIN
`define RUNTIME_GX_STORE `HG_STORE
`define RUNTIME_GX_SD_ADAPTER `HG_SD
`define RUNTIME_GX_SD_TRANSPORT_DRAINED hg193_system_drained
`include "runtime_import_gx_sd_ready.svh"
`undef RUNTIME_GX_SD_TRANSPORT_DRAINED
`undef RUNTIME_GX_SD_ADAPTER
`undef RUNTIME_GX_STORE

bit hg193_system_drained=0, hg193_applied=0;
logic[31:0] hg193_context[0:3711],hg193_records[0:65535];
logic[31:0] hg193_packets[0:131071],hg193_cold[0:21];
logic[31:0] hg193_current[0:5],hg193_tables[0:71];
logic[10:0] hg193_order[0:4095],hg193_links[0:2047];
logic[16:0] hg193_ytab[0:4095];
logic[22:0] hg193_buckets[0:255];
logic[31:0] hg193_live[0:5][0:15],hg193_frozen[0:3][0:15];
logic[11:0] hg193_sort_bl[0:511];
logic[12:0] hg193_sort_ct[0:511];
logic hg193_sort_tag;
logic[14:0] hg193_generation;
`include "hg193_context.svh"

task automatic hg193_assert_boundary(input bit held);
 assert(held && hg193_system_drained && !`HG_GPU.clk && !`HG_GPU.clk_2x &&
        !$root.tb_ds_pocket.dut.clk_sys && $root.tb_ds_pocket.dut.line_start &&
        $root.tb_ds_pocket.dut.vcount==193 && !hg193_applied)
 else $fatal(1,"HG193 requires the held/drained pre-release line193 hook");
 `include "hg193_profile.svh"
 hg193_assert_gx_sd_pair_drained(held);
 assert(`HG_STORE.READ_DONE && `HG_STORE.BANK_META && `HG_STORE.MAW==12 &&
        `HG_STORE.PSREG && `HG_ENG.PU_DIV_P2X && !`HG_ENG.DIV_P2X &&
        !`HG_RASTER.LB2 && !`HG_RASTER.TR3 && `HG_RING.LLR)
 else $fatal(1,"HG193 physical storage/clock layout differs");
 assert(`HG_GEOM.dbg_idle && `HG_ENG.idle && !`HG_ENG.we_o && !`HG_ENG.we_m &&
        !`HG_ENG.rf_we && !`HG_ENG.div_busy && `HG_ENG.ssp==0 &&
        !`HG_GEOM.e_more && !`HG_GEOM.e_pop && !`HG_GEOM.io_req &&
        !`HG_GEOM.mrd_pend && !`HG_GEOM.mrd_req && !`HG_GEOM.mrd_cap &&
        !`HG_GEOM.swap_go && !`HG_GEOM.swap_ack && !`HG_GEOM.oc_valid &&
        `HG_GEOM.mrd_model_seq==`HG_GEOM.mrd_engine_seq &&
        !`HG_FIN.busy && !`HG_FIN.snapshot_active &&
        !`HG_FIN.g_group_pump.u_groups.pending_we &&
        !`HG_ENG.g_pu.u_cull_products.tex_phase &&
        !`HG_ENG.g_pu.u_cull_products.second &&
        `HG_ENG.g_pu.u_cull_products.cross_tag==`HG_ENG.g_pu.u_cull_products.cross_seen &&
        `HG_ENG.g_pu.u_cull_products.dot_tag==`HG_ENG.g_pu.u_cull_products.dot_seen &&
        !`HG_ENG.lu_busy && !`HG_ENG.lu_spec && !`HG_ENG.lu_pre &&
        !`HG_ENG.lu_cready && !`HG_ENG.dc_pend &&
        `HG_FRONT.wr==`HG_GEOM.dp && `HG_FRONT.mx==`HG_GEOM.dp &&
        `HG_FRONT.f==0 && `HG_FRONT.p==0 &&
        `HG_FRONT.st_w==`HG_FRONT.st_n && `HG_FRONT.st_a==`HG_FRONT.st_n &&
        `HG_FRONT.st_aq==`HG_FRONT.st_a && !`HG_FRONT.act && !`HG_FRONT.up &&
        !`HG_FRONT.flush && !`HG_FRONT.busy && `HG_FRONT.oq_count==0 &&
        `HG_FRONT.engine_lead==0 && `HG_FRONT.g_spill.occ==0 &&
        `HG_FRONT.g_spill.sq==0 && !`HG_FRONT.g_spill.wact &&
        !`HG_FRONT.g_spill.ract && !`HG_FRONT.g_spill.w1 && !`HG_FRONT.g_spill.w2 &&
        `HG_FRONT.tm.cyc==0 && `HG_FRONT.tm.vp==0 && `HG_FRONT.tm.np==0 &&
        `HG_FRONT.tm.pp==0 && `HG_FRONT.tm.vsc==0 && `HG_FRONT.tm.vsf &&
        `HG_FRONT.tm.pend==0 && `HG_FRONT.tm.pend_e==0)
 else $fatal(1,"HG193 geometry/FAST response owner is live");
 assert(!`HG_GPU.r_busy && !`HG_GPU.frame_go && !`HG_GPU.ps_line_req &&
        !`HG_GPU.l3d_go && !`HG_GPU.lv_go && !`HG_GPU.po_valid && !`HG_GPU.po_wv &&
        !`HG_GPU.so_we && !`HG_GPU.so_done && !`HG_GPU.g_busy && !`HG_GPU.sk_v &&
        !`HG_GPU.cp_on && !`HG_GPU.cp_v && !`HG_GPU.tbl_we &&
        `HG_GPU.t_out==0 && `HG_GPU.p_out==0 && `HG_GPU.t_drop==0 &&
        `HG_GPU.p_drop==0 && `HG_GPU.t_n==0 && !`HG_GPU.t_req &&
        !`HG_GPU.t_rvalid && !`HG_GPU.ow_v && !`HG_GPU.rg_rreq &&
        !`HG_GPU.rg_wreq && !`HG_GPU.rg_rvalid &&
        !`HG_GEOM.sp_rreq && !`HG_GEOM.sp_wreq &&
        !`HG_STORE.f_live && !`HG_STORE.f_clr && !`HG_STORE.rq_v &&
        `HG_STORE.fa_n==0 && `HG_STORE.fb_n==0 &&
        !`HG_STORE.u_headers.q_valid && !`HG_STORE.u_vertices.q_valid &&
        !`HG_STORE.u_headers.last_tag_write && !`HG_STORE.u_vertices.last_tag_write &&
        `HG_JOURNAL.copied==`HG_JOURNAL.head &&
        `HG_RING.est==`HG_RING.E_IDLE && !`HG_RING.rd_on &&
        !`HG_GPU.q_wreq && !`HG_GPU.q_rreq && `HG_GPU.rg_wdrained &&
        `HG_GPU.g_sparb.u_arb.wo==0 && `HG_GPU.g_sparb.u_arb.ro==0 &&
        `HG_GPU.g_sparb.u_arb.wp==0 && `HG_GPU.g_sparb.u_arb.rp==0 &&
        `HG_GPU.g_sparb.u_arb.wc==0 && `HG_GPU.g_sparb.u_arb.rc==0 &&
        `HG_GPU.g_sparb.u_arb.w_req==0 && `HG_GPU.g_sparb.u_arb.r_req==0 &&
        `HG_RASTER.pipe_idle && !`HG_RASTER.wk_act && !`HG_RASTER.nx_full &&
        `HG_RASTER.u_front.fe_quiet && `HG_RASTER.u_front.st==`HG_RASTER.u_front.S_IDLE &&
        !`HG_RASTER.u_front.ld_pend && !`HG_RASTER.u_fpass.fp_run &&
        `HG_RASTER.u_fpass.fst==`HG_RASTER.u_fpass.F_IDLE)
 else $fatal(1,"HG193 raster/canonical/transport response owner is live");
 assert(`HG_GPU.geom_en && `HG_GPU.rend_en &&
        `HG_GPU.disp3dcnt==hg193_current[0] && `HG_GPU.alpharef_val==hg193_current[1] &&
        `HG_GPU.clear_attr1==hg193_current[2] && `HG_GPU.clear_attr2==hg193_current[3] &&
        `HG_GPU.fog_color==hg193_current[4] && `HG_GPU.fog_offset==hg193_current[5])
 else $fatal(1,"HG193 ordinary IO replay/current registers differ");
 assert(`HG_STORE.publish_left==0 && `HG_GEOM.swap_n==0 &&
        `HG_ENG.np_r==0 && `HG_ENG.nv_r==0 && `HG_ENG.sort_n==0 &&
        !`HG_ENG.sort_go && !`HG_ENG.g_sort.smo && `HG_ENG.fo_s==0)
 else $fatal(1,"HG193 prepared writer or sort publication debt");
endtask

task automatic hg193_verify_publication;
 logic[31:0] tag;
 for(int key=0;key<16384;key++)begin
  tag=32'hc4e00000 | (32'(key)<<2);
  for(int w=0;w<4;w++)
   assert(sd_peek32(24'h1a0000+24'(8*key+w))===hg193_records[4*key+w])
   else $fatal(1,"HG193 canonical payload record%0d word%0d",key,w);
  assert(sd_peek32(24'h1a0000+24'(8*key+4))===tag &&
         sd_peek32(24'h1a0000+24'(8*key+5))===~tag &&
         sd_peek32(24'h1a0000+24'(8*key+6))===32'h47335344 &&
         sd_peek32(24'h1a0000+24'(8*key+7))===0)
  else $fatal(1,"HG193 canonical record/address/tag guard %0d",key);
 end
 for(int i=0;i<4096;i++)
  assert(`HG_STORE.u_ord.mem[i]===hg193_order[i] && `HG_STORE.u_ytab.mem[i]===hg193_ytab[i])
  else $fatal(1,"HG193 banked order/Y readback %0d",i);
 for(int i=0;i<2048;i++)assert(`HG_STORE.u_lk.mem[i]===hg193_links[i])
  else $fatal(1,"HG193 arrival link readback %0d",i);
 for(int i=0;i<256;i++)assert(`HG_STORE.u_bk.mem[i]===hg193_buckets[i] &&
                                           `HG_STORE.u_bkf.mem[i]===hg193_buckets[i])
  else $fatal(1,"HG193 arrival bucket readback %0d",i);
 for(int i=0;i<128;i++)assert(`HG_STORE.u_headers.u_tags.mem[i]===84'd0)
  else $fatal(1,"HG193 header cache still valid");
 for(int i=0;i<512;i++)assert(`HG_STORE.u_vertices.u_tags.mem[i]===84'd0)
  else $fatal(1,"HG193 vertex cache still valid");
 assert(`HG_JOURNAL.wb==1 && `HG_STORE.rb==0 && `HG_JOURNAL.vptr==0 &&
        `HG_STORE.rcount==622 && `HG_STORE.tag && `HG_STORE.ready &&
        `HG_STORE.bank_gen[0]==hg193_generation && `HG_STORE.draw_gen==hg193_generation &&
        `HG_STORE.draw_bank==0 && `HG_STORE.publish_left==0 && `HG_GEOM.so_count==622)
 else $fatal(1,"HG193 bank/count/generation publication differs");
 hg193_verify_context();
 for(int i=0;i<512;i++)assert(`HG_ENG.g_sort.u_bl.mem[i]===hg193_sort_bl[i] &&
       `HG_ENG.g_sort.u_ct.mem[i]===hg193_sort_ct[i] &&
       `HG_ENG.g_sort.u_bl.mem[i][11]===!hg193_sort_tag &&
       `HG_ENG.g_sort.u_ct.mem[i][12]===!hg193_sort_tag)
 else $fatal(1,"HG193 writer sort epoch changed");
 assert(`HG_ENG.g_sort.stag===hg193_sort_tag)
 else $fatal(1,"HG193 writer sort tag changed");
 `include "hg193_cold_verify.svh"
endtask

task automatic hg193_publish(input string directory,input bit held,input bit system_drained);
 logic[31:0] tag;
 $readmemh({directory,"/context.hex"},hg193_context);
 $readmemh({directory,"/records.hex"},hg193_records);
 $readmemh({directory,"/sd-packets.hex"},hg193_packets);
 $readmemh({directory,"/order.hex"},hg193_order);
 $readmemh({directory,"/ytab.hex"},hg193_ytab);
 $readmemh({directory,"/links.hex"},hg193_links);
 $readmemh({directory,"/buckets.hex"},hg193_buckets);
 $readmemh({directory,"/current_regs.hex"},hg193_current);
 $readmemh({directory,"/render_tables.hex"},hg193_tables);
 $readmemh({directory,"/cold_epoch.hex"},hg193_cold);
 hg193_system_drained=system_drained;
 hg193_assert_boundary(held);
 assert(hg193_cold[0]==32'h48473139 && hg193_cold[1]==2 && hg193_cold[2]==0 &&
        hg193_cold[3]==622 && hg193_cold[4]==4500 && hg193_cold[5]==192 &&
        hg193_cold[6]==193 && hg193_cold[7]==0 && hg193_cold[8]==0 &&
        hg193_cold[9]==400416 && hg193_cold[16]==1 && hg193_cold[17]==12 &&
        hg193_cold[18]==0 && hg193_cold[19]==622 && hg193_cold[20]==2048 &&
        hg193_cold[21]==4096 && hg193_context[3603]==1 && hg193_context[3608]==0 &&
        hg193_context[3592]==0 && hg193_context[3593]==0)
 else $fatal(1,"HG193 descriptor/continuation differs");
 // Validate the entire translated image before any target deposit.
 for(int key=0;key<16384;key++)begin
  tag=32'hc4e00000 | (32'(key)<<2);
  for(int w=0;w<4;w++)assert(hg193_packets[8*key+w]===hg193_records[4*key+w])
   else $fatal(1,"HG193 translated payload differs");
  assert(hg193_packets[8*key+4]===tag && hg193_packets[8*key+5]===~tag &&
         hg193_packets[8*key+6]===32'h47335344 && hg193_packets[8*key+7]===0)
   else $fatal(1,"HG193 translated record/address/tag differs");
 end
 assert(`HG_ENG.g_sort.stag===1'b0 || `HG_ENG.g_sort.stag===1'b1)
 else $fatal(1,"HG193 unknown writer sort tag");
 hg193_sort_tag=`HG_ENG.g_sort.stag;
 for(int i=0;i<512;i++)begin
  assert(`HG_ENG.g_sort.u_bl.mem[i][11]===!hg193_sort_tag &&
         `HG_ENG.g_sort.u_ct.mem[i][12]===!hg193_sort_tag)
   else $fatal(1,"HG193 current writer sort not empty");
  hg193_sort_bl[i]=`HG_ENG.g_sort.u_bl.mem[i];
  hg193_sort_ct[i]=`HG_ENG.g_sort.u_ct.mem[i];
 end
 hg193_apply_context();
 for(int i=0;i<131072;i++)sd_poke32(24'h1a0000+24'(i),hg193_packets[i]);
 for(int i=0;i<4096;i++)begin
  `HG_STORE.u_ord.mem[i]=hg193_order[i];`HG_STORE.u_ytab.mem[i]=hg193_ytab[i];
 end
 for(int i=0;i<2048;i++)`HG_STORE.u_lk.mem[i]=hg193_links[i];
 for(int i=0;i<256;i++)begin
  `HG_STORE.u_bk.mem[i]=hg193_buckets[i];`HG_STORE.u_bkf.mem[i]=hg193_buckets[i];
 end
 // Invalidate all cached aliases after the durable backing-image deposit.
 // No pending query, invalidation, recency write or physical response exists.
 for(int i=0;i<128;i++)`HG_STORE.u_headers.u_tags.mem[i]=84'd0;
 for(int i=0;i<512;i++)`HG_STORE.u_vertices.u_tags.mem[i]=84'd0;
 `HG_STORE.u_headers.saved_hit=0;`HG_STORE.u_vertices.saved_hit=0;
 // Rebase cache identity to the actual empty journal cursor. The legacy
 // payload has no journal generation. No fictitious completion is issued.
 hg193_generation=`HG_JOURNAL.head;
 `HG_JOURNAL.wb=1;`HG_JOURNAL.vptr=0;
 `HG_STORE.bank_gen[0]=hg193_generation;
 `HG_STORE.draw_bank=0;`HG_STORE.draw_gen=hg193_generation;
 `HG_STORE.rb=0;`HG_STORE.rcount=622;`HG_STORE.tag=1;
 `HG_STORE.bpos=622;`HG_STORE.building=0;
 `HG_GEOM.so_count=622;
 `HG_STORE.lgo=0;`HG_STORE.ly=192;`HG_STORE.l_drawn=0;`HG_STORE.l_re=0;
 `HG_STORE.f_dead=0;`HG_STORE.fquiet=0;`HG_STORE.fa=0;`HG_STORE.fa_i=0;
 `HG_STORE.ha_v=0;`HG_STORE.hr_v=0;
 `include "hg193_cold_apply.svh"
 // Ready is the final publication store; all clocks remain held through readback.
 `HG_STORE.ready=1;
 hg193_verify_publication();
 hg193_assert_gx_sd_pair_drained(held);
 hg193_applied=1;
 $display("HG193_SD_PAIR_SOURCE_ADAPTER_APPLIED: bank0 count622; default importer unchanged");
endtask
`undef HG_GPU
`undef HG_GEOM
`undef HG_ENG
`undef HG_FRONT
`undef HG_FIN
`undef HG_STORE
`undef HG_SD
`undef HG_JOURNAL
`undef HG_RASTER
`undef HG_RING
`endif
