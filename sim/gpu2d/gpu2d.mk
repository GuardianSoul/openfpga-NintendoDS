# 2D engine (docs/2d-engine.md): Verilator model diffed pixel-exact against
# melonDS's 2D soft renderer, on synthetic scenes and census dumps.
#   make test-gpu2d                       built-in scenes
#   make test-gpu2d G2D_ARGS='--dump build/census/gpu2d/heartgold.g2d'
TOOLS      ?= build/tools/oss-cad-suite/bin
VERILATOR  ?= $(TOOLS)/verilator
MELONDS    ?= references/melonDS
G2D_BUILD  := build/gpu2d
G2D_RTL    := rtl/gpu2d/gpu2d_pkg.sv rtl/ds/nds_ram.sv rtl/gpu2d/gpu2d_ram.sv rtl/gpu2d/gpu2d_cache.sv \
              rtl/gpu2d/gpu2d_bg.sv rtl/gpu2d/gpu2d_obj.sv rtl/gpu2d/gpu2d.sv
G2D_SIM    := sim/gpu2d/tb_gpu2d.cpp sim/gpu2d/golden2d.cpp sim/gpu2d/scenes2d.cpp sim/gpu2d/dump2d.cpp
G2D_GOLD   := $(addprefix $(G2D_BUILD)/golden/,GPU2D.cpp GPU2D.h GPU2D_Soft.cpp GPU2D_Soft.h GPU_ColorOp.h types.h)
G2D_TB     := $(G2D_BUILD)/obj/Vgpu2d
G2D_ARGS   ?=
G2D_VFLAGS := --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
              -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --top-module gpu2d

.PHONY: test-gpu2d

# melonDS's 2D renderer is compiled unmodified, copied next to nothing but
# itself so that its quoted includes resolve to sim/gpu2d/melonds_shim.
$(G2D_BUILD)/golden/%: $(MELONDS)/src/%
	@mkdir -p $(dir $@)
	cp $< $@

$(G2D_TB): $(G2D_RTL) $(G2D_SIM) $(G2D_GOLD) sim/gpu2d/state2d.h sim/gpu2d/golden2d.h \
           $(wildcard sim/gpu2d/melonds_shim/*.h) sim/gpu2d/gpu2d.mk
	@mkdir -p $(G2D_BUILD)/obj
	$(VERILATOR) $(G2D_VFLAGS) --Mdir $(G2D_BUILD)/obj \
	  -CFLAGS "-std=c++20 -O2 -I$(abspath sim/gpu2d) -I$(abspath sim/gpu2d/melonds_shim) -I$(abspath $(G2D_BUILD)/golden)" \
	  $(G2D_RTL) $(abspath $(G2D_SIM)) $(abspath $(G2D_BUILD)/golden/GPU2D.cpp) $(abspath $(G2D_BUILD)/golden/GPU2D_Soft.cpp) \
	  >$(G2D_BUILD)/verilator.log 2>&1 || { tail -40 $(G2D_BUILD)/verilator.log; exit 1; }

test-gpu2d: $(G2D_TB)
	$(G2D_TB) $(G2D_ARGS)
