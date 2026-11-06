// memtime kernels. Built into ITCM in ARM state (the *.itcm.* rule), so the
// measuring code's own fetches never touch the bus or the I-cache. Each
// kernel is an unrolled block in a counted loop; the loop's subs + bne add
// about 4 ARM9 cycles per iteration (see the calib row).
#include "memtime.h"

#define ITCM_DATA __attribute__((section(".itcm")))
u32 g_dma_timeouts ITCM_DATA;

#define CLOB "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "cc", "memory"
#define ZERO "mov r2,#0\nmov r3,#0\nmov r4,#0\nmov r5,#0\nmov r6,#0\nmov r7,#0\nmov r8,#0\nmov r9,#0\n"

// pre: run at the top of every iteration ("mov %0,%2" restarts at the base).
#define K(name, pre, body, cnt)                                              \
	static void name(u32 b, u32 it)                                      \
	{                                                                    \
		u32 p = b;                                                   \
		__asm__ __volatile__(ZERO "1:\n" pre "\n.rept " #cnt "\n"   \
			body "\n.endr\nsubs %1, %1, #1\nbne 1b\n"            \
			: "+&r"(p), "+&r"(it) : "r"(b) : CLOB);              \
	}

#define RST "mov %0, %2"
#define KSET(op, insn, w)                                  \
	K(k_##op##_seq, RST, insn " r2, [%0], #" #w, 64)   \
	K(k_##op##_s32, RST, insn " r2, [%0], #32", 64)    \
	K(k_##op##_adv, "", insn " r2, [%0], #32", 64)     \
	K(k_##op##_fix, "", insn " r2, [%0]", 64)
KSET(ldr, "ldr", 4)
KSET(ldrh, "ldrh", 2)
KSET(ldrb, "ldrb", 1)
KSET(str, "str", 4)
KSET(strh, "strh", 2)
KSET(strb, "strb", 1)
K(k_ldm_seq, RST, "ldmia %0!, {r2-r9}", 16)
K(k_ldm_adv, "", "ldmia %0!, {r2-r9}", 16)
K(k_stm_seq, RST, "stmia %0!, {r2-r9}", 16)
K(k_stm_adv, "", "stmia %0!, {r2-r9}", 16)
K(k_raw, RST, "str r2, [%0]\nldr r3, [%0], #32", 64)
K(k_nop64, "", "nop", 64)

#define ROW(op) { k_##op##_seq, k_##op##_s32, k_##op##_adv, k_##op##_fix }
const KFn g_kern[OP_COUNT][KM_COUNT] = {
	[OP_LDR] = ROW(ldr), [OP_LDRH] = ROW(ldrh), [OP_LDRB] = ROW(ldrb),
	[OP_LDM] = { k_ldm_seq, NULL, k_ldm_adv, NULL },
	[OP_STR] = ROW(str), [OP_STRH] = ROW(strh), [OP_STRB] = ROW(strb),
	[OP_STM] = { k_stm_seq, NULL, k_stm_adv, NULL },
};
const KFn g_k_raw = k_raw;
const KFn g_k_nop64 = k_nop64;

// Single shots; the loaded values are used so the timer read waits for them.
#define K1(name, body) \
	static void name(u32 b, u32 it) { (void)it; __asm__ __volatile__(body :: "r"(b) : "r2", "r3", "memory"); }
K1(k_f_w0, "ldr r2, [%0]\nadd r3, r2, r2")
K1(k_f_w7, "ldr r2, [%0, #28]\nadd r3, r2, r2")
K1(k_f_w01, "ldr r2, [%0]\nldr r3, [%0, #4]\nadd r3, r3, r2")
K1(k_f_w07, "ldr r2, [%0]\nldr r3, [%0, #28]\nadd r3, r3, r2")
const KFn g_k_fill[4] = { k_f_w0, k_f_w7, k_f_w01, k_f_w07 };

u32 mt_time(KFn f, u32 base, u32 it, bool flush)
{
	ArmIrqState st = armIrqLockByPsr();
	if (flush) armDCacheFlushAll();
	u32 t0 = now32();
	f(base, it);
	u32 t1 = now32();
	armIrqUnlockByPsr(st);
	return t1 - t0;
}

u32 mt_fill(KFn f, u32 base, bool miss)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	if (!miss) f(base, 0);
	u32 t0 = now32();
	f(base, 0);
	u32 t1 = now32();
	armIrqUnlockByPsr(st);
	return t1 - t0;
}

// ---- CP15 ----
#define MRC(r) ({ u32 v_; __asm__ __volatile__("mrc p15, 0, %0, " r : "=r"(v_)); v_; })
void mt_cp15_read(Cp15* c)
{
	c->ctrl = MRC("c1, c0, 0");
	c->dcache = armMpuGetDCacheConfig();
	c->icache = armMpuGetICacheConfig();
	c->wrbuf = armMpuGetWrBufConfig();
	c->dperm = armMpuGetDataPerm();
	c->iperm = armMpuGetCodePerm();
	for (int i = 0; i < 8; i++) c->region[i] = armMpuGetRegion(i);
	c->dtcm = MRC("c9, c1, 0");
	c->itcm = MRC("c9, c1, 1");
}

int mt_region_of(u32 addr)
{
	for (int i = 7; i >= 0; i--) {
		u32 r = armMpuGetRegion(i);
		if (!(r & 1)) continue;
		u32 n = (r >> 1) & 0x1F;
		u64 size = 2ull << n;
		u32 base = r & ~0xFFFu;
		if (addr >= base && (u64)addr < base + size) return i;
	}
	return -1;
}

static u32 s_dc ITCM_DATA, s_ic ITCM_DATA, s_wb ITCM_DATA;

void mt_cfg_save(void)
{
	s_dc = armMpuGetDCacheConfig();
	s_ic = armMpuGetICacheConfig();
	s_wb = armMpuGetWrBufConfig();
}

void mt_cfg_set(int r, int c, int b)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetRegionDCacheEnable(r, c);
	armMpuSetRegionWrBufEnable(r, b);
	armIrqUnlockByPsr(st);
}

void mt_cfg_set_icache(int r, int i)
{
	ArmIrqState st = armIrqLockByPsr();
	armICacheInvalidateAll();
	armMpuSetRegionICacheEnable(r, i);
	armIrqUnlockByPsr(st);
}

void mt_cfg_restore(void)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetDCacheConfig(s_dc);
	armMpuSetWrBufConfig(s_wb);
	armICacheInvalidateAll();
	armMpuSetICacheConfig(s_ic);
	armIrqUnlockByPsr(st);
}

// ---- instruction fetch ----
__asm__(".section .itcm.sled, \"ax\", %progbits\n.arm\n.align 5\n"
	".global mt_sled_itcm\n.type mt_sled_itcm, %function\nmt_sled_itcm:\n"
	".rept 1024\nnop\n.endr\nbx lr\n.size mt_sled_itcm, . - mt_sled_itcm\n.previous\n");

u32 mt_ifetch(const u32* sled, u32 n, int mode)
{
	void (*entry)(void) = (void (*)(void))(sled + (SLED_N - n));
	ArmIrqState st = armIrqLockByPsr();
	if (mode == 0) entry();
	else armICacheInvalidateAll();
	u32 t0 = now32();
	entry();
	u32 t1 = now32();
	armIrqUnlockByPsr(st);
	return t1 - t0;
}

// ---- DMA3, immediate ----
#define R_DMA3SAD REG32(0x040000D4)
#define R_DMA3DAD REG32(0x040000D8)
#define R_DMA3CNT REG32(0x040000DC)

u32 mt_dma(u32 src, u32 dst, u32 cnt)
{
	ArmIrqState st = armIrqLockByPsr();
	R_DMA3CNT = 0;
	R_DMA3SAD = src;
	R_DMA3DAD = dst;
	u32 i = 0;
	u32 t0 = now32();
	R_DMA3CNT = cnt | (1u << 31);
	while ((R_DMA3CNT & (1u << 31)) && ++i < 1000000) {}
	u32 t1 = now32();
	if (i >= 1000000) {
		R_DMA3CNT = 0;
		g_dma_timeouts++;
		t1 = t0 - 1;
	}
	armIrqUnlockByPsr(st);
	return t1 - t0;
}
