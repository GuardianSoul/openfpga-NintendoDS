#!/usr/bin/env bash
# Full-chip Pocket build of the Phase 1 test core, NDSPhase1
# (docs/phase1-foundation.md):
#   scripts/build_phase1.sh OUTDIR SEED
# Generates a Quartus project from rtl/pocket, rtl/mem and the APF shell in
# rtl/apf, runs map/fit/asm/sta, requires non-negative slack for every
# analysis and corner, and packages OUTDIR/package/NDSPhase1.zip. Writes
# OUTDIR/result.txt.
# Run it only through the Jenkins nds-fit job (TARGET=phase1, docs/fitting.md):
# never start Quartus by hand on a fit node.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$1 seed=$2
top=apf_top
apf=$root/rtl/apf
mkdir -p "$out/apf"; cd "$out"

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
  echo 'set_global_assignment -name SDC_FILE phase1.sdc'
  echo 'set_global_assignment -name MIF_FILE apf/build_id.mif'
  for f in apf_top.v common.v io_bridge_peripheral.v io_pad_controller.v mf_ddio_bidir_12.v mf_datatable.v \
           core_bridge_cmd_lean.v mf_audio_pll.v mf_audio_pll_0002.v; do
    echo "set_global_assignment -name VERILOG_FILE \"$apf/$f\""
  done
  echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$apf/sound_i2s.sv\""
  for f in psx_sdram_ctrl.sv psx_psram_pair.sv psx_pq_psram.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/mem/$f\""
  done
  for f in nds_sig.sv nds_cdc.sv nds_pll.sv nds_sdram.sv nds_apf_host.sv nds_save_read.sv nds_cart_cache.sv nds_bus_tests.sv \
           nds_mem_tests.sv nds_log.sv psx_pocket_pad_combo.sv nds_controls.sv nds_screens.sv core_top.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/pocket/$f\""
  done
  # PSRAM read data and WAIT in the input registers, as PocketQuake and openfpga-PlayStation's PSRAM probes;
  # the DQ output and output-enable registers in the I/O cells too (#124 failed by 0.13 ns on
  # data_out_en driving 16 pins from fabric; openfpga-PlayStation does the same for its SDRAM DQ)
  for c in cram0 cram1; do
    for i in $(seq 0 15); do
      echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to ${c}_dq[$i]"
      echo "set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to ${c}_dq[$i]"
      echo "set_instance_assignment -name FAST_OUTPUT_ENABLE_REGISTER ON -to ${c}_dq[$i]"
    done
    echo "set_instance_assignment -name FAST_INPUT_REGISTER ON -to ${c}_wait"
    for o in "a[*]" adv_n cre ce0_n ce1_n oe_n we_n ub_n lb_n; do
      echo "set_instance_assignment -name FAST_OUTPUT_REGISTER ON -to ${c}_$o"
    done
  done
} > $top.qsf

cat > phase1.sdc <<'SDC'
source "APF_DIR/apf_constraints.sdc"
# Core PLL (rtl/pocket/nds_pll.sv): 0 bus, 1 mem, 2 PSRAM chip clock, 3 video, 4 video 90 degrees
set pll {ic|core_pll|pll|general}
set clk_bus  "${pll}\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_mem  "${pll}\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_cram "${pll}\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_vid  "${pll}\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"
set clk_vid90 "${pll}\[4\].gpll~PLL_OUTPUT_COUNTER|divclk"
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
derive_clock_uncertainty
# Clock domains (docs/phase1-foundation.md, "Clocks and crossings"): bus,
# mem and the PSRAM chip clock are one related group (the SDRAM controller's
# 3:1 pair); everything else crosses through nds_cdc (two-flop toggles over
# held bundles, a Gray-pointer FIFO), dual-clock RAMs or display-only samples.
set_clock_groups -asynchronous \
  -group { bridge_spiclk } \
  -group { clk_74a } \
  -group { clk_74b } \
  -group [get_clocks "$clk_bus $clk_mem $clk_cram cram0_clk_out cram1_clk_out"] \
  -group [get_clocks "$clk_vid $clk_vid90"] \
  -group [get_clocks {*audio_pll*}]
SDC
sed -i "s|APF_DIR|$apf|" phase1.sdc

set +e
quartus_map $top > map.log 2>&1 && quartus_fit $top > fit.log 2>&1 && quartus_asm $top > asm.log 2>&1 && quartus_sta $top > sta.log 2>&1
rc=$?; set -e
echo $rc > chain.rc
if [ $rc -ne 0 ]; then
  echo "RESULT phase1 s$seed: quartus failed (rc $rc)" | tee result.txt
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
grep -a "Stuck at" output_files/$top.map.rpt | grep -a "core_top:ic|nds_" > stuck_registers.txt || true
stuck=$(wc -l < stuck_registers.txt)
echo "RESULT phase1 s$seed: ${labs%% /*} LABs, timing $timing (worst slack $worst ns, all corners and analyses), ALMs ${alms%% (*}, block bits ${bits%% (*}, nds_* registers stuck at a constant: $stuck" | tee result.txt
[ "$timing" = PASS ] || exit 1
python3 "$root/tools/phase1/package.py" output_files/$top.rbf package
