# 3D rasterizer (docs/renderer-3d.md): Verilator model diffed pixel-exact
# against melonDS's software renderer.
#   make test-gpu3d                  all built-in scenes
#   make test-gpu3d G3D_ARGS='--only aa --lat 0'
#   make test-gpu3d-area             the same with AREA=1 (half-rate pixel
#                                    pipeline, one shared divider)
#   make test-gpu3d-hwref            the hwref cap3d scenes (the DS-verified
#                                    rules' regression set, hwref-cap3d.tar.zst)
#   make test-gpu3d-stock            the melonDS-rule RTL (DS_* = 0) against
#                                    plain melonDS (-DMELONDS_STOCK)
#   make synth-gpu3d                 Yosys generic + Cyclone V cell counts
#   make test-gpu3d-rcache           the raster with the core's texture/palette caches (below)
TOOLS      ?= build/tools/oss-cad-suite/bin
VERILATOR  ?= $(TOOLS)/verilator
YOSYS      ?= $(TOOLS)/yosys
MELONDS    ?= references/melonDS
G3D_BUILD  := build/gpu3d
G3D_RTL    := rtl/gpu3d/gpu3d_pkg.sv rtl/gpu3d/gpu3d_div4.sv rtl/gpu3d/gpu3d_ram.sv rtl/gpu3d/gpu3d_edge.sv rtl/gpu3d/gpu3d_front.sv rtl/gpu3d/gpu3d_fpass.sv rtl/gpu3d/gpu3d_raster.sv
G3D_SIM    := sim/gpu3d/tb_gpu3d.cpp sim/gpu3d/golden.cpp sim/gpu3d/scenes.cpp
G3D_GOLD   := $(G3D_BUILD)/golden/GPU3D_Soft.cpp $(G3D_BUILD)/golden/GPU3D_Soft.h
G3D_TB     := $(G3D_BUILD)/obj/Vgpu3d_raster
G3D_ARGS   ?=

.PHONY: test-gpu3d-par test-gpu3d-rcache test-gpu3d test-gpu3d-area test-gpu3d-stock test-gpu3d-hwref synth-gpu3d

# melonDS's renderer is compiled unmodified; it is copied next to nothing
# but itself so that its quoted includes resolve to sim/gpu3d/melonds_shim.
$(G3D_BUILD)/golden/%: $(MELONDS)/src/%
	@mkdir -p $(dir $@)
	cp $< $@

# the golden is melonDS with the DS-verified rules (AGENTS.md:
# tools/melonds-census/ds-rules.patch, the census build's too); -DMELONDS_STOCK
# (test-gpu3d-stock) compiles them out
$(G3D_BUILD)/golden/GPU3D_Soft.cpp: $(MELONDS)/src/GPU3D_Soft.cpp $(MELONDS)/src/GPU3D_Soft.h tools/melonds-census/ds-rules.patch sim/gpu3d/golden_hooks.py
	@mkdir -p $(dir $@)
	cp $(MELONDS)/src/GPU3D_Soft.cpp $(MELONDS)/src/GPU3D_Soft.h $(dir $@)
	patch -s -p2 -d $(dir $@) < tools/melonds-census/ds-rules.patch
	python3 sim/gpu3d/golden_hooks.py $@
	touch $(dir $@)GPU3D_Soft.h   # newer than the hooked .cpp: the copy rule must not replace it
$(G3D_BUILD)/golden/GPU3D_Soft.h: $(G3D_BUILD)/golden/GPU3D_Soft.cpp

$(MELONDS)/src/GPU3D_Soft.cpp $(MELONDS)/src/GPU3D_Soft.h:
	@echo "missing $@: run 'git submodule update --init references/melonDS' or set MELONDS=" >&2; exit 1

$(G3D_TB): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(G3D_BUILD)/obj
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	  --Mdir $(G3D_BUILD)/obj --top-module gpu3d_raster \
	  -CFLAGS "-std=c++20 -O2 -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(G3D_BUILD)/verilator.log 2>&1 \
	  || { tail -40 $(G3D_BUILD)/verilator.log; exit 1; }

test-gpu3d: $(G3D_TB)
	$(G3D_TB) --out $(G3D_BUILD) $(G3D_ARGS)

G3D_TBF    := $(G3D_BUILD)/obj_area/Vgpu3d_raster
$(G3D_TBF): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(G3D_BUILD)/obj_area
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -GAREA=1 \
	  --Mdir $(G3D_BUILD)/obj_area --top-module gpu3d_raster \
	  -CFLAGS "-std=c++20 -O2 -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(G3D_BUILD)/verilator_area.log 2>&1 \
	  || { tail -40 $(G3D_BUILD)/verilator_area.log; exit 1; }

test-gpu3d-area: $(G3D_TBF)
	$(G3D_TBF) --out $(G3D_BUILD) $(G3D_ARGS)

# The core's own texture/palette caches (nds_g3d_cache / nds_g3d_cache2 from
# rtl/ds/nds_gpu3d.sv) and block port mux around the raster (sim/gpu3d/g3d_rc.sv),
# the block port served with --cache2's timing (--cache LAT: first beat;
# --cache-occ, --cache-jitter, --cache-stall). G3D_RC: -G options, e.g.
#   make test-gpu3d-rcache G3D_RC='-GTXD=5 -GTL=8 -GV2=1' G3D_ARGS='--cache2 --cache 23 --cache-occ 12 --profile'
G3D_RC     ?= -GTXD=5 -GTL=8 -GV2=1
G3D_RCN    := $(subst =,,$(subst -G,,$(subst $(eval) ,_,$(strip $(G3D_RC)))))
G3D_TBR    := $(G3D_BUILD)/obj_rc_$(G3D_RCN)/Vg3d_rc
$(G3D_TBR): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h sim/gpu3d/g3d_rc.sv rtl/ds/nds_gpu3d.sv rtl/ds/nds_lcache.sv $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(dir $@)
	sed -n '/^module nds_g3d_cache/,/^endmodule/p' rtl/ds/nds_gpu3d.sv > $(dir $@)nds_g3d_cache.sv
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINMISSING $(G3D_RC) \
	  --Mdir $(dir $@) --top-module g3d_rc \
	  -CFLAGS "-std=c++20 -O2 -DRCACHE -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) rtl/ds/nds_lcache.sv $(dir $@)nds_g3d_cache.sv sim/gpu3d/g3d_rc.sv \
	  $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(dir $@)verilator.log 2>&1 \
	  || { tail -40 $(dir $@)verilator.log; exit 1; }

test-gpu3d-rcache: $(G3D_TBR)
	$(G3D_TBR) --out $(G3D_BUILD) $(G3D_ARGS)

# Switched-off features (G3D_OFF, e.g. "aa toon fog atest"): the raster
# built with those FEAT_* = 0 against the golden on the scene with the same
# features disabled (tb --feat-off), one build per set
G3D_OFF    ?= aa toon fog atest
G3D_OFFN   := $(subst $(eval) ,_,$(strip $(G3D_OFF)))
G3D_TBP    := $(G3D_BUILD)/obj_off_$(G3D_OFFN)/Vgpu3d_raster
G3D_FEAT0  := $(foreach f,$(G3D_OFF),-GFEAT_$(shell echo $(f) | tr a-z A-Z)=0)
$(G3D_TBP): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL $(G3D_FEAT0) \
	  --Mdir $(dir $@) --top-module gpu3d_raster \
	  -CFLAGS "-std=c++20 -O2 -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(dir $@)verilator.log 2>&1 \
	  || { tail -40 $(dir $@)verilator.log; exit 1; }

test-gpu3d-off: $(G3D_TBP)
	$(G3D_TBP) --feat-off "$(G3D_OFF)" --out $(G3D_BUILD) $(G3D_ARGS)

# The raster with parameter overrides (G3D_PAR, Verilator -G flags) against
# the same golden, one build per set, e.g.
#   make test-gpu3d-par G3D_PAR='-GTOONR=1 -GLRING3=1 -GEMARR=1'
G3D_PAR    ?= -GTOONR=1 -GLRING3=1 -GEMARR=1
G3D_PARN   := $(subst =,,$(subst -G,,$(subst $(eval) ,_,$(strip $(G3D_PAR)))))
G3D_TBQ    := $(G3D_BUILD)/obj_par_$(G3D_PARN)/Vgpu3d_raster
$(G3D_TBQ): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL $(G3D_PAR) \
	  --Mdir $(dir $@) --top-module gpu3d_raster \
	  -CFLAGS "-std=c++20 -O2 -DDS_RULE_TOON -DDS_RULE_HILITE -DDS_RULE_LIN17 -DDS_RULE_LINZ -DDS_RULE_YPERSP -DDS_RULE_XPERSP16 -DDS_RULE_AACOV -DDS_RULE_AAYCOV -DDS_RULE_TEXRND -DDS_RULE_ZFACE -DDS_RULE_TEX4X4 -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(dir $@)verilator.log 2>&1 \
	  || { tail -40 $(dir $@)verilator.log; exit 1; }

test-gpu3d-par: $(G3D_TBQ)
	$(G3D_TBQ) --out $(G3D_BUILD) $(G3D_ARGS)

synth-gpu3d:
	@mkdir -p $(G3D_BUILD)/synth
	sim/gpu3d/synth_gpu3d.sh $(YOSYS) $(G3D_BUILD)/synth

G3D_TBS    := $(G3D_BUILD)/obj_stock/Vgpu3d_raster
$(G3D_TBS): $(G3D_RTL) $(G3D_SIM) $(G3D_GOLD) sim/gpu3d/scene.h $(wildcard sim/gpu3d/melonds_shim/*.h) sim/gpu3d/gpu3d.mk
	@mkdir -p $(G3D_BUILD)/obj_stock
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -GDS_AA0=0 -GDS_TOON=0 -GDS_HILITE=0 -GDS_LIN17=0 -GDS_LINZ=0 -GDS_YPERSP=0 -GDS_XPERSP16=0 -GDS_AACOV=0 -GDS_AAYCOV=0 -GDS_TEXRND=0 -GDS_ZFACE=0 -GDS_TEX4X4=0 \
	  --Mdir $(G3D_BUILD)/obj_stock --top-module gpu3d_raster \
	  -CFLAGS "-std=c++20 -O2 -DMELONDS_STOCK -I$(abspath sim/gpu3d) -I$(abspath sim/gpu3d/melonds_shim) -I$(abspath $(G3D_BUILD)/golden)" \
	  $(G3D_RTL) $(abspath $(G3D_SIM)) $(abspath $(G3D_BUILD)/golden/GPU3D_Soft.cpp) >$(G3D_BUILD)/verilator_stock.log 2>&1 \
	  || { tail -40 $(G3D_BUILD)/verilator_stock.log; exit 1; }

test-gpu3d-stock: $(G3D_TBS)
	$(G3D_TBS) --out $(G3D_BUILD) $(G3D_ARGS)

# hwref cap3d (docs/hw-reference.md) as renderer scenes: the census runner's GX
# trace of cap3d.nds through gx2scene, one scene per cap3d test in its order
test-gpu3d-hwref: $(G3D_TB)
	@mkdir -p $(G3D_BUILD)/hwref
	tar -C $(G3D_BUILD)/hwref --zstd -xf sim/gpu3d/hwref-cap3d.tar.zst
	$(G3D_TB) --out $(G3D_BUILD) $(G3D_ARGS) $$(for f in $(G3D_BUILD)/hwref/*.scn; do printf -- '--scene %s ' $$f; done)
