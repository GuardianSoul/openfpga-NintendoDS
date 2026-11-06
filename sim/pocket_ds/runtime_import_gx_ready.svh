// Local composed GX boundary only. Enclosing CPU/cache/transport drain is a
// separate obligation. Define RUNTIME_GEOMETRY, RUNTIME_GX_STORE/RECORDS.
task automatic assert_gx_publication_ready(input bit held);
 assert(held && `RUNTIME_GEOMETRY.u_eng.idle && !`RUNTIME_GEOMETRY.u_eng.we_o &&
  !`RUNTIME_GEOMETRY.u_eng.we_m && !`RUNTIME_GEOMETRY.u_eng.g_fu.u_fin.busy &&
  `RUNTIME_GEOMETRY.u_eng.ssp==0 && !`RUNTIME_GEOMETRY.mrd_pend &&
  `RUNTIME_GX_STORE.wq_n==0 && !`RUNTIME_GX_STORE.p_busy &&
  !`RUNTIME_GX_STORE.l_req && !`RUNTIME_GX_STORE.building &&
  `RUNTIME_GX_RECORDS.left==0 && !`RUNTIME_GX_RECORDS.p_req)
 else $fatal(1,"composed GX publication has pending work/return or running clocks");
endtask
