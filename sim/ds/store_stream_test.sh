#!/bin/sh
# nds_g3d_store STREAM: tb_g3d_store_stream against its reference model, STREAM 0 and 1, and a mutant
# (docs/geometry-engine.md "Store pool: one line's polygons"). Small pool (SL 5, CL 7) so the scenes press it.
set -e
cd "$(dirname "$0")/../.."
V=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
B=build/store-stream
mkdir -p $B
SRC="rtl/gpu3d/gpu3d_ram.sv rtl/ds/nds_g3d_store.sv sim/ds/tb_g3d_store_stream.sv"
build() {  # build NAME STREAM [store source] [DROP] [extra Verilator flags]
    s=${3:-rtl/ds/nds_g3d_store.sv}
    nice -n 10 $V --binary --timing -j 4 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL ${5:-} \
        --top-module tb_g3d_store_stream -GSTREAM=$2 -GDROP=${4:-0} --Mdir $B/$1 rtl/gpu3d/gpu3d_ram.sv $s sim/ds/tb_g3d_store_stream.sv \
        > $B/$1.log 2>&1 || { grep %Error $B/$1.log | head; exit 1; }
}
run() {  # run NAME SCENE SEED -> the result line
    timeout 600 $B/$1/Vtb_g3d_store_stream +scene=$2 +seed=$3 2>&1 | grep -E '^(PASS|FAIL|STALL)|%Error:' | head -1
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
# DROP after a raster restart (scene 4): the next frame's first arrivals come while the free lists refill after the
# clear; DROP must wait for them, not drop (before the fix: the line-0 polygons dropped)
for seed in 1 2 3; do
    r=$(run s1 4 $seed); echo "s1 restart seed $seed: $r"; case "$r" in PASS*) ;; *) fail=1;; esac
    r=$(run d1 4 $seed); echo "d1 restart seed $seed (DROP): $r"; case "$r" in PASS*) ;; *) fail=1;; esac
done
# its mutant: the chunk list's refill not waited for (l_drop without !fc_busy): the drops come back
sed 's/ \&\& !fs_busy \&\& !fc_busy;/ \&\& !fs_busy;/' rtl/ds/nds_g3d_store.sv > $B/mutant_restart.sv
cmp -s rtl/ds/nds_g3d_store.sv $B/mutant_restart.sv && { echo "restart mutant not applied"; exit 1; }
build rm 1 $B/mutant_restart.sv 1
r=$(run rm 4 1); echo "restart mutant (expected to fail): $r"; case "$r" in PASS*) fail=1;; esac
# vertex records past 6,144 (FF4's opening): 2,048 quad-strip polygons (8,192 records) and the bound, 10,240 records
for sc in 5 6; do
    for b in s1 d1; do r=$(run $b $sc 1); echo "$b records scene $sc: $r"; case "$r" in PASS*) ;; *) fail=1;; esac; done
done
# its mutant: the record number's address sums in 13 bits again (the store before the fix)
sed -e "s/{3'd0, 16'h0800 + {2'd0, vptr}}/{6'd0, 13'h0800 + vptr[12:0]}/" \
    -e "s/{3'd0, 16'h0800 + {2'd0, lv}, 2'b00}/{6'd0, 13'h0800 + lv[12:0], 2'b00}/" rtl/ds/nds_g3d_store.sv > $B/mutant_rec.sv
[ $(diff rtl/ds/nds_g3d_store.sv $B/mutant_rec.sv | grep -c '^>') = 2 ] || { echo "records mutant not applied"; exit 1; }
build vm 1 $B/mutant_rec.sv 1
r=$(run vm 5 1); echo "records mutant scene 5 (expected to fail): $r"; case "$r" in PASS*) fail=1;; esac
# the beat ports split (ps_data headers, ps_vdata vertices): a mutant with the vertex beats' first word from the header lanes
sed "s/assign ps_vdata = PSREG ? ps_data_r : {12'd0, ch_q};/assign ps_vdata = PSREG ? ps_data_r : {12'd0, ch_q[115:32], sh_q[31:0]};/" \
    rtl/ds/nds_g3d_store.sv > $B/mutant_ps.sv
cmp -s rtl/ds/nds_g3d_store.sv $B/mutant_ps.sv && { echo "beat-port mutant not applied"; exit 1; }
build pm 1 $B/mutant_ps.sv 1
r=$(run pm 0 1); echo "beat-port mutant random (expected to fail): $r"; case "$r" in PASS*) fail=1;; esac
# equivalence with an earlier store (OLD, default 1a74b2c7e: the FF4 record fix, before the store trims): every beat
# and PSRAM access at the same clock. A store from before the beat-port split builds with
# -DPS_ONE_PORT (found by its ports). Before the FF4 fix (OLD b315eeccd) only frames of at most 6,144 records compare (EQ_SCENES without 5 and 6)
OLD=${OLD:-1a74b2c7e}
[ -n "${OLD_SV:-}" ] && cp "$OLD_SV" $B/store_old.sv || git show $OLD:rtl/ds/nds_g3d_store.sv > $B/store_old.sv
OF=""; grep -q 'output logic \[127:0\] ps_vdata' $B/store_old.sv || OF=-DPS_ONE_PORT
build o1 1 $B/store_old.sv 0 "$OF"; build od 1 $B/store_old.sv 1 "$OF"
eq() {  # eq NEW OLD SCENE SEED
    $B/$1/Vtb_g3d_store_stream +scene=$3 +seed=$4 +beatlog=$B/eq_new.log > /dev/null 2>&1
    $B/$2/Vtb_g3d_store_stream +scene=$3 +seed=$4 +beatlog=$B/eq_old.log > /dev/null 2>&1
    if [ -s $B/eq_new.log ] && cmp -s $B/eq_new.log $B/eq_old.log; then echo "equivalence $1/$2 scene $3 seed $4: same ($(wc -l < $B/eq_new.log) events)"
    else echo "equivalence $1/$2 scene $3 seed $4: DIFFERENT"; fail=1; fi
}
for seed in 1 2 3 4 5; do eq s1 o1 0 $seed; eq d1 od 0 $seed; done
for sc in ${EQ_SCENES:-1 4 5 6 7}; do eq s1 o1 $sc 1; eq d1 od $sc 1; done
eq d1 od 2 1
[ $fail = 0 ] && echo "store_stream_test: PASS" || { echo "store_stream_test: FAIL"; exit 1; }
