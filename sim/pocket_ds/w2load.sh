#!/usr/bin/env bash
# White 2 load-time check (suspect 3 of the city tree-corner bug, build/coordinator/units/nds-geometry-2.json):
# the Pocket model through a White 2 map-block load, its main RAM and GX entries against melonDS's.
#
#   sim/pocket_ds/w2load.sh [D=29] [TAG=w2l]
#
# pkw2-load.mln: pkw2-exit.mln (the maintainer's city, at the Route 19 gate) walked DOWN 114 frames, cut just before
# the next map block streams in (melonDS reads the card at its frames 3-28). The scene pkw2-load (scenes.txt,
# hold=DOWN) runs the Pocket model from it with DOWN held; at video frame D after the release it dumps main
# RAM (tb_ds_pocket +dump_frame) and logs every GX entry (gpu3d_gxfront +gxlog). melonDS runs the same
# window from the export (its frame e0 is the release), traces its GX entries and exports main RAM around
# frame D + e0. sim/pocket_ds/w2load_cmp.py compares both: the words the load wrote and kept must match, and
# every vertex word the Pocket sent must be one melonDS sent. Results in build/scenes/pkw2-load/w2load-TAG/
# (cmp.txt; exit 1 on a difference). ~22 min on the Desktop with a cached model (D=29), +9 min for a build.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
main=$HOME/Git/NDS_Pocket
D=${1:-29}; tag=${2:-w2l}
st=$main/build/census/states
roms=$main/roms
census=$main/build/census-melonds/build/census
[ -x "$root/build/census-melonds/build/census" ] && census=$root/build/census-melonds/build/census
d=$root/build/scenes/pkw2-load; o=$d/w2load-$tag
mkdir -p "$o"
echo "0 1000000 DOWN" > "$o/hold.txt"
cen() { "$census" --bios9 "$roms/bios9.bin" --bios7 "$roms/bios7.bin" --firmware "$roms/firmware.bin" --rom "$roms/pkw2.nds" \
        --script "$o/hold.txt" "$@"; }

# 1. the state, once (melonDS, seconds)
if [ ! -f "$st/pkw2-load.mln" ]; then
  [ -f "$st/pkw2-exit.mln" ] || { echo "no $st/pkw2-exit.mln"; exit 1; }
  cen --out "$o/cut" --load-state "$st/pkw2-exit.mln" --frames 115 --shot-every 0 \
      --save-state "$st/pkw2-load.mln" --save-state-at 114 > "$o/cut.log" 2>&1
fi

# (run.py --frames counts video frames from power-on: the scene's frames + 9 cover ~10 before the release, so D
# must stay below frames - 1; scenes.txt has 32, the release comes at video frame 10)
# 2. the Pocket model (SKIP_POCKET=1: compare the last run again) (the scene's export and melonDS frames are made by scenes.py)
[ -n "${SKIP_POCKET:-}" ] || python3 "$root/sim/pocket_ds/scenes.py" --only pkw2-load --tag "$tag" \
    --plus "dump_frame=$D" --plus "dump_file=$o/pocket_main.bin" --plus "gxlog=$o/pocket_gx.bin" | tee "$o/scene.txt" || true
[ -f "$o/pocket_main.bin" ] || { echo "the Pocket run made no RAM dump (see $d/run-$tag.log)"; exit 2; }

# 3. melonDS over the same window: GX entries from the release (e0) to 12 frames past D; main RAM at D-3..D + e0
# (the Pocket can be a frame or two behind: w2load_cmp.py takes the closest) and 16 frames later (what stays)
e0=$(awk '{print $2}' "$d/exp/clean.txt" 2>/dev/null || echo 0)
mels=()
for f in $((D - 3)) $((D - 2)) $((D - 1)) $D $((D + 16)); do
  cen --out "$o/m$f" --load-state "$st/pkw2-load.mln" --frames $((e0 + f)) --shot-every 0 --final-state "$o/m$f.mln" > "$o/m$f.log" 2>&1
  cen --out "$o/m$f" --load-state "$o/m$f.mln" --export-state "$o/m$f/exp" >> "$o/m$f.log" 2>&1
  mels+=("$o/m$f/exp/main.bin")
done
cen --out "$o/mgx" --load-state "$st/pkw2-load.mln" --frames $((e0 + D + 12)) --shot-every 0 \
    --gx-first "$e0" --gx-frames $((D + 12)) --vram-every 1000000 > "$o/mgx.log" 2>&1

# 4. compare
python3 "$root/sim/pocket_ds/w2load_cmp.py" "$o/pocket_main.bin" "$d/exp/main.bin" "${mels[@]}" "$o/pocket_gx.bin" "$o/mgx/gx.bin" | tee "$o/cmp.txt"
