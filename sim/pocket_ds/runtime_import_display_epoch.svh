// Simulation-only paused pre-scanline epoch and affine runtime deposit.
// The unchanged bootstrap owns display configuration/palette/OAM separately.
// Does not invent a cold raster/GX state or claim pixel publication acceptance.
// Define RUNTIME_DISPLAY to actual nds_disp.
task automatic import_display_epoch(input logic[31:0] epoch[0:8],input logic[31:0] affine[0:15]);
 assert(`RUNTIME_DISPLAY.q==`RUNTIME_DISPLAY.Q_IDLE&&!`RUNTIME_DISPLAY.q_pend&&
        !`RUNTIME_DISPLAY.pw_v&&!`RUNTIME_DISPLAY.ld_v&&`RUNTIME_DISPLAY.u_refs.qv==0)
   else $fatal(1,"display epoch has pending sequencer/reference writes");
 `RUNTIME_DISPLAY.hc=epoch[0][12:0];`RUNTIME_DISPLAY.vc=epoch[1][8:0];
 `RUNTIME_DISPLAY.vc_next=epoch[2][8:0];`RUNTIME_DISPLAY.vc_ovr=epoch[3][0];
 `RUNTIME_DISPLAY.dstat[0]=epoch[4][15:0];`RUNTIME_DISPLAY.dstat[1]=epoch[5][15:0];
 `RUNTIME_DISPLAY.vmatch[0]=epoch[6][8:0];`RUNTIME_DISPLAY.vmatch[1]=epoch[7][8:0];
 `RUNTIME_DISPLAY.cap_enable=epoch[8][0];
 `RUNTIME_DISPLAY.irq_vblank=0;`RUNTIME_DISPLAY.irq_hblank=0;`RUNTIME_DISPLAY.irq_vcount=0;
 `RUNTIME_DISPLAY.dma_vblank=0;`RUNTIME_DISPLAY.dma_hblank=0;`RUNTIME_DISPLAY.dma_dstart=0;
 `RUNTIME_DISPLAY.dma_dstop=0;`RUNTIME_DISPLAY.dma_mmstop=0;`RUNTIME_DISPLAY.frame_start=0;`RUNTIME_DISPLAY.line_start=0;
 for(int a=0;a<8;a++)begin
  `RUNTIME_DISPLAY.u_refs.mem_c[a]=affine[a];`RUNTIME_DISPLAY.u_refs.mem_s[a]=affine[a];
  `RUNTIME_DISPLAY.u_pr.mem[(a/4)*16+8+a%4]=affine[a];
  `RUNTIME_DISPLAY.u_pr.mem[(a/4)*16+12+a%4]=affine[8+a];
 end
 `RUNTIME_DISPLAY.u_refs.vld=8'hff;
endtask
