#!/bin/sh
# Builds the replay3d set (docs/hw-reference.md "replay3d method") from the
# census GX traces: build/hwref/seed/hwref/replay/*.gxb and list.txt, ready
# for the card (hwref/replay/) and for run_melonds.sh (SD_SEED).
#   tools/hwref/replay-set.sh [CENSUS_DIR]   (default: build/census of the main checkout)
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
census=${1:-$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/../build/census}
out=$root/build/hwref/seed/hwref/replay
rm -rf "$out"
mkdir -p "$out"
while read -r trace name frame; do
    python3 "$root/tools/hwref/mkreplay.py" "$census/$trace/gx.bin" "$out/$name.gxb" --frame "$frame"
done <<'LIST'
kh358 kh6011 6011
kh358 kh6061 6061
kh-plaza khplaza 1813
kh-halloween khhallow 6509
replay/hg-ow hgtitle 689
replay/hg-ow hgow 1306
replay/hg-battle hgbattle 3380
hg-goldenrod hggold 2011
replay/mkds mkds 9030
replay/platinum-ow ptow 3021
replay/nsmb nsmb 6050
LIST
(cd "$out" && ls *.gxb > list.txt)
echo "$(wc -l < "$out/list.txt") replays in $out"
