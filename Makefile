# NDS_Pocket checks. `make test` runs the ARM pipeline test ROMs in Verilator.
# Test ROM sources are fetched into local-assets/ (gitignored): `make fetch-tests`.

TOOLS     ?= build/tools/oss-cad-suite/bin
# One Verilator build at a time on this machine, at most 8 jobs (AGENTS.md; sim/pocket_ds/run.py takes the same lock)
VJOBS     ?= 8
VERILATOR ?= $(CURDIR)/tools/verilator-locked
export TOOLS
IVERILOG  ?= $(TOOLS)/iverilog
VVP       ?= $(TOOLS)/vvp
YOSYS     ?= $(TOOLS)/yosys
CLANG     ?= clang
LLD       ?= ld.lld
OBJCOPY   ?= llvm-objcopy
NM        ?= llvm-nm
PYTHON    ?= python3

ASSETS := local-assets/arm-tests
B      := build/arm

ARM_RTL := rtl/arm/arm_pkg.sv rtl/arm/arm_regfile.sv rtl/arm/arm_mul.sv \
           rtl/arm/arm_thumb.sv rtl/arm/arm_core.sv rtl/arm/arm7_ds.sv rtl/arm/arm9_ram.sv \
           rtl/arm/arm9_mem.sv rtl/arm/arm_cpu.sv
ARM_TB  := sim/arm/tb_arm.sv

# Pinned test ROM sources (docs/arm-pipeline.md)
GBA_TESTS_URL   := https://github.com/jsmolka/gba-tests.git
GBA_TESTS_REV   := a7113b67e63f83a9b321696ddd7042ccfad6c881
ARMWREST_URL    := https://github.com/destoer/armwrestler-gba-fixed.git
ARMWREST_REV    := 802e55ad61b421f4bbbc6f74f96aa4e5df4d630f
ROCKWREST_URL   := https://github.com/RockPolish/rockwrestler.git
ROCKWREST_REV   := b0067a06cddb9bbc9c46ecf0c60a2d572594e581

.PHONY: cdc-test cdc-mutate
# the clock crossings of rtl/arm/cpu_domain.sv (CPU_FAST): two-clock test at
# several ratios, and its deliberate bugs
cdc-test:
	@sim/arm/tools/cdc_test.sh $(VERILATOR) $(B)/cdc
cdc-mutate:
	@$(PYTHON) sim/arm/tools/cdc_mutate.py $(VERILATOR) $(B)/cdcmut
# the ARM7 port's crossings (rtl/arm/cdc_a7.sv) with nds_fr_arb and a fabric
# model: no deadlock, SRAM stores before later fabric stores
.PHONY: a7cross-test a7cross-mutate
a7cross-test:
	@sim/arm/tools/a7cross_test.sh $(VERILATOR) $(B)/a7cross
a7cross-mutate:
	@$(PYTHON) sim/arm/tools/a7cross_mutate.py $(VERILATOR) $(B)/a7crossmut

.PHONY: lcache-test lcache-pump dspadd-test lcache-mutate arm7port-eq arm7port-eq-mutate g3dcache-eq g3dcache-eq-mutate
# rtl/ds/nds_lcache.sv (M3, docs/phase2-integration.md) against a register
# valid array, and its deliberate bugs; nds_arm7_port against its version at
# EQ_REF (default: the commit before the last one that changed it), every
# output every cycle, and its deliberate bugs
EQ_REF ?= $(shell git log -2 --format=%h -- rtl/ds/nds_arm7_port.sv | tail -1)
lcache-test:
	@sim/ds/lcache_test.sh $(VERILATOR) build/lcache
# rtl/ds/nds_dsp_add.sv (an adder in a DSP block) against a + b
dspadd-test:
	@mkdir -p build && $(VERILATOR) --binary -j $(VJOBS) -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module tb_dsp_add \
	    -Mdir build/dspadd rtl/ds/nds_dsp_add.sv sim/ds/tb_dsp_add.sv > build/dspadd.log 2>&1 || { tail -20 build/dspadd.log; exit 1; }
	@build/dspadd/Vtb_dsp_add | grep -E '^(PASS|FAIL)'
lcache-mutate:
	@$(PYTHON) sim/ds/lcache_mutate.py $(VERILATOR) build/lcache-mut
# nds_lcache PUMP (the tag store double-pumped on clk_2x) against PUMP = 0, and its mutants
lcache-pump:
	@sim/ds/lcache_pump.sh $(VERILATOR) build/lcache-pump
arm7port-eq:
	@sim/ds/arm7port_eq.sh $(VERILATOR) build/a7eq $(EQ_REF)
arm7port-eq-mutate:
	@$(PYTHON) sim/ds/arm7port_eq_mutate.py $(VERILATOR) build/a7eq-mut $(EQ_REF)
# nds_g3d_cache against its version at G3D_REF (default: the commit before
# the last one that changed nds_gpu3d.sv), and its deliberate bugs
G3D_REF ?= $(shell git log -2 --format=%h -- rtl/ds/nds_gpu3d.sv | tail -1)
g3dcache-eq:
	@sim/ds/g3dcache_eq.sh $(VERILATOR) build/g3eq $(G3D_REF)
g3dcache-eq-mutate:
	@$(PYTHON) sim/ds/g3dcache_eq_mutate.py $(VERILATOR) build/g3eq-mut $(G3D_REF)

.PHONY: disp-refs-test disp-refs-mutate
# nds_disp's affine reference points in MLAB (rtl/ds/nds_disp_refs.sv) against
# the registers they replace, and their deliberate bugs
disp-refs-test:
	@sim/ds/disp_refs_test.sh $(VERILATOR) build/disp-refs
disp-refs-mutate:
	@$(PYTHON) sim/ds/disp_refs_mutate.py $(VERILATOR) build/disp-refs-mut

.PHONY: test test-icarus arm-equiv arm-mutate fetch-tests arm-images synth-yosys clean-arm

test: $(B)/obj/Vtb_arm $(B)/obj2/Vtb_arm arm-images
	@$(PYTHON) sim/arm/tools/run_tests.py --sim $(B)/obj/Vtb_arm --build $(B) --assets $(ASSETS)
	@echo "--- the same with the 2-way ARM9 caches (arm9_mem WAYS=2)"
	@$(PYTHON) sim/arm/tools/run_tests.py --sim $(B)/obj2/Vtb_arm --build $(B) --assets $(ASSETS)

# Icarus runs everything except armwrestler (1.5M cycles; Icarus is ~100x slower).
test-icarus: $(B)/tb_arm.vvp arm-images
	@$(PYTHON) sim/arm/tools/run_tests.py --sim "$(VVP) -n $(B)/tb_arm.vvp" --build $(B) \
	    --assets $(ASSETS) --only exc_dual,hazard_dual,rockwrestler,jsmolka_arm,jsmolka_thumb,dual,exc_dual_wait,hazard_dual_wait,dual_wait

# Equivalence against an earlier revision: same retired instructions, same
# architectural state after each one (sim/arm/tools/equiv.py)
REF ?= HEAD
arm-equiv: $(B)/obj/Vtb_arm arm-images
	@$(PYTHON) sim/arm/tools/equiv.py $(VERILATOR) $(B)/obj/Vtb_arm $(B) $(ASSETS) $(REF)

# Deliberate bugs that the test set must catch (sim/arm/tools/mutate.py)
arm-mutate: arm-images
	@$(PYTHON) sim/arm/tools/mutate.py $(VERILATOR) $(B) $(ASSETS)

fetch-tests:
	@mkdir -p $(ASSETS)
	@$(call fetch,gba-tests,$(GBA_TESTS_URL),$(GBA_TESTS_REV))
	@$(call fetch,armwrestler-gba-fixed,$(ARMWREST_URL),$(ARMWREST_REV))
	@$(call fetch,rockwrestler,$(ROCKWREST_URL),$(ROCKWREST_REV))

define fetch
	if [ ! -d $(ASSETS)/$(1)/.git ]; then git clone -q $(2) $(ASSETS)/$(1); fi; \
	git -C $(ASSETS)/$(1) fetch -q --depth 1 origin $(3) 2>/dev/null || git -C $(ASSETS)/$(1) fetch -q origin; \
	git -C $(ASSETS)/$(1) checkout -q $(3) && echo "$(1) @ $(3)"
endef

# ---- simulators
$(B)/obj/Vtb_arm: $(ARM_RTL) $(ARM_TB)
	@mkdir -p $(B)
	$(VERILATOR) --binary -j $(VJOBS) -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	    --top-module tb_arm -Mdir $(B)/obj $(ARM_RTL) $(ARM_TB) > $(B)/verilator.log 2>&1 \
	    || (cat $(B)/verilator.log; exit 1)

# the 2-way ARM9 caches (the cheaper option; 4-way stays the default)
$(B)/obj2/Vtb_arm: $(ARM_RTL) $(ARM_TB)
	@mkdir -p $(B)
	$(VERILATOR) --binary -j $(VJOBS) -O3 --x-assign fast --x-initial fast \
	    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -GARM9_WAYS=2 \
	    --top-module tb_arm -Mdir $(B)/obj2 $(ARM_RTL) $(ARM_TB) > $(B)/verilator2.log 2>&1 \
	    || (cat $(B)/verilator2.log; exit 1)

# the 2-way build's instruction streams against the 4-way default's (only
# timing may differ)
arm-equiv-2way: $(B)/obj2/Vtb_arm arm-images
	@$(PYTHON) sim/arm/tools/equiv.py $(VERILATOR) $(B)/obj2/Vtb_arm $(B) $(ASSETS) $(or $(REF),HEAD)

$(B)/tb_arm.vvp: $(ARM_RTL) $(ARM_TB)
	@mkdir -p $(B)
	$(IVERILOG) -g2012 -o $@ -s tb_arm $(ARM_RTL) $(ARM_TB) 2>&1 | grep -v 'sorry: constant selects' || true
	@test -f $@

# ---- test images
ASFLAGS_V4 := --target=armv4t-none-eabi -c
ASFLAGS_V5 := --target=armv5te-none-eabi -c

arm-images: $(B)/exc.hex $(B)/hazard0.hex $(B)/hazard1.hex $(B)/cache.hex \
            $(B)/bpred7.hex $(B)/bpred9.hex $(B)/halt.hex \
            $(B)/hazard_c.hex $(B)/rockwrestler_c.hex $(B)/jsmolka_thumb9c.hex \
            $(B)/stress_c.hex $(B)/stress1.hex $(B)/jsmolka_arm.hex $(B)/jsmolka_thumb.hex \
            $(B)/armwrestler.hex $(B)/armwrestler.hooks $(B)/rockwrestler.hex $(B)/lzcopy.hex $(B)/swflush.hex $(B)/evict.hex $(B)/ldruse2.hex

$(B)/%.o: sim/arm/tests/%.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

# cached ARM9 builds (cp15.inc: caches, MPU, TCMs on)
$(B)/%_c.o: sim/arm/tests/%.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests -Wa,-defsym,CACHED=1 $< -o $@

$(B)/gba_boot_c.bin: $(B)/gba_boot_c.o
	$(LLD) --image-base=0 -Ttext=0 --entry=_start $< -o $(B)/gba_boot_c.elf
	$(OBJCOPY) -O binary $(B)/gba_boot_c.elf $@

$(B)/jsmolka_thumb9c.hex: $(B)/gba_boot_c.bin $(ASSETS)/gba-tests/thumb/thumb.gba
	$(PYTHON) sim/arm/tools/mkhex.py $@ $(B)/gba_boot_c.bin@0 $(ASSETS)/gba-tests/thumb/thumb.gba@0x08000000

$(B)/hazard_c.bin: $(B)/hazard_c.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/hazard_c.elf
	$(OBJCOPY) -O binary $(B)/hazard_c.elf $@

$(B)/hazard_c.hex: $(B)/hazard_c.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/rockwrestler_c.bin: $(B)/rw_main_c.o $(B)/rw_armv4.o $(B)/rw_armv5.o $(B)/rw_interwork.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $^ -o $(B)/rockwrestler_c.elf
	$(OBJCOPY) -O binary $(B)/rockwrestler_c.elf $@

$(B)/rockwrestler_c.hex: $(B)/rockwrestler_c.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/exc.o: sim/arm/tests/exc.s
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) -Wa,-I,sim/arm/tests $< -o $@

$(B)/gba_boot.bin: $(B)/gba_boot.o
	$(LLD) --image-base=0 -Ttext=0 --entry=_start $< -o $(B)/gba_boot.elf
	$(OBJCOPY) -O binary $(B)/gba_boot.elf $@

$(B)/exc.bin: $(B)/exc.o
	$(LLD) --image-base=0 -Ttext=0 --entry=_start $< -o $(B)/exc.elf
	$(OBJCOPY) -O binary $(B)/exc.elf $@

$(B)/exc.hex: $(B)/exc.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0

$(B)/lzcopy.o: sim/arm/tests/lzcopy.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

$(B)/lzcopy.bin: $(B)/lzcopy.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/lzcopy.elf
	$(OBJCOPY) -O binary $(B)/lzcopy.elf $@

$(B)/lzcopy.hex: $(B)/lzcopy.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/cache.o: sim/arm/tests/cache.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

$(B)/cache.bin: $(B)/cache.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/cache.elf
	$(OBJCOPY) -O binary $(B)/cache.elf $@

$(B)/cache.hex: $(B)/cache.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/swflush.o: sim/arm/tests/swflush.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

$(B)/swflush.bin: $(B)/swflush.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/swflush.elf
	$(OBJCOPY) -O binary $(B)/swflush.elf $@

$(B)/swflush.hex: $(B)/swflush.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/ldruse2.o: sim/arm/tests/ldruse2.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

$(B)/ldruse2.bin: $(B)/ldruse2.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/ldruse2.elf
	$(OBJCOPY) -O binary $(B)/ldruse2.elf $@

$(B)/ldruse2.hex: $(B)/ldruse2.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/evict.o: sim/arm/tests/evict.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests $< -o $@

$(B)/evict.bin: $(B)/evict.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/evict.elf
	$(OBJCOPY) -O binary $(B)/evict.elf $@

$(B)/evict.hex: $(B)/evict.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/stress1.o: sim/arm/tests/stress.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) -Wa,-I,sim/arm/tests -Wa,-defsym,CTXOFF=64 $< -o $@

$(B)/stress%.bin: $(B)/stress%.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/stress$*.elf
	$(OBJCOPY) -O binary $(B)/stress$*.elf $@

$(B)/stress%.hex: $(B)/stress%.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/halt.o: sim/arm/tests/halt.s
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) $< -o $@

$(B)/halt.bin: $(B)/halt.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/halt.elf
	$(OBJCOPY) -O binary $(B)/halt.elf $@

$(B)/halt.hex: $(B)/halt.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

# bpred.s: ARMv4T for the ARM7, and ARMv5TE with caches and BLX for the ARM9
$(B)/bpred7.o: sim/arm/tests/bpred.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) -Wa,-I,sim/arm/tests $< -o $@

$(B)/bpred9.o: sim/arm/tests/bpred.s sim/arm/tests/cp15.inc
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V5) -Wa,-I,sim/arm/tests -Wa,-defsym,V5=1 -Wa,-defsym,CACHED=1 $< -o $@

$(B)/bpred%.bin: $(B)/bpred%.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/bpred$*.elf
	$(OBJCOPY) -O binary $(B)/bpred$*.elf $@

$(B)/bpred%.hex: $(B)/bpred%.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

# hazard.s is built twice, the second copy with its block transfers 64 bytes up
$(B)/hazard0.o: sim/arm/tests/hazard.s
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) -Wa,-I,sim/arm/tests $< -o $@

$(B)/hazard1.o: sim/arm/tests/hazard.s
	@mkdir -p $(B)
	$(CLANG) $(ASFLAGS_V4) -Wa,-I,sim/arm/tests -Wa,-defsym,CTXOFF=64 $< -o $@

$(B)/hazard%.bin: $(B)/hazard%.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $< -o $(B)/hazard$*.elf
	$(OBJCOPY) -O binary $(B)/hazard$*.elf $@

$(B)/hazard%.hex: $(B)/hazard%.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

$(B)/jsmolka_arm.hex: $(B)/gba_boot.bin $(ASSETS)/gba-tests/arm/arm.gba
	$(PYTHON) sim/arm/tools/mkhex.py $@ $(B)/gba_boot.bin@0 $(ASSETS)/gba-tests/arm/arm.gba@0x08000000

$(B)/jsmolka_thumb.hex: $(B)/gba_boot.bin $(ASSETS)/gba-tests/thumb/thumb.gba
	$(PYTHON) sim/arm/tools/mkhex.py $@ $(B)/gba_boot.bin@0 $(ASSETS)/gba-tests/thumb/thumb.gba@0x08000000

AW := $(ASSETS)/armwrestler-gba-fixed
$(B)/armwrestler.hex: $(B)/gba_boot.bin $(AW)/armwrestler-gba-fixed.gba
	$(PYTHON) sim/arm/tools/mkhex.py $@ $(B)/gba_boot.bin@0 $(AW)/armwrestler-gba-fixed.gba@0x08000000

# DrawResult, CheckKeys, _drawresult, _checkkeys from the shipped ELF
$(B)/armwrestler.hooks: $(AW)/armwrestler-gba-fixed.elf
	@mkdir -p $(B)
	$(NM) $< | awk '$$3=="DrawResult"{a=$$1} $$3=="CheckKeys"{b=$$1} \
	    $$3=="_drawresult"{c=$$1} $$3=="_checkkeys"{d=$$1} \
	    END{print "+hook0=" a " +hook1=" b " +hook2=" c " +hook3=" d}' > $@

RW := $(ASSETS)/rockwrestler/src9/tests
$(B)/rw_armv4.s: $(RW)/armv4.s sim/arm/tools/fix_gas_thumb.py
	$(PYTHON) sim/arm/tools/fix_gas_thumb.py $< $@
$(B)/rw_armv5.s: $(RW)/armv5.s sim/arm/tools/fix_gas_thumb.py
	$(PYTHON) sim/arm/tools/fix_gas_thumb.py $< $@
$(B)/rw_interwork.s: $(ASSETS)/rockwrestler/src9/framework/interwork.s
	cp $< $@
$(B)/rw_%.o: $(B)/rw_%.s
	$(CLANG) $(ASFLAGS_V5) $< -o $@

$(B)/rockwrestler.bin: $(B)/rw_main.o $(B)/rw_armv4.o $(B)/rw_armv5.o $(B)/rw_interwork.o
	$(LLD) --image-base=0 -Ttext=0x02000000 --entry=_start $^ -o $(B)/rockwrestler.elf
	$(OBJCOPY) -O binary $(B)/rockwrestler.elf $@

$(B)/rockwrestler.hex: $(B)/rockwrestler.bin
	$(PYTHON) sim/arm/tools/mkhex.py $@ $<@0x02000000

# ---- rough generic synthesis (no Quartus). synthesizes
# GBA_MiSTer's gba_cpu the same way, to calibrate against its Quartus number.
GBA_RTL := references/GBA_MiSTer/rtl
YOSYS_STAT = awk '/^=== $(1) ===/{on=1} on && /MISTRAL/{print}' $(2) | sort -u -k2

synth-yosys:
	@mkdir -p $(B)
	$(YOSYS) -m slang -q -l $(B)/yosys.log -p "read_slang -D SYNTHESIS $(ARM_RTL) --top arm_cpu --unroll-limit=100000; \
	    synth_intel_alm -family cyclonev -top arm_cpu; stat" > /dev/null
	@$(call YOSYS_STAT,arm_cpu,$(B)/yosys.log)
	$(YOSYS) -m slang -q -l $(B)/yosys_nolutram.log -p "read_slang -D SYNTHESIS $(ARM_RTL) --top arm_cpu --unroll-limit=100000; \
	    synth_intel_alm -family cyclonev -top arm_cpu -nolutram; stat" > /dev/null
	@$(call YOSYS_STAT,arm_cpu,$(B)/yosys_nolutram.log)


clean-arm:
	rm -rf $(B)

# ---- 3D rasterizer (docs/renderer-3d.md): pixel-exact diff against melonDS
include sim/gpu3d/gpu3d.mk
include sim/gpu3d/geom.mk
include sim/gpu2d/gpu2d.mk
include sim/sound/sound.mk
include sim/sys/sys.mk
include sim/ds_dev/ds_dev.mk
include sw/tests/tests.mk
test: test-gpu3d test-gpu2d test-sound test-sys test-dsdev

# ---- SD data-slot read probe (docs/sd-probe.md): APF host model, decoder, planted faults
.PHONY: test-probe
test-probe:
	@$(PYTHON) sim/probe/run.py --tools $(TOOLS)

# ---- Phase 1 test core (docs/phase1-foundation.md): whole chip with an APF host model, memory pin models, planted faults
.PHONY: test-phase1
test-phase1:
	@$(PYTHON) sim/phase1/run.py --tools $(TOOLS)

# ---- direct-boot program (sw/boot/): KEY1 secure area on the ARM7 RTL vs C reference vs melonDS
include sim/boot/boot.mk
include sim/ds/ds.mk

# The Pocket model (sim/pocket_ds) from saved melonDS scenes, with the tree's own core_top_ds
# parameters (NDS_DEBUG 0): the gate before a build goes on the card (docs/pocket-sim.md).
test-ds-pocket-scene:
	python3 sim/pocket_ds/scenes.py
.PHONY: test-ds-pocket-scene
