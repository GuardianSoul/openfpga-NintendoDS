// arm7time (docs/hw-reference.md "arm7time"; CPU and integration sessions):
// ARM7 cycles per op, ARM7 VRAM-as-WRAM access in VBlank vs display, and
// ARM9/ARM7 main-RAM contention. Our own ARM7 program (arm7.c) runs the
// kernels on command over PXI user channel 0; every wait here is bounded.
//   arm7time.csv: kernel, arg, arm7_cycles_per_op_x100
//   arm7time_contention.csv: case, rep, value (ARM9 cycles per line fill x100,
//     or ARM7 ticks for 5000 x 64 main-RAM loads)
#include "../common/hwref.h"
#include "arm7time.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "arm7time 1"
#define TIMEOUT_TICKS (2u * 33513982u)   // 2 s

static Mailbox s_mb;
static u32 s_slots[4];

static u32 a7(u32 cmd)
{
	u32 m;
	while (mailboxTryRecv(&s_mb, &m)) {}   // drop stale answers
	pxiSend(A7_CH, cmd);
	u32 t0 = now32();
	while (!mailboxTryRecv(&s_mb, &m))
		if (now32() - t0 > TIMEOUT_TICKS) return A7_BAD;
	return m;
}

// ARM9 line fills: 2048 loads 32 bytes apart over 64 KiB (the 4 KiB D-cache
// misses on each); ARM9 cycles per fill x 100
static u32 fill_rep(const vu32* buf)
{
	ArmIrqState st = armIrqLockByPsr();
	u32 t0 = now32(), s = 0;
	for (u32 i = 0; i < 2048; i++) s += buf[i * 8];
	u32 t = now32() - t0;
	armIrqUnlockByPsr(st);
	(void)s;
	return t * 2 * 100 / 2048;
}

static const char* s_names[A7K_NKERNELS] = {
	"alu", "alu_shift_by_reg", "b", "mul_rs8", "mul_rs16", "mul_rs24", "mul_rs32", "mla_rs8", "mla_rs16",
	"mla_rs24", "mla_rs32", "ldr_wram", "str_wram", "ldm4_wram", "stm4_wram", "swp_wram", "ldr_main", "str_main",
	"ldm4_main", "stm4_main", "swp_main", "code_main_alu", "code_main_alu_shift_by_reg", "code_main_b",
	"code_main_mul_rs32", "code_main_ldr_wram", "code_main_str_wram", "ldr_vram_c", "str_vram_c",
};

int main(void)
{
	hw_init(VERSION " - ARM7 timing");
	mailboxPrepare(&s_mb, s_slots, 4);
	pxiSetMailbox(A7_CH, &s_mb);
	Buf csv = {0}, con = {0};
	buf_printf(&csv, "kernel,arg,arm7_cycles_per_op_x100\n");
	buf_printf(&con, "case,rep,value\n");
	if (a7(A7K_PING) != 0x123456) {
		hw_status("ARM7 program not answering");
		buf_printf(&csv, "# ARM7 program not answering\n");
		buf_write(&csv, "arm7time.csv");
		hw_done();
	}
	// display on, both engines, BG0-3 and OBJ on engine A (bank A), for the
	// mid-display VRAM C rows; VRAM C to the ARM7 at 0x06000000
	R_VRAMCNT(0) = 0x81;
	R_VRAMCNT(2) = 0x82;
	REG32(0x04000000) = 0x10000 | (0xF << 8) | (1 << 12);
	REG32(0x04001000) = 0x10000;
	for (unsigned id = 0; id < A7K_NKERNELS; id++)
		for (u32 arg = 0; arg < (id >= A7K_LDR_VRAMC ? 2u : 1u); arg++) {
			hw_status("%s %lu", s_names[id], (unsigned long)arg);
			u32 r = a7(id | arg << 8);
			buf_printf(&csv, "%s,%lu,%ld\n", s_names[id], (unsigned long)arg, r == A7_BAD ? -1L : (long)r);
		}
	buf_write(&csv, "arm7time.csv");

	// contention: ARM9 line fills vs ARM7 main-RAM loads
	vu32* buf = aligned_alloc(32, 0x10000);
	if (buf) {
		for (int r = 0; r < 20; r++) buf_printf(&con, "arm9_fill_alone,%d,%lu\n", r, (unsigned long)fill_rep(buf));
		buf_printf(&con, "arm7_loads_alone,0,%lu\n", (unsigned long)a7(A7K_MAINLOAD | 5000u << 8));
		u32 m;
		while (mailboxTryRecv(&s_mb, &m)) {}
		pxiSend(A7_CH, A7K_MAINLOAD | 5000u << 8);
		u32 got = A7_BAD;
		// until the ARM7 is done, then 20 more (it starts at its next VBlank)
		for (int r = 0, after = 0; r < 2000 && after < 20; r++) {
			buf_printf(&con, "arm9_fill_with_arm7,%d,%lu\n", r, (unsigned long)fill_rep(buf));
			if (got != A7_BAD) after++;
			else if (mailboxTryRecv(&s_mb, &m)) { got = m; buf_printf(&con, "arm7_done_after_rep,%d,0\n", r); }
		}
		for (u32 t0 = now32(); got == A7_BAD && now32() - t0 < TIMEOUT_TICKS;)
			if (mailboxTryRecv(&s_mb, &m)) got = m;
		buf_printf(&con, "arm7_loads_with_arm9,0,%ld\n", got == A7_BAD ? -1L : (long)got);
		free((void*)buf);
	}
	buf_write(&con, "arm7time_contention.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nARM7 kernels: 64 ops per iteration, 4 and 16 iterations, best of 5, IRQs off,"
	           " ARM7 TM0+TM1 (ARM7 cycles); arg 0/1 for VRAM C = VCOUNT 192 / 96; contention: ARM9 2048 line fills"
	           " per rep (ARM9 cycles per fill x100) and ARM7 5000 x 64 loads of one main-RAM word (ARM7 ticks)\n",
	           VERSION, __DATE__, __TIME__);
	buf_write(&info, "arm7time_info.txt");
	hw_done();
}
