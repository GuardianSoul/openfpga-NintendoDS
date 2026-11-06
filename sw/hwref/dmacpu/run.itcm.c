// dmacpu kernels, in ITCM (ARM state): the measurement and the TCM loop.
#include "dmacpu.h"

// k iterations of reads from d (8 words), summed in a register: no stores,
// so nothing reaches the bus unless the data or the code does.
u32 dk_loop_itcm(const vu32* d, u32 k)
{
	u32 s = 0;
	for (u32 i = 0; i < k; i++) s += d[i & 7];
	return s;
}

static inline void cp15_ctrl_set(u32 v) { __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(v)); }
static inline u32 cp15_ctrl(void) { u32 v; __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(v)); return v; }

// Time from the DMA start until a timer read succeeds after the loop. The
// timer read is I/O: it waits for the DMA. CPU running during the DMA gives
// about max(DMA, loop); halted gives DMA + loop. words == 0: loop alone.
// clear: CP15 control bits to clear around it (bit 2 data cache, bit 12
// instruction cache), restored after.
u32 dk_measure(u32 src, u32 dst, u32 words, dk_loop_fn fn, const vu32* d, u32 k, u32 clear, u32* sum)
{
	u32 ctrl = cp15_ctrl();
	if (clear) cp15_ctrl_set(ctrl & ~clear);
	REG32(0x040000D4) = src;
	REG32(0x040000D8) = dst;
	u32 t0 = now32();
	if (words) REG32(0x040000DC) = words | (1u << 31) | (1u << 26);   // enable, 32-bit, immediate
	*sum = fn(d, k);
	u32 t1 = now32();
	for (u32 i = 0; (REG32(0x040000DC) & (1u << 31)) && i < 10000000; i++) {}
	if (clear) cp15_ctrl_set(ctrl);
	return t1 - t0;
}

// v2 (CPU session): does a bus access that collides with the DMA wait for the
// whole DMA or interleave with it? D-cache off; right after the DMA start,
// load (or store to) the destination at the given word offsets, in order.
// Loads keep what they saw in out[]; stores write marker | offset. The
// caller compares with the destination's old fill and the source pattern.
void dk_collide(u32 src, u32 dst, u32 words, const u32* offs, u32 n, u32* out, bool store)
{
	u32 ctrl = cp15_ctrl();
	cp15_ctrl_set(ctrl & ~(1u << 2));
	REG32(0x040000D4) = src;
	REG32(0x040000D8) = dst;
	REG32(0x040000DC) = words | (1u << 31) | (1u << 26);
	vu32* d = (vu32*)dst;
	if (store) for (u32 i = 0; i < n; i++) d[offs[i]] = 0xC0DE0000 | offs[i];
	else for (u32 i = 0; i < n; i++) out[i] = d[offs[i]];
	for (u32 i = 0; (REG32(0x040000DC) & (1u << 31)) && i < 10000000; i++) {}
	cp15_ctrl_set(ctrl);
}
