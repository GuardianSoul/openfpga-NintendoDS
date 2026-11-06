#!/usr/bin/env bash
# nds_spi equivalence: rtl/ds/nds_spi.sv (or a mutant) against REF. spi_eq.sh [REF] [seeds] [new.sv]
set -euo pipefail
cd "$(dirname "$0")/../../.."
PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
ref=${1:-afc78fe6}; seeds=${2:-10}; src=${3:-rtl/ds/nds_spi.sv}
out=build/spi_eq/$(basename "$src" .sv); mkdir -p "$out"
git show "$ref:rtl/ds/nds_spi.sv" | sed 's/^module nds_spi\b/module nds_spi_ref/' > "$out/ref.sv"
pass=0
for s in $(seq 1 "$seeds"); do
    verilator --binary --timing -j 8 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL  -GSEED="$s" -GOPS="${OPS:-60000}" --top-module tb_spi_eq \
        --Mdir "$out/obj$s" "$src" "$out/ref.sv" rtl/ds/nds_dsp_add.sv sim/ds_dev/spi_eq/tb_spi_eq.sv > "$out/build.log" 2>&1 || { tail -20 "$out/build.log"; exit 1; }
    "$out/obj$s/Vtb_spi_eq" | grep -E '^(PASS|FAIL)' | tail -4 | tee "$out/run$s.log" | tail -1 | grep -q '^PASS' && pass=$((pass + 1)) || cat "$out/run$s.log"
    rm -rf "$out/obj$s"
done
echo "spi_eq: $pass/$seeds PASS"
[ "$pass" = "$seeds" ]
