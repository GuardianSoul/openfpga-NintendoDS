// Passive observer and pre-arm stop only. No DUT state assignment or force.
module sound_fabric_setup_observer;
 integer fd=0;string path;longint unsigned cycle=0,stop_cycle=0;bit stop_pending=0;
 initial if($value$plusargs("sndfabric=%s",path))begin
  fd=$fopen(path,"r");if(fd)begin $fclose(fd);$fatal(1,"preserve fabric trace");end
  fd=$fopen(path,"w");if(!fd)$fatal(1,"open fabric trace");
  $fdisplay(fd,"cycle,st,mst,grant,last,tgt,blk,a7_req,a7_ack,a7_addr,a7_we,a9_req,a9_ack,dm_req,dm_cpu,io_req,io_cpu,io_addr,io_ack,sn_req,sn_ack,sn_addr,sn_we,sn_n4,sn_rvalid,sd_st,ra_st,sd_busy,p7_f_req,p7_f_ack,p7_f_addr,p7_f_we,cpu_d_req,cpu_d_ok,cpu_d_we,cpu_d_addr,cpu_d_data,cap0,cap1");
 end
 always @(posedge $root.tb_ds_pocket.dut.clk_sys)begin
  if(fd && $root.tb_ds_pocket.snd_v2_active)begin
   $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",cycle,$root.tb_ds_pocket.dut.ds.u_fab.st,$root.tb_ds_pocket.dut.ds.u_fab.mst,$root.tb_ds_pocket.dut.ds.u_fab.grant,$root.tb_ds_pocket.dut.ds.u_fab.last,$root.tb_ds_pocket.dut.ds.u_fab.tgt,$root.tb_ds_pocket.dut.ds.u_fab.blk,$root.tb_ds_pocket.dut.ds.u_fab.a7_req,$root.tb_ds_pocket.dut.ds.u_fab.a7_ack,$root.tb_ds_pocket.dut.ds.u_fab.a7_addr,$root.tb_ds_pocket.dut.ds.u_fab.a7_we,$root.tb_ds_pocket.dut.ds.u_fab.a9_req,$root.tb_ds_pocket.dut.ds.u_fab.a9_ack,$root.tb_ds_pocket.dut.ds.u_fab.dm_req,$root.tb_ds_pocket.dut.ds.u_fab.dm_cpu,$root.tb_ds_pocket.dut.ds.u_fab.io_req,$root.tb_ds_pocket.dut.ds.u_fab.io_cpu,$root.tb_ds_pocket.dut.ds.u_fab.io_addr,$root.tb_ds_pocket.dut.ds.u_fab.io_ack,$root.tb_ds_pocket.dut.ds.u_fab.sn_req,$root.tb_ds_pocket.dut.ds.u_fab.sn_ack,$root.tb_ds_pocket.dut.ds.u_fab.sn_addr,$root.tb_ds_pocket.dut.ds.u_fab.sn_we,$root.tb_ds_pocket.dut.ds.u_fab.sn_n4,$root.tb_ds_pocket.dut.ds.u_fab.sn_rvalid,$root.tb_ds_pocket.dut.ds.u_fab.sd_st,$root.tb_ds_pocket.dut.ds.u_fab.ra_st,$root.tb_ds_pocket.dut.ds.u_fab.sd_busy,$root.tb_ds_pocket.dut.ds.u_cpud.g_a7c.u_p7.f_req,$root.tb_ds_pocket.dut.ds.u_cpud.g_a7c.u_p7.f_ack,$root.tb_ds_pocket.dut.ds.u_cpud.g_a7c.u_p7.f_addr,$root.tb_ds_pocket.dut.ds.u_cpud.g_a7c.u_p7.f_we,$root.tb_ds_pocket.dut.ds.u_cpud.a7_d_req,$root.tb_ds_pocket.dut.ds.u_cpud.a7_d_ok,$root.tb_ds_pocket.dut.ds.u_cpud.a7_d_we,$root.tb_ds_pocket.dut.ds.u_cpud.a7_d_addr,$root.tb_ds_pocket.dut.ds.u_cpud.a7_d_wdata,$root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt0,$root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt1);
   if($root.tb_ds_pocket.dut.ds.u_cpud.a7_d_req && $root.tb_ds_pocket.dut.ds.u_cpud.a7_d_we && $root.tb_ds_pocket.dut.ds.u_cpud.a7_d_addr==32'h04000508 && $root.tb_ds_pocket.dut.ds.u_cpud.a7_d_wdata[15:0]==16'h8484)begin
    if($root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt0[7]||$root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt1[7])$fatal(1,"capture armed before stop");
    stop_pending=1;stop_cycle=cycle;
   end
  end
  cycle++;
 end
 always @(negedge $root.tb_ds_pocket.dut.clk_sys)if(stop_pending)begin
  $display("SOUND_FABRIC_PREARM_STOP cycle=%0d capture0=%0h capture1=%0h",stop_cycle,$root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt0,$root.tb_ds_pocket.dut.ds.g_snd.u_snd.capcnt1);
  $fclose(fd);fd=0;$finish;
 end
 final if(fd)$fclose(fd);
endmodule
bind tb_ds_pocket sound_fabric_setup_observer u_sound_fabric_setup_observer();
