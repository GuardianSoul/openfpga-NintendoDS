#!/usr/bin/env bash
# Full-chip Pocket build of the SD data-slot read probe (docs/sd-probe.md):
#   scripts/build_sd_probe.sh OUTDIR SEED
# Generates a Quartus project from rtl/probe (APF shell in rtl/apf),
# runs map/fit/asm/sta, requires non-negative slack for every analysis and
# corner, and packages OUTDIR/package/NDSSDProbe.zip (bit-reversed RBF and
# APF JSON). Writes OUTDIR/result.txt.
# Run it only through the Jenkins nds-fit job (TARGET=sd-probe, docs/fitting.md):
# never start Quartus by hand on a fit node.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$1 seed=$2
top=apf_top
apf=$root/rtl/apf
mkdir -p "$out/apf"; cd "$out"

# Build ID ROM read by the APF (mf_datatable init file): date, time, unique word.
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
  # Board assignments from the APF template, without its build hooks.
  grep '^set_' "$apf/pocket.tcl" | grep -v -e SCRIPT_FILE -e QIP_FILE -e ENABLE_SIGNALTAP
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
  echo "set_global_assignment -name SEED $seed"
  echo 'set_global_assignment -name SDC_FILE sd_probe.sdc'
  echo 'set_global_assignment -name MIF_FILE apf/build_id.mif'
  for f in apf_top.v common.v io_bridge_peripheral.v io_pad_controller.v mf_ddio_bidir_12.v mf_datatable.v \
           core_bridge_cmd.v mf_audio_pll.v mf_audio_pll_0002.v; do
    echo "set_global_assignment -name VERILOG_FILE \"$apf/$f\""
  done
  for f in apf/sound_i2s.sv sd_probe.sv sd_probe_screen.sv core_top.sv; do
    echo "set_global_assignment -name SYSTEMVERILOG_FILE \"$root/rtl/probe/$f\""
  done
} > $top.qsf

cat > sd_probe.sdc <<SDC
source "$apf/apf_constraints.sdc"
derive_clock_uncertainty
# The probe and the APF command handler run on clk_74a. The screen samples
# the probe's slow status through two flops (sd_probe_screen status_meta).
set_clock_groups -asynchronous \\
  -group { bridge_spiclk } \\
  -group { clk_74a } \\
  -group { clk_74b } \\
  -group [get_clocks {*video_pll*}] \\
  -group [get_clocks {*audio_pll*}]
SDC

set +e
quartus_map $top > map.log 2>&1 && quartus_fit $top > fit.log 2>&1 && quartus_asm $top > asm.log 2>&1 && quartus_sta $top > sta.log 2>&1
rc=$?; set -e
echo $rc > chain.rc
if [ $rc -ne 0 ]; then
  echo "RESULT sd-probe s$seed: quartus failed (rc $rc)" | tee result.txt
  grep -a -h "^Error (" map.log fit.log asm.log sta.log 2>/dev/null | sed 's/ Check for.*//; s/ File: .*//' | head -20
  exit 1
fi
field() { grep -a -m1 "^; $1" "$2" 2>/dev/null | awk -F';' '{gsub(/^ +| +$/, "", $3); print $3}'; }
labs=$(field "Total LABs:  partially or completely used" output_files/$top.fit.rpt)
alms=$(field "Logic utilization (in ALMs)" output_files/$top.fit.rpt)
bits=$(field "Total block memory bits" output_files/$top.fit.rpt)
# Every analysis (setup, hold, recovery, removal, pulse width) at every corner.
worst=$(grep -a -A1 "^Type *:" output_files/$top.sta.summary | awk '/^Slack/{print $3}' | sort -g | head -1)
timing=FAIL; [ -n "$worst" ] && awk -v s="$worst" 'BEGIN{exit !(s+0 >= 0)}' && timing=PASS
echo "RESULT sd-probe s$seed: ${labs%% /*} LABs, timing $timing (worst slack $worst ns, all corners and analyses), ALMs ${alms%% (*}, block bits ${bits%% (*}" | tee result.txt
[ "$timing" = PASS ] || exit 1
python3 "$root/tools/sd-probe/package.py" output_files/$top.rbf package
