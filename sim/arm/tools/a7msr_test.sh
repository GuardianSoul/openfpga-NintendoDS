#!/bin/sh
# arm7_ds: an IRQ taken as an MSR commits (sim/arm/tb_a7_msr_irq.cpp); the 2-clock check must stay quiet.
#   a7msr_test.sh VERILATOR BUILD_DIR     (the CPU before S_IWAIT, afc78fe6: 1096 trips)
V=$1; B=$2
$V --cc --exe --build -j 4 -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
   -Wno-CASEINCOMPLETE -Wno-PINMISSING --top-module arm7_ds --Mdir $B -CFLAGS -std=c++17 rtl/arm/arm_pkg.sv rtl/arm/arm_mul.sv \
   rtl/arm/arm_thumb.sv rtl/arm/arm_regfile.sv rtl/arm/arm7_ds.sv sim/arm/tb_a7_msr_irq.cpp >/dev/null 2>&1 || { echo build failed; exit 1; }
$B/Varm7_ds > $B/out.txt 2>&1
n=$(grep -ac "arm7_ds:" $B/out.txt); echo "$(grep -a '^irqs' $B/out.txt), $n check errors"
[ "$n" = 0 ] && grep -aq "^irqs [1-9]" $B/out.txt
