# System blocks (docs/system-blocks.md): DMA, timers, IRQ, IPC, DIV/SQRT in
# Verilator against the melonDS-derived golden model.
#   make test-sys                       all blocks, seed 1
#   make test-sys SYS_ARGS='--seed 7 --only dma --scale 4'
SYS_BUILD  := build/sys
SYS_RTL    := rtl/ds/nds_dsp_add.sv rtl/sys/sys_ram.sv rtl/sys/sys_irq.sv rtl/sys/sys_timers.sv rtl/sys/sys_ipc.sv \
              rtl/sys/sys_math.sv rtl/sys/sys_dma.sv rtl/sys/nds_sys.sv
SYS_TB     := $(SYS_BUILD)/obj/Vnds_sys
SYS_ARGS   ?=
SYS_VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module nds_sys

.PHONY: test-sys sys-mutate

$(SYS_TB): $(SYS_RTL) sim/sys/tb_sys.cpp sim/sys/golden_sys.h sim/sys/sys.mk
	@mkdir -p $(SYS_BUILD)/obj
	$(VERILATOR) $(SYS_VFLAGS) --Mdir $(SYS_BUILD)/obj -CFLAGS "-std=c++20 -O2 -I$(abspath sim/sys)" \
	  $(SYS_RTL) $(abspath sim/sys/tb_sys.cpp) >$(SYS_BUILD)/verilator.log 2>&1 \
	  || { tail -40 $(SYS_BUILD)/verilator.log; exit 1; }

test-sys: $(SYS_TB)
	$(SYS_TB) $(SYS_ARGS)

# Deliberate bugs the tests must catch (sim/sys/mutate.sh)
sys-mutate:
	@sim/sys/mutate.sh
