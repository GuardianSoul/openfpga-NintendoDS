# Sound engine (docs/sound.md): Verilator model diffed against melonDS's SPU on
# synthetic tests, random register traffic and census traces.
#   make test-sound                                  synthetic + 20 fuzz seeds
#   make test-sound SND_ARGS='--trace build/census/spu/mkds.spu'
TOOLS      ?= build/tools/oss-cad-suite/bin
VERILATOR  ?= $(TOOLS)/verilator
MELONDS    ?= references/melonDS
SND_BUILD  := build/sound
SND_RTL    := rtl/ds/nds_dsp_add.sv rtl/sound/sound_ram.sv rtl/sound/sound.sv
SND_SIM    := sim/sound/tb_sound.cpp sim/sound/golden_snd.cpp
SND_GOLD   := $(addprefix $(SND_BUILD)/golden/,SPU.cpp SPU.h types.h blip-buf/blip_buf.c blip-buf/blip_buf.h)
SND_TB     := $(SND_BUILD)/obj/Vsound
SND_ARGS   ?=
SND_VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module sound

.PHONY: test-sound

# melonDS's SPU is compiled unmodified, copied next to nothing but itself so
# that its quoted includes resolve to sim/sound/melonds_shim.
$(SND_BUILD)/golden/%: $(MELONDS)/src/%
	@mkdir -p $(dir $@)
	cp $< $@

# the golden is melonDS with the DS-verified sound rules (AGENTS.md: the DS
# is ground truth; tools/melonds-census/ds-rules-spu.patch, the census
# build's too). SND_STOCK=1 compiles them out.
$(SND_BUILD)/golden/SPU.cpp: $(MELONDS)/src/SPU.cpp tools/melonds-census/ds-rules-spu.patch
	@mkdir -p $(dir $@)
	cp $< $@
	patch -s -p2 -d $(dir $@) < tools/melonds-census/ds-rules-spu.patch
SND_RULES  := $(if $(SND_STOCK),-DMELONDS_STOCK,-DDS_RULE_SPU_CAPTURE -DDS_RULE_SPU_CAP8)

$(SND_TB): $(SND_RTL) $(SND_SIM) $(SND_GOLD) sim/sound/spu_trace.h sim/sound/golden_snd.h \
           $(wildcard sim/sound/melonds_shim/*.h) sim/sound/sound.mk
	@mkdir -p $(SND_BUILD)/obj
	$(VERILATOR) $(SND_VFLAGS) --Mdir $(SND_BUILD)/obj \
	  -CFLAGS "-std=c++20 -O2 $(SND_RULES) -I$(abspath sim/sound) -I$(abspath sim/sound/melonds_shim) -I$(abspath $(SND_BUILD)/golden)" \
	  $(SND_RTL) $(abspath $(SND_SIM)) $(abspath $(SND_BUILD)/golden/SPU.cpp) $(abspath $(SND_BUILD)/golden/blip-buf/blip_buf.c) \
	  >$(SND_BUILD)/verilator.log 2>&1 || { tail -40 $(SND_BUILD)/verilator.log; exit 1; }

test-sound: $(SND_TB)
	$(SND_TB) $(SND_ARGS)
