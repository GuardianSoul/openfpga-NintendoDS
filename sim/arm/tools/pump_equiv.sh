#!/bin/sh
# The double-pumped register file (RF_PUMP=1) against the plain one, at SLOW 0 and 1:
#   make arm-pump-equiv       (usage: pump_equiv.sh VERILATOR BUILD ASSETS)
# 1. run_tests on a plain and a pumped build, SLOW 0 and 1: every line of the output (cycle
#    counts included) must be identical, and every test passes;
# 2. equiv.py of the pumped SLOW 0 build against the plain revision in HEAD (retired PC,
#    CPSR and r0-r14, also with random memory waits);
# 3. the mutant (the middle-cycle detector inverted) must fail 1 and 2.
set -u
REF=${REF:-origin/main}
V=$1; B=$2; A=$3
P=$B/pump; rm -rf "$P"; mkdir -p "$P"
RTL="rtl/arm/arm_pkg.sv rtl/arm/arm_regfile.sv rtl/arm/arm_mul.sv rtl/arm/arm_thumb.sv rtl/arm/arm_core.sv rtl/arm/arm9_ram.sv rtl/arm/arm9_mem.sv rtl/arm/arm_cpu.sv"
build() {   # DIR PUMP SLOW [regfile]
    rf=${4:-rtl/arm/arm_regfile.sv}
    $V --binary --timing -j 8 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
       -Wno-UNUSEDSIGNAL -GRF_PUMP=$2 -GSLOW=$3 --top-module tb_arm -Mdir "$P/$1" \
       $(echo $RTL | sed "s#rtl/arm/arm_regfile.sv#$rf#") sim/arm/tb_arm.sv > "$P/$1.log" 2>&1 || { cat "$P/$1.log"; exit 1; }
}
build r0 0 0 & build r1 0 1 & build s0 1 0 & build s1 1 1 &
sed 's/wire         mid = tg != tq;/wire         mid = tg == tq;/' rtl/arm/arm_regfile.sv > "$P/mut_regfile.sv"
build mut 1 0 "$P/mut_regfile.sv" &
wait
for x in r0 r1 s0 s1 mut; do
    python3 sim/arm/tools/run_tests.py --sim "$P/$x/Vtb_arm" --build "$B" --assets "$A" > "$P/$x.txt" 2>&1
    echo "== $x: $(grep -c PASS "$P/$x.txt") PASS, $(grep -c FAIL "$P/$x.txt") FAIL"
done
echo "s0 vs r0 lines differ: $(diff "$P/s0.txt" "$P/r0.txt" | grep -c '^[<>]')"
echo "s1 vs r1 lines differ: $(diff "$P/s1.txt" "$P/r1.txt" | grep -c '^[<>]')"
echo "mut vs r0 lines differ: $(diff "$P/mut.txt" "$P/r0.txt" | grep -c '^[<>]')"
python3 sim/arm/tools/equiv.py "$V" "$P/s0/Vtb_arm" "$B" "$A" "$REF" > "$P/equiv_s0.txt" 2>&1; echo "== equiv s0: $(grep -c '^DIFF' "$P/equiv_s0.txt") DIFF, $(tail -1 "$P/equiv_s0.txt")"
python3 sim/arm/tools/equiv.py "$V" "$P/mut/Vtb_arm" "$B" "$A" "$REF" > "$P/equiv_mut.txt" 2>&1; echo "== equiv mut: $(grep -c '^DIFF' "$P/equiv_mut.txt") DIFF"
