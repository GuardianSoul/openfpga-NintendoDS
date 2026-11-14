#!/bin/bash
# nds_g3d_store equivalence on game scenes (docs/g3d-storage-map.md, store trims): the core built from this tree's
# rtl/ and from BASE's (a commit), each with the same simulation-only log patched into nds_g3d_store (every beat the
# raster takes, every PSRAM access, with its clock), run on the same scenes; the logs and every screenshot must be
# identical. A beat's data is its type's port (ps_vdata for vertex beats once the store has one, else ps_data).
#   sim/ds/store_game_eq.sh BASE SCENE:FRAMES...     e.g. 1a74b2c7e hg-title:19 ff4-newgame:20 mkds-pack:20
# Scene exports (build/scenes/NAME/exp) come from EXP_ROOT (default: this tree's build/scenes). OUT (default
# build/store-game-eq) holds both rtl trees, their Verilator builds and the runs; delete it when done.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BASE=$1; shift
EXP_ROOT=${EXP_ROOT:-$ROOT/build/scenes}
OUT=${OUT:-$ROOT/build/store-game-eq}
MAIN=/home/user/Git/NDS_Pocket
mkdir -p "$OUT"
patch_log() {  # the log block, before the +g3dtrace block
    python3 - "$1" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
d = "ps_type == 2'd1 ? ps_vdata : ps_data" if 'output logic [127:0] ps_vdata' in s else 'ps_data'
blk = f'''    // store_game_eq.sh: +g3dbeatlog=FILE, every beat and PSRAM access with its clock
    int bl_fd = 0; longint bl_cyc = 0;
    initial begin string fn; if ($value$plusargs("g3dbeatlog=%s", fn)) bl_fd = $fopen(fn, "w"); end
    always_ff @(posedge clk) begin
        bl_cyc <= bl_cyc + 1;
        if (bl_fd != 0 && ps_valid && ps_ready) $fdisplay(bl_fd, "%0d beat %0d %h", bl_cyc, ps_type, ps_type == 2'd3 ? 128'd0 : {d});
        if (bl_fd != 0 && p_req && p_ack) $fdisplay(bl_fd, "%0d psram %s %h %h", bl_cyc, p_we ? "W" : "R", p_addr, p_we ? p_wdata : 32'd0);
        if (bl_fd != 0 && p_rvalid) $fdisplay(bl_fd, "%0d rd %h", bl_cyc, p_rdata);
    end
'''
a = '    // +g3dtrace: records in, beats out, PSRAM accesses\n'
assert s.count(a) == 1, 'no +g3dtrace block'
s = s.replace(a, blk + a)
open(p, 'w').write(s)
EOF
}
rm -rf "$OUT/rtl_base" "$OUT/rtl_new"
mkdir -p "$OUT/rtl_base"
git archive "$BASE" rtl | tar -x -C "$OUT/rtl_base" --strip-components=1
cp -r rtl "$OUT/rtl_new"
patch_log "$OUT/rtl_base/ds/nds_g3d_store.sv"
patch_log "$OUT/rtl_new/ds/nds_g3d_store.sv"
fail=0
for sf in "$@"; do
    s=${sf%%:*}; n=${sf##*:}
    rom=$(awk -v s="$s" '$1 == s {print $2; exit}' sim/pocket_ds/scenes.txt)
    for v in base new; do
        d=$OUT/$s-$v
        rm -rf "$d"; mkdir -p "$d"
        NDS_DISK_GUARD_OFF=1 python3 sim/pocket_ds/run.py --nodebug --rtl-root "$OUT/rtl_$v" --obj-root "$OUT/obj_$v" \
            --rom "$MAIN/roms/$rom" --import "$EXP_ROOT/$s/exp" --frames "$n" --out "$d/run" --shots "$d/shots" \
            --plus "g3dbeatlog=$d/beats.log" > "$d/run.log" 2>&1 || true
        rm -f "$d/run/rom.hex" "$d/run/imp_"*.hex
    done
    b=$OUT/$s-base; w=$OUT/$s-new
    nb=$(wc -l < "$b/beats.log"); ns=$(ls "$b/shots" | wc -l)
    if [ "$nb" -gt 0 ] && cmp -s "$b/beats.log" "$w/beats.log" && diff -rq "$b/shots" "$w/shots" > /dev/null &&
       [ "$ns" -gt 0 ]; then
        echo "$s: same ($nb store events, $ns screenshots identical)"
    else
        echo "$s: DIFFERENT (store events $nb / $(wc -l < "$w/beats.log"), first difference:"
        cmp "$b/beats.log" "$w/beats.log" | head -1 || true
        diff -rq "$b/shots" "$w/shots" | head -2 || true
        echo ")"; fail=1
    fi
done
[ $fail = 0 ] && echo "store_game_eq: PASS" || { echo "store_game_eq: FAIL"; exit 1; }
