// cacheorg (docs/hw-reference.md "cacheorg"): the ITCM walker.
#pragma once
#include "../common/hwref.h"

enum { CO_D, CO_I };
// Empties the cache (D: calico's clean-and-invalidate, then invalidate; I:
// invalidate), walks list[0..n) `passes` times (D: LDR from each address;
// I: BLX to each, every word of the buffer is BX LR) and returns the TM0
// ticks (system cycles) of the last `ntimed` accesses of the last pass.
// Called with IRQs locked. list must be in DTCM.
u32 co_trial(const u32* list, u32 n, u32 passes, u32 ntimed, u32 kind);
