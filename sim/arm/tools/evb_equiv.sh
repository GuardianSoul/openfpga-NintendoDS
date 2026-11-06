#!/bin/sh
# The ARM9 eviction buffer (arm9_mem EVB), make evb-equiv (usage: evb_equiv.sh VERILATOR BUILD ASSETS [REF])
# 1. EVB = 0 against the reference revision's own build: run_tests output identical in every line but the seconds;
# 2. EVB = 1: all tests pass, equiv.py (retired streams, also with random waits) against REF;
# 3. the mutants (the copy off by one word; a fill that does not wait for the drain; the block write's words out of order; a fill passing the drain with no address compare; a read passing the drain with a store pending) must fail.
set -u
V=$1; B=$2; A=$3; REF=${4:-origin/main}
P=$B/evb; rm -rf "$P"; mkdir -p "$P/ref"
RTL="arm_pkg.sv arm_regfile.sv arm_mul.sv arm_thumb.sv arm_core.sv arm9_ram.sv arm9_mem.sv arm_cpu.sv"
for f in $RTL; do git show $REF:rtl/arm/$f > "$P/ref/$f" 2>/dev/null || rm -f "$P/ref/$f"; done
git show $REF:sim/arm/tb_arm.sv > "$P/ref/tb_arm.sv"
VF="--binary --timing -j 8 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module tb_arm"
(cd "$P/ref" && $V $VF -Mdir obj $RTL tb_arm.sv > ../ref.log 2>&1) &
mk() {  # DIR EVB [mutant-sed] [EVBW]
    d=$P/$1; mkdir -p $d/rtl; for f in $RTL; do cp rtl/arm/$f $d/rtl/; done
    [ -n "${3:-}" ] && sed -i "$3" $d/rtl/arm9_mem.sv
    $V $VF -GEVB=$2 -GEVBW=${4:-0} -Mdir $d/obj $(for f in $RTL; do echo $d/rtl/$f; done) sim/arm/tb_arm.sv > $d.log 2>&1 || { cat $d.log; exit 1; }
}
mk e0 0 & mk e1 1 & mk e2 1 "" 1 &
mk m1 1 's/if (k != 3.d0) ev_d\[k - 3.d1\] <= dc_aq\[vway\];/if (k != 3'"'"'d0) ev_d[k] <= dc_aq[vway];/' &
mk m3 1 's/if (b_wnext) k <= k + 3.d1;/if (b_wnext) k <= k + 3'"'"'d2;/' 1 &
mk m4 1 's/dp_a\[21:5\] != ev_a\[16:0\]/1'"'"'b1/; s/ip_a\[21:5\] != ev_a\[16:0\]/1'"'"'b1/' &
mk m5 1 's/wire         ev_pass = ev_v \&\& !wbuf_v \&\&/wire         ev_pass = ev_v \&\&/' &
mk m2 1 's/if (EVB \&\& ev_v \&\& !ev_pass) st <= S_EVDRN;/if (1'"'"'b0) st <= S_EVDRN;/' &
wait
for x in e0 e1 e2 m1 m2 m3 m4 m5; do
    python3 sim/arm/tools/run_tests.py --sim "$P/$x/obj/Vtb_arm" --build "$B" --assets "$A" > "$P/$x.txt" 2>&1
    echo "== $x: $(grep -c PASS "$P/$x.txt") PASS, $(grep -c FAIL "$P/$x.txt") FAIL"
done
python3 sim/arm/tools/run_tests.py --sim "$P/ref/obj/Vtb_arm" --build "$B" --assets "$A" > "$P/ref.txt" 2>&1
echo "== ref: $(grep -c PASS "$P/ref.txt") PASS"
norm() { sed 's/, [0-9.]*s)/)/' "$1"; }
echo "EVB=0 vs ref (cycles included) lines differ: $(diff <(norm $P/e0.txt) <(norm $P/ref.txt) | grep -c '^[<>]')"
python3 sim/arm/tools/equiv.py "$V" "$P/e1/obj/Vtb_arm" "$B" "$A" "$REF" > "$P/equiv_e1.txt" 2>&1; echo "== equiv EVB=1: $(grep -c '^DIFF' "$P/equiv_e1.txt") DIFF, $(tail -1 "$P/equiv_e1.txt")"
python3 sim/arm/tools/equiv.py "$V" "$P/e2/obj/Vtb_arm" "$B" "$A" "$REF" > "$P/equiv_e2.txt" 2>&1; echo "== equiv EVB=1 EVBW=1 (block write): $(grep -c '^DIFF' "$P/equiv_e2.txt") DIFF, $(tail -1 "$P/equiv_e2.txt")"
for m in m1 m2 m3 m4 m5; do python3 sim/arm/tools/equiv.py "$V" "$P/$m/obj/Vtb_arm" "$B" "$A" "$REF" > "$P/equiv_$m.txt" 2>&1; echo "== equiv mutant $m: $(grep -c '^DIFF' "$P/equiv_$m.txt") DIFF"; done
