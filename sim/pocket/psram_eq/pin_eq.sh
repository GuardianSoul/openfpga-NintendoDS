#!/usr/bin/env bash
# nds_psram against REF's, every chip pin and the DS port on every clock (tb_b8_eq.sv with STRICT=1;
# b8_eq.sh compares A/DQ only while a chip is selected), for B8 = 0 and 1, with the chips' WAITs equal and
# different (chip 1's burst latency 6, chip 0's 4) (docs/space-io.md).
#   pin_eq.sh [REF=HEAD] [seeds=8] [reqs=3000]
# MUTATE_OLD=<text> MUTATE_NEW=<text> mutates the new side's nds_psram first (the text must occur once).
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-8}; reqs=${3:-3000}
out=${PIN_EQ_WORK:-${TMPDIR:-/tmp}/pin_eq.$USER}; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_psram.sv" | sed -E 's/^module nds_psram\b/module old_nds_psram/; s/\bnds_pq_psram2\b/old_nds_pq_psram2/g' > "$out/old.sv"
cp rtl/pocket/nds_psram.sv "$out/new.sv"
if [ -n "${MUTATE_OLD:-}" ]; then
    python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); assert s.count(sys.argv[2])==1, 'mutation text not found once'; open(p,'w').write(s.replace(sys.argv[2], sys.argv[3]))" \
        "$out/new.sv" "$MUTATE_OLD" "$MUTATE_NEW"
fi
rc=0
for cfg in 0:4 1:4 0:6 1:6; do      # B8:chip 1's burst latency (6: its data phase 2 clocks after chip 0's)
    b8=${cfg%:*} l1=${cfg#*:}
    verilator --binary --timing -O2 -j 4 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-MULTIDRIVEN \
        --top-module tb_b8_eq -GB8=$b8 -GSTREAM=$b8 -GSTRICT=1 -GL1=$l1 --Mdir "$out/obj$b8" rtl/mem/psx_pq_psram.sv "$out/old.sv" "$out/new.sv" \
        sim/phase1/cram_model.sv sim/phase1/sim_prims.sv sim/pocket/psram_eq/tb_b8_eq.sv > "$out/build$b8.log" 2>&1 \
        || { grep -E "%Error" "$out/build$b8.log" | head >&2; exit 2; }
    pass=0
    for s in $(seq 1 "$seeds"); do
        "$out/obj$b8/Vtb_b8_eq" +seed=$s +reqs=$reqs | grep -E "^(PASS|FAIL)|^  [0-9]" | tail -3 | tee -a "$out/runs$b8.log" | grep -q '^PASS' && pass=$((pass + 1)) || true
    done
    rm -rf "$out/obj$b8"
    echo "pin_eq B8=$b8 STREAM=$b8 L1=$l1 against $(git rev-parse --short "$ref")${MUTATE_OLD:+ (mutated)}: $pass/$seeds PASS"
    [ "$pass" = "$seeds" ] || rc=1
done
exit $rc
