// cputime (docs/hw-reference.md "cputime"): ARM9 cycles per operation for
// what memtime doesn't cover: ALU (ARM, Thumb), branches, multiplies, the
// load-use interlock, D-cache evictions of dirty vs clean lines, and VRAM
// stores back to back vs spaced (does the write buffer hide them?).
//
// Each kernel repeats 64 copies of the operation per loop iteration. Run
// with n1 and n2 iterations; cycles per op = (T(n2) - T(n1)) * 2 / ((n2 -
// n1) * 64), T in TM0+TM1 ticks (33.5 MHz = half the ARM9 clock), best of
// 5, IRQs off. The kernels run from main RAM with the I-cache warm (memtime:
// 1-cycle fetch); ITCM is full in hwref.nds. Results: cputime.csv on the SD
// card, and the tb_ds result block at 0x023F0000 (values in row order).
#include "../common/hwref.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "cputime 3"
#define K __attribute__((target("arm"), noinline, aligned(32)))
#define R64(s) ".rept 64\n" s "\n.endr\n"
#define LOOP(setup, body, ...) \
	__asm__ volatile(setup "1:\n" R64(body) "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : __VA_ARGS__); return n;

K static u32 k_nop(u32 n, u32 p)       { LOOP("", "mov r0, r0", "r0", "cc") }
K static u32 k_add_dep(u32 n, u32 p)   { LOOP("mov r0, #0\nmov r1, #1\n", "add r0, r0, r1", "r0", "r1", "cc") }
K static u32 k_add_indep(u32 n, u32 p) { LOOP("mov r1, #1\nmov r2, #2\n", "add r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_add_shift(u32 n, u32 p) { LOOP("mov r1, #1\nmov r2, #2\nmov r4, #3\n", "add r3, r1, r2, lsl r4", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_b_taken(u32 n, u32 p)   { LOOP("", "b 2f\n2:", "cc") }
K static u32 k_b_not(u32 n, u32 p)     // the bne is never taken
{
	__asm__ volatile("1:\n" R64("cmp r0, r0\nbne 9f") "subs %0, %0, #1\nbne 1b\n9:\n" : "+r"(n) : "r"(p) : "r0", "cc");
	return n;
}
K static u32 k_mul(u32 n, u32 p)       { LOOP("mov r1, #3\nmov r2, #5\n", "mul r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_mul_dep(u32 n, u32 p)   { LOOP("mov r0, #3\nmov r1, #5\n", "mul r0, r1, r0", "r0", "r1", "cc") }
K static u32 k_mla(u32 n, u32 p)       { LOOP("mov r1, #3\nmov r2, #5\nmov r4, #7\n", "mla r3, r1, r2, r4", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_smull(u32 n, u32 p)     { LOOP("mov r1, #3\nmov r2, #5\n", "smull r3, r4, r1, r2", "r1", "r2", "r3", "r4", "cc") }
K static u32 k_smulxy(u32 n, u32 p)    { LOOP("mov r1, #3\nmov r2, #5\n", "smulbb r3, r1, r2", "r1", "r2", "r3", "cc") }
K static u32 k_ld_use(u32 n, u32 p)    { LOOP("", "ldr r0, [%1]\nadd r1, r0, #1", "r0", "r1", "cc") }
K static u32 k_ld_nouse(u32 n, u32 p)  { LOOP("", "ldr r0, [%1]\nadd r1, r2, #1", "r0", "r1", "r2", "cc") }
K static u32 k_str(u32 n, u32 p)       { LOOP("mov r0, #0\n", "str r0, [%1]", "r0", "cc", "memory") }
K static u32 k_str_nop4(u32 n, u32 p)  { LOOP("mov r0, #0\n", "str r0, [%1]\nmov r1, r1\nmov r1, r1\nmov r1, r1\nmov r1, r1", "r0", "r1", "cc", "memory") }
K static u32 k_strh(u32 n, u32 p)      { LOOP("mov r0, #0\n", "strh r0, [%1]", "r0", "cc", "memory") }
// fresh lines: one load per 32-byte line, the pointer stepping through
K static u32 k_ld_line(u32 n, u32 p)
{
	__asm__ volatile("mov r1, %1\n1:\n" R64("ldr r0, [r1], #32") "subs %0, %0, #1\nbne 1b\n"
	                 : "+r"(n) : "r"(p) : "r0", "r1", "cc", "memory");
	return n;
}
// two loads per fresh line, the second dependent on nothing: word 0 then 7,
// and word 7 then 0 (CPU session: critical-word restart and fill order)
K static u32 k_ld_w0w7(u32 n, u32 p)
{
	__asm__ volatile("mov r1, %1\n1:\n" R64("ldr r0, [r1]\nldr r2, [r1, #28]\nadd r1, r1, #32")
	                 "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : "r0", "r1", "r2", "cc", "memory");
	return n;
}
K static u32 k_ld_w7w0(u32 n, u32 p)
{
	__asm__ volatile("mov r1, %1\n1:\n" R64("ldr r0, [r1, #28]\nldr r2, [r1]\nadd r1, r1, #32")
	                 "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : "r0", "r1", "r2", "cc", "memory");
	return n;
}
// Thumb: 64 dependent adds
__attribute__((target("thumb"), noinline, aligned(32))) static u32 k_thumb_add(u32 n, u32 p)
{
	__asm__ volatile(".syntax unified\nmovs r0, #0\nmovs r1, #1\n1:\n" R64("adds r0, r0, r1") "subs %0, %0, #1\nbne 1b\n"
	                 : "+l"(n) : "l"(p) : "r0", "r1", "cc");
	return n;
}
__attribute__((target("thumb"), noinline, aligned(32))) static u32 k_thumb_b(u32 n, u32 p)
{
	__asm__ volatile(".syntax unified\n1:\n" R64("b 2f\n2:") "subs %0, %0, #1\nbne 1b\n" : "+l"(n) : "l"(p) : "cc");
	return n;
}

// v3 (CPU session): issue interlocks, 64 bodies per iteration as above
K static u32 k_alu_shiftop(u32 n, u32 p)  { LOOP("mov r1, #0\nmov r3, #1\n", "add r1, r1, #1\nadd r2, r3, r1, lsl #2", "r1", "r2", "r3", "cc") }
K static u32 k_alu_shiftamt(u32 n, u32 p) { LOOP("mov r1, #0\nmov r3, #1\n", "add r1, r1, #1\nmov r2, r3, lsl r1", "r1", "r2", "r3", "cc") }
K static u32 k_adds_addeq(u32 n, u32 p)   { LOOP("mov r1, #0\nmov r2, #0\n", "adds r1, r1, #0\naddeq r2, r2, #1", "r1", "r2", "cc") }
K static u32 k_cmp_beq_t(u32 n, u32 p)    { LOOP("mov r0, #0\n", "cmp r0, r0\nbeq 2f\n2:", "r0", "cc") }
K static u32 k_alt_branch(u32 n, u32 p)   { LOOP("mov r6, #0\n", "add r6, r6, #1\ntst r6, #1\nbne 2f\n2:", "r6", "cc") }
K static u32 k_ld_use2(u32 n, u32 p)      { LOOP("", "ldr r0, [%1]\nmov r2, r2\nadd r1, r0, #1", "r0", "r1", "r2", "cc") }
K static u32 k_ld_use3(u32 n, u32 p)      { LOOP("", "ldr r0, [%1]\nmov r2, r2\nmov r2, r2\nadd r1, r0, #1", "r0", "r1", "r2", "cc") }
K static u32 k_ldrb_use(u32 n, u32 p)     { LOOP("", "ldrb r0, [%1]\nadd r1, r0, #1", "r0", "r1", "cc") }
K static u32 k_ldrh_use(u32 n, u32 p)     { LOOP("", "ldrh r0, [%1]\nadd r1, r0, #1", "r0", "r1", "cc") }
K static u32 k_ldm4_use(u32 n, u32 p)     { LOOP("", "ldmia %1, {r2-r5}\nadd r1, r5, #1", "r1", "r2", "r3", "r4", "r5", "cc") }
K static u32 k_str_ldr(u32 n, u32 p)      { LOOP("mov r0, #0\n", "str r0, [%1]\nldr r1, [%1]", "r0", "r1", "cc", "memory") }
K static u32 k_mla_use1(u32 n, u32 p)     { LOOP("mov r1, #3\nmov r2, #5\nmov r4, #7\n", "mla r3, r1, r2, r4\nadd r5, r3, #1", "r1", "r2", "r3", "r4", "r5", "cc") }
K static u32 k_mla_use2(u32 n, u32 p)     { LOOP("mov r1, #3\nmov r2, #5\nmov r4, #7\n", "mla r3, r1, r2, r4\nmov r6, r6\nadd r5, r3, #1", "r1", "r2", "r3", "r4", "r5", "r6", "cc") }
K static u32 k_smull_use1(u32 n, u32 p)   { LOOP("mov r1, #3\nmov r2, #5\n", "smull r3, r4, r1, r2\nadd r5, r4, #1", "r1", "r2", "r3", "r4", "r5", "cc") }
K static u32 k_smull_use2(u32 n, u32 p)   { LOOP("mov r1, #3\nmov r2, #5\n", "smull r3, r4, r1, r2\nmov r6, r6\nadd r5, r4, #1", "r1", "r2", "r3", "r4", "r5", "r6", "cc") }
K static u32 k_bx(u32 n, u32 p)           { LOOP("", "adr r2, 2f\nbx r2\n2:", "r2", "cc") }
K static u32 k_blx(u32 n, u32 p)          { LOOP("", "adr r2, 2f\nblx r2\n2:", "r2", "lr", "cc") }
__attribute__((target("thumb"), noinline, aligned(32))) static u32 k_thumb_bl(u32 n, u32 p)
{
	// 64 BL pairs are 256 bytes: past a Thumb conditional branch's reach
	__asm__ volatile(".syntax unified\n1:\n" R64("bl 2f\n2:") "subs %0, %0, #1\nbeq 3f\nb 1b\n3:\n" : "+l"(n) : "l"(p) : "lr", "cc");
	return n;
}

typedef u32 (*Kern)(u32 n, u32 p);
static u8* s_main;          // main RAM, cached write-back (calico region 1)
static u8* s_other;
static u32 s_dtcm[16] DTCM_BSS __attribute__((aligned(32)));

enum { PREP_NONE, PREP_CLEAN, PREP_DIRTY };

static u32 run(Kern k, u32 n, u32 p, int prep)
{
	u32 best = ~0u;
	for (int r = 0; r < 6; r++) {
		ArmIrqState st = armIrqLockByPsr();
		armDCacheFlushAll();
		if (prep == PREP_CLEAN) for (u32 i = 0; i < 0x2000; i += 32) (void)*(vu32*)(s_other + i);
		if (prep == PREP_DIRTY) for (u32 i = 0; i < 0x2000; i += 32) *(vu32*)(s_other + i) = i;
		k(1, p);   // warms the kernel's I-cache lines (one iteration)
		if (prep != PREP_NONE) {   // the warm-up touched lines: redo the cache state
			armDCacheFlushAll();
			if (prep == PREP_CLEAN) for (u32 i = 0; i < 0x2000; i += 32) (void)*(vu32*)(s_other + i);
			if (prep == PREP_DIRTY) for (u32 i = 0; i < 0x2000; i += 32) *(vu32*)(s_other + i) = i;
		}
		u32 t0 = now32();
		k(n, p);
		u32 t = now32() - t0;
		armIrqUnlockByPsr(st);
		if (r && t < best) best = t;
	}
	return best;
}

typedef struct { const char* name; Kern k; int where; int prep; u32 n1, n2; } Row;
enum { AT_DTCM, AT_MAIN, AT_VRAM, AT_MAIN_LINES };


// v3 (sound/timer session, ds-rules "Timers"): timer start, prescaler phase
// and cascade latency. TM2 is borrowed as a 16-bit F/1 clock (system cycles)
// with IRQs locked; TM0 is the subject, TM1 cascades from it. TM0+TM1 (our
// clock) and TM2 are set back after. cputime_timers.csv.
#define TMCNT(n) REG16(0x04000102 + 4 * (n))
#define TMVAL(n) REG16(0x04000100 + 4 * (n))
static void timers(void)
{
	Buf c = {0};
	buf_printf(&c, "case,prescaler,reload,rep_or_n,value\n");
	ArmIrqState st = armIrqLockByPsr();
	u16 c2 = TMCNT(2), v2 = TMVAL(2);
	TMCNT(2) = 0; TMVAL(2) = 0; TMCNT(2) = 0x80;
	static const u16 pre[3] = { 0, 1, 3 }, pdiv[3] = { 1, 64, 1024 };
	// 1. start write -> first overflow (IF bit 3), reload 0xFFFF and 0xFFF0,
	//    32 starts at different delays: constant if the prescaler restarts on start
	for (int p = 1; p < 3; p++)
		for (int rl = 0; rl < 2; rl++) {
			u16 reload = rl ? 0xFFF0 : 0xFFFF;
			for (int r = 0; r < 32; r++) {
				TMCNT(0) = 0;
				REG32(0x04000214) = 1u << 3;
				TMVAL(0) = reload;
				for (volatile int d = 0; d < r * 3; d++) {}
				u16 t0 = TMVAL(2);
				TMCNT(0) = 0x80 | 0x40 | pre[p];
				u32 i = 0;
				while (!(REG32(0x04000214) & (1u << 3)) && ++i < 1000000) {}
				u16 t1 = TMVAL(2);
				buf_printf(&c, "start_to_overflow,%u,%04x,%d,%u\n", pdiv[p], reload, r, (u16)(t1 - t0));
			}
			TMCNT(0) = 0;
		}
	// 2. cascade: TM0 F/1 from 0xFFF0, TM1 cascade from 0: ticks from the
	//    IF bit to TM1's first count, as seen by one polling loop
	for (int r = 0; r < 16; r++) {
		TMCNT(0) = 0; TMCNT(1) = 0;
		REG32(0x04000214) = 1u << 3;
		TMVAL(0) = 0xFFF0; TMVAL(1) = 0;
		TMCNT(1) = 0x84;
		TMCNT(0) = 0xC0;
		u16 tif = 0, tc = 0;
		int seen_if = 0, seen_c = 0;
		for (u32 i = 0; i < 100000 && !(seen_if && seen_c); i++) {
			u16 t = TMVAL(2);
			if (!seen_if && (REG32(0x04000214) & (1u << 3))) { seen_if = 1; tif = t; }
			if (!seen_c && TMVAL(1) != 0) { seen_c = 1; tc = t; }
		}
		buf_printf(&c, "cascade_if_to_tm1,1,fff0,%d,%d\n", r, (int)(s16)(tc - tif));
	}
	TMCNT(0) = 0; TMCNT(1) = 0;
	// 3. TMCNT_L read right after the start write (counter left at a known value)
	for (int p = 0; p < 3; p++) {
		TMVAL(0) = 0x1234; TMCNT(0) = 0x80; TMCNT(0) = 0;   // counter now 0x1234 (+0..2)
		u16 before = TMVAL(0);
		TMVAL(0) = 0xFFF0;
		TMCNT(0) = 0x80 | pre[p];
		u16 a = TMVAL(0), b = TMVAL(0);
		buf_printf(&c, "read_after_start,%u,fff0,before_%04x,%04x %04x\n", pdiv[p], before, a, b);
	}
	// our clock back (hw_init's TM0+TM1), TM2 as it was
	TMCNT(0) = 0; TMCNT(1) = 0; TMVAL(0) = 0; TMVAL(1) = 0;
	TMCNT(1) = 0x84; TMCNT(0) = 0x80;
	TMCNT(2) = 0; TMVAL(2) = v2; TMCNT(2) = c2;
	REG32(0x04000214) = 1u << 3;
	armIrqUnlockByPsr(st);
	buf_write(&c, "cputime_timers.csv");
}
int main(void)
{
	hw_init(VERSION " - ARM9 cycles per op");
	s_main = aligned_alloc(32, 0x24000);
	s_other = aligned_alloc(32, 0x4000);
	if (!s_main || !s_other) { iprintf("OUT OF MEMORY\n"); hw_done(); }
	R_VRAMCNT(1) = 0x80;   // B: LCDC
	const Row rows[] = {
		{ "nop",            k_nop,        AT_DTCM, PREP_NONE, 16, 64 },
		{ "add_dep",        k_add_dep,    AT_DTCM, PREP_NONE, 16, 64 },
		{ "add_indep",      k_add_indep,  AT_DTCM, PREP_NONE, 16, 64 },
		{ "add_reg_shift",  k_add_shift,  AT_DTCM, PREP_NONE, 16, 64 },
		{ "b_taken",        k_b_taken,    AT_DTCM, PREP_NONE, 16, 64 },
		{ "b_not_taken",    k_b_not,      AT_DTCM, PREP_NONE, 16, 64 },
		{ "mul",            k_mul,        AT_DTCM, PREP_NONE, 16, 64 },
		{ "mul_dep",        k_mul_dep,    AT_DTCM, PREP_NONE, 16, 64 },
		{ "mla",            k_mla,        AT_DTCM, PREP_NONE, 16, 64 },
		{ "smull",          k_smull,      AT_DTCM, PREP_NONE, 16, 64 },
		{ "smulbb",         k_smulxy,     AT_DTCM, PREP_NONE, 16, 64 },
		{ "thumb_add_dep",  k_thumb_add,  AT_DTCM, PREP_NONE, 16, 64 },
		{ "thumb_b_taken",  k_thumb_b,    AT_DTCM, PREP_NONE, 16, 64 },
		{ "ldr_use_dtcm",   k_ld_use,     AT_DTCM, PREP_NONE, 16, 64 },
		{ "ldr_nouse_dtcm", k_ld_nouse,   AT_DTCM, PREP_NONE, 16, 64 },
		{ "ldr_use_main_hit", k_ld_use,   AT_MAIN, PREP_NONE, 16, 64 },
		{ "str_vram",       k_str,        AT_VRAM, PREP_NONE, 16, 64 },
		{ "str_vram_nop4",  k_str_nop4,   AT_VRAM, PREP_NONE, 16, 64 },
		{ "strh_vram",      k_strh,       AT_VRAM, PREP_NONE, 16, 64 },
		{ "str_main_wb",    k_str,        AT_MAIN, PREP_NONE, 16, 64 },
		{ "line_miss_clean_evict", k_ld_line, AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
		{ "line_miss_dirty_evict", k_ld_line, AT_MAIN_LINES, PREP_DIRTY, 8, 32 },
		// fill word order (clean lines): the missed word is word 0, 3, 4 or 7
		{ "fill_w0",        k_ld_line,    AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
		{ "fill_w3",        k_ld_line,    AT_MAIN_LINES + 3, PREP_CLEAN, 8, 32 },
		{ "fill_w4",        k_ld_line,    AT_MAIN_LINES + 4, PREP_CLEAN, 8, 32 },
		{ "fill_w7",        k_ld_line,    AT_MAIN_LINES + 7, PREP_CLEAN, 8, 32 },
		{ "fill_w0_then_w7", k_ld_w0w7,   AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
		{ "fill_w7_then_w0", k_ld_w7w0,   AT_MAIN_LINES, PREP_CLEAN, 8, 32 },
		// v3: per body (2-4 instructions), not per instruction
		{ "v3_add_then_shifted_operand", k_alu_shiftop, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_add_then_shift_amount", k_alu_shiftamt, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_adds_then_addeq", k_adds_addeq, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_cmp_beq_taken", k_cmp_beq_t, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_cmp_bne_not_taken", k_b_not, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_branch_taken_every_other", k_alt_branch, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_ldr_use_dist2_dtcm", k_ld_use2, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_ldr_use_dist3_dtcm", k_ld_use3, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_ldrb_use_dtcm", k_ldrb_use, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_ldrh_use_dtcm", k_ldrh_use, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_ldm4_use_last_dtcm", k_ldm4_use, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_str_then_ldr_dtcm", k_str_ldr, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_str_then_ldr_main_hit", k_str_ldr, AT_MAIN, PREP_NONE, 16, 64 },
		{ "v3_mla_use_dist1", k_mla_use1, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_mla_use_dist2", k_mla_use2, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_smull_use_dist1", k_smull_use1, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_smull_use_dist2", k_smull_use2, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_adr_bx", k_bx, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_adr_blx", k_blx, AT_DTCM, PREP_NONE, 16, 64 },
		{ "v3_thumb_bl", k_thumb_bl, AT_DTCM, PREP_NONE, 16, 64 },
	};
	// tb_ds test channel (tools/ds-tests/README.md "Result block"): the same
	// values (cyc_per_op_x100, in row order) at main RAM 0x023F0000, all
	// marked pass. The heap stays far below it.
	struct { vu32 magic, n, mask, done, value[32]; } *res = (void*)0x023F0000;
	const int nrows = sizeof rows / sizeof rows[0];
	res->magic = 0x52545344; res->n = nrows < 32 ? nrows : 32; res->done = 0;
	res->mask = nrows >= 32 ? 0xFFFFFFFF : (1u << nrows) - 1;
	Buf csv = {0};
	buf_printf(&csv, "op,n1,n2,t1,t2,cyc_per_op_x100\n");
	for (int i = 0; i < nrows; i++) {
		const Row* r = &rows[i];
		u32 p = r->where == AT_DTCM ? (u32)s_dtcm : r->where == AT_VRAM ? 0x06820000
		      : r->where == AT_MAIN ? (u32)s_main : (u32)s_main + 0x1000 + 4 * (r->where - AT_MAIN_LINES);
		u32 t1 = run(r->k, r->n1, p, r->prep), t2 = run(r->k, r->n2, p, r->prep);
		u32 c = (u32)((u64)(t2 - t1) * 2 * 100 / ((r->n2 - r->n1) * 64));
		if (i < 32) res->value[i] = c;
		buf_printf(&csv, "%s,%lu,%lu,%lu,%lu,%lu\n", r->name, (unsigned long)r->n1, (unsigned long)r->n2,
		           (unsigned long)t1, (unsigned long)t2, (unsigned long)c);
		iprintf("\x1b[4;0H%2d %-22s", i, r->name);
	}
	res->done = 1;
	timers();
	free(s_main);
	free(s_other);
	buf_write(&csv, "cputime.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\ncycles are ARM9 cycles (67 MHz); 64 ops per iteration, differential n1/n2, best of 5;"
	           " kernels in main RAM, I-cache warm; line_* load one word per fresh 32-byte line after 8 KiB of clean or"
	           " dirty lines (D-cache flushed first)\n", VERSION, __DATE__, __TIME__);
	buf_write(&info, "cputime_info.txt");
	hw_done();
}
