// arm7time, ARM7 side: calico's stock ARM7 start-up (ds7_maine: NVRAM
// settings, keypad server, VBlank IRQ, RTC, power management, block device
// for the SD card), without the touch, sound, mic, WiFi and maxmod servers,
// plus a command loop for the timing kernels (arm7time.h).
#include <calico.h>
#include "arm7time.h"

#define REG32(a) (*(volatile u32*)(a))
#define REG16(a) (*(volatile u16*)(a))

static inline u32 now32(void)
{
	u16 h = REG16(0x04000104), l = REG16(0x04000100), h2 = REG16(0x04000104);
	if (h != h2) { l = REG16(0x04000100); h = h2; }
	return ((u32)h << 16) | l;
}

#define K __attribute__((target("arm"), noinline, aligned(32)))
#define KM __attribute__((target("arm"), noinline, aligned(32), section(".main.k")))
#define R8(s) s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n"
#define R64(s) R8(R8(s))
#define LOOP(setup, body, ...) \
	__asm__ volatile(setup "1:\n" R64(body) "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p), "r"(q) : __VA_ARGS__); return n;
typedef u32 (*Kern)(u32 n, u32 p, u32 q);

K static u32 k_alu(u32 n, u32 p, u32 q)      { LOOP("mov r1, #1\n", "add r0, r0, r1", "r0", "r1", "cc") }
K static u32 k_alu_sr(u32 n, u32 p, u32 q)   { LOOP("mov r1, #1\nmov r2, #2\n", "add r0, r0, r1, lsl r2", "r0", "r1", "r2", "cc") }
K static u32 k_b(u32 n, u32 p, u32 q)        { LOOP("", "b 2f\n2:", "cc") }
K static u32 k_mul(u32 n, u32 p, u32 q)      { LOOP("mov r1, #3\n", "mul r3, r1, %2", "r1", "r3", "cc") }   // q = the multiplier (Rs)
K static u32 k_mla(u32 n, u32 p, u32 q)      { LOOP("mov r1, #3\nmov r4, #7\n", "mla r3, r1, %2, r4", "r1", "r3", "r4", "cc") }
K static u32 k_ldr(u32 n, u32 p, u32 q)      { LOOP("", "ldr r0, [%1]", "r0", "cc") }
K static u32 k_str(u32 n, u32 p, u32 q)      { LOOP("mov r0, #0\n", "str r0, [%1]", "r0", "cc", "memory") }
K static u32 k_ldm4(u32 n, u32 p, u32 q)     { LOOP("", "ldmia %1, {r2-r5}", "r2", "r3", "r4", "r5", "cc") }
K static u32 k_stm4(u32 n, u32 p, u32 q)     { LOOP("", "stmia %1, {r2-r5}", "r2", "r3", "r4", "r5", "cc", "memory") }
K static u32 k_swp(u32 n, u32 p, u32 q)      { LOOP("mov r1, #0\n", "swp r0, r1, [%1]", "r0", "r1", "cc", "memory") }
KM static u32 km_alu(u32 n, u32 p, u32 q)    { LOOP("mov r1, #1\n", "add r0, r0, r1", "r0", "r1", "cc") }
KM static u32 km_alu_sr(u32 n, u32 p, u32 q) { LOOP("mov r1, #1\nmov r2, #2\n", "add r0, r0, r1, lsl r2", "r0", "r1", "r2", "cc") }
KM static u32 km_b(u32 n, u32 p, u32 q)      { LOOP("", "b 2f\n2:", "cc") }
KM static u32 km_mul(u32 n, u32 p, u32 q)    { LOOP("mov r1, #3\n", "mul r3, r1, %2", "r1", "r3", "cc") }
KM static u32 km_ldr(u32 n, u32 p, u32 q)    { LOOP("", "ldr r0, [%1]", "r0", "cc") }
KM static u32 km_str(u32 n, u32 p, u32 q)    { LOOP("mov r0, #0\n", "str r0, [%1]", "r0", "cc", "memory") }

static u32 s_wram[16] __attribute__((aligned(32)));
static u32 s_main[16] __attribute__((aligned(32), section(".main.d")));

static const struct { Kern k; int where; u32 q; } s_k[A7K_NKERNELS] = {
	[A7K_ALU] = { k_alu, 0, 0 }, [A7K_ALU_SHIFTREG] = { k_alu_sr, 0, 0 }, [A7K_B] = { k_b, 0, 0 },
	[A7K_MUL8] = { k_mul, 0, 0x7F }, [A7K_MUL16] = { k_mul, 0, 0x7FFF }, [A7K_MUL24] = { k_mul, 0, 0x7FFFFF },
	[A7K_MUL32] = { k_mul, 0, 0x7FFFFFFF },
	[A7K_MLA8] = { k_mla, 0, 0x7F }, [A7K_MLA16] = { k_mla, 0, 0x7FFF }, [A7K_MLA24] = { k_mla, 0, 0x7FFFFF },
	[A7K_MLA32] = { k_mla, 0, 0x7FFFFFFF },
	[A7K_LDR_WRAM] = { k_ldr, 0, 0 }, [A7K_STR_WRAM] = { k_str, 0, 0 }, [A7K_LDM4_WRAM] = { k_ldm4, 0, 0 },
	[A7K_STM4_WRAM] = { k_stm4, 0, 0 }, [A7K_SWP_WRAM] = { k_swp, 0, 0 },
	[A7K_LDR_MAIN] = { k_ldr, 1, 0 }, [A7K_STR_MAIN] = { k_str, 1, 0 }, [A7K_LDM4_MAIN] = { k_ldm4, 1, 0 },
	[A7K_STM4_MAIN] = { k_stm4, 1, 0 }, [A7K_SWP_MAIN] = { k_swp, 1, 0 },
	[A7K_M_ALU] = { km_alu, 0, 0 }, [A7K_M_ALU_SHIFTREG] = { km_alu_sr, 0, 0 }, [A7K_M_B] = { km_b, 0, 0 },
	[A7K_M_MUL32] = { km_mul, 0, 0x7FFFFFFF }, [A7K_M_LDR_WRAM] = { km_ldr, 0, 0 }, [A7K_M_STR_WRAM] = { km_str, 0, 0 },
	[A7K_LDR_VRAMC] = { k_ldr, 2, 0 }, [A7K_STR_VRAMC] = { k_str, 2, 0 },
};

static u32 timed(Kern k, u32 n, u32 p, u32 q, int line)
{
	ArmIrqState st = armIrqLockByPsr();
	k(1, p, q);
	if (line >= 0) {
		while (REG16(0x04000006) == line) {}
		while (REG16(0x04000006) != line) {}
	}
	u32 t0 = now32();
	k(n, p, q);
	u32 t = now32() - t0;
	armIrqUnlockByPsr(st);
	return t;
}

static u32 measure(unsigned id, u32 arg)
{
	if (id >= A7K_NKERNELS) return A7_BAD;
	u32 p = s_k[id].where == 1 ? (u32)s_main : s_k[id].where == 2 ? 0x06000100 : (u32)s_wram;
	int line = s_k[id].where == 2 ? (arg ? 96 : 192) : -1;
	u32 b1 = ~0u, b2 = ~0u;
	for (int r = 0; r < 5; r++) {
		u32 t1 = timed(s_k[id].k, 4, p, s_k[id].q, line), t2 = timed(s_k[id].k, 16, p, s_k[id].q, line);
		if (t1 < b1) b1 = t1;
		if (t2 < b2) b2 = t2;
	}
	return b2 > b1 ? (b2 - b1) * 100 / (12 * 64) : 0;
}

// Main-RAM loads for the contention test: 64 per iteration over 64 KiB
static u32 mainload(u32 iters)
{
	static u32 buf[16] __attribute__((section(".main.d")));
	ArmIrqState st = armIrqLockByPsr();
	u32 t0 = now32();
	k_ldr(iters, (u32)buf, 0);
	u32 t = now32() - t0;
	armIrqUnlockByPsr(st);
	return t > 0x3FFFFFE ? 0x3FFFFFE : t;
}

int main(void)
{
	envReadNvramSettings();
	keypadStartExtServer();
	lcdSetIrqMask(DISPSTAT_IE_ALL, DISPSTAT_IE_VBLANK);
	irqEnable(IRQ_VBLANK);
	rtcInit();
	rtcSyncTime();
	pmInit();
	blkInit();

	// TM0 F/1 + TM1 cascade: the ARM7's clock (calico's ARM7 doesn't use them here)
	REG16(0x04000102) = 0;
	REG16(0x04000106) = 0;
	REG16(0x04000104) = 0;
	REG16(0x04000100) = 0;
	REG16(0x04000106) = (1 << 7) | (1 << 2);
	REG16(0x04000102) = 1 << 7;

	static u32 slots[4];
	static Mailbox mb;
	mailboxPrepare(&mb, slots, 4);
	pxiSetMailbox(A7_CH, &mb);

	while (pmMainLoop()) {
		u32 msg;
		while (mailboxTryRecv(&mb, &msg)) {
			unsigned id = msg & 0xFF;
			u32 arg = (msg >> 8) & 0xFFFF;
			u32 r = id == A7K_MAINLOAD ? mainload(arg) : id == A7K_PING ? 0x123456 : measure(id, arg);
			pxiSend(A7_CH, r);
		}
		threadIrqWait(true, IRQ_VBLANK);
	}
	return 0;
}
