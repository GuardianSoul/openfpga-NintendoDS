// Observational only. Counts overlap; D-category and F-category rows each partition slots.
`define B dut.shared
`define E dut.shared.engine
longint slots[2],fcat[2][5],dcat[2][7],ret[2],rew[2],replay[2],redirect[2];
longint ienq[2],iack[2],icons[2],denq[2],dack[2],dcons[2];
longint iborn[2],dborn[2],ianswered[2],danswered[2];
longint ila[2],icl[2],dla[2],dcl[2],imax[2],dmax[2],imin[2],dmin[2];
longint busy_i[2],busy_d[2],wait_d[2],memissue[2];
always @(posedge clk2)if(!rst)begin
 integer c,a;longint nowtick,lat;
 c=`B.ci_tid;a=`B.answer_context;nowtick=$rtoi($realtime/5.0);
 slots[c]++;
 if(`E.fetch_en)fcat[c][0]++;else if(`B.ibusy[c])fcat[c][1]++;else if(`E.pd_rew)fcat[c][2]++;else if(`E.halted[0])fcat[c][3]++;else fcat[c][4]++;
 c=`E.c1;
 if(`E.have)dcat[c][0]++;else if(`E.wb_kill)dcat[c][1]++;else if(`E.hazard)dcat[c][2]++;else if(`E.sbub)dcat[c][3]++;else if(`E.dw_hold)dcat[c][4]++;else if(!`E.ib_v[1])dcat[c][5]++;else dcat[c][6]++;
 if(`E.have&&`E.c_ismem)memissue[c]++;
 c=`B.ci_tid;
 if(`E.pd_rew)rew[c]++;
 if(`E.x2_rdr&&`E.x_replay)replay[c]++;
 if(`E.kill_e)redirect[c]++;
 if(dbg_retire)ret[dbg_tid]++;
 if(`B.ibusy[c])busy_i[c]++;if(`B.dbusy[c])busy_d[c]++;if(dut.shared.native_wait[c])wait_d[c]++;
 if(`B.ci_req&&!`B.ibusy[c]&&(`B.idone[c]||`B.iq[c]!={`B.ci_priv,`B.ci_addr}))begin ienq[c]++;iborn[c]=nowtick;end
 c=`B.cd_tid;
 if((`B.cd_req||`B.cc_req)&&!`B.cd_kill&&!`B.dbusy[c]&&`B.ddone[c])begin denq[c]++;dborn[c]=nowtick;end
 if(`B.last_iv[a]&&`B.ci_ok&&!`B.idone[a])begin icons[a]++;icl[a]+=nowtick-ianswered[a];end
 if(`B.last_dv[a]&&`B.cd_ok&&!`B.ddone[a])begin dcons[a]++;dcl[a]+=nowtick-danswered[a];end
 if(cycle<160&&run[0]&&(`B.ci_req||`B.cd_req||`B.cc_req||`E.pd_rew||dbg_retire))
  $display("BRIDGE tick=%0d c=%0d F=%b pc=%h Ibusy=%b Iok=%b rew=%b D=%b CP=%b addr=%h Dbusy=%b Dok=%b ret=%b rpc=%h",nowtick,`B.ci_tid,`B.ci_req,`B.ci_addr,`B.ibusy,`B.ci_ok,`E.pd_rew,`B.cd_req,`B.cc_req,`B.cd_addr,`B.dbusy,`B.cd_ok,dbg_retire,dbg_pc);
end
always @(posedge clk)if(!rst)begin
 longint nowtick,lat;nowtick=$rtoi($realtime/5.0);
 for(integer c=0;c<2;c++)begin
  if(`B.ibusy[c]&&dut.ni_ok[c])begin iack[c]++;lat=nowtick-iborn[c];ila[c]+=lat;if(iack[c]==1||lat<imin[c])imin[c]=lat;if(lat>imax[c])imax[c]=lat;ianswered[c]=nowtick;end
  if(`B.dbusy[c]&&dut.nd_ok[c])begin dack[c]++;lat=nowtick-dborn[c];dla[c]+=lat;if(dack[c]==1||lat<dmin[c])dmin[c]=lat;if(lat>dmax[c])dmax[c]=lat;danswered[c]=nowtick;end
 end
end
final for(integer c=0;c<2;c++)begin
 $display("DIAG c=%0d slots=%0d retired=%0d rew=%0d replay=%0d redirect=%0d busyI=%0d busyD=%0d nativeDwait=%0d memissue=%0d",c,slots[c],ret[c],rew[c],replay[c],redirect[c],busy_i[c],busy_d[c],wait_d[c],memissue[c]);
 $display("FCAT c=%0d issued=%0d busy=%0d rewind=%0d halted=%0d buffer_or_other=%0d",c,fcat[c][0],fcat[c][1],fcat[c][2],fcat[c][3],fcat[c][4]);
 $display("DCAT c=%0d issue=%0d wbkill=%0d hazard=%0d solo=%0d nativewait=%0d empty=%0d other=%0d",c,dcat[c][0],dcat[c][1],dcat[c][2],dcat[c][3],dcat[c][4],dcat[c][5],dcat[c][6]);
 $display("ILAT c=%0d enq=%0d ack=%0d consume=%0d sum_halfSYS=%0d min_halfSYS=%0d max_halfSYS=%0d afterACK_halfSYS=%0d",c,ienq[c],iack[c],icons[c],ila[c],imin[c],imax[c],icl[c]);
 $display("DLAT c=%0d enq=%0d ack=%0d consume=%0d sum_halfSYS=%0d min_halfSYS=%0d max_halfSYS=%0d afterACK_halfSYS=%0d",c,denq[c],dack[c],dcons[c],dla[c],dmin[c],dmax[c],dcl[c]);
end
`undef B
`undef E
