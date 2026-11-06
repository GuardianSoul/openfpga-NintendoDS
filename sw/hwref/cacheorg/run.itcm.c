// cacheorg's walker, in ITCM (ARM state): no instruction fetch goes through
// the I-cache, and its literals and the list (DTCM) don't touch the D-cache.
#include "cacheorg.h"

typedef void (*Fn)(void);

u32 co_trial(const u32* list, u32 n, u32 passes, u32 ntimed, u32 kind)
{
	if (kind == CO_I) {
		__asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0) : "memory");
	} else {
		armDCacheFlushAll();   // clean: nothing dirty is lost by the invalidate
		__asm__ volatile("mcr p15, 0, %0, c7, c6, 0" :: "r"(0) : "memory");
	}
	u32 t0 = 0;
	for (u32 p = 0; p < passes; p++)
		for (u32 i = 0; i < n; i++) {
			if (p == passes - 1 && i == n - ntimed) t0 = R_TM0;
			u32 a = list[i];
			if (kind == CO_I) ((Fn)a)();
			else (void)*(vu32*)a;
		}
	return (u16)(R_TM0 - t0);
}
