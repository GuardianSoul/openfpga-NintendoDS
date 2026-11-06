#!/usr/bin/env bash
# Equivalence of the working-tree rtl/sys against an earlier revision: both
# run side by side on random register traffic, events and memory acks, and
# every output is compared every cycle (equiv_top.sv, equiv.cpp).
#   sim/sys/equiv.sh [REF=HEAD] [cycles=2000000] [seed=1]
# MUTATE_FILE=<file in rtl/sys> MUTATE_EXPR='<sed expr>' mutates the new
# side first, to show that the check catches a difference.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
ref=${1:-HEAD} cycles=${2:-2000000} seed=${3:-1}
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
work=$root/build/sys/equiv
rm -rf "$work"; mkdir -p "$work/old" "$work/new"
files="sys_ram sys_irq sys_timers sys_ipc sys_math sys_dma nds_sys"
for f in $files; do
    git -C "$root" show "$ref:rtl/sys/$f.sv" |
        sed -E 's/\b(sys_ram96|sys_ram64be|sys_ram32be|sys_ram|sys_mlab64be|sys_mlab|sys_irq|sys_timers|sys_ipc|sys_math|sys_dma|nds_sys)\b/old_\1/g' > "$work/old/$f.sv"
    cp "$root/rtl/sys/$f.sv" "$work/new/$f.sv"
done
if [ -n "${MUTATE_FILE:-}" ]; then
    before=$(md5sum "$work/new/$MUTATE_FILE")
    sed -i -e "$MUTATE_EXPR" "$work/new/$MUTATE_FILE"
    [ "$before" != "$(md5sum "$work/new/$MUTATE_FILE")" ] || { echo "mutation did not change $MUTATE_FILE" >&2; exit 2; }
fi
"$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -GPUMP=${PUMP:-0} -GFAST=${FAST:-0} --top-module sys_equiv \
    --Mdir "$work/obj" $(for f in $files; do echo "$work/old/$f.sv $work/new/$f.sv"; done) \
    "$root/rtl/ds/nds_dsp_add.sv" "$root/sim/sys/equiv_top.sv" "$root/sim/sys/equiv.cpp" > "$work/verilator.log" 2>&1 ||
    { tail -20 "$work/verilator.log"; exit 2; }
echo "rtl/sys against $(git -C "$root" rev-parse --short "$ref")${MUTATE_FILE:+ (new side mutated: $MUTATE_FILE: $MUTATE_EXPR)}"
"$work/obj/Vsys_equiv" --cycles "$cycles" --seed "$seed"
