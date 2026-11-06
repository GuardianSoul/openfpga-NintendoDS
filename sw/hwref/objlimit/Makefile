# Explicit standalone build only; no historical menu or shipping-trip edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/objlimit-v2
.PHONY: all
all:
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=objlimit \
		objlimit_SRC=objlimit/main.c \
		objlimit_TITLE='hwref OBJ discriminator;NDS_Pocket;source staged, not DS qualified' \
		EXTRA='-DHWREF_DIR=\"fat:/hwref/objlimit-v2\"' $(OUT)/objlimit.nds
