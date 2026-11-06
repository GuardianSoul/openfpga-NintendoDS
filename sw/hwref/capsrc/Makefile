# Explicit new-only standalone probe; no historical menu or trip edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/capsrc-v1
.PHONY: all
all:
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=capsrc \
	 capsrc_SRC=capsrc/main.c \
	 capsrc_TITLE='hwref capture-source odd;NDS_Pocket;new-only, not DS qualified' \
	 EXTRA='-DHWREF_DIR=\"fat:/hwref/capsrc-v1\"' $(OUT)/capsrc.nds
