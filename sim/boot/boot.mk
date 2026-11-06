# Direct-boot program pieces (sw/boot/): KEY1 secure-area decryption.
#   make test-boot                  sw/boot/key1.s on the ARM7 RTL vs sim/boot/key1_ref.c,
#                                   and key1_ref.c vs melonDS's own KEY1 code
# ROMs and BIOS stay outside the repo; MELONDS is shared with the other .mk files.
BOOT_B      := build/boot
BOOT_ROMDIR ?= $(HOME)/Git/NDS_Pocket/roms
BOOT_ROMS   ?= $(wildcard $(addprefix $(BOOT_ROMDIR)/,platinum.nds heartgold.nds kh358.nds mkds.nds nsmb.nds))
BOOT_BIOS7  ?= $(BOOT_ROMDIR)/bios7.bin

.PHONY: test-boot

$(BOOT_B)/key1_ref: sim/boot/key1_ref.c
	@mkdir -p $(BOOT_B)
	cc -O2 -Wall -Wextra -o $@ $<

$(BOOT_B)/oracle.cpp: sim/boot/gen_oracle.py $(MELONDS)/src/NDSCart.cpp
	@mkdir -p $(BOOT_B)
	$(PYTHON) sim/boot/gen_oracle.py $(MELONDS) $@

$(BOOT_B)/oracle: $(BOOT_B)/oracle.cpp
	c++ -O2 -std=c++17 -w -o $@ $<

$(BOOT_B)/%.o: sw/boot/%.s
	@mkdir -p $(BOOT_B)
	$(CLANG) $(ASFLAGS_V4) $< -o $@

$(BOOT_B)/key1_test.o: sim/boot/key1_test.s
	@mkdir -p $(BOOT_B)
	$(CLANG) $(ASFLAGS_V4) $< -o $@

$(BOOT_B)/key1_test.bin: $(BOOT_B)/key1_test.o $(BOOT_B)/key1.o
	$(LLD) --image-base=0 -Ttext=0x00008000 --entry=_start $^ -o $(BOOT_B)/key1_test.elf
	$(OBJCOPY) -O binary $(BOOT_B)/key1_test.elf $@

test-boot: $(B)/obj/Vtb_arm $(BOOT_B)/key1_ref $(BOOT_B)/oracle $(BOOT_B)/key1_test.bin
	@test -n "$(BOOT_ROMS)" || { echo "no ROMs in $(BOOT_ROMDIR) (set BOOT_ROMDIR=)" >&2; exit 1; }
	@$(PYTHON) sim/boot/run.py --sim $(B)/obj/Vtb_arm --build $(BOOT_B) --prog $(BOOT_B)/key1_test.bin \
	    --ref $(BOOT_B)/key1_ref --oracle $(BOOT_B)/oracle --bios7 $(BOOT_BIOS7) $(BOOT_ROMS)
