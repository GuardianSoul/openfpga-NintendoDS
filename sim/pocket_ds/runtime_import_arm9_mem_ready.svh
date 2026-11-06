// Simulation-only local ARM9 memory publication gate. Define RUNTIME_MEM9.
// Caller stops issue, lets already-owned traffic complete, then holds clocks.
// This does not drain anything or prove CPU/ARM7/fabric/PSRAM quiescence.
function automatic bit arm9_mem_publication_ready();
 return !`RUNTIME_MEM9.i_req && !`RUNTIME_MEM9.d_req && !`RUNTIME_MEM9.cp_req &&
  !`RUNTIME_MEM9.f_req && !`RUNTIME_MEM9.w_req && !`RUNTIME_MEM9.w_cp &&
  `RUNTIME_MEM9.st==`RUNTIME_MEM9.S_IDLE && !`RUNTIME_MEM9.b_req &&
  !`RUNTIME_MEM9.dp_v && !`RUNTIME_MEM9.ip_v && !`RUNTIME_MEM9.pf_run &&
  !`RUNTIME_MEM9.wbuf_v && !`RUNTIME_MEM9.nb_owned && !`RUNTIME_MEM9.ev_v &&
  !`RUNTIME_MEM9.qw_v && !`RUNTIME_MEM9.pw_v &&
  !`RUNTIME_MEM9.rbuf_v && !`RUNTIME_MEM9.ibuf_v && !`RUNTIME_MEM9.cmo_done &&
  !`RUNTIME_MEM9.busy_d && !`RUNTIME_MEM9.busy_i &&
  !`RUNTIME_MEM9.col_d && !`RUNTIME_MEM9.col_i;
endfunction
 task automatic assert_arm9_mem_publication_ready(input bit held);
 assert(held && arm9_mem_publication_ready())
  else $fatal(1,"ARM9 memory publication has pending request/write/return or running clocks");
 endtask
