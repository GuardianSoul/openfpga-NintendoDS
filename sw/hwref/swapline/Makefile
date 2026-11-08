# Explicit new-only standalone probe (POWCNT1 bit 15 timing); no historical menu or trip edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/swapline-v1
.PHONY: all
all:
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=swapline \
	 swapline_SRC=swapline/main.c \
	 swapline_TITLE='hwref display swap timing;NDS_Pocket;new-only, visual' \
	 EXTRA='-DHWREF_DIR=\"fat:/hwref/swapline-v1\"' $(OUT)/swapline.nds
