// dmaslip's trial, in ITCM (ARM state): its delay and work loops run from
// ITCM with no data accesses, so they keep running during a DMA (run 22);
// only the access under test and the two timer reads reach the bus.
#include "dmaslip.h"

static inline void spin(u32 n)
{
	if (n) __asm__ volatile("1: subs %0, %0, #1\n bne 1b" : "+r"(n) :: "cc", "memory");
}

u32 ds_spin_cal(u32 loops)
{
	u32 t0 = now32();
	spin(loops);
	return now32() - t0;
}

// From before the DMA start to a timer read after the work loops. The timer
// read waits for a DMA still running, so the work loops (l) outlast the DMA:
// then an access that slips in costs about its own time, one that waits for
// the DMA costs the DMA's remaining length.
u32 ds_trial(const DsTrial* t, u32* cnt)
{
	u32 a = t->addr, v = 0, c = 0;
	if (t->prep == P_DLINE) __asm__ volatile("mcr p15, 0, %0, c7, c14, 1" :: "r"(a) : "memory");   // clean + invalidate
	if (t->prep == P_ILINE) __asm__ volatile("mcr p15, 0, %0, c7, c5, 1" :: "r"(a) : "memory");    // invalidate I line
	__asm__ volatile("mcr p15, 0, %0, c7, c10, 4" :: "r"(0) : "memory");                          // drain write buffer
	REG32(0x040000D4) = t->src;
	REG32(0x040000D8) = t->dst;
	u32 t0 = now32();
	if (t->ctl) REG32(0x040000DC) = t->ctl;
	spin(t->n);
	if (t->kind == K_LOAD) v = *(vu32*)a;
	else if (t->kind == K_STORE) *(vu32*)a = 0;
	else if (t->kind == K_CALL) ((void (*)(void))a)();
	__asm__ volatile("mov %0, %0" : "+r"(v));   // use the loaded word: the pipeline waits for it
	if (t->flag) c = REG32(0x040000DC);
	spin(t->l);
	u32 t1 = now32();
	for (u32 i = 0; (REG32(0x040000DC) & (1u << 31)) && i < 1000000; i++) {}
	*cnt = c;
	return t1 - t0;
}
