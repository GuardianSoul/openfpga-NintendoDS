# Hardware-reference test programs (docs/hw-reference.md). devkitARM +
# libnds 2 (calico) + libfat; DEVKITPRO defaults to ~/devkitpro (the
# user-local install), /opt/devkitpro works too.
#   make -C sw/hwref            -> build/hwref/<program>.nds and hwref.nds (all)
DEVKITPRO ?= $(HOME)/devkitpro
DEVKITARM ?= $(DEVKITPRO)/devkitARM
CALICO := $(DEVKITPRO)/calico
LIBNDS := $(DEVKITPRO)/libnds
CC := $(DEVKITARM)/bin/arm-none-eabi-gcc
NDSTOOL := $(DEVKITPRO)/tools/bin/ndstool
LD := $(DEVKITARM)/bin/arm-none-eabi-ld
OBJCOPY := $(DEVKITARM)/bin/arm-none-eabi-objcopy

ROOT := $(abspath ../..)
OUT := $(ROOT)/build/hwref
ARCH := -march=armv5te -mtune=arm946e-s
CFLAGS := -O2 -g -Wall -Wno-missing-braces $(EXTRA) $(ARCH) -mthumb -D__NDS__ -DARM9 \
	-I$(CALICO)/include -I$(LIBNDS)/include -ffunction-sections -fdata-sections
LDFLAGS := -specs=$(CALICO)/share/ds9.specs $(ARCH) -L$(CALICO)/lib -L$(LIBNDS)/lib
LIBS := -lfat -lnds9 -lcalico_ds9 -lm
ARM7 := $(CALICO)/bin/ds7_maine.elf

PROGS := gxtime cap3d rules3d memtime sndcap rand3d replay3d gxcount dmacpu cputime lat2d load3d vramcnt gxburst sndq late3d tmcnt
ALL := $(OUT)/hwref.nds
COMMON := common/hwref.c
gxtime_SRC := gxtime/main.c gxtime/run.itcm.c
gxtime_TITLE := hwref GX timing;NDS_Pocket hw reference;results in /hwref/
cap3d_SRC := cap3d/main.c
cap3d_EXTRA := $(OUT)/obj/font.o
cap3d_TITLE := hwref 3D capture;NDS_Pocket hw reference;results in /hwref/
rules3d_SRC := rules3d/main.c
rules3d_EXTRA := $(OUT)/obj/font.o
rules3d_TITLE := hwref 3D rules;NDS_Pocket hw reference;results in /hwref/
memtime_SRC := $(wildcard memtime/*.c)
memtime_TITLE := hwref memory timing;NDS_Pocket hw reference;results in /hwref/
sndcap_SRC := $(wildcard sndcap/*.c)
sndcap_TITLE := hwref sound capture;NDS_Pocket hw reference;results in /hwref/
rand3d_SRC := rand3d/main.c rand3d/gen.c common/gxplay.c
rand3d_TITLE := hwref random 3D scenes;NDS_Pocket hw reference;results in /hwref/
replay3d_SRC := replay3d/main.c common/gxplay.c
replay3d_TITLE := hwref game frame replay;NDS_Pocket hw reference;results in /hwref/
gxcount_SRC := gxcount/main.c common/gxplay.c
gxcount_TITLE := hwref polygon/vertex counts;NDS_Pocket hw reference;results in /hwref/
dmacpu_SRC := dmacpu/main.c dmacpu/run.itcm.c
dmacpu_TITLE := hwref CPU during DMA;NDS_Pocket hw reference;results in /hwref/
cputime_SRC := cputime/main.c
cputime_TITLE := hwref ARM9 cycles per op;NDS_Pocket hw reference;results in /hwref/
lat2d_SRC := lat2d/main.c common/gxplay.c
lat2d_TITLE := hwref 2D latch timing;NDS_Pocket hw reference;results in /hwref/
load3d_SRC := load3d/main.c common/gxplay.c
load3d_TITLE := hwref 3D render load;NDS_Pocket hw reference;results in /hwref/
vramcnt_SRC := vramcnt/main.c vramcnt/run.itcm.c
vramcnt_TITLE := hwref VRAMCNT remap timing;NDS_Pocket hw reference;results in /hwref/
gxburst_SRC := gxburst/main.c common/gxplay.c
gxburst_TITLE := hwref GX DMA bursts;NDS_Pocket hw reference;results in /hwref/
sndq_SRC := sndq/main.c
sndq_TITLE := hwref sound questions;NDS_Pocket hw reference;results in /hwref/
late3d_SRC := late3d/main.c common/gxplay.c
late3d_TITLE := hwref late 3D lines;NDS_Pocket hw reference;results in /hwref/
tmcnt_SRC := tmcnt/main.c
tmcnt_TITLE := hwref TMCNT_H read-back;NDS_Pocket hw reference;results in /hwref/

all: $(PROGS:%=$(OUT)/%.nds) $(ALL) $(OUT)/arm7time.nds

# arm7time.nds: its own ARM7 program (calico's ds7 library, arm7time/arm7.c),
# so it isn't part of hwref.nds, which keeps calico's stock ARM7.
CFLAGS7 := -O2 -g -Wall -mcpu=arm7tdmi -mthumb -D__NDS__ -DARM7 -I$(CALICO)/include -ffunction-sections -fdata-sections
$(OUT)/obj7/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS7) -MMD -c $< -o $@
$(OUT)/arm7time7.elf: $(OUT)/obj7/arm7time/arm7.o
	$(CC) -specs=$(CALICO)/share/ds7.specs -mcpu=arm7tdmi -L$(CALICO)/lib $^ -lcalico_ds7 -o $@
ARM7TIME_OBJ := $(OUT)/obj/arm7time/main.o $(OUT)/obj/common/hwref.o
$(OUT)/arm7time.elf: $(ARM7TIME_OBJ)
	$(CC) $(LDFLAGS) $^ $(LIBS) -o $@
$(OUT)/arm7time.nds: $(OUT)/arm7time.elf $(OUT)/arm7time7.elf
	$(NDSTOOL) -c $@ -9 $< -7 $(OUT)/arm7time7.elf -b $(CALICO)/share/nds-icon.bmp "hwref ARM7 timing;NDS_Pocket hw reference;results in /hwref/" >/dev/null
-include $(OUT)/obj7/arm7time/arm7.d

define prog
$(1)_OBJ := $$(patsubst %.c,$(OUT)/obj/%.o,$$($(1)_SRC) $(COMMON))
$(OUT)/$(1).elf: $$($(1)_OBJ) $$($(1)_EXTRA)
	$(CC) $(LDFLAGS) $$^ $(LIBS) -o $$@
$(OUT)/$(1).nds: $(OUT)/$(1).elf
	$(NDSTOOL) -c $$@ -9 $$< -7 $(ARM7) -b $(CALICO)/share/nds-icon.bmp "$$($(1)_TITLE)" >/dev/null
endef
$(foreach p,$(PROGS),$(eval $(call prog,$(p))))

# ITCM code: ARM state, long calls out to main RAM.
$(OUT)/obj/%.itcm.o: %.itcm.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -marm -mlong-calls -MMD -c $< -o $@
$(OUT)/obj/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -c $< -o $@

# hwref.nds: every program in one run. Each program's objects are compiled
# again with main renamed, linked into one relocatable object, and all its
# symbols except the entry made local, so the programs can't collide.
# ITCM is shared by gxtime's and memtime's loops in hwref.nds: gxtime keeps
# 1232 samples (runs log a few hundred events) instead of 1536; vramcnt's
# kernels took the last 1 KiB.
CHAIN_DEFS := -DMAX_SAMPLES=1232
define chain
$(1)_COBJ := $$(patsubst %.c,$(OUT)/chain/%.o,$$($(1)_SRC))
$(OUT)/chain/$(1).o: $$($(1)_COBJ) $$($(1)_EXTRA)
	$(LD) -r $$^ -o $$@.tmp
	$(OBJCOPY) --keep-global-symbol=hwref_main_$(1) $$@.tmp $$@
	rm -f $$@.tmp
endef
$(foreach p,$(PROGS),$(eval $(call chain,$(p))))
$(OUT)/chain/%.itcm.o: %.itcm.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(CHAIN_DEFS) -marm -mlong-calls -Dmain=hwref_main_$(word 1,$(subst /, ,$*)) -MMD -c $< -o $@.tmp
	# the linker script places ITCM code by file name (*.itcm.*), which ld -r
	# loses: prefix the sections instead, which ds9.ld also matches (.itcm.*)
	$(OBJCOPY) --prefix-alloc-sections=.itcm $@.tmp $@
	rm -f $@.tmp
$(OUT)/chain/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(CHAIN_DEFS) -Dmain=hwref_main_$(word 1,$(subst /, ,$*)) -MMD -c $< -o $@
$(OUT)/hwref.elf: $(OUT)/obj/all/main.o $(PROGS:%=$(OUT)/chain/%.o) $(OUT)/obj/common/hwref.o
	$(CC) $(LDFLAGS) $^ $(LIBS) -o $@
$(OUT)/hwref.nds: $(OUT)/hwref.elf
	$(NDSTOOL) -c $@ -9 $< -7 $(ARM7) -b $(CALICO)/share/nds-icon.bmp "hwref all programs;NDS_Pocket hw reference;results in /hwref/" >/dev/null

# The 8x8 font of the DS test ROMs (tools/ds-tests/mkfont.py).
$(OUT)/obj/font.c: $(ROOT)/tools/ds-tests/mkfont.py
	@mkdir -p $(dir $@)
	python3 $< $@
$(OUT)/obj/font.o: $(OUT)/obj/font.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(OUT)

-include $(shell find $(OUT)/obj -name '*.d' 2>/dev/null)
.PHONY: all clean
