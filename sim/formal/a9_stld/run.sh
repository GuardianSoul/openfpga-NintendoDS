#!/usr/bin/env bash
# sim/formal/a9_stld/run.sh: the proof (BMC depth 30 + ABC PDR), its covers, and the mutant (no h_sl) that must fail
set -euo pipefail
cd "$(dirname "$0")"
export PATH=${TOOLS:-build/tools/oss-cad-suite/bin}:$PATH
sed 's/ || h_bub || h_sl;/ || h_bub;   \/\/ (mutant: no h_sl)/' ../../../rtl/arm/arm9_core.sv > arm9_core_mut.sv
cmp -s ../../../rtl/arm/arm9_core.sv arm9_core_mut.sv && { echo "mutation changed nothing"; exit 2; }
sby -f a9_stld.sby bmc   | tail -1
sby -f a9_stld.sby prove | tail -1
sby -f a9_stld_chk.sby cover | grep -E "Reached cover|Unreached|DONE"
out=$(sby -f a9_stld_chk.sby mutant 2>&1 || true)
if echo "$out" | grep -q "DONE (FAIL"; then echo "mutant (no h_sl): caught"; else echo "mutant NOT caught"; exit 1; fi
rm -rf a9_stld_bmc a9_stld_prove a9_stld_chk_cover a9_stld_chk_mutant a9_stld a9_stld_chk arm9_core_mut.sv
