#!/bin/sh
# Runs the hwref programs in the melonDS census runner (DLDI SD folder) and
# collects their /hwref/ output in OUT (docs/hw-reference.md).
#   tools/hwref/run_melonds.sh OUT [prog...]     (default: gxtime cap3d)
# ROMS: folder with bios9.bin, bios7.bin, firmware.bin (default: roms/ of the
# main checkout). CENSUS: runner binary. FRAMES: frames to run (3600).
# SD_SEED: a folder copied onto the SD card first (replay3d's replay/).
# SD_MB: SD image size (64). Extra environment (GX_CHEAP=...) passes
# through to melonDS.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1; shift
[ $# -gt 0 ] || set -- gxtime cap3d
roms=${ROMS:-$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/../roms}
census=${CENSUS:-$root/build/census-melonds/build/census}
mkdir -p "$root/build"
tmp=$(mktemp -d -p "$root/build" hwref-run.XXXXXX)   # on disk: /tmp may be a full tmpfs
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/script.txt"
mkdir -p "$out"
for p in "$@"; do
    mkdir -p "$tmp/$p/sd"
    [ -z "${SD_SEED:-}" ] || cp -r "$SD_SEED/." "$tmp/$p/sd/"
    "$census" --bios9 "$roms/bios9.bin" --bios7 "$roms/bios7.bin" --firmware "$roms/firmware.bin" \
        --rom "$root/build/hwref/$p.nds" --script "$tmp/script.txt" --out "$tmp/$p/run" \
        --frames ${FRAMES:-3600} --shot-every ${FRAMES:-3600} --sd-dir "$tmp/$p/sd" --sd-mb ${SD_MB:-64} 2>&1 | grep -v 'incomplete SD write' || true
    [ -d "$tmp/$p/sd/hwref" ] || { echo "$p: no /hwref output" >&2; exit 1; }
    if find "$tmp/$p/sd/hwref" -type f -size 0 | grep -q .; then echo "$p: empty output files (disk full?)" >&2; exit 1; fi
    find "$tmp/$p/sd/hwref" -maxdepth 1 -type f -exec cp -t "$out/" {} +
    cp "$tmp/$p/run/shots/f$(printf %06d ${FRAMES:-3600}).ppm" "$out/$p-screen.ppm"
done
echo "results in $out"
