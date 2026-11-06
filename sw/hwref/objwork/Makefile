# Explicit standalone build only; no historical menu or shipping-trip edit.
ROOT := $(abspath ../../..)
OUT ?= $(ROOT)/build/objwork-v1
.PHONY: all
all:
	$(MAKE) -j1 -C .. OUT=$(OUT) SPEED_TRIP=0 PROGS=objwork \
		objwork_SRC=objwork/main.c \
		objwork_TITLE='hwref OBJ work discriminator;NDS_Pocket;source staged, not DS qualified' \
		EXTRA='-DHWREF_DIR=\"fat:/hwref/objwork-v1\" $(OBJWORK_DEFS)' $(OUT)/objwork.nds
