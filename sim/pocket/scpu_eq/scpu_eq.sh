#!/usr/bin/env bash
# nds_cart_scpu equivalence: the working tree's cache and firmware against REF's, seeds 1..N.
#   scpu_eq.sh [REF] [seeds] [reads] [SLOTS]
# MUTATE_FILE=<rtl or firmware .c in the tree> MUTATE_EXPR='<sed expr>' mutates a copy for the new side.
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-HEAD}; seeds=${2:-8}; reads=${3:-2000}; slots=${4:-24}
out=build/scpu_eq; rm -rf "$out"; mkdir -p "$out"
git show "$ref:rtl/pocket/nds_cart_scpu.sv" | sed 's/^module nds_cart_scpu\b/module nds_cart_scpu_ref/' > "$out/ref.sv"
git show "$ref:sw/scpu/cache.bin" > "$out/ref.bin"
cp rtl/pocket/nds_cart_scpu.sv "$out/new.sv"; cp sw/scpu/cache.bin "$out/new.bin"
if [ -n "${MUTATE_FILE:-}" ]; then
    case "$MUTATE_FILE" in
    *.sv) sed -i -e "$MUTATE_EXPR" "$out/new.sv"; cmp -s rtl/pocket/nds_cart_scpu.sv "$out/new.sv" && { echo "mutation did not change it"; exit 2; } ;;
    *.c)  cp sw/scpu/cache.c "$out/cache.c"; sed -i -e "$MUTATE_EXPR" "$out/cache.c"; cmp -s sw/scpu/cache.c "$out/cache.c" && { echo "mutation did not change it"; exit 2; }
          clang --target=riscv32 -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-builtin -fuse-ld=lld -Wl,-T,sw/scpu/link.ld sw/scpu/start.s "$out/cache.c" -o "$out/cache.elf"
          llvm-objcopy -O binary "$out/cache.elf" "$out/new.bin" ;;
    esac
fi
verilator --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINMISSING -GSLOTS="$slots" \
    --top-module tb_scpu_eq --Mdir "$out/obj" "$out/new.sv" "$out/ref.sv" rtl/serv/*.v sim/pocket/scpu_eq/tb_scpu_eq.sv \
    "$PWD/sim/pocket/scpu_eq/scpu_eq.cpp" > "$out/build.log" 2>&1 || { grep -E "%Error" "$out/build.log" | head; exit 1; }
pass=0
for s in $(seq 1 "$seeds"); do
    ok=1
    for strict in 1 0; do
        "$out/obj/Vtb_scpu_eq" --seed "$s" --ref "$out/ref.bin" --new "$out/new.bin" --reads "$reads" --strict $strict | tail -2 | tee -a "$out/runs.log" | cut -c1-170
        tail -1 "$out/runs.log" | grep -q '^PASS' || ok=0
    done
    pass=$((pass + ok))
done
echo "scpu_eq: $pass/$seeds seeds pass"
[ "$pass" = "$seeds" ]
