# Geometry engine (docs/geometry-engine.md): Verilator model diffed against
# melonDS's GPU3D (the census build, tools/melonds-census/build.sh).
#   make geom-ucode                  regenerate the control store
#   make test-geom                   synthetic streams and the census traces
#   make geom-trace GEOM_TRACE=build/census/kh358/gx.bin
GEOM_BUILD ?= build/geom
GEOM_G     ?=                        # extra -G parameters (e.g. -GDIV_R4=1; use with GEOM_BUILD=...)
GEOM_RTL   := rtl/gpu3d/gpu3d_gxu_pkg.sv rtl/gpu3d/gpu3d_ram.sv rtl/gpu3d/gpu3d_gxrom.sv rtl/gpu3d/gpu3d_gxrom_us.sv \
              rtl/gpu3d/gpu3d_gxrom_ul.sv rtl/gpu3d/gpu3d_gxrom_uv.sv rtl/gpu3d/gpu3d_gxrom_uw.sv rtl/gpu3d/gpu3d_gxrom_uf.sv rtl/gpu3d/gpu3d_gxlight.sv rtl/gpu3d/gpu3d_gxvfin.sv rtl/gpu3d/gpu3d_gxdiv.sv rtl/gpu3d/gpu3d_gxfront.sv rtl/gpu3d/gpu3d_gxeng.sv \
              rtl/gpu3d/gpu3d_gxsort.sv rtl/gpu3d/gpu3d_geom.sv
GEOM_MELON := build/census-melonds
GEOM_USORT ?= 1                       # gpu3d_geom USORT: 1 sorts in the engine's microcode, 0 gpu3d_gxsort (obj-gxsort)
GEOM_LUNIT ?= 0                       # gpu3d_geom LUNIT: 1 adds the lighting unit gpu3d_gxlight (obj-lu)
GEOM_SPILL ?= 0                       # gpu3d_geom SPILL with a behavioural SDRAM (SP_SIM) and SP_ON=GEOM_SPON (obj...-sp)
GEOM_SPON  ?= 16
GEOM_FF    ?= 0                       # gpu3d_geom FF: the geometry redesign (USORT only; obj-ff)
GEOM_VFIN  ?= 0                       # gpu3d_geom VFIN: 1 adds the vertex-finish unit gpu3d_gxvfin (with LUNIT; obj-lu-vf)
GEOM_OBJ   := obj$(if $(filter 0,$(GEOM_USORT)),-gxsort,)$(if $(filter 1,$(GEOM_LUNIT)),-lu,)$(if $(filter 1,$(GEOM_VFIN)),-vf,)$(if $(filter 2,$(GEOM_VFIN)),-vf2,)$(if $(filter 1,$(GEOM_FF)),-ff,)$(if $(filter 1,$(GEOM_SPILL)),-sp,)
GEOM_TB    := $(GEOM_BUILD)/$(GEOM_OBJ)/Vgpu3d_geom
GEOM_ARGS  ?=
GEOM_CHEAP ?= 1                       # gpu3d_geom GX_CHEAP: the test bench gives melonDS the same table (GX_CHEAP)
GEOM_SMALL ?= 1                       # gpu3d_gxeng SMALL: 0 builds the first version (kept and tested)
GEOM_TRACE ?= build/census/kh358/gx.bin

.PHONY: geom-ucode test-geom geom-trace

rtl/gpu3d/gpu3d_gxrom.sv rtl/gpu3d/gpu3d_gxrom_us.sv rtl/gpu3d/gpu3d_gxrom_ul.sv rtl/gpu3d/gpu3d_gxrom_uv.sv rtl/gpu3d/gpu3d_gxrom_uw.sv rtl/gpu3d/gpu3d_gxrom_uf.sv rtl/gpu3d/gpu3d_gxu_pkg.sv: tools/gxasm/ucode.py tools/gxasm/asm.py tools/gxasm/isa.py
	$(PYTHON) tools/gxasm/ucode.py

# register-file addresses for the test bench (written with the control store)
$(GEOM_BUILD)/ucode.h: rtl/gpu3d/gpu3d_gxrom.sv
	@test -f $@ || $(PYTHON) tools/gxasm/ucode.py

geom-ucode: rtl/gpu3d/gpu3d_gxrom.sv

$(GEOM_MELON)/build/melonDS/src/libcore.a:
	@echo "missing $@: run tools/melonds-census/build.sh" >&2; exit 1

$(GEOM_TB): $(GEOM_RTL) $(GEOM_BUILD)/ucode.h sim/gpu3d/tb_geom.cpp tools/melonds-census/platform.cpp sim/gpu3d/geom.mk $(GEOM_MELON)/build/melonDS/src/libcore.a
	@mkdir -p $(GEOM_BUILD)/$(GEOM_OBJ)
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	  --Mdir $(GEOM_BUILD)/$(GEOM_OBJ) --top-module gpu3d_geom --public-flat-rw -GSMALL=$(GEOM_SMALL) -GUSORT=$(GEOM_USORT) -GLUNIT=$(GEOM_LUNIT) -GVFIN=$(GEOM_VFIN) -GFF=$(GEOM_FF) $(if $(filter 1,$(GEOM_SPILL)),-GSPILL=1 -GSP_SIM=1 -GSP_ON=$(GEOM_SPON),) -GGX_CHEAP=$(GEOM_CHEAP) $(GEOM_G) \
	  -CFLAGS "-std=c++20 -O2 -fwrapv -DGEOM_USORT=$(GEOM_USORT) -DGEOM_CHEAP=$(GEOM_CHEAP) -DGEOM_FF=$(GEOM_FF) -DGEOM_SPILL=$(GEOM_SPILL) -I$(abspath $(GEOM_BUILD)) -I$(abspath $(GEOM_MELON)/melonDS/src) -I$(abspath $(GEOM_MELON)/build/melonDS/src)" \
	  -LDFLAGS "$(abspath $(GEOM_MELON)/build/melonDS/src/libcore.a) $(abspath $(GEOM_MELON)/build/melonDS/src/teakra/src/libteakra.a) -lrt" \
	  $(GEOM_RTL) $(abspath sim/gpu3d/tb_geom.cpp) $(abspath tools/melonds-census/platform.cpp) >$(GEOM_BUILD)/$(GEOM_OBJ)/verilator.log 2>&1 \
	  || { tail -40 $(GEOM_BUILD)/$(GEOM_OBJ)/verilator.log; exit 1; }

# the equivalence build: the reference front (nds-fit #67) beside the current one
GEOM_EQ_TB := $(GEOM_BUILD)/eq/Vgpu3d_geom
$(GEOM_EQ_TB): $(GEOM_RTL) sim/gpu3d/ref/gpu3d_gxfront_ref.sv $(GEOM_BUILD)/ucode.h sim/gpu3d/tb_geom.cpp tools/melonds-census/platform.cpp sim/gpu3d/geom.mk $(GEOM_MELON)/build/melonDS/src/libcore.a
	@mkdir -p $(GEOM_BUILD)/eq
	$(VERILATOR) --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -DGEOM_EQ \
	  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
	  --Mdir $(GEOM_BUILD)/eq --top-module gpu3d_geom --public-flat-rw -GSMALL=$(GEOM_SMALL) -GUSORT=$(GEOM_USORT) -GGX_CHEAP=0 \
	  -CFLAGS "-std=c++20 -O2 -fwrapv -DGEOM_EQ -DGEOM_USORT=$(GEOM_USORT) -DGEOM_CHEAP=0 -I$(abspath $(GEOM_BUILD)) -I$(abspath $(GEOM_MELON)/melonDS/src) -I$(abspath $(GEOM_MELON)/build/melonDS/src)" \
	  -LDFLAGS "$(abspath $(GEOM_MELON)/build/melonDS/src/libcore.a) $(abspath $(GEOM_MELON)/build/melonDS/src/teakra/src/libteakra.a) -lrt" \
	  $(GEOM_RTL) sim/gpu3d/ref/gpu3d_gxfront_ref.sv $(abspath sim/gpu3d/tb_geom.cpp) $(abspath tools/melonds-census/platform.cpp) >$(GEOM_BUILD)/verilator-eq.log 2>&1 \
	  || { tail -40 $(GEOM_BUILD)/verilator-eq.log; exit 1; }

geom-trace: $(GEOM_TB)
	$(GEOM_TB) --trace $(GEOM_TRACE) $(GEOM_ARGS)
