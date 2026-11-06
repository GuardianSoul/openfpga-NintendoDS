// Canonical cold-unpublished prior-render input metadata, not raster pixels.
// Define RUNTIME_GX_STORE to actual full-pool BANK_META nds_g3d_store.
// Caller drains the enclosing system and keeps clocks stopped.
task automatic import_gx_prior_store(input logic[31:0]order_data[],input logic[31:0]ytab_data[],input logic[31:0]bucket_data[],input logic[31:0]link_data[],input int count,input bit write_bank,render_bank,held);
 assert(held&&`RUNTIME_GX_STORE.bst==`RUNTIME_GX_STORE.B_IDLE&&`RUNTIME_GX_STORE.lst==`RUNTIME_GX_STORE.L_IDLE&&`RUNTIME_GX_STORE.fst==`RUNTIME_GX_STORE.F_IDLE&&`RUNTIME_GX_STORE.wq_n==0&&!`RUNTIME_GX_STORE.p_busy&&!`RUNTIME_GX_STORE.l_req&&`RUNTIME_GX_STORE.u_fs.ok&&`RUNTIME_GX_STORE.u_fc.ok)else $fatal(1,"prior store metadata not a cold drained boundary");
 assert(`RUNTIME_GX_STORE.BANK_META && `RUNTIME_GX_STORE.SL==11 && `RUNTIME_GX_STORE.CL==13 &&
        `RUNTIME_GX_STORE.u_fs.n==2048 && `RUNTIME_GX_STORE.u_fc.n==8192 && write_bank!=render_bank &&
        count>=0 && count<=2048 && $size(order_data)>=count && $size(ytab_data)>=count &&
        $size(bucket_data)==256 && $size(link_data)==2048)else $fatal(1,"prior store layout/capacity/image mismatch");
 for(int i=0;i<count;i++)begin
  assert(order_data[i]<32'(count) && ytab_data[i]<131072)else $fatal(1,"prior metadata value truncation"); `RUNTIME_GX_STORE.u_ytab.mem[int'(render_bank)*2048+i]=ytab_data[i][16:0];`RUNTIME_GX_STORE.u_ord.mem[int'(render_bank)*2048+i]=order_data[i][10:0];end
 for(int i=0;i<256;i++)begin `RUNTIME_GX_STORE.u_bk.mem[i]=bucket_data[i][22:0];`RUNTIME_GX_STORE.u_bkf.mem[i]=bucket_data[i][22:0];end
 for(int i=0;i<2048;i++)`RUNTIME_GX_STORE.u_lk.mem[i]=link_data[i][10:0];
 `RUNTIME_GX_STORE.wb=write_bank;`RUNTIME_GX_STORE.rb=render_bank;`RUNTIME_GX_STORE.tag=1;`RUNTIME_GX_STORE.rcount=12'(count);`RUNTIME_GX_STORE.ready=1;`RUNTIME_GX_STORE.building=0;
endtask
