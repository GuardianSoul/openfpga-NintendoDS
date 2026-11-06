// dmaslip: does an ARM9 main-RAM access wait for a running ARM9 DMA?
// (docs/hw-reference.md "dmaslip")
#pragma once
#include "../common/hwref.h"

enum { K_NONE, K_LOAD, K_STORE, K_CALL };
enum { P_NONE, P_DLINE, P_ILINE };   // the line made cold before t0
typedef struct {
	u32 src, dst, ctl;    // DMA3 (ctl 0: no DMA)
	u32 kind, prep, addr; // the access after the delay
	u32 n, l;             // delay loops before it, work loops after it
	u32 flag;             // read DMA3CNT right after the access
} DsTrial;

u32 ds_spin_cal(u32 loops);
u32 ds_trial(const DsTrial* t, u32* cnt);
