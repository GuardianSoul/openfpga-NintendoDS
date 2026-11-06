# ---- DS test ROMs (tools/ds-tests/README.md): `make ds-tests`
# Each ROM is built twice: <rom>.nds with the ARM7 binary in shared WRAM at
# 0x037F8000 (as commercial games), <rom>_m7.nds with it in main RAM at
# 0x02380000. The ARM9 binary always loads and starts at 0x02000000.

DT        := build/ds-tests
DT_SRC    := sw/tests
DT_ROMS   := hello irq sys cart g3d plane cputime latch win dmacpu g3dtex affdma dmau unitmem unitgx unita7 unitcpu
DT_A7_w   := 0x037F8000
DT_A7_m   := 0x02380000
DT_CODE_hello := TSHE
DT_CODE_irq   := TSIR
DT_CODE_sys   := TSSY
DT_CODE_cart  := TSCA
DT_CODE_g3d   := TS3D
DT_CODE_g3dtex := TS3T
DT_CODE_plane := TSRP
DT_CODE_cputime := TSCT
DT_CODE_dmacpu := TSDC
DT_CODE_latch := TSLT
DT_CODE_win   := TSWN
DT_CODE_affdma := TSAD
DT_CODE_dmau  := TSDU
DT_CODE_unitmem := TSUM
DT_CODE_unitgx := TSUG
DT_CODE_unita7 := TSU7
DT_CODE_unitcpu := TSUC
DT_PAT_cart   := --pattern 0x20000:0x10000

DT_CF     := -O2 -marm -ffreestanding -fno-builtin -nostdlib -fno-pic -mfloat-abi=soft \
             -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Wno-unused-parameter
DT_CF9    := --target=armv5te-none-eabi -mcpu=arm946e-s $(DT_CF)
DT_CF7    := --target=armv4t-none-eabi -mcpu=arm7tdmi $(DT_CF)
DT_COMMON := $(wildcard $(DT_SRC)/common/*.h) $(DT_SRC)/common/crt0.s $(DT_SRC)/common/ds.ld

.PHONY: ds-tests ds-tests-melonds
ds-tests: $(foreach r,$(DT_ROMS),$(DT)/$(r).nds $(DT)/$(r)_m7.nds)

$(DT)/font.c: tools/ds-tests/mkfont.py
	@mkdir -p $(DT)
	$(PYTHON) $< $@

# $(1) = rom, $(2) = variant suffix (w|m), $(3) = output name
define DT_ROM
$(DT)/$(3)/arm9.elf: $(DT_SRC)/$(1)/arm9.c $(DT_SRC)/common/con.c $(DT_SRC)/common/results.c $(DT)/font.c $(DT_COMMON)
	@mkdir -p $(DT)/$(3)
	$(CLANG) --target=armv5te-none-eabi -mcpu=arm946e-s -Wa,-defsym,ARM9=1 -c $(DT_SRC)/common/crt0.s -o $(DT)/$(3)/crt0_9.o
	$(CLANG) $(DT_CF9) -DA7BASE=$(DT_A7_$(2)) -c $(DT_SRC)/$(1)/arm9.c -o $(DT)/$(3)/arm9.o
	$(CLANG) $(DT_CF9) -c $(DT_SRC)/common/con.c -o $(DT)/$(3)/con.o
	$(CLANG) $(DT_CF9) -c $(DT_SRC)/common/results.c -o $(DT)/$(3)/results.o
	$(CLANG) $(DT_CF9) -c $(DT)/font.c -o $(DT)/$(3)/font.o
	$(LLD) -T $(DT_SRC)/common/ds.ld --defsym=__base=0x02000000 $(DT)/$(3)/crt0_9.o $(DT)/$(3)/arm9.o \
	    $(DT)/$(3)/con.o $(DT)/$(3)/results.o $(DT)/$(3)/font.o -o $$@

$(DT)/$(3)/arm7.elf: $(DT_SRC)/$(1)/arm7.c $(DT_COMMON)
	@mkdir -p $(DT)/$(3)
	$(CLANG) --target=armv4t-none-eabi -mcpu=arm7tdmi -c $(DT_SRC)/common/crt0.s -o $(DT)/$(3)/crt0_7.o
	$(CLANG) $(DT_CF7) -DA7BASE=$(DT_A7_$(2)) -c $(DT_SRC)/$(1)/arm7.c -o $(DT)/$(3)/arm7.o
	$(LLD) -T $(DT_SRC)/common/ds.ld --defsym=__base=$(DT_A7_$(2)) $(DT)/$(3)/crt0_7.o $(DT)/$(3)/arm7.o -o $$@

$(DT)/$(3).nds: $(DT)/$(3)/arm9.elf $(DT)/$(3)/arm7.elf tools/ds-tests/mknds.py
	$(OBJCOPY) -O binary $(DT)/$(3)/arm9.elf $(DT)/$(3)/arm9.bin
	$(OBJCOPY) -O binary $(DT)/$(3)/arm7.elf $(DT)/$(3)/arm7.bin
	$(PYTHON) tools/ds-tests/mknds.py $$@ --title $(1) --code $(DT_CODE_$(1)) \
	    --arm9 $(DT)/$(3)/arm9.bin --arm9-ram 0x02000000 \
	    --arm7 $(DT)/$(3)/arm7.bin --arm7-ram $(DT_A7_$(2)) $(DT_PAT_$(1))
endef
$(foreach r,$(DT_ROMS),$(eval $(call DT_ROM,$(r),w,$(r))))
$(foreach r,$(DT_ROMS),$(eval $(call DT_ROM,$(r),m,$(r)_m7)))

# Golden check in melonDS (census runner, tools/melonds-census/README.md):
# 120 frames per ROM, a screenshot every 30 frames, a savestate at frame 119
# whose main RAM tools/ds-tests/check.py decodes into the result block.
CENSUS   ?= $(HOME)/Git/NDS_Pocket/build/census-melonds/build/census
DS_BIOS  ?= $(HOME)/Git/NDS_Pocket/roms
ds-tests-melonds: ds-tests
	@for r in $(DT_ROMS); do for v in "" _m7; do \
	    $(PYTHON) tools/ds-tests/check.py --census $(CENSUS) --bios $(DS_BIOS) \
	        --rom $(DT)/$$r$$v.nds --out $(DT)/melonds/$$r$$v || exit 1; \
	done; done
