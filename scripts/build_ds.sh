#!/usr/bin/env bash
# Full-chip Pocket build of the DS core, NDS (docs/phase2-integration.md):
#   scripts/build_ds.sh OUTDIR SEED
# Generates a Quartus project from
# rtl/ds, rtl/arm, rtl/sys, rtl/gpu2d, rtl/pocket, rtl/mem and the APF shell
# in rtl/apf, runs map/fit/asm/sta, requires non-negative slack for every
# analysis and corner, and packages OUTDIR/package/NDS.zip. Writes
# OUTDIR/result.txt.
# Run it only through the Jenkins nds-fit job (TARGET=ds, docs/fitting.md):
# never start Quartus by hand on a fit node.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$1 seed=$2
# Check the complete source before paying for synthesis; Verilator alone
# accepts module-scope/generate constructs rejected by Quartus Standard.
python3 "$root/tools/ds/qlint.py"
# Quartus-settings experiments ride on the seed (the Jenkins job passes only
# TARGET and SEED): a trailing "a" = OPTIMIZATION_MODE "AGGRESSIVE AREA",
# "p" = HIGH PERFORMANCE EFFORT plus ALM_REGISTER_PACKING_EFFORT HIGH,
# "r" (with either) = ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION ON,
# "k" = ALM_REGISTER_PACKING_EFFORT HIGH in any mode,
# "R" / "P" / "N" = aggressive routability / placement effort x4 / no duplication,
# "s" = AUTO_RESOURCE_SHARING ON plus MUX_RESTRUCTURE ON,
# "h" = AUTO_SHIFT_REGISTER_RECOGNITION ALWAYS,
# "m" = STATE_MACHINE_PROCESSING "MINIMAL BITS" (binary FSM encoding, not one-hot),
# "i" = OPTIMIZATION_TECHNIQUE AREA on the blocks with timing slack only
#       (raster, 2D, sound, system; not geometry, whose timing is tight; #201: raster -240 ALMs, slack kept)
# "I" = as "i", also on the display controller, geometry, the CPUs and nds_disp's
#       own logic (nds_disp, gpu3d_geom, arm_cpu)
#       (i and I only matter without "a": AGGRESSIVE AREA already makes the
#       global Optimization Technique Area, so #507 = 1asI came out identical
#       to #502 = 1as; #201's -240 ALMs was against the Balanced default)
# "w" = ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON (resynthesise WYSIWYG primitives)
# "c" = PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON
# "t" = SYNTH_TIMING_DRIVEN_SYNTHESIS OFF, "d" = DSP_BLOCK_BALANCING "DSP BLOCKS",
# "e" = REMOVE_REDUNDANT_LOGIC_CELLS ON, "u" = AUTO_RAM_TO_LCELL_CONVERSION OFF
# "q" = physical synthesis for timing (combo, retiming, duplication) + router timing MAXIMUM
# (openfpga-PlayStation's --pack-high), e.g. SEED=3a
qmode=${seed//[0-9]/}
seed=${seed%%[!0-9]*}
top=apf_top
apf=$root/rtl/apf
mkdir -p "$out/apf"
# the boot ROM (sw/boot/bootrom.bin, checked in: the fit nodes have no ARM
# toolchain; `make bootrom-check` keeps it equal to the sources), as a MIF
python3 - "$root/sw/boot/bootrom.bin" "$out/bootrom.mif" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
d += b'\0' * (8192 - len(d))
w = struct.unpack('<2048I', d)
with open(sys.argv[2], 'w') as f:
    f.write('DEPTH = 2048;\nWIDTH = 32;\nADDRESS_RADIX = HEX;\nDATA_RADIX = HEX;\nCONTENT\nBEGIN\n')
    for i, v in enumerate(w):
        f.write('%03X : %08X;\n' % (i, v))
    f.write('END;\n')
PY
cd "$out"

now=$(date -u +%Y%m%d%H%M%S)
cat > apf/build_id.mif <<MIF
DEPTH = 256;
WIDTH = 32;
ADDRESS_RADIX = HEX;
DATA_RADIX = HEX;
CONTENT
BEGIN
   0E0 : ${now:0:8};
   0E1 : 00${now:8:6};
   0E2 : $(printf '%08x' $((RANDOM << 16 | RANDOM)));
END;
MIF

echo "PROJECT_REVISION = \"$top\"" > $top.qpf
{
  grep '^set_' "$apf/pocket.tcl" | grep -v -e SCRIPT_FILE -e QIP_FILE -e ENABLE_SIGNALTAP
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
  echo "set_global_assignment -name SEED $seed"
  # registers power up as declared: with "don't care" Quartus ignored initial
  # values and made set-only flags constants (#55)
  echo 'set_global_assignment -name ALLOW_POWER_UP_DONT_CARE OFF'
  echo 'set_global_assignment -name SDC_FILE ds.sdc'
  echo 'set_global_assignment -name MIF_FILE apf/build_id.mif'
  echo 'set_global_assignment -name MIF_FILE bootrom.mif'
  # the two high fan-out resets on global lines (#817: on local routing they
  # took a LAB input in every LAB they reach; LAB input limits cost 400 ALMs)
  echo 'set_instance_assignment -name GLOBAL_SIGNAL "GLOBAL CLOCK" -to "core_top:ic|rst_sys_s[2]"'
  echo 'set_instance_assignment -name GLOBAL_SIGNAL "GLOBAL CLOCK" -to "core_top:ic|nds_top:ds|cpu_rst_q"'
  case "$qmode" in
    *a*) echo 'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"' ;;
    *p*) echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"'
         echo 'set_global_assignment -name ALM_REGISTER_PACKING_EFFORT HIGH' ;;
    *)   echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"' ;;
  esac
  # "r": small register arrays may become RAM (MLAB) too
  case "$qmode" in *r*) echo 'set_global_assignment -name ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION ON' ;; esac
  # area experiments for the full core (#182: register-only ALMs are the excess)
  case "$qmode" in *k*) echo 'set_global_assignment -name ALM_REGISTER_PACKING_EFFORT HIGH' ;; esac
  # LAB-input fan-in experiments (#822: 360 ALMs lost to LAB input limits):
  # "R" = aggressive routability, "P" = placement effort x4, "N" = no fitter
  # logic or register duplication
  case "$qmode" in *R*) echo 'set_global_assignment -name FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS' ;; esac
  case "$qmode" in *P*) echo 'set_global_assignment -name PLACEMENT_EFFORT_MULTIPLIER 4.0' ;; esac
  case "$qmode" in *N*) echo 'set_global_assignment -name LOGIC_CELL_INSERTION_LOGIC_DUPLICATION OFF'
                        echo 'set_global_assignment -name AUTO_REGISTER_DUPLICATION OFF' ;; esac
  case "$qmode" in *s*) echo 'set_global_assignment -name AUTO_RESOURCE_SHARING ON'
                        echo 'set_global_assignment -name MUX_RESTRUCTURE ON' ;; esac
  case "$qmode" in *h*) echo 'set_global_assignment -name AUTO_SHIFT_REGISTER_RECOGNITION ALWAYS' ;; esac
  case "$qmode" in *m*) echo 'set_global_assignment -name STATE_MACHINE_PROCESSING "MINIMAL BITS"' ;; esac
  case "$qmode" in *i*)
    for e in gpu3d_raster:u_raster gpu2d:u_gpu2d sound:g_snd.u_snd nds_sys:u_sys; do
      echo "set_instance_assignment -name OPTIMIZATION_TECHNIQUE AREA -to \"*|$e\""
    done ;;
  esac
  case "$qmode" in *I*)
    for e in gpu3d_raster:u_raster nds_disp:u_disp sound:g_snd.u_snd nds_sys:u_sys gpu3d_geom:u_geom arm_cpu:u_cpu; do
      echo "set_instance_assignment -name OPTIMIZATION_TECHNIQUE AREA -to \"*|$e\""
    done ;;
  esac
  case "$qmode" in *w*) echo 'set_global_assignment -name ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON' ;; esac
  case "$qmode" in *c*) echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON' ;; esac
  # "t": synthesis not timing-driven (no logic duplicated for speed); "d": let
  # Quartus balance arithmetic into the free DSP blocks; "e": remove redundant
  # logic cells; "u": no automatic RAM-to-logic conversion of small RAMs
  case "$qmode" in *t*) echo 'set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF' ;; esac
  case "$qmode" in *d*) echo 'set_global_assignment -name DSP_BLOCK_BALANCING "DSP BLOCKS"' ;; esac
  case "$qmode" in *e*) echo 'set_global_assignment -name REMOVE_REDUNDANT_LOGIC_CELLS ON' ;; esac
  case "$qmode" in *u*) echo 'set_global_assignment -name AUTO_RAM_TO_LCELL_CONVERSION OFF' ;; esac
  # "q": timing closure when the chip is nearly full: physical synthesis
  # (combinational resynthesis, register retiming and duplication) and the
  # router's maximum timing effort; costs a little area
  case "$qmode" in *q*) echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON'
                        echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON'
                        echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON'
                        echo 'set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM' ;; esac
  for f in apf_top.v common.v io_bridge_peripheral.v io_pad_controller.v mf_ddio_bidir_12.v mf_datatable.v \
           core_bridge_cmd_lean.v mf_audio_pll.v mf_audio_pll_0002.v; do
    echo "set_global_assignment -name VERILOG_FILE \"$apf/$f\""
  done
  echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$apf/sound_i2s.sv\""
  for f in psx_sdram_ctrl.sv psx_pq_psram.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/mem/$f\""
  done
  for f in arm/arm_pkg.sv arm/arm_regfile.sv arm/arm_mul.sv arm/arm_thumb.sv arm/arm_core.sv arm/arm7_ds.sv arm/arm9_ram.sv \
           arm/arm9_mem.sv arm/arm_cpu.sv arm/cdc_req.sv arm/cdc_fifo.sv arm/cdc_a7.sv arm/cpu_domain.sv \
           ds/nds_dsp_add.sv sys/sys_ram.sv sys/sys_irq.sv sys/sys_timers.sv sys/sys_ipc.sv sys/sys_math.sv sys/sys_dma.sv sys/nds_sys.sv \
           gpu2d/gpu2d_pkg.sv gpu2d/gpu2d_ram.sv gpu2d/gpu2d_cache.sv gpu2d/gpu2d_bg.sv gpu2d/gpu2d_obj.sv gpu2d/gpu2d.sv \
           ds/nds_ram.sv ds/nds_lcache.sv ds/nds_arm7_port.sv ds/nds_arm7_port_min.sv ds/nds_fabric.sv ds/nds_vram.sv ds/nds_io.sv ds/nds_disp_refs.sv ds/nds_disp.sv \
           sound/sound_ram.sv sound/sound.sv \
           gpu3d/gpu3d_pkg.sv gpu3d/gpu3d_div4.sv gpu3d/gpu3d_ram.sv gpu3d/gpu3d_edge.sv gpu3d/gpu3d_front.sv gpu3d/gpu3d_fpass.sv gpu3d/gpu3d_raster.sv \
           gpu3d/gpu3d_gxu_pkg.sv gpu3d/gpu3d_gxrom.sv gpu3d/gpu3d_gxrom_us.sv gpu3d/gpu3d_gxrom_ul.sv gpu3d/gpu3d_gxrom_uv.sv gpu3d/gpu3d_gxrom_uw.sv gpu3d/gpu3d_gxrom_uf.sv gpu3d/gpu3d_gxlight.sv gpu3d/gpu3d_gxvfin.sv gpu3d/gpu3d_gxdiv.sv gpu3d/gpu3d_gxfront.sv gpu3d/gpu3d_gxeng.sv gpu3d/gpu3d_gxsort.sv gpu3d/gpu3d_geom.sv ds/nds_blk_arb.sv ds/nds_g3d_plane.sv ds/nds_l3d_xscroll.sv ds/nds_fr_arb.sv ds/nds_mr_arb.sv ds/nds_g3d_store.sv ds/nds_g3d_ring.sv ds/nds_gpu3d.sv \
           ds/nds_cart.sv ds/nds_spi.sv ds/nds_rtc.sv ds/nds_wifi.sv ds/nds_wifi_mc.sv ds/nds_top.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/$f\""
  done
  # SERV (rtl/serv, ISC): nds_cart_scpu's processor (core_top_ds SHELL_CPU)
  for f in serv_aligner serv_alu serv_bufreg2 serv_bufreg serv_compdec serv_csr serv_ctrl serv_debug serv_decode serv_immdec \
           serv_mem_if serv_rf_if serv_rf_ram_if serv_rf_ram serv_rf_top serv_state serv_top; do
    echo "set_global_assignment -name VERILOG_FILE \"$root/rtl/serv/$f.v\""
  done
  echo "set_global_assignment -name SEARCH_PATH \"$root/rtl/pocket\""     # nds_settings.svh
  for f in nds_sig.sv nds_cdc.sv nds_pll_ds.sv nds_sdram_mc.sv nds_sdram_bus.sv nds_apf_host.sv nds_save_read.sv nds_cart_cache.sv nds_cart_scpu.sv nds_bport_share.sv nds_bus_tests.sv \
           nds_log.sv psx_pocket_pad_combo.sv nds_controls.sv nds_x2b.sv nds_psram.sv nds_video.sv nds_audio_interp.sv nds_sram.sv core_top_ds.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/pocket/$f\""
  done
  # PSRAM read data and WAIT in the input registers, as PocketQuake and openfpga-PlayStation's PSRAM probes
  for c in cram0 cram1; do
    for i in $(seq 0 15); do echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to ${c}_dq[$i]"; done
    echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to ${c}_wait"
    # outputs from IOE registers too: with the chip nearly full, the routes from
    # core registers to these pins missed the PSRAM output setup (nds-fit #62)
    for p in "a[*]" "dq[*]" adv_n cre ce0_n ce1_n oe_n we_n ub_n lb_n; do
      echo "set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to ${c}_$p"
      echo "set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to ${c}_$p"
    done
  done
  # async SRAM (rtl/pocket/nds_sram.sv): every pin in its I/O cell register
  for p in "a[*]" "dq[*]" oe_n we_n ub_n lb_n; do
    echo "set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to sram_$p"
  done
  echo "set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to sram_dq[*]"
  for i in $(seq 0 15); do echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to sram_dq[$i]"; done
  # SDRAM (rtl/pocket/nds_sdram_mc.sv, timed by rtl/pocket/nds_sdram_io.sdc; docs/sdram-io.md): Pocket board
  # timing, not DS behaviour. Command pins from I/O cell registers (#1643: decoded in the core, -2.97 ns setup),
  # the DQ output enable from its I/O cell register (#1643: dq[10] -0.11 ns), and D1=24 on the DQ inputs (the
  # input buffer -> capture register delay; #1643: next-beat hold -0.205 ns; openfpga-PlayStation's released setting)
  for p in ras_n cas_n we_n "a[*]" "ba[*]" "dqm[*]" "dq[*]"; do
    echo "set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to dram_$p"
  done
  echo "set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to dram_dq[*]"
  for i in $(seq 0 15); do
    echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to dram_dq[$i]"
    echo "set_instance_assignment -name D1_DELAY 24 -to dram_dq[$i]"
  done
} > $top.qsf

cat > ds.sdc <<'SDC'
source "APF_DIR/apf_constraints.sdc"
# Core PLL (rtl/pocket/nds_pll_ds.sv): 0 bus, 1 mem, 2 PSRAM chip clock, 3 video, 4 video 90 degrees, 5 sys, 6 cpu (CPU_FAST), 7 2 x sys
set pll {ic|core_pll|pll|general}
set clk_bus  "${pll}\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_mem  "${pll}\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_cram "${pll}\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_vid  "${pll}\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_vid90 "${pll}\[4\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_sys  "${pll}\[5\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_cpu  "${pll}\[6\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_2x   "${pll}\[7\].gpll~PLL_OUTPUT_COUNTER|divclk"
# PSRAM pins: PocketQuake's constraints (core_constraints.sdc) on the gated
# chip clock, as openfpga-PlayStation's hardware-run PSRAM stress probes used them.
foreach c {cram0 cram1} n {chip0 chip1} {
  create_generated_clock -name ${c}_clk_out -source [get_pins $clk_cram] [get_ports ${c}_clk]
  set outs [get_ports "${c}_a\[*\] ${c}_dq\[*\] ${c}_adv_n ${c}_cre ${c}_ce0_n ${c}_ce1_n ${c}_oe_n ${c}_we_n ${c}_ub_n ${c}_lb_n"]
  set_output_delay -clock ${c}_clk_out -max 3.0 -add_delay $outs
  set_output_delay -clock ${c}_clk_out -min -0.5 -add_delay $outs
  set_input_delay -clock ${c}_clk_out -max 6.5 -add_delay [get_ports "${c}_dq\[*\] ${c}_wait"]
  set_input_delay -clock ${c}_clk_out -min 1.0 -add_delay [get_ports "${c}_dq\[*\] ${c}_wait"]
  set caps [get_registers "*|psram|${n}|cram_dq_r\[*\] *|psram|${n}|cram_wait_r"]
  set_multicycle_path -setup 3 -from [get_clocks ${c}_clk_out] -to $caps
  set_multicycle_path -hold 2 -from [get_clocks ${c}_clk_out] -to $caps
}
# sound (rtl/sound): the engine runs on every clk_sys cycle (ce = 1 since
# 2026-10-28), so its paths keep one cycle; the two-cycle multicycle that
# ce = tick allowed (#483) is gone. Its RAMs' clock arrives later than the
# flops' (#644: -0.004 ns hold, w7[15] -> sound_run_ram datain); the plain hold
# check covers that (#1365: +0.01 ns; the 0.1 ns margin once asked for here
# reported -0.09 ns on the full chip).
# async SRAM: nds_sram holds every address two clk_sys cycles (29.8 ns) and
# drives and samples the pins from I/O cell registers, so the pin paths are
# fixed by the protocol, not by placement
set_false_path -to [get_ports "sram_a\[*\] sram_dq\[*\] sram_oe_n sram_we_n sram_ub_n sram_lb_n"]
set_false_path -from [get_ports "sram_dq\[*\]"]
# nds_psram (rtl/pocket/nds_psram.sv): main RAM's held request fields
# (b_word/b_wdata/b_be, clk_sys) are read on clk_mem only in the sequencer's
# WR/RD state, after the IDLE edge that sees req_valid, raised on the first
# clk_mem edge after the request toggle that changed them: three clk_mem
# edges (two kept, as for nds_psram_port before). Its read
# data (got0/got1, clk_mem, final before the done toggle; read
# through rsp_raw, held until the next read, which cannot start before the
# hand-out ends) is read on clk_sys from the edge after the one that sees
# the toggle: two clk_sys edges.
# Hold: no destination takes these values before that second edge (the
# sequencer only in WR/RD, s_rdata only while out_n counts), so a new
# value arriving at the coincident edge (#360/#361: -0.004/-0.014 ns hold
# there) changes nothing: -hold 2 checks hold against the edge before it.
set pp {*|nds_psram:psram}
set preq [get_registers "$pp|b_word\[*\] $pp|b_wdata\[*\] $pp|b_be\[*\]"]
set_multicycle_path -setup 2 -from $preq -to [get_clocks $clk_mem]
set_multicycle_path -hold 2 -from $preq -to [get_clocks $clk_mem]
# (B8: the read data is the g_raw8 MLABs, written on clk_mem and read
# without a clock by clk_sys at out_k: the same two edges)
set prd [get_keepers "$pp|got0\[*\]\[*\] $pp|got1\[*\]\[*\] $pp|*g_raw8*"]
set_multicycle_path -setup 2 -from $prd -to [get_registers "$pp|s_rdata\[*\]"]
set_multicycle_path -hold 2 -from $prd -to [get_registers "$pp|s_rdata\[*\]"]
# The SDRAM ports (rtl/pocket/nds_sdram_bus.sv: nds_sdram_xport, clk_sys;
# nds_sdram_bport, clk_bus): the arbiter reads a port's held request (b_*)
# only after granting it, on the third clk_mem edge after the req_t flip
# that changed it at the earliest (m_valid, the grant, nds_sdram_mc's take),
# and b_* hold until the take has come back. Setup on the second edge, hold
# against the edge before the first (nothing takes them earlier). If req_s
# sees the flip on the clk_mem edge it coincides with (a hold race there),
# the take moves to the second edge after the flip: still the setup edge.
set sp [get_registers "*|nds_sdram_xport:*|b_*"]
set_multicycle_path -setup 2 -from $sp -to [get_clocks $clk_mem]
set_multicycle_path -hold 2 -from $sp -to [get_clocks $clk_mem]
# nds_sdram_bport has no copy: its clients hold c_* from the request until
# c_ready (after the take), so the same two-edge rule goes from the clients'
# own request registers: the bridge FIFO's head (bp_bridge), and the cart cache and
# save read (its address is {sel2_b ? base 2 : base} + wp, its valid busy)
# behind nds_bport_share (bp_cache), with the share's owner select
# (#795: -0.389 ns on the drain's and cache's m_wdata -> q_wdata, single-cycle)
set bpc [get_registers "*|nds_dcfifo:wfifo|rdata\[*\] *|nds_cart_cache:cache|m_* *|nds_save_read:save_read|wp* *|nds_save_read:save_read|sel2_b *|nds_save_read:save_read|busy *|nds_bport_share:x_share|*"]
set_multicycle_path -setup 2 -from $bpc -to [get_clocks $clk_mem]
set_multicycle_path -hold 2 -from $bpc -to [get_clocks $clk_mem]
# The card ROM's read words (nds_cart_cache r_data, clk_bus) reach nds_cart
# (clk_sys: dout and its word buffer q) through nds_x2b x_cart, which passes
# them on only with take (nds_bus_phase): in the clk_sys cycle that starts
# at a clk_bus edge, so they are taken at the clk_sys edge between clk_bus
# edges. The clk_sys edge coincident with r_data's launch never loads it
# (tb_ds_pocket.sv counts a word there as an error), so the hold check
# moves to the edge before it (#519: -0.091 ns hold there). Setup stays one
# cycle, and take's own path (bt -> bs) is not relaxed.
set crd [get_registers "*|nds_cart_cache:cache|r_data\[*\] *|nds_sdram_bport:bp_cache|r_data\[*\]"]
set_multicycle_path -hold 1 -from $crd -to [get_clocks $clk_sys]
# gpu3d_raster's P12 operand copies of the span descriptor (p12_ma = ad,
# p12_mc = abase << 17: the multiply-add lanes). sd_cur changes only when the
# walker loads a span, which waits until P0-P13 hold no pixel of the last one,
# and the new span's first pixel reaches P11 eleven or more advances later. So
# nothing P12 takes from sd_cur within two cycles of a change is used (a
# simulation check in gpu3d_raster asserts it: two unchanged cycles before
# any used capture). Setup on the second edge; hold against the edge before
# the launch, as for nds_psram_port: a capture at the edge sd_cur changes is
# never used either, P0-P13 being empty then (#480: -0.076 ns setup; #491/
# #492: -0.050 ns hold with -hold 1, the skew above the copy's delay).
set r3d {*|gpu3d_raster:u_raster}
# (the M10K word g_dram.u_dram holds abase/aqs: it changes the clock after
# sd_cur does, the same rule)
# (#819: "$r3d|g_dram.u_dram|*" matched nothing, the entity prefix missing:
# q[115] -> p12_mc[2][20] -0.070 ns single-cycle)
set sdc3 [get_registers "$r3d|sd_cur.* $r3d|gpu3d_dword:g_dram.u_dram|*"]
set p12c [get_registers "$r3d|p12_ma\[*\] $r3d|p12_mc\[*\]"]
set_multicycle_path -setup 2 -from $sdc3 -to $p12c
set_multicycle_path -hold 2 -from $sdc3 -to $p12c
# sd_cur takes sd_nx only when the walker loads a span (nx_full set), and
# sd_nx is written only while nx_full is clear (gpu3d_front: fe_wr needs
# !nx_full): at an edge where sd_cur captures, sd_nx does not change, so the
# new sd_nx of a write edge never meets a capture and the hold check has
# nothing to protect. Setup stays single-cycle (#519 -0.05 ns, #551 -0.027 ns
# hold at the fast corner, the copy's delay under the skew).
set_false_path -hold -from [get_registers "$r3d|sd_nx.*"] -to $sdc3
# p12_ma/p12_mc load straight from sd_nx at a span load (raster C15, 2026-10-29), the same edge as sd_cur: no hold to protect
set_false_path -hold -from [get_registers "$r3d|sd_nx.*"] -to $p12c
# nds_video's outputs (rgb/de/hs/vs, clk_sys) to core_top_ds's o_* (clk_vid
# = clk_sys / 4, same PLL): nds_video changes them only on the clk_sys edge
# two clocks after a clk_vid edge (vid_t; tb_ds_pocket fails a run whose
# outputs change less than two clk_sys clocks before a clk_vid edge), so o_*
# take each value two clk_sys periods after it is launched, and the next
# change comes two periods after that capture. Setup: two clk_sys periods;
# hold: against the clk_vid edge one clk_sys period before the launch (the
# real margin is two). #578: -0.573 ns hold on rgb[4] -> o_rgb[4] at the
# coincident edge, which the free-running phase before this allowed.
set vout [get_registers "*|nds_video:video|rgb\[*\] *|nds_video:video|de *|nds_video:video|hs *|nds_video:video|vs"]
set vin [get_registers "*|o_rgb\[*\] *|o_de *|o_hs *|o_vs"]
set_max_delay -from $vout -to $vin 29.8
set_min_delay -from $vout -to $vin -14.9
# clk_cpu (CPU_FAST: the CPUs, rtl/arm/cpu_domain.sv) comes from the same PLL,
# so Quartus relates it to clk_sys. Every crossing goes through cpu_domain's
# cdc_req (held payloads, sampled at least two receiver clocks after a
# synchronised toggle), cdc_fifo (Gray pointers) or two-flop synchronisers,
# none of which relies on the edge relationship. Each direction is bounded by
# 11 ns, under one source period (clk_cpu 11.19 ns, clk_sys 14.92 ns: the Gray
# pointers' skew bound), and hold is not required (-5 ns). Not a clock group:
# set_clock_groups would override these bounds.
# (Only with CPU_FAST: otherwise nothing uses the counter and the clock is absent.)
if {[get_collection_size [get_clocks -nowarn $clk_cpu]] > 0} {
  set_max_delay -from [get_clocks $clk_sys] -to [get_clocks $clk_cpu] 11.0
  set_max_delay -from [get_clocks $clk_cpu] -to [get_clocks $clk_sys] 11.0
  set_min_delay -from [get_clocks $clk_sys] -to [get_clocks $clk_cpu] -5.0
  set_min_delay -from [get_clocks $clk_cpu] -to [get_clocks $clk_sys] -5.0
}
# clk_2x = 2 x clk_sys, phase 0 (the double-pumped RAMs, docs/phase2-integration.md "Double-pumped RAMs";
# nds_lcache PUMP): what clk_sys logic launches for a pumped block is taken at the coincident clk_2x edge
# a whole clk_sys cycle later (port B's write registers, enabled only there, and the check's read
# address); the block's results go back through a clk_2x register (clk_2x -> clk_sys, half a cycle,
# timed as is). The one path that is really half a cycle, the clk_sys toggle into the phase register
# (tg -> ph), is one LUT, so the relaxed check keeps it well inside it (as arm_regfile PUMP, #788).
set_multicycle_path -setup -end 2 -from [get_clocks $clk_sys] -to [get_clocks $clk_2x]
set_multicycle_path -hold -end 1 -from [get_clocks $clk_sys] -to [get_clocks $clk_2x]
# x_vwr (core_top_ds: the clk_sys -> clk_mem write chain FIFO, nds_dcfifo):
# its Gray pointers cross between clk_sys and clk_mem, which are timed as one
# group, so STA held wgray -> s_w2r's first flop to the nearest 2:3 edge pair
# (~5 ns; #901 -0.034 ns on wgray[4]). A Gray crossing needs its bits' delays
# within one period of either clock, not an edge relationship: bounded at
# 9.0 ns (under clk_mem's 9.95), hold not required (-5 ns), as clk_cpu above.
set vwr {*|nds_dcfifo:x_vwr}
set_max_delay -from [get_registers "$vwr|wgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_w2r|s0\[*\]"] 9.0
set_min_delay -from [get_registers "$vwr|wgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_w2r|s0\[*\]"] -5.0
set_max_delay -from [get_registers "$vwr|rgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_r2w|s0\[*\]"] 9.0
set_min_delay -from [get_registers "$vwr|rgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_r2w|s0\[*\]"] -5.0
set_max_delay -from [get_registers "$vwr|pgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_p2w|s0\[*\]"] 9.0
set_min_delay -from [get_registers "$vwr|pgray\[*\]"] -to [get_registers "$vwr|nds_sync:s_p2w|s0\[*\]"] -5.0
# nds_psram's STREAM word count (a Gray pointer, clk_mem -> clk_sys) and the bridge port's take toggle (one bit into
# two flops, clk_mem -> clk_bus; #1403 -0.358 ns, #1404 -0.048 ns): the same bound
set_max_delay -from [get_registers "$pp|wc_g\[*\]"] -to [get_registers "$pp|wc_s1\[*\]"] 9.0
set_min_delay -from [get_registers "$pp|wc_g\[*\]"] -to [get_registers "$pp|wc_s1\[*\]"] -5.0
set brp {*|nds_sdram_bport:bp_bridge}
set_max_delay -from [get_registers "$brp|take_t"] -to [get_registers "$brp|take_s0"] 9.0
set_min_delay -from [get_registers "$brp|take_t"] -to [get_registers "$brp|take_s0"] -5.0
derive_clock_uncertainty
# Clock domains (docs/phase2-integration.md, "Clocks"): sys, bus, mem, the
# PSRAM chip clock and the video clock come from one PLL with aligned edges
# and are timed as one group (the DS core crosses to the memory clients and
# the video output synchronously); clk_74a crosses through nds_cdc (two-flop
# toggles over held bundles, a Gray-pointer FIFO).
set_clock_groups -asynchronous \
  -group { bridge_spiclk } \
  -group { clk_74a } \
  -group { clk_74b } \
  -group [get_clocks -nowarn "$clk_bus $clk_mem $clk_cram $clk_sys $clk_2x $clk_vid $clk_vid90 cram0_clk_out cram1_clk_out"] \
  -group [get_clocks {*audio_pll*}]
# arm7_ds: one ARM7 cycle is two clocks. E's registers change only at the end of ph 1, and every register below
# captures at the end of ph 1, two clocks after them. Not here: sho/shc, opc, the read and write numbers (ph 0),
# cpsr[11] (lands in ph 0), and what comes through the register file's read, whose ph 1 number changes in ph 0 (not in the list of launches).
set a7 "*g_a7ds.u_a7|"
set a7_from {}
foreach r {ins[*] k[*] tk[*] tpcal es[*] es.* e_mem e_blk e_mul e_mull e_swp e_sr e_rs0 b_usr first mc rl[*] br[*] wcnt[*] cpsr[12] cpsr[10] cpsr[9] cpsr[8] cpsr[7] cpsr[6] cpsr[5] cpsr[4] cpsr[3] cpsr[2] cpsr[1] cpsr[0]} {
  lappend a7_from "$a7$r" "$a7$r~*"
}
set a7_to {}
foreach r {rf_wd[*] pc_f[*] addr[*] cpsr[*] es[*] es.* rl[*] br[*] wcnt[*] first mc z_en z_lo x e_v d_v} {
  lappend a7_to "$a7$r" "$a7$r~*"
}
set a7_fr [get_registers -nowarn $a7_from]
lappend a7_to "${a7}altdpram:rf_rtl_0|*"
set a7_tr [get_registers -nowarn $a7_to]
if {[get_collection_size $a7_fr] > 0} {
  set_multicycle_path -setup 2 -from $a7_fr -to $a7_tr
  set_multicycle_path -hold 1 -from $a7_fr -to $a7_tr
  post_message -type info "arm7_ds 2-clock paths: [get_collection_size $a7_fr] -> [get_collection_size $a7_tr]"
}
# The fabric's request: addr, be, wdata load on entering S_GO. An I/O register captures on S_GO's second clock (io_go2), the
# VRAM on S_WAIT: 2 clocks. A 2D fill's ack (nds_vram g_ack) needs g_req, which takes g_off out of the resolver: no path from addr.
set fab "*|nds_fabric:u_fab|"
set fab_fr [get_registers -nowarn [list "${fab}addr\[*\]" "${fab}addr\[*\]~*" "${fab}be\[*\]" "${fab}be\[*\]~*" "${fab}wdata\[*\]" "${fab}wdata\[*\]~*" "${fab}we" "${fab}we~*" "${fab}cpu" "${fab}cpu~*"]]
set fab_to {}
foreach u {nds_vram:u_vram|res_q* nds_vram:u_vram|va* nds_vram:u_vram|vwe* nds_vram:u_vram|vblk* nds_vram:u_vram|vbe* nds_vram:u_vram|vwd* nds_vram:u_vram|st* nds_vram:u_vram|vsv* nds_vram:u_vram|c_ack* nds_vram:u_vram|r_q*
           gpu2d:u_gpu2d|q_v* gpu2d:u_gpu2d|out_v* nds_io:*|* sys_*:*|* nds_sys:*|* nds_rtc:*|* nds_spi*:*|* nds_ipc*:*|*} {
  lappend fab_to "*|$u"
}
set fab_tr [get_registers -nowarn $fab_to]
if {[get_collection_size $fab_fr] > 0 && [get_collection_size $fab_tr] > 0} {
  set_multicycle_path -setup 2 -from $fab_fr -to $fab_tr
  set_multicycle_path -hold 1 -from $fab_fr -to $fab_tr
  post_message -type info "Fabric request 2-clock paths: [get_collection_size $fab_fr] -> [get_collection_size $fab_tr]"
}

SDC
sed -i "s|APF_DIR|$apf|" ds.sdc
# SDRAM pin timing (Pocket board): chip clock on dram_clk, read capture, command/data outputs
cat "$root/rtl/pocket/nds_sdram_io.sdc" >> ds.sdc

set +e
quartus_map $top > map.log 2>&1 && quartus_fit $top > fit.log 2>&1 && quartus_asm $top > asm.log 2>&1 && quartus_sta $top > sta.log 2>&1
rc=$?; set -e
echo $rc > chain.rc
if [ $rc -ne 0 ]; then
  echo "RESULT ds s$seed$qmode: quartus failed (rc $rc)" | tee result.txt
  grep -a -h "^Error (" map.log fit.log asm.log sta.log 2>/dev/null | sed 's/ Check for.*//; s/ File: .*//' | head -20
  exit 1
fi
# the worst paths of every clock, for the record (a failing fit names its paths)
cat > worst_paths.tcl <<'TCL'
project_open apf_top
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection c [all_clocks] {
  set n [get_clock_info -name $c]
  report_timing -setup -to_clock $n -npaths 8 -detail summary -file worst_paths.txt -append -panel_name "setup $n"
  report_timing -hold -to_clock $n -npaths 3 -detail summary -file worst_paths.txt -append -panel_name "hold $n"
}
# deep view for timing closure: worst path per endpoint, and full paths of the worst pairs overall and per unit
foreach c {5 7} {
  set n "ic|core_pll|pll|general\[$c\].gpll~PLL_OUTPUT_COUNTER|divclk"
  report_timing -setup -to_clock $n -npaths 6000 -nworst 1 -detail summary -file timing_endpoints.log -append -panel_name "endpoints $c"
  report_timing -setup -to_clock $n -npaths 12 -pairs_only -detail path_only -file timing_detail.log -append -panel_name "worst $c"
}
foreach g {u_mem9 u_p7 u_core u_a7 g_a7ds.u_a7 u_dma u_fabric u_gpu2d u_ppu g_3d.u_gpu3d u_sound u_rf} {
  set r [get_registers -nowarn "*|$g|*"]
  if {[get_collection_size $r] > 0} {
    report_timing -setup -to $r -npaths 3 -pairs_only -detail path_only -file timing_detail.log -append -panel_name "to $g"
  }
}
# setup in every corner: the default one is not always the worst (#372 failed
# only at Slow 1100mV 0C)
foreach cond [get_available_operating_conditions] {
  set_operating_conditions $cond
  update_timing_netlist
  foreach_in_collection c [all_clocks] {
    set n [get_clock_info -name $c]
    report_timing -setup -to_clock $n -npaths 3 -detail summary -file worst_paths.txt -append -panel_name "setup $n ($cond)"
  }
}
# hold is worst at the fast corner (#63 failed hold there only)
foreach cond [get_available_operating_conditions] {
  if {[string match "*MIN_FAST*" $cond] || [string match "*fast*" [string tolower $cond]]} {
    set_operating_conditions $cond
    update_timing_netlist
    foreach_in_collection c [all_clocks] {
      set n [get_clock_info -name $c]
      report_timing -hold -to_clock $n -npaths 4 -detail summary -file worst_paths.txt -append -panel_name "hold $n ($cond)"
    }
  }
}
TCL
quartus_sta -t worst_paths.tcl > worst_paths.log 2>&1 || true
field() { grep -a -m1 "^; $1" "$2" 2>/dev/null | awk -F';' '{gsub(/^ +| +$/, "", $3); print $3}'; }
labs=$(field "Total LABs:  partially or completely used" output_files/$top.fit.rpt)
alms=$(field "Logic utilization (in ALMs)" output_files/$top.fit.rpt)
bits=$(field "Total block memory bits" output_files/$top.fit.rpt)
worst=$(grep -a -A1 "^Type *:" output_files/$top.sta.summary | awk '/^Slack/{print $3}' | sort -g | head -1)
timing=FAIL; [ -n "$worst" ] && awk -v s="$worst" 'BEGIN{exit !(s+0 >= 0)}' && timing=PASS
# unconstrained-path and ignored-constraint counts, for the record
grep -a -i "ignored\|Warning (332174)\|Warning (332049)" sta.log | head -10 > sta_warnings.txt || true
# registers Quartus made constant (#55: set-only flags became "Stuck at VCC");
# simulation honours initial values and cannot see this
grep -a "Stuck at" output_files/$top.map.rpt | grep -a "core_top:ic|" > stuck_registers.txt || true
stuck=$(wc -l < stuck_registers.txt)
# map ALUTs per top-level block, for the area table (docs/phase2-integration.md)
grep -a -E "^; +\|(core_top|nds_top|arm_cpu|nds_sys|nds_disp|gpu2d|nds_fabric|nds_vram|nds_io|nds_cart|nds_spi|nds_rtc|nds_arm7_port|nds_video|nds_apf_host|nds_cart_cache|nds_sdram|nds_psram|psx_psram_pair)[:|]" \
  output_files/$top.map.rpt | head -60 > area_blocks.txt || true
echo "RESULT ds s$seed$qmode: ${labs%% /*} LABs, timing $timing (worst slack $worst ns, all corners and analyses), ALMs ${alms%% (*}, block bits ${bits%% (*}, registers stuck at a constant: $stuck" | tee result.txt
# memories Quartus built as logic instead of RAM (#357: 400 ALMs unnoticed)
python3 "$root/tools/fit/ramcheck.py" output_files/$top.fit.rpt > ramcheck.txt 2>&1 || true
grep -v '^ramcheck:' ramcheck.txt | sed 's/^/RAMCHECK /' | tee -a result.txt || true
tail -1 ramcheck.txt | tee -a result.txt || true
[ "$timing" = PASS ] || exit 1
python3 "$root/tools/ds/package.py" output_files/$top.rbf package
