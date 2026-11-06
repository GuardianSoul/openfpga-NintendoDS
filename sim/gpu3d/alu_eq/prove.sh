#!/usr/bin/env bash
# SAT proof that gpu3d_gxeng's ALU result path (funnel shifter without reversal, truth-table logic unit) equals
# the one before (alu_eq.sv). MUT=1 proves a mutant instead (it must fail).
set -euo pipefail
d=$(cd "$(dirname "$0")" && pwd)
yosys=${YOSYS:-build/tools/oss-cad-suite/bin/yosys}
src=$d/alu_eq.sv
if [ "${MUT:-0}" = 1 ]; then src=$(mktemp --suffix .sv); sed 's/sh_a   = fsh ? kreg\[4:0\] : shl ? ~yo\[4:0\] : yo\[4:0\];/sh_a = fsh ? kreg[4:0] : shl ? 5'"'"'d31 - yo[4:0] + 5'"'"'d1 : yo[4:0];/' "$d/alu_eq.sv" > "$src"; grep -q "5'd31 - yo" "$src"; fi
"$yosys" -q -p "plugin -i slang; read_slang --top miter $src; prep -top miter; flatten; opt; sat -prove ok 1 -verify" && echo "alu_eq: PROVED"
