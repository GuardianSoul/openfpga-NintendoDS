# New-only probe; no historical menu, trip, card path or deploy script edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/a7mulphase-v1
DEVKITPRO ?= $(HOME)/devkitpro
CC := $(DEVKITPRO)/devkitARM/bin/arm-none-eabi-gcc
CALICO := $(DEVKITPRO)/calico
BUILD_INPUTS := protocol.h arm7.c kernel.S main.c quiet.itcm.c Makefile ../common/hwref.c ../common/hwref.h ../Makefile ../wramarb/linker.py
BUILD_ID := $(shell cat $(BUILD_INPUTS) | sha256sum | cut -d' ' -f1)
CFLAGS7 := -O2 -g -Wall -mcpu=arm7tdmi -mthumb -D__NDS__ -DARM7 -I$(CALICO)/include -ffunction-sections -fdata-sections -include $(OUT)/build-id.h
OBJS7 := $(OUT)/obj7/arm7.o $(OUT)/obj7/kernel.o
.PHONY: all FORCE
all: $(OUT)/a7mulphase7.elf
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=a7mulphase \
	 a7mulphase_SRC='a7mulphase/main.c a7mulphase/quiet.itcm.c' \
	 a7mulphase_TITLE='hwref ARM7 MUL phases;NDS_Pocket;new-only software qualification' \
	 ARM7=$(OUT)/a7mulphase7.elf EXTRA='-DHWREF_DIR=\"fat:/hwref/a7mulphase-v1\" -include $(OUT)/build-id.h' $(OUT)/a7mulphase.nds
$(OBJS7): $(OUT)/build-id.h
$(OUT)/build-id.h: FORCE
	@mkdir -p $(dir $@)
	@printf '#define MP_BUILD_ID "%s"\n' '$(BUILD_ID)' > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@
$(OUT)/obj7/%.o: %.c protocol.h Makefile
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS7) -MMD -c $< -o $@
$(OUT)/obj7/%.o: %.S Makefile
	@mkdir -p $(dir $@)
	$(CC) -g -mcpu=arm7tdmi -marm -c $< -o $@
$(OUT)/private-ds7.ld: $(CALICO)/lib/ds7.ld ../wramarb/linker.py
	@mkdir -p $(dir $@)
	python3 ../wramarb/linker.py $< $@
$(OUT)/a7mulphase7.elf: $(OBJS7) $(OUT)/private-ds7.ld
	$(CC) -specs=$(CALICO)/share/ds7.specs -mcpu=arm7tdmi -L$(CALICO)/lib -Wl,-T,$(OUT)/private-ds7.ld -Wl,-Map,$@.map $(OBJS7) -lcalico_ds7 -o $@
-include $(OUT)/obj7/*.d
