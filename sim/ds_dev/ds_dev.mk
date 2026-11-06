# ARM7 SPI bus (power manager, firmware flash, touchscreen) and RTC
# (rtl/ds/nds_spi.sv, rtl/ds/nds_rtc.sv) in Verilator, driven like ARM7 code.
#   make test-dsdev                              all, seed 1
#   make test-dsdev DSDEV_ARGS='--seed 7 --only fw'
#   make dsdev-mutate                            planted faults (sim/ds_dev/mutate.sh)
#   make synth-yosys-dsdev                       Yosys cell estimate per module
DSDEV_BUILD  := build/ds_dev
DSDEV_RTL    := rtl/ds/nds_dsp_add.sv rtl/ds/nds_spi.sv rtl/ds/nds_rtc.sv
DSDEV_TB     := $(DSDEV_BUILD)/obj/Vtb_ds_dev
DSDEV_FW     ?= $(HOME)/Git/NDS_Pocket/roms/firmware.bin
DSDEV_ARGS   ?=
DSDEV_VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
                -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module tb_ds_dev

.PHONY: test-dsdev dsdev-mutate synth-yosys-dsdev

$(DSDEV_TB): $(DSDEV_RTL) sim/ds_dev/tb_ds_dev.sv sim/ds_dev/tb_ds_dev.cpp sim/ds_dev/ds_dev.mk
	@mkdir -p $(DSDEV_BUILD)/obj
	$(VERILATOR) $(DSDEV_VFLAGS) --Mdir $(DSDEV_BUILD)/obj -CFLAGS "-std=c++20 -O2" \
	  $(DSDEV_RTL) sim/ds_dev/tb_ds_dev.sv $(abspath sim/ds_dev/tb_ds_dev.cpp) >$(DSDEV_BUILD)/verilator.log 2>&1 \
	  || { tail -40 $(DSDEV_BUILD)/verilator.log; exit 1; }

test-dsdev: $(DSDEV_TB)
	$(DSDEV_TB) --fw $(DSDEV_FW) $(DSDEV_ARGS)

dsdev-mutate:
	@sim/ds_dev/mutate.sh

synth-yosys-dsdev:
	@mkdir -p $(DSDEV_BUILD)
	@for m in nds_spi nds_rtc; do \
	  $(YOSYS) -m slang -q -l $(DSDEV_BUILD)/yosys_$$m.log -p "read_slang rtl/ds/$$m.sv --top $$m; \
	    synth_intel_alm -family cyclonev -top $$m; stat" > /dev/null || exit 1; \
	  echo "$$m:"; awk '/^=== /{n=0} /MISTRAL/{l[n++]=$$0} END{for(i=0;i<n;i++) print l[i]}' $(DSDEV_BUILD)/yosys_$$m.log; \
	done
