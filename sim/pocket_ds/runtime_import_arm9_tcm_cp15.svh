// Simulation-only available-state import. Define RUNTIME_MEM9, include the
// local memory readiness helper first. No cache data/tags/dirty/replacement
// state is changed: the reference export does not contain that state.
// cp words: c1,c2D,c2I,c3,c5D,c5I,c6[0..7],c9D,c9I.
task automatic import_arm9_tcm_cp15(input logic[31:0]itcm[0:8191],input logic[31:0]dtcm[0:4095],input logic[31:0]cp[0:15],input bit held);
 assert_arm9_mem_publication_ready(held);
 assert(cp[0]==((cp[0]&32'h000ff085)|32'h78) && cp[1][31:8]==0 && cp[2][31:8]==0 && cp[3][31:8]==0)
  else $fatal(1,"unsupported captured CP15 control/cache settings");
 assert(cp[14]==(cp[14]&32'hfffff03e) && cp[15]==(cp[15]&32'h3e))else $fatal(1,"unsupported captured TCM readback");
 for(int a=0;a<8192;a++)begin
  `RUNTIME_MEM9.u_itcm.lane[0].mem[a]=itcm[a][7:0];`RUNTIME_MEM9.u_itcm.lane[1].mem[a]=itcm[a][15:8];
  `RUNTIME_MEM9.u_itcm.lane[2].mem[a]=itcm[a][23:16];`RUNTIME_MEM9.u_itcm.lane[3].mem[a]=itcm[a][31:24];
 end
 for(int a=0;a<4096;a++)begin
  `RUNTIME_MEM9.u_dtcm.lane[0].mem[a]=dtcm[a][7:0];`RUNTIME_MEM9.u_dtcm.lane[1].mem[a]=dtcm[a][15:8];
  `RUNTIME_MEM9.u_dtcm.lane[2].mem[a]=dtcm[a][23:16];`RUNTIME_MEM9.u_dtcm.lane[3].mem[a]=dtcm[a][31:24];
 end
 `RUNTIME_MEM9.ctrl=cp[0];`RUNTIME_MEM9.dcb=cp[1][7:0];`RUNTIME_MEM9.icb=cp[2][7:0];`RUNTIME_MEM9.wbb=cp[3][7:0];
 `RUNTIME_MEM9.dap=cp[4];`RUNTIME_MEM9.iap=cp[5];
 for(int n=0;n<8;n++)begin
  `RUNTIME_MEM9.rbase[n]=cp[6+n][31:12];`RUNTIME_MEM9.rmask[n]=`RUNTIME_MEM9.rmask_of(cp[6+n][5:1]);
  `RUNTIME_MEM9.ren[n]=cp[6+n][0];`RUNTIME_MEM9.cprb[n]=cp[6+n];`RUNTIME_MEM9.cprb_v[n]=1;
 end
 `RUNTIME_MEM9.dtcm_mask=`RUNTIME_MEM9.tmask_of(cp[14][5:1]);
 `RUNTIME_MEM9.dtcm_base=cp[14][31:12]&`RUNTIME_MEM9.tmask_of(cp[14][5:1]);
 `RUNTIME_MEM9.itcm_mask=`RUNTIME_MEM9.tmask_of(cp[15][5:1]);
 `RUNTIME_MEM9.cprb[8]=cp[14];`RUNTIME_MEM9.cprb[9]=cp[15];`RUNTIME_MEM9.cprb_v[9:8]=2'b11;
 // Keep the held, unused F2 lookup mirrors coherent with the restored map.
 // f_req is zero by the readiness gate; no request/address is fabricated.
 for(int n=0;n<8;n++)`RUNTIME_MEM9.f_rm[n]=`RUNTIME_MEM9.ren[n]&&((`RUNTIME_MEM9.f_addr[31:12]^`RUNTIME_MEM9.rbase[n])&`RUNTIME_MEM9.rmask[n])==0;
 `RUNTIME_MEM9.f_tm=(`RUNTIME_MEM9.f_addr[31:12]&`RUNTIME_MEM9.itcm_mask)==0;
endtask

task automatic verify_arm9_tcm_cp15(input logic[31:0]itcm[0:8191],input logic[31:0]dtcm[0:4095],input logic[31:0]cp[0:15]);
 for(int a=0;a<8192;a++)assert({`RUNTIME_MEM9.u_itcm.lane[3].mem[a],`RUNTIME_MEM9.u_itcm.lane[2].mem[a],`RUNTIME_MEM9.u_itcm.lane[1].mem[a],`RUNTIME_MEM9.u_itcm.lane[0].mem[a]}===itcm[a])else $fatal(1,"ITCM restore mismatch word%0d",a);
 for(int a=0;a<4096;a++)assert({`RUNTIME_MEM9.u_dtcm.lane[3].mem[a],`RUNTIME_MEM9.u_dtcm.lane[2].mem[a],`RUNTIME_MEM9.u_dtcm.lane[1].mem[a],`RUNTIME_MEM9.u_dtcm.lane[0].mem[a]}===dtcm[a])else $fatal(1,"DTCM restore mismatch word%0d",a);
 assert(`RUNTIME_MEM9.ctrl===cp[0]&&`RUNTIME_MEM9.dcb===cp[1][7:0]&&`RUNTIME_MEM9.icb===cp[2][7:0]&&`RUNTIME_MEM9.wbb===cp[3][7:0]&&`RUNTIME_MEM9.dap===cp[4]&&`RUNTIME_MEM9.iap===cp[5])else $fatal(1,"CP15 restore control/permission mismatch");
 for(int n=0;n<8;n++)assert(`RUNTIME_MEM9.rbase[n]===cp[6+n][31:12]&&`RUNTIME_MEM9.rmask[n]===`RUNTIME_MEM9.rmask_of(cp[6+n][5:1])&&`RUNTIME_MEM9.ren[n]===cp[6+n][0]&&`RUNTIME_MEM9.cprb[n]===cp[6+n]&&`RUNTIME_MEM9.cprb_v[n])else $fatal(1,"CP15 restore region mismatch%0d",n);
 assert(`RUNTIME_MEM9.dtcm_mask===`RUNTIME_MEM9.tmask_of(cp[14][5:1])&&`RUNTIME_MEM9.dtcm_base===(cp[14][31:12]&`RUNTIME_MEM9.tmask_of(cp[14][5:1]))&&`RUNTIME_MEM9.itcm_mask===`RUNTIME_MEM9.tmask_of(cp[15][5:1])&&`RUNTIME_MEM9.cprb[8]===cp[14]&&`RUNTIME_MEM9.cprb[9]===cp[15]&&`RUNTIME_MEM9.cprb_v[9:8]==2'b11)else $fatal(1,"CP15 restore TCM mirror mismatch");
endtask
