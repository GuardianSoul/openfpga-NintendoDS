// Include inside the private tb_ds_pocket overlay only. No production edits.
`ifdef HG193_COMBINED_HOOK
`include "hg193_shared_model_binding.svh"
`define RUNTIME_MEM9 dut.ds.u_cpud.g_one.u_cpu.u_mem9
`include "runtime_import_arm9_mem_ready.svh"
`undef RUNTIME_MEM9
bit hg193_combined_present=0,hg193_combined_held=0;
string hg193_combined_directory;
string hg193_combined_kind;
logic[9:0]hg193_clock_levels;
logic[10:0]hg193_saved_rom_addr;
logic[9:0]hg193_saved_rom_index;
logic[69:0]hg193_saved_rom_word;
logic[3:0]hg193_saved_rom_phase;
`include "hg193_combined_drain.svh"
initial begin
 hg193_combined_present=$value$plusargs("g3d_seed=%s",hg193_combined_directory);
 if(hg193_combined_present)begin
  assert_hg193_shared_model_binding();
`ifdef COMBINED_STATE_IMPORT
  assert($test$plusargs("combined_wram_restore") && $test$plusargs("imp_main="))
   else $fatal(1,"HG193 requires selected combined state importer and WRAM contract");
`else
  $fatal(1,"HG193 requires COMBINED_STATE_IMPORT");
`endif
  assert($value$plusargs("g3d_seed_kind=%s",hg193_combined_kind) && hg193_combined_kind=="hg193")
   else $fatal(1,"HG193 combined requires hg193 kind; import arguments checked at publication");
 end
end
task automatic hg193_combined_hold_clocks;
 // Capture and force each clock at its CURRENT level: no synthetic edge.
 // No delay, event control or clock advancement occurs in this task chain.
 hg193_clock_levels={clk_74a,clk_74b,dut.clk_sys,dut.clk_2x,dut.clk_cpu,
                     dut.clk_mem,dut.clk_bus,dut.clk_cram,dut.clk_vid,dut.clk_vid90};
 force clk_74a=hg193_clock_levels[9];force clk_74b=hg193_clock_levels[8];
 force dut.clk_sys=hg193_clock_levels[7];force dut.clk_2x=hg193_clock_levels[6];
 force dut.clk_cpu=hg193_clock_levels[5];force dut.clk_mem=hg193_clock_levels[4];
 force dut.clk_bus=hg193_clock_levels[3];force dut.clk_cram=hg193_clock_levels[2];
 force dut.clk_vid=hg193_clock_levels[1];force dut.clk_vid90=hg193_clock_levels[0];
 hg193_combined_held=1;
endtask
task automatic hg193_combined_release_clocks;
 release clk_74a;release clk_74b;release dut.clk_sys;release dut.clk_2x;
 release dut.clk_cpu;release dut.clk_mem;release dut.clk_bus;release dut.clk_cram;
 release dut.clk_vid;release dut.clk_vid90;
 hg193_combined_held=0;
endtask
task automatic hg193_combined_publish;
 realtime before_time;
 int before_frames;
 assert_hg193_shared_model_binding();
`ifdef COMBINED_STATE_IMPORT
 assert(combined_wram_present && combined_wram_applied)
  else $fatal(1,"HG193 requires verified combined WRAM restore before stateload release");
`else
 $fatal(1,"HG193 requires COMBINED_STATE_IMPORT WRAM contract");
`endif
 assert(hg193_combined_present && imp_vc==193 && imp_ready9==6 && imp_ready7==7 &&
        imp_ov=='hc2400 && imp_ovn=='h4b60 && imp_blk==0 && imp_blkn==8 && imp_stubn=='h89 &&
        !imp_stub_pend && dut.line_start && dut.vcount==193 && !dut.clk_sys)
 else $fatal(1,"HG193 import ordering/descriptor is not accepted638 pre-release");
 // Real PLL has FAST rising at SYS falling; use its next falling edge
 // inside the SAME SYS half-cycle, before the unchanged release E edge.
 // This is phase alignment only, never a readiness wait or an extra line.
 if(dut.clk_2x)@(negedge dut.clk_2x);
 assert(!dut.clk_sys && !dut.clk_2x && dut.line_start && dut.vcount==193)
 else $fatal(1,"HG193 FAST alignment crossed the original release edge");
 before_time=$realtime;before_frames=v_frames;
 hg193_combined_hold_clocks();
 assert_hg193_combined_drained();
 hg193_saved_rom_addr=dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.addr;
 hg193_saved_rom_index=dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.index_q;
 hg193_saved_rom_word=dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.word_q;
 hg193_saved_rom_phase={dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.tg,
  dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.tq,
  dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.ph,
  dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.reset_q};
 hg193_publish(hg193_combined_directory,hg193_combined_held,hg193_combined_transport_drained());
 assert_hg193_combined_drained();
 assert(dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.addr===hg193_saved_rom_addr &&
        dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.index_q===hg193_saved_rom_index &&
        dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.word_q===hg193_saved_rom_word &&
        {dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.tg,
         dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.tq,
         dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.ph,
         dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_romx.u_rom.g_a_dict.u_a.reset_q}===hg193_saved_rom_phase)
 else $fatal(1,"HG193 ROM65 caller/address/phase changed across publication");
 assert($realtime==before_time && v_frames==before_frames && dut.vcount==193 &&
        {clk_74a,clk_74b,dut.clk_sys,dut.clk_2x,dut.clk_cpu,dut.clk_mem,
         dut.clk_bus,dut.clk_cram,dut.clk_vid,dut.clk_vid90}===hg193_clock_levels)
 else $fatal(1,"HG193 publication advanced clocks/frame/time");
 hg193_combined_release_clocks();
endtask
`define HG193_SD_PAIR_OPT_IN
`include "hg193_sd_pair.svh"
`undef HG193_SD_PAIR_OPT_IN
`endif
