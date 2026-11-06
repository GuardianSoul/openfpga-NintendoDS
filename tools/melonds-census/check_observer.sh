#!/bin/sh
# Observer check: the census hooks must not change emulation. Runs the same
# script with hooks installed, with no hooks, and with a deliberate mutation,
# and compares the per-frame framebuffer hashes.
# usage: check_observer.sh <rom> <script> <frames> [--save F]
# ROMS: directory with bios7/bios9/firmware (default <repo>/roms)
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
roms=${ROMS:-$root/roms}
bin="$root/build/census-melonds/build/census"
out="$root/build/census/observer"
rom=$1 script=$2 frames=$3; shift 3
common="--bios9 $roms/bios9.bin --bios7 $roms/bios7.bin --firmware $roms/firmware.bin --rom $rom --script $script --frames $frames --shot-every 0"
"$bin" $common "$@" --out "$out/hooks" 2>/dev/null
"$bin" $common "$@" --out "$out/nohooks" --no-hooks 1 2>/dev/null
"$bin" $common "$@" --out "$out/mutate" --mutate 1 2>/dev/null
hashes() { awk -F, 'NR>1 {print $NF}' "$1/frames.csv"; }
hashes "$out/hooks" > "$out/a"; hashes "$out/nohooks" > "$out/b"; hashes "$out/mutate" > "$out/c"
if cmp -s "$out/a" "$out/b"; then echo "PASS: hooked and unhooked runs match on all $frames frames"
else echo "FAIL: first differing frame $(cmp "$out/a" "$out/b" | awk '{print $NF}')"; exit 1; fi
if cmp -s "$out/a" "$out/c"; then echo "FAIL: mutation not detected"; exit 1
else echo "PASS: mutation detected (first differing line $(cmp "$out/a" "$out/c" | awk '{print $NF}'))"; fi
