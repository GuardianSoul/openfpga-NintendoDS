# Integrated DS system (docs/phase2-integration.md).
#   make bootrom                 sw/boot -> build/boot/bootrom.hex (the boot ROM image)
#   make ds-sim                  build/ds/obj/Vnds_top (Verilator)
#   make test-ds                 the DS test ROMs (tools/ds-tests) in the system simulation
#   build/ds/obj/Vnds_top --rom F --frames N --shots DIR [--trace-dir DIR] ...  (sim/ds/tb_ds.cpp)
DS_SOUND ?= 0
DS_3D    ?= 0
DS_A7C   ?= 1
DS_THREADS ?= 1
DS_FAST  ?= 0
DS_CLK2X ?= 0   # 1: tb_ds drives nds_top's clk_2x (2 x clk_sys); 0 holds it low (nothing uses it yet)
DS_G     ?=                        # extra nds_top parameters (-GNAME=V), e.g. -GDMA9_RUN=0 (with DS_B=build/...)
DS_USORT ?= 1
DS_B     := build/ds$(if $(filter 1,$(DS_SOUND)),-snd,)$(if $(filter 1,$(DS_3D)),-3d,)$(if $(filter 1,$(DS_FAST)),-fast,)$(if $(filter 0,$(DS_USORT)),-gxsort,)$(if $(filter 0,$(DS_A7C)),-a7m,)$(if $(filter-out 1,$(DS_THREADS)),-t$(DS_THREADS),)
DS_RTL   := rtl/arm/arm_pkg.sv rtl/arm/arm_regfile.sv rtl/arm/arm_mul.sv rtl/arm/arm_thumb.sv \
            rtl/arm/arm_core.sv rtl/arm/arm7_ds.sv rtl/arm/arm9_ram.sv rtl/arm/arm9_mem.sv rtl/arm/arm_cpu.sv \
            rtl/arm/cdc_req.sv rtl/arm/cdc_fifo.sv rtl/arm/cdc_a7.sv rtl/arm/cpu_domain.sv \
            rtl/ds/nds_dsp_add.sv rtl/sys/sys_ram.sv rtl/sys/sys_irq.sv rtl/sys/sys_timers.sv rtl/sys/sys_ipc.sv \
            rtl/sys/sys_math.sv rtl/sys/sys_dma.sv rtl/sys/nds_sys.sv \
            rtl/gpu2d/gpu2d_pkg.sv rtl/gpu2d/gpu2d_ram.sv rtl/gpu2d/gpu2d_cache.sv rtl/gpu2d/gpu2d_bg.sv \
            rtl/gpu2d/gpu2d_obj.sv rtl/gpu2d/gpu2d.sv \
            rtl/sound/sound_ram.sv rtl/sound/sound.sv \
            rtl/ds/nds_ram.sv rtl/ds/nds_lcache.sv rtl/ds/nds_arm7_port.sv rtl/ds/nds_arm7_port_min.sv rtl/ds/nds_fabric.sv rtl/ds/nds_vram.sv \
            rtl/ds/nds_io.sv rtl/ds/nds_disp_refs.sv rtl/ds/nds_disp.sv rtl/ds/nds_cart.sv rtl/ds/nds_spi.sv rtl/ds/nds_rtc.sv rtl/ds/nds_wifi.sv rtl/ds/nds_wifi_mc.sv \
            rtl/gpu3d/gpu3d_pkg.sv rtl/gpu3d/gpu3d_div4.sv rtl/gpu3d/gpu3d_ram.sv rtl/gpu3d/gpu3d_edge.sv rtl/gpu3d/gpu3d_front.sv rtl/gpu3d/gpu3d_fpass.sv rtl/gpu3d/gpu3d_raster.sv \
            rtl/gpu3d/gpu3d_gxu_pkg.sv rtl/gpu3d/gpu3d_gxrom.sv rtl/gpu3d/gpu3d_gxrom_us.sv rtl/gpu3d/gpu3d_gxrom_ul.sv rtl/gpu3d/gpu3d_gxrom_uv.sv rtl/gpu3d/gpu3d_gxrom_uw.sv rtl/gpu3d/gpu3d_gxrom_uf.sv rtl/gpu3d/gpu3d_gxlight.sv rtl/gpu3d/gpu3d_gxvfin.sv rtl/gpu3d/gpu3d_gxdiv.sv rtl/gpu3d/gpu3d_gxfront.sv rtl/gpu3d/gpu3d_gxeng.sv rtl/gpu3d/gpu3d_gxsort.sv rtl/gpu3d/gpu3d_geom.sv rtl/ds/nds_blk_arb.sv rtl/ds/nds_g3d_plane.sv rtl/ds/nds_l3d_xscroll.sv rtl/ds/nds_fr_arb.sv rtl/ds/nds_mr_arb.sv rtl/ds/nds_g3d_store.sv rtl/ds/nds_g3d_ring.sv rtl/ds/nds_gpu3d.sv \
            rtl/ds/nds_top.sv
DS_TB    := $(DS_B)/obj/Vnds_top
DS_VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast --threads $(DS_THREADS) --savable sim/ds/ds_config.vlt \
             -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE \
             --top-module nds_top -GSOUND=$(DS_SOUND) -GGPU3D=$(DS_3D) -GCPU_FAST=$(DS_FAST) -GARM7_CACHE=$(DS_A7C) -GGX_USORT=$(DS_USORT) $(DS_G)
DS_CONFIG := $(DS_B)/verilator-config.txt
# A reused DS_B must rebuild when command-line parameters or clock drive
# change. Keep the stamp's mtime when the effective settings are identical.
.PHONY: ds-config-force
$(DS_CONFIG): ds-config-force
	@mkdir -p $(DS_B)
	@set -e; tmp='$@.tmp.'$$$$; trap 'rm -f "$$tmp"' 0; \
	  printf '%s\n' '$(subst ','"'"',$(VERILATOR))' '$(subst ','"'"',$(DS_VFLAGS))' 'DS_FAST=$(DS_FAST)' 'DS_CLK2X=$(DS_CLK2X)' > "$$tmp"; \
	  if cmp -s "$$tmp" '$@'; then rm -f "$$tmp"; else mv -f "$$tmp" '$@'; fi
BOOT_OBJS := $(BOOT_B)/boot9.o $(BOOT_B)/boot7.o $(BOOT_B)/key1.o $(BOOT_B)/import.o $(BOOT_B)/savelist.o

.PHONY: bootrom ds-sim test-ds test-ds-pocket

$(BOOT_B)/boot9.o: sw/boot/boot9.s
	@mkdir -p $(BOOT_B)
	$(CLANG) $(ASFLAGS_V5) $< -o $@

$(BOOT_B)/import.o: sw/boot/import.s
	@mkdir -p $(BOOT_B)
	$(CLANG) $(ASFLAGS_V5) $< -o $@

$(BOOT_B)/bootrom.bin: $(BOOT_OBJS) sw/boot/boot.ld
	$(LLD) -T sw/boot/boot.ld $(BOOT_OBJS) -o $(BOOT_B)/bootrom.elf
	$(OBJCOPY) -O binary $(BOOT_B)/bootrom.elf $@
	@test $$(stat -c %s $@) -le 8192 || { echo "boot ROM over 8 KiB"; exit 1; }

$(BOOT_B)/bootrom.hex: $(BOOT_B)/bootrom.bin
	$(PYTHON) -c "import sys,struct; d=open(sys.argv[1],'rb').read(); d+=b'\0'*(8192-len(d)); \
	open(sys.argv[2],'w').write(''.join('%08x\n'%w for w in struct.unpack('<2048I',d)))" $< $@

bootrom: $(BOOT_B)/bootrom.hex

# the checked-in copy the Quartus build uses (scripts/build_ds.sh) must equal the sources
.PHONY: bootrom-check bootrom-update
bootrom-check: $(BOOT_B)/bootrom.bin
	@cmp -s $< sw/boot/bootrom.bin && echo "sw/boot/bootrom.bin is current" || { echo "sw/boot/bootrom.bin is stale: make bootrom-update"; exit 1; }
bootrom-update: $(BOOT_B)/bootrom.bin
	cp $< sw/boot/bootrom.bin

$(DS_TB): $(DS_RTL) sim/ds/tb_ds.cpp sim/ds/ds.mk sim/ds/ds_config.vlt $(DS_CONFIG)
	@mkdir -p $(DS_B)/obj
	$(VERILATOR) $(DS_VFLAGS) --Mdir $(DS_B)/obj -CFLAGS "-std=c++17 -O2 -DCPU_FAST=$(DS_FAST) -DDS_CLK2X=$(DS_CLK2X)" \
	  $(DS_RTL) $(abspath sim/ds/tb_ds.cpp) >$(DS_B)/verilator.log 2>&1 \
	  || { grep -E '%Error' $(DS_B)/verilator.log | head -40; tail -5 $(DS_B)/verilator.log; exit 1; }

ds-sim: $(DS_TB) bootrom

# the same with FST waveforms (--fst F --fst-from C --fst-to C)
DS_TBF := $(DS_B)/objf/Vnds_top
$(DS_TBF): $(DS_RTL) sim/ds/tb_ds.cpp sim/ds/ds.mk sim/ds/ds_config.vlt $(DS_CONFIG)
	@mkdir -p $(DS_B)/objf
	$(VERILATOR) $(DS_VFLAGS) --trace-fst --Mdir $(DS_B)/objf -CFLAGS "-std=c++17 -O2 -DDS_FST -DCPU_FAST=$(DS_FAST) -DDS_CLK2X=$(DS_CLK2X)" \
	  $(DS_RTL) $(abspath sim/ds/tb_ds.cpp) >$(DS_B)/verilator-fst.log 2>&1 \
	  || { grep -E '%Error' $(DS_B)/verilator-fst.log | head -40; exit 1; }
ds-sim-fst: $(DS_TBF) bootrom

# the same with the ARM9 main-RAM shadow check (sim/ds/ds_memcheck.sv, run with +memcheck)
DS_TBC := $(DS_B)/objc/Vnds_top
$(DS_TBC): $(DS_RTL) sim/ds/tb_ds.cpp sim/ds/ds_memcheck.sv sim/ds/ds.mk sim/ds/ds_config.vlt $(DS_CONFIG)
	@mkdir -p $(DS_B)/objc
	$(VERILATOR) $(DS_VFLAGS) --Mdir $(DS_B)/objc -CFLAGS "-std=c++17 -O2 -DCPU_FAST=$(DS_FAST) -DDS_CLK2X=$(DS_CLK2X)" \
	  $(DS_RTL) sim/ds/ds_memcheck.sv $(abspath sim/ds/tb_ds.cpp) >$(DS_B)/verilator-chk.log 2>&1 \
	  || { grep -E '%Error' $(DS_B)/verilator-chk.log | head -40; exit 1; }
ds-sim-check: $(DS_TBC) bootrom

DS_TESTS ?= hello hello_m7 sys sys_m7 irq irq_m7 cart cart_m7 $(if $(filter 1,$(DS_3D)),g3d g3dtex,plane) latch win affdma dmau
# A test with tools/ds-tests/<rom>.md5 also has its last frame (f000120.ppm)
# checked against that hash: g3d's picture, the same with the polygon store
# in PSRAM and on chip (EXT_STORE 0), and as melonDS draws it.
# The test ROMs run in parallel (DS_JOBS, default 8: the desktop is also a
# Quartus fit node, so sims keep to about 16 of its 28 cores).
DS_JOBS ?= 8
.PHONY: qlint
qlint:
	$(PYTHON) tools/ds/qlint.py

test-ds: qlint ds-sim ds-tests bootrom-check
	@printf '%s\n' $(DS_TESTS) | xargs -P $(DS_JOBS) -I{} sh -c '$(DS_TB) --rom $(DT)/{}.nds \
	    --bios9 $(BOOT_ROMDIR)/bios9.bin --bios7 $(BOOT_ROMDIR)/bios7.bin --firmware $(BOOT_ROMDIR)/firmware.bin \
	    --frames 120 --result --quiet $$([ -f tools/ds-tests/{}.md5 ] && mkdir -p $(DS_B)/shot-{} && echo --shots $(DS_B)/shot-{} --shot-every 120) \
	    > $(DS_B)/{}.log 2>&1; rc=$$?; \
	    if [ $$rc = 0 ] && [ -f tools/ds-tests/{}.md5 ]; then \
	      (cd $(DS_B)/shot-{} && md5sum -c $(abspath tools/ds-tests)/{}.md5) >> $(DS_B)/{}.log 2>&1 || rc=1; fi; \
	    echo $$rc > $(DS_B)/{}.rc'
	@fail=0; for r in $(DS_TESTS); do \
	  printf '%-10s ' $$r; \
	  if [ "$$(cat $(DS_B)/$$r.rc)" = 0 ]; then echo PASS; else echo FAIL; fail=1; tail -3 $(DS_B)/$$r.log; fi; \
	done; exit $$fail

# test-ds on the exact nds_top parameters of this tree's Pocket build
# (core_top_ds.sv's defaults and its nds_top instance, tools/ds/pocket_params.py;
# POCKET_P="GPU3D=0" for the 3D-off build). Every build for the test Pocket runs it
# on its own commit first (compat.md "Pocket builds: tested parameter sets", #495).
test-ds-pocket:
	@mkdir -p build && $(PYTHON) tools/ds/pocket_params.py $(POCKET_P) > build/ds-pocket.args && cat build/ds-pocket.args
	xargs -d '\n' -a build/ds-pocket.args $(MAKE) test-ds

.PHONY: test-dma-local
test-dma-local:
	$(PYTHON) tools/ds/check_dma_local.py --tools $(TOOLS) --bios $(BOOT_ROMDIR)

# the state import's restore stub (sw/stateload, docs/state-import.md): checked in as
# sw/stateload/stateload.bin, as the boot ROM (the Laptop has no ARM toolchain)
$(BOOT_B)/stateload.bin: sw/stateload/stateload.s
	@mkdir -p $(BOOT_B)
	$(CLANG) $(ASFLAGS_V5) $< -o $(BOOT_B)/stateload.o
	$(LLD) -T sw/boot/boot.ld $(BOOT_B)/stateload.o -o $(BOOT_B)/stateload.elf
	$(OBJCOPY) -O binary $(BOOT_B)/stateload.elf $@
stateload-update: $(BOOT_B)/stateload.bin
	cp $< sw/stateload/stateload.bin

# SERV's ROM-cache firmware (rtl/pocket/nds_cart_scpu.sv), appended to nds_boot.bin after the boot ROM;
# sw/scpu/cache.bin is the checked-in copy (scpu-check / scpu-update, as the boot ROM)
build/scpu/cache.bin: sw/scpu/cache.c sw/scpu/start.s sw/scpu/link.ld
	@mkdir -p build/scpu
	$(CLANG) --target=riscv32 -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-builtin -Wall \
	    -fuse-ld=lld -Wl,--relax-gp -Wl,-T,sw/scpu/link.ld sw/scpu/start.s sw/scpu/cache.c -o build/scpu/cache.elf
	$(OBJCOPY) -O binary build/scpu/cache.elf $@
	@test $$(stat -c %s $@) -le 4096 || { echo "SERV firmware over 4 KiB"; exit 1; }
.PHONY: scpu-check scpu-update
scpu-check: build/scpu/cache.bin
	@cmp -s $< sw/scpu/cache.bin && echo "sw/scpu/cache.bin is current" || { echo "sw/scpu/cache.bin is stale: make scpu-update"; exit 1; }
scpu-update: build/scpu/cache.bin
	cp $< sw/scpu/cache.bin
