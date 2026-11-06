# Run ONLY in the private prepared directory after explicit worker allocation.
# Preparing source/input maps does not need this target or a worker.
CC := clang
LD := ld.lld
OBJCOPY := llvm-objcopy
FLAGS := --target=armv5te-none-eabi -mcpu=arm946e-s -marm -O2 -ffreestanding -fno-builtin -fno-pic -fno-unwind-tables -fno-asynchronous-unwind-tables -nostdlib -Wall -Wextra $(MUTANT_DEFS)
ROOT ?= /home/user/Git/NDS_Pocket
.PHONY: all lease
all: lease ds41.nds
lease:
	@test -n "$(HWREF_BUILD_LEASE)" || { echo 'No worker lease: compilation remains queued'; exit 2; }
# Explicit prerequisite also guards parallel/manual object target invocation.
%.o: %.c | lease
	$(CC) $(FLAGS) -I. -c $< -o $@
%.o: %.S | lease
	$(CC) $(FLAGS) -I. -c $< -o $@
adapter.elf: boot.o invoke.o driver.o tables.o adapter.ld | lease
	$(LD) -T adapter.ld -Map=adapter.map boot.o invoke.o driver.o tables.o -o $@
arm9.bin: adapter.elf
	$(OBJCOPY) -O binary $< $@
arm7.elf: arm7.S | lease
	$(CC) --target=armv4t-none-eabi -mcpu=arm7tdmi -c $< -o arm7.o
	$(LD) -Ttext=0x03800000 arm7.o -o $@
arm7.bin: arm7.elf
	$(OBJCOPY) -O binary $< $@
ds41.nds: arm9.bin arm7.bin
	python3 $(ROOT)/tools/ds-tests/mknds.py $@ --title 'DS41 IO native' --code DI41 --arm9 arm9.bin --arm9-ram 0x02300000 --arm9-entry 0x02300000 --arm7 arm7.bin --arm7-ram 0x03800000
