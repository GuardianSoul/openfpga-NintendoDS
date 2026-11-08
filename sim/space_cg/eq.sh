#!/bin/bash
# sim/space_cg/eq.sh FILE.sv GOLD GATE [GATE...]: SAT miter proof (combinational, all inputs) per gate; then Yosys
# synth_intel_alm LUT/arith/FF counts per module
Y=build/tools/oss-cad-suite/bin/yosys
f=$1; g=$2; shift 2; L=build/space_cg/$(basename ${f%.sv}); mkdir -p build/space_cg
for m in "$@"; do
  log="$L.$m.sat.log"
  $Y -p "read_verilog -sv $f; prep; miter -equiv -flatten -make_assert $g $m miter; hierarchy -top miter; flatten; sat -verify -prove-asserts miter" > "$log" 2>&1
  rc=$?
  echo "$g vs $m: exit $rc: $(grep -o 'SAT proof finished - no model found: SUCCESS!\|SAT proof finished - model found: FAIL!' $log | head -1)"
done
for m in $g "$@"; do
  $Y -p "read_verilog -sv $f; synth_intel_alm -top $m; flatten; stat" > "$L.$m.syn.log" 2>&1
  echo "$m: $(awk '/Printing statistics/{n++} n>=2' $L.$m.syn.log | grep -E 'MISTRAL_ALUT|MISTRAL_FF' | awk '{s[$2]+=$1} END {for (k in s) printf "%s=%d ", k, s[k]}')"
done
