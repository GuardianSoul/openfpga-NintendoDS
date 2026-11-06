#!/usr/bin/env bash
# Mutation check for the sound harness: copy rtl/sound, apply one sed
# expression to one file, rebuild the testbench and expect a run to fail.
# Usage: sim/sound/mutate.sh <file-in-rtl/sound> '<sed expr>' [tb args...]
# Exit 0 when the mutation is caught, 1 when it is not.
set -euo pipefail
file=$1; expr=$2; shift 2
root=$(cd "$(dirname "$0")/../.." && pwd)
tag=$(printf '%s' "$file$expr" | md5sum | cut -c1-8)
work=$root/build/sound/mutant-$tag
rm -rf "$work"; mkdir -p "$work/rtl"
cp "${MUT_SRC:-$root/rtl/sound}"/*.sv "$work/rtl/"
before=$(md5sum "$work/rtl/$file")
sed -i -e "$expr" "$work/rtl/$file"
[ "$before" != "$(md5sum "$work/rtl/$file")" ] || { echo "mutation did not change $file" >&2; exit 2; }
make -s -C "$root" ${MELONDS:+MELONDS=$MELONDS} build/sound/obj/Vsound >/dev/null   # golden copies
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
g=$root/build/sound/golden
s=$root/sim/sound
"$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --Mdir "$work/obj" --top-module sound \
  -CFLAGS "-std=c++20 -O2 ${SND_RULES:--DDS_RULE_SPU_CAPTURE -DDS_RULE_SPU_CAP8} -I$s -I$s/melonds_shim -I$g" \
  "$work"/rtl/sound_ram.sv "$work"/rtl/sound.sv \
  "$s/tb_sound.cpp" "$s/golden_snd.cpp" "$g/SPU.cpp" "$g/blip-buf/blip_buf.c" \
  >"$work/verilator.log" 2>&1 || { tail -20 "$work/verilator.log"; exit 2; }
if timeout 3600 "$work/obj/Vsound" "$@" > "$work/run.log" 2>/dev/null; then
  echo "NOT CAUGHT: $file: $expr"; exit 1
else
  echo "caught: $file: $expr -> $(grep -c '^FAIL ' "$work/run.log") runs fail ($(grep -m1 '^FAIL ' "$work/run.log" | awk '{print $2}') first)"
fi
