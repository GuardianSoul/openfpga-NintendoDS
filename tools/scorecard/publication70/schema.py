"""Read-only input schema. Fields are LSB first; no production drivers."""
A={
'CR':'$root.tb_ds_pocket','CD':'$root.tb_ds_pocket.dut',
'CS':'$root.tb_ds_pocket.dut.ds','CG':'$root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d'}
A.update(RG=A['CG']+'.g_ring.u_ringx',RA=A['CG']+'.u_raster',
 FP=A['CG']+'.u_raster.u_fpass',FR=A['CG']+'.u_raster.u_front',
 BG=A['CS']+'.u_disp.u_gpu2d.u_bg',XS=A['CS']+'.g_3d.u_xscroll',
 PST=A['CG']+'.g_ext.g_pair.u_store',JR=A['CG']+'.g_ext.g_pair.u_store.u_journal',
 CA=A['CG']+'.g_ext.g_pair.u_canonical')
GROUPS={}; FIELDS=[]
def group(kind,items):
 rows=[]
 for name,width,expr in items:
  for a,p in A.items():expr=expr.replace(a+'.',p+'.')
  row=dict(name=name,width=width,expression=expr,offset=sum(x['width']for x in FIELDS))
  assert name not in [x['name']for x in FIELDS]
  FIELDS.append(row);rows.append(row)
 GROUPS[kind]=rows
def fields(alias,items):return [(name,width,alias+'.'+name)for name,width in items]
group(60,fields('RG',[('frame_go',1),('l3d_go',1),('l3d_line',8),('l3d_raddr',8),('r_go',9),('fp_line',8),('fp_act',1),('ll_ack',1),('ll_q',23),('px_valid',1),('px_x',8),('px_y',8),('px_color',23),('rg_wdrained',1),('rg_wack',1),('rg_rack',1),('rg_rvalid',1),('rg_rdata',32),('ll_rd',1),('ll_slot',2),('ll_x',8)])+[('rst',1,'CD.rst_sys'),('video_frame',16,'CR.v_frames'),('shot',16,'CR.nshot')])
group(61,fields('RG',[('rb_v',2),('rb_p',2),('st_full',4),('st_pres',4),('fp_d',9),('lc_pend',1),('lc_cnt',12),('lc_y',8),('lc_x',9),('lc_px',8),('lc_pv',1),('lc_ab',1),('lc_expired',1),('cp_y',8),('cp_s',2),('cp_x',9),('cp_ab',1),('dir',1),('rb_we_px',1),('cp_we',1),('lc_we',1),('est',3),('drop',1),('blk',5),('w',3),('rblk',5),('rk',3),('w_resume',1),('w_turn',1),('wdone',9),('wdone_q',9),('wsafe',9),('sr_a',10),('dline',8),('need',8),('tgt',8),('rd_on',1),('rd_y',8),('rd_ok',1),('cp_ok',1),('lc_ok',1),('fp_wait',1),('urgent_read',1),('write_turn',1)])+[(f'st_y{i}',8,f'RG.st_y[{i}]')for i in range(4)]+[(f'rb_y{i}',8,f'RG.rb_y[{i}]')for i in range(2)])
group(62,[(n,w,'RG.u_rbuf.'+s)for n,w,s in [('rb_we',1,'we'),('rb_wa',9,'waddr'),('rb_wd',23,'wdata'),('rb_ra',9,'raddr'),('rb_q',23,'rdata')]]+[('rb_source',2,'RG.rb_we_px ? 2\'d0 : RG.cp_we ? 2\'d1 : RG.lc_we ? 2\'d2 : 2\'d3')])
group(63,[(n,w,'RG.u_stage.'+s)for n,w,s in [('st_we',1,'we'),('st_wa',10,'waddr'),('st_wd',23,'wdata'),('st_ra',10,'raddr'),('st_q',23,'rdata')]])
group(64,[('top_we',1,'RA.lbt_we'),('top_wa',10,'RA.lbt_waddr'),('top_lo',32,'RA.lbt_wdata[31:0]'),('top_mid',32,'RA.lbt_wdata[63:32]'),('top_hi',7,'RA.lbt_wdata[70:64]'),('top_flags',3,'{RA.pxt_we,RA.clr_we,RA.fp_clr_ack}'),('fpt_ra',10,'RA.fpt_raddr')])
group(65,[(n,w,'FP.'+s)for n,w,s in [('fp_st',4,'fst'),('fp_x',8,'fp_x'),('fp_y',8,'fp_y'),('fp_done',8,'fp_done'),('fp_run',1,'fp_run'),('fp_hold',1,'px_hold')]]+[(n,w,'RA.'+s)for n,w,s in [('lines_done',8,'lines_done'),('front_y',8,'y'),('adv',1,'adv'),('ll20',1,'ll20'),('lin_hold',1,'lin_hold'),('pxt_we',1,'pxt_we'),('clr_we',1,'clr_we'),('clr_req',1,'fp_clr_req'),('clr_ack',1,'fp_clr_ack')]])
group(66,fields('CG',[('lv_go',1),('ring_have',1),('ring_q',23),('l3d_rear',1),('lv_on',1),('lv_lo',9),('lv_fin',9),('rear_q',23),('l3d_q',23)])+[('cg_rd',32,'CG.l3d_rdata'),('xs_raddr',8,'XS.raddr'),('xs_xpos',9,'XS.xpos'),('xs_l3d_raddr',8,'XS.l3d_raddr'),('xs_in',1,'XS.in_q'),('xs_rd',32,'XS.rdata')])
group(67,fields('BG',[('stall',1),('j_eng',1),('j_line',8),('c_kind',3),('s3_bg',26),('s3_bgop',1),('wmask',8)])+[('s3_v',1,'BG.s3.v'),('s3_x',8,'BG.s3.x'),('s4_v',1,'BG.s4.v'),('s4_x',8,'BG.s4.x'),('s5_v',1,'BG.s5.v'),('s5_x',8,'BG.s5.x'),('s5_c3d',23,'BG.s5.c3d')])
group(68,[(n,w,'CS.u_disp.'+s)for n,w,s in [('out_valid',1,'out_valid'),('out_eng',1,'out_eng'),('draw_line',8,'draw_line'),('out_x',8,'out_x'),('out_rgb',18,'out_rgb')]]+[(n,w,'CS.'+s)for n,w,s in [('cap_we',1,'cap_we'),('cap_ready',1,'cap_ready'),('cap_addr',18,'cap_addr'),('cap_data',16,'cap_data')]])
group(80,[(n,w,'JR.'+s)for n,w,s in [('j_valid',1,'po_valid'),('j_ready',1,'po_ready'),('j_wv',1,'po_wv'),('j_credit',1,'logical_credit'),('j_copy',1,'copy_on'),('j_sealed',1,'sealed[JR.tail[0]]'),('j_other',1,'sealed[!JR.tail[0]]'),('j_used',15,'ingress_used'),('j_unsafe',15,'unsafe_blocks'),('j_req',1,'jw_req'),('j_ack',1,'jw_ack'),('j_word',3,'tx_word'),('j_drained',1,'jw_drained'),('j_quiet',3,'quiet'),('j_tx',1,'tx_on'),('j_copied_pending',1,'sent != JR.copied')]]+[(n,w,'RG.'+s)for n,w,s in [('q_req',1,'rg_wreq'),('q_ack',1,'rg_wack'),('q_addr',24,'rg_waddr')]]+[(n,w,'PST.'+s)for n,w,s in [('f_st',4,'fst'),('f_y',8,'fy'),('draw_gen',15,'draw_gen'),('draw_bank',1,'draw_bank'),('out_free',1,'out_free'),('h_fhit',1,'h_fhit'),('v_fhit',1,'v_fhit'),('f_re',1,'l_re'),('f_ready',1,'ready'),('f_lgo',1,'lgo'),('f_through',1,'l_through'),('f_ly',9,'ly')]]+[('ps_req',1,'CG.ps_line_req'),('ps_y',8,'CG.ps_line_y'),('ps_v',1,'CG.ps_valid'),('ps_r',1,'CG.ps_ready'),('ps_t',2,'CG.ps_type'),('r_phase',3,'CG.r_phase'),('fr_st',4,'FR.st'),('bk_full',1,'FR.bk_full'),('bk_commit',1,'FR.bk_commit'),('e_res',1,'FR.e_res'),('span_st',3,'FR.ss'),('pipe_mask',10,'{RA.lin_hold,RA.hold15,RA.wait17,RA.take17,RA.hold17,RA.wait19,RA.take19,RA.hz20,RA.ll20,1\'b0}'),('ca_st',3,'CA.state'),('h_used',2,'PST.u_headers.used'),('v_used',2,'PST.u_vertices.used'),('h_ast',1,'PST.u_headers.ast'),('v_ast',1,'PST.u_vertices.ast')])
group(81,[('fp_at5',1,'FP.fst == FP.F_5'),('f_y_lim',9,'CG.y_lim')])
BITS=sum(x['width']for x in FIELDS)
