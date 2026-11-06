# Standalone/new-only SDK envelope; no historical menu or shipped trip edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/arm7fetch-v1
DEVKITPRO ?= $(HOME)/devkitpro
CC := $(DEVKITPRO)/devkitARM/bin/arm-none-eabi-gcc
CALICO := $(DEVKITPRO)/calico
CFLAGS7 := -O2 -g -Wall -mcpu=arm7tdmi -mthumb -D__NDS__ -DARM7 -I$(CALICO)/include -ffunction-sections -fdata-sections
OBJS7 := $(OUT)/obj7/arm7.o $(OUT)/obj7/kernels.o $(OUT)/obj7/kernels-asm.o
.PHONY: all
all: $(OUT)/arm7fetch7.elf
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=arm7fetch \
	 arm7fetch_SRC='arm7fetch/main.c arm7fetch/quiet.itcm.c' \
	 arm7fetch_TITLE='hwref ARM7 fetch;NDS_Pocket;new-only source, not DS qualified' \
	 ARM7=$(OUT)/arm7fetch7.elf EXTRA='-DHWREF_DIR=\"fat:/hwref/arm7fetch-v1\"' $(OUT)/arm7fetch.nds
$(OUT)/obj7/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS7) -MMD -c $< -o $@
$(OUT)/obj7/kernels-asm.o: kernels.S
	@mkdir -p $(dir $@)
	$(CC) -g -mcpu=arm7tdmi -marm -c $< -o $@
$(OUT)/private-ds7.ld: $(CALICO)/lib/ds7.ld ../wramarb/linker.py
	@mkdir -p $(dir $@)
	python3 ../wramarb/linker.py $< $@
$(OUT)/arm7fetch7.elf: $(OBJS7) $(OUT)/private-ds7.ld
	$(CC) -specs=$(CALICO)/share/ds7.specs -mcpu=arm7tdmi -L$(CALICO)/lib -Wl,-T,$(OUT)/private-ds7.ld -Wl,-Map,$@.map $(OBJS7) -lcalico_ds7 -o $@
-include $(OUT)/obj7/*.d
