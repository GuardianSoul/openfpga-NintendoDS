// GX timing loops. Built into ITCM (the *.itcm.* linker rule), sample buffers
// in ITCM too, so the measured loops touch only TCM and I/O: no cache or
// main-RAM timing in the samples. IRQs are off while they run.
#include "gxtime.h"

#define ITCM_DATA __attribute__((section(".itcm")))
Sample g_samples[MAX_SAMPLES] ITCM_DATA;
u32 g_stall[MAX_STALL + 1] ITCM_DATA;
u32 g_iters ITCM_DATA;
u32 g_timeouts ITCM_DATA;
u32 g_timeout_gxstat ITCM_DATA;
u32 g_resets ITCM_DATA, g_reset_fail ITCM_DATA, g_dropped ITCM_DATA;

#define R_DMA1SAD REG32(0x040000BC)
#define R_DMA1DAD REG32(0x040000C0)
#define R_DMA1CNT REG32(0x040000C4)
#define LIMIT 400000u    // iterations, ~10 frames

// Waits (bounded, ~3 frames) for GXSTAT & mask to clear. On a timeout the
// GXSTAT value is kept, the FIFO cleared (GXSTAT bit 29) and false returned.
static void gx_recover(u32 mask)
{
	g_timeouts++;
	g_timeout_gxstat = R_GXSTAT;
	R_GXSTAT = (1u << 29) | (1u << 15);
	if (R_GXSTAT & mask) {
		// Still stuck (seen on the DS after quad strips: busy with an
		// empty FIFO). Power-cycle the geometry engine (POWCNT1 bit 3).
		g_resets++;
		R_POWCNT1 &= ~(1u << 3);
		for (volatile int i = 0; i < 1000; i++) {}
		R_POWCNT1 |= (1u << 3);
		R_GXSTAT = (1u << 29) | (1u << 15);
		for (u32 i = 0; i < 200000 && (R_GXSTAT & mask); i++) {}
		if (R_GXSTAT & mask) g_reset_fail++;
	}
	gx_note_timeout();
}

bool gx_wait(u32 mask)
{
	for (u32 i = 0; i < 2000000; i++)
		if (!(R_GXSTAT & mask)) return true;
	gx_recover(mask);
	return false;
}

// A GX write that never blocks the CPU on a full FIFO (GXSTAT bit 24): if
// the FIFO stays full, the engine is recovered first.
void gx_put(vu32* port, u32 v)
{
	u32 i = 0;
	while ((R_GXSTAT & (1u << 24)) && ++i < 2000000) {}
	if (i >= 2000000) gx_recover(1u << 24);
	if (R_GXSTAT & (1u << 24)) { g_dropped++; return; }   // still full: never block
	*port = v;
}

// True when the engine is idle (after a recovery if needed). The timed runs
// skip themselves otherwise, rather than block on writes to a stuck engine.
static inline bool idle(void)
{
	return gx_wait(GXSTAT_BUSY) || !(R_GXSTAT & GXSTAT_BUSY);
}

int gx_run_drain(const Wr* w, int nw, u32 swap, int ext, u32 irqmode,
                 const u32* dma_src, u32 dma_words, bool stall_first)
{
	if (!idle()) return 0;
	wait_vcount(16);
	ArmIrqState st = armIrqLockByPsr();
	if (stall_first) *GXPORT(0x50) = swap;
	for (int i = 0; i < nw; i++) *w[i].a = w[i].v;
	if (irqmode) {
		R_GXSTAT = irqmode << 30;
		R_IF = 1u << 21;
	}
	if (dma_words) {
		R_DMA1SAD = (u32)dma_src;
		R_DMA1DAD = 0x04000400;
		// enable, 32-bit, GX FIFO start mode (7), dest fixed, source increment
		R_DMA1CNT = (1u << 31) | (1u << 26) | (7u << 27) | (2u << 21) | dma_words;
	}
	u32 last = ~0u, it = 0;
	u16 lt = 0;
	int n = 0;
	if (!ext) {
		for (;;) {
			u16 t = R_TM0;
			u32 s = R_GXSTAT;
			if (s != last || ((t ^ lt) & 0x8000)) {
				if (n < MAX_SAMPLES - 1) n++;
				g_samples[n - 1].s = s;
				g_samples[n - 1].t = t;
				last = s;
				lt = t;
			}
			if (!(s & GXSTAT_BUSY) || ++it > LIMIT) break;
		}
	} else {
		for (;;) {
			u16 t = R_TM0;
			u32 s = R_GXSTAT | ((R_IF >> 21) & 1) << 28 | (R_DMA1CNT >> 31) << 29;
			if (s != last || ((t ^ lt) & 0x8000)) {
				if (n < MAX_SAMPLES - 1) n++;
				g_samples[n - 1].s = s;
				g_samples[n - 1].t = t;
				last = s;
				lt = t;
			}
			if (!(s & (GXSTAT_BUSY | SF_DMA)) || ++it > LIMIT) break;
		}
	}
	g_iters = it;
	if (it > LIMIT) {
		R_DMA1CNT = 0;
		g_timeouts++;
		g_timeout_gxstat = R_GXSTAT;
	}
	if (irqmode) {
		R_GXSTAT = 0;
		R_IF = 1u << 21;
	}
	armIrqUnlockByPsr(st);
	return n;
}

u32 gx_run_iso(const Wr* w, int nw, u32 mask)
{
	if (!idle()) return 0xFFFF0000;
	ArmIrqState st = armIrqLockByPsr();
	u16 t0 = R_TM0;
	for (int i = 0; i < nw; i++) *w[i].a = w[i].v;
	u32 n = 0;
	while ((R_GXSTAT & mask) && ++n < 2000000) {}
	u16 t1 = R_TM0;
	if (n >= 2000000) {
		armIrqUnlockByPsr(st);
		gx_wait(mask);
		return 0xFFFF0000;
	}
	armIrqUnlockByPsr(st);
	return (u16)(t1 - t0);
}

u32 gx_run_swap(int line, u32 param, u16* vc_end)
{
	*vc_end = 0xFFFF;
	if (!idle()) return 0;
	ArmIrqState st = armIrqLockByPsr();
	wait_vcount(line);
	u32 t0 = now32();
	*GXPORT(0x50) = param;
	u32 n = 0;
	while ((R_GXSTAT & GXSTAT_BUSY) && ++n < 4000000) {}
	u32 t1 = now32();
	*vc_end = R_VCOUNT;
	armIrqUnlockByPsr(st);
	return t1 - t0;
}

void gx_run_stall(vu32* port, u32 v, int n)
{
	if (!idle()) { for (int i = 0; i <= n; i++) g_stall[i] = 0; return; }
	wait_vcount(16);
	ArmIrqState st = armIrqLockByPsr();
	*GXPORT(0x50) = 0;
	for (int i = 0; i < n; i++) {
		g_stall[i] = now32();
		*port = v;
	}
	for (u32 k = 0; (R_GXSTAT & GXSTAT_BUSY) && k < 4000000; k++) {}
	g_stall[n] = now32();
	armIrqUnlockByPsr(st);
	idle();
}
