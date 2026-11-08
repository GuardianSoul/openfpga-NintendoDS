#!/bin/sh
# nds_g3d_store STREAM: tb_g3d_store_stream against its reference model, STREAM 0 and 1, and a mutant
# (docs/geometry-engine.md "Store pool: one line's polygons"). Small pool (SL 5, CL 7) so the scenes press it.
set -e
cd "$(dirname "$0")/../.."
V=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
B=build/store-stream
mkdir -p $B
SRC="rtl/gpu3d/gpu3d_ram.sv rtl/ds/nds_g3d_store.sv sim/ds/tb_g3d_store_stream.sv"
build() {  # build NAME STREAM [store source] [DROP]
    s=${3:-rtl/ds/nds_g3d_store.sv}
    nice -n 10 $V --binary --timing -j 4 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
        --top-module tb_g3d_store_stream -GSTREAM=$2 -GDROP=${4:-0} --Mdir $B/$1 rtl/gpu3d/gpu3d_ram.sv $s sim/ds/tb_g3d_store_stream.sv \
        > $B/$1.log 2>&1 || { grep %Error $B/$1.log | head; exit 1; }
}
run() {  # run NAME SCENE SEED -> the result line
    timeout 600 $B/$1/Vtb_g3d_store_stream +scene=$2 +seed=$3 2>&1 | grep -E '^(PASS|FAIL|STALL)' | head -1
}
build s0 0; build s1 1; build d1 1 rtl/ds/nds_g3d_store.sv 1
fail=0
for seed in 1 2 3 4 5; do
    for b in s0 s1 d1; do r=$(run $b 0 $seed); echo "$b random seed $seed: $r"; case "$r" in PASS*) ;; *) fail=1;; esac; done
done
r=$(run s1 1 1); echo "s1 horizon: $r"; case "$r" in PASS*) ;; *) fail=1;; esac
r=$(run d1 1 1); echo "d1 horizon (DROP: same beats): $r"; case "$r" in PASS*) ;; *) fail=1;; esac
# DROP (item 16): a 2-line band over the pool stalls STREAM alone; with DROP the frame goes on without the polygons
# the pool can't take
for seed in 1 2 3; do
    r=$(run s1 2 $seed); echo "s1 band seed $seed (expected to stall): $r"; case "$r" in STALL*) ;; *) fail=1;; esac
    r=$(run d1 2 $seed); echo "d1 band seed $seed (DROP): $r"; case "$r" in PASS*) ;; *) fail=1;; esac
done
# DROP's mutant: the fetcher doesn't skip a dropped position (it sends slot 0's polygon instead)
sed 's/if (DROP \&\& sp_q\[SL + DROP - 1\]) begin f_keep/if (1'"'"'b0) begin f_keep/' rtl/ds/nds_g3d_store.sv > $B/mutant_drop.sv
cmp -s rtl/ds/nds_g3d_store.sv $B/mutant_drop.sv && { echo "drop mutant not applied"; exit 1; }
build dm 1 $B/mutant_drop.sv 1
r=$(run dm 2 1); echo "drop mutant band (expected to fail): $r"; case "$r" in PASS*) fail=1;; esac
r=$(run s0 1 1); echo "s0 horizon (expected to stall): $r"; case "$r" in STALL*) ;; *) fail=1;; esac
# mutant: the fetcher takes an arrival of the loader's line without waiting for it to be loaded (l_av ignored)
sed 's/(f_lyeq \&\& l_av != 12'"'"'d0)/(f_lyeq)/' rtl/ds/nds_g3d_store.sv > $B/mutant.sv
cmp -s rtl/ds/nds_g3d_store.sv $B/mutant.sv && { echo "mutant not applied"; exit 1; }
build m1 1 $B/mutant.sv
r=$(run m1 1 1); echo "mutant horizon (expected to fail): $r"; case "$r" in PASS*) fail=1;; esac
[ $fail = 0 ] && echo "store_stream_test: PASS" || { echo "store_stream_test: FAIL"; exit 1; }
