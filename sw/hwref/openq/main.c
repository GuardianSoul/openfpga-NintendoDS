// openq (docs/hw-reference.md "openq"): the last two open DS questions in
// docs/ds-rules.md that a probe can answer safely.
//
// 1. cascade (timers): how long after TM2 overflows does a cascaded TM3
//    count? TM2 F/1 reloads 0xFFF0 (overflows every 16 system cycles), TM3
//    counts up on it. 2,048 samples of both counts with a varying gap
//    (0-7 loop steps): one LDM of TM2 then TM3 (openq_casc_ldm.bin), and two
//    LDRH, TM3 first (openq_casc_rev.bin); 8 bytes per sample (u16 TM2
//    count, u16 TM2 control, u16 TM3 count, u16 TM3 control; rev: TM3 in
//    the first word). TM2/TM3 belong to calico: set back after.
// 2. mpu (CPU session, ds-rules "After an MCR to CP15 c1 that turns the
//    protection unit on"): code in main RAM writes CP15 and then runs 16
//    ADDs; the write takes away main RAM's code permission, so a fetch
//    under the new map aborts. Which ADD aborts says how many instructions
//    still ran under the old map. Cases: ctrl (protection unit and caches
//    off, region 1 no code access, then an MCR c1 that turns the unit on),
//    perm_cold / perm_warm (unit on: an MCR c5 that takes region 1's code
//    access away; the kernel's I-cache line invalidated or loaded). The
//    prefetch-abort vector points at a handler in ITCM for the test
//    (run.itcm.c): it records the address, gives the permission back and
//    retries; a third abort in one trial turns the unit off instead, so it
//    can't loop. 8 trials each.
// openq.csv: test,case,trial,value,detail.
//
// Hang-safe: no waits on hardware state; the cascade step first, the mpu
// step last; openq_progress.txt ("V <version>", "start <step>", "done
// <step>"): a restart on the same card skips the steps that ended and the
// one that began without ending.
#include "../common/hwref.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "openq 1"
#define ARMFN __attribute__((target("arm"), noinline))
#define TMCNT(n) REG16(0x04000102 + 4 * (n))
#define TMVAL(n) REG16(0x04000100 + 4 * (n))

static Buf s_csv;

// ---- 1. cascade
#define NSAMP 2048
ARMFN static void samp_ldm(u32* out, u32 n)
{
	__asm__ volatile(
		"mov r2, #0x04000000\n"
		"add r2, r2, #0x108\n"
		"1:\n"
		"ldmia r2, {r3, r12}\n"
		"stmia %0!, {r3, r12}\n"
		"and r3, %1, #7\n"
		"2: subs r3, r3, #1\n"
		"bpl 2b\n"
		"subs %1, %1, #1\n"
		"bne 1b\n"
		: "+r"(out), "+r"(n) : : "r2", "r3", "r12", "cc", "memory");
}
ARMFN static void samp_rev(u32* out, u32 n)
{
	__asm__ volatile(
		"mov r2, #0x04000000\n"
		"add r2, r2, #0x108\n"
		"1:\n"
		"ldrh r3, [r2, #4]\n"   // TM3 count first
		"ldrh r12, [r2]\n"      // then TM2
		"stmia %0!, {r3, r12}\n"
		"and r3, %1, #7\n"
		"2: subs r3, r3, #1\n"
		"bpl 2b\n"
		"subs %1, %1, #1\n"
		"bne 1b\n"
		: "+r"(out), "+r"(n) : : "r2", "r3", "r12", "cc", "memory");
}

static void cascade(void)
{
	u32* buf = malloc(NSAMP * 8);
	if (!buf) { buf_printf(&s_csv, "cascade,nomem,0,0,\n"); return; }
	for (int mode = 0; mode < 2; mode++) {
		memset(buf, 0, NSAMP * 8);
		ArmIrqState st = armIrqLockByPsr();
		u16 c2 = TMCNT(2), v2 = TMVAL(2), c3 = TMCNT(3), v3 = TMVAL(3);
		TMCNT(2) = 0; TMCNT(3) = 0;
		TMVAL(2) = 0xFFF0; TMVAL(3) = 0;
		TMCNT(3) = 0x84;   // count-up (cascade), start
		TMCNT(2) = 0x80;   // F/1, start
		if (mode == 0) samp_ldm(buf, NSAMP); else samp_rev(buf, NSAMP);
		TMCNT(2) = 0; TMCNT(3) = 0;
		TMVAL(2) = v2; TMVAL(3) = v3;   // reload = the count each had
		TMCNT(2) = c2; TMCNT(3) = c3;
		armIrqUnlockByPsr(st);
		hw_write(mode == 0 ? "openq_casc_ldm.bin" : "openq_casc_rev.bin", buf, NSAMP * 8);
		// summary: samples whose TM3*16 + TM2 phase went backwards (TM3 late)
		u32 back = 0, prev = 0;
		for (int i = 0; i < NSAMP; i++) {
			u16 t2 = mode == 0 ? buf[2 * i] & 0xFFFF : buf[2 * i + 1] & 0xFFFF;
			u16 t3 = mode == 0 ? buf[2 * i + 1] & 0xFFFF : buf[2 * i] & 0xFFFF;
			u32 t = (u32)t3 * 16 + (u16)(t2 - 0xFFF0);
			if (i && t < prev) back++;
			prev = t;
		}
		buf_printf(&s_csv, "cascade,%s,0,%lu,samples %d\n", mode == 0 ? "ldm" : "rev", (unsigned long)back, NSAMP);
	}
	free(buf);
}

// ---- 2. mpu
volatile u32 oq_abt_lr DTCM_BSS, oq_abt_n DTCM_BSS, oq_hcp DTCM_BSS;
void oq_pabt(void);

#define MRC(r) ({ u32 v_; __asm__ __volatile__("mrc p15, 0, %0, " r : "=r"(v_)); v_; })
ARMFN static u32 ctrl_get(void) { return MRC("c1, c0, 0"); }
ARMFN static void ctrl_set(u32 v) { __asm__ volatile("mcr p15, 0, %0, c1, c0, 0" :: "r"(v) : "memory"); }
ARMFN static u32 cperm_get(void) { return MRC("c5, c0, 3"); }
ARMFN static void cperm_set(u32 v) { __asm__ volatile("mcr p15, 0, %0, c5, c0, 3" :: "r"(v) : "memory"); }
ARMFN static void icache_inval(void) { __asm__ volatile("mcr p15, 0, %0, c7, c5, 0" :: "r"(0) : "memory"); }
ARMFN static u32 abt_sp(u32 set, u32 v)   // abort mode's SP: read, or write when set
{
	u32 old;
	__asm__ volatile(
		"mrs r2, cpsr\n"
		"bic r3, r2, #0x1F\n"
		"orr r3, r3, #0x17\n"
		"msr cpsr_c, r3\n"
		"mov %0, sp\n"
		"cmp %1, #0\n"
		"movne sp, %2\n"
		"msr cpsr_c, r2\n"
		: "=&r"(old) : "r"(set), "r"(v) : "r2", "r3", "cc");
	return old;
}

// the kernels (main RAM, region 1): the CP15 write, 16 ADDs, return
__attribute__((naked, target("arm"), noinline, aligned(32))) static void k_ctrl(u32 v)
{
	__asm__ volatile("mcr p15, 0, r0, c1, c0, 0\n.rept 16\nadd r1, r1, #1\n.endr\nbx lr\n");
}
__attribute__((naked, target("arm"), noinline, aligned(32))) static void k_perm(u32 v)
{
	__asm__ volatile("mcr p15, 0, r0, c5, c0, 3\n.rept 16\nadd r1, r1, #1\n.endr\nbx lr\n");
}

// one trial, IRQs locked by the caller; returns the index of the aborted
// instruction after the MCR (0-15 the ADDs, 16 the BX LR), or -1 none
ARMFN static int trial(int kase, u32* nabt)
{
	u32 c = ctrl_get(), p = cperm_get();
	u32 p_off = p & ~0xF0u;   // region 1: no code access
	void (*k)(u32) = kase == 0 ? k_ctrl : k_perm;
	oq_hcp = p;
	oq_abt_lr = 0;
	oq_abt_n = 0;
	if (kase == 0) {
		u32 off = c & ~(1u | 4u | 0x1000u);   // protection unit, D- and I-cache off
		armDCacheFlushAll();
		ctrl_set(off);
		cperm_set(p_off);   // takes effect when the unit comes on
		k(off | 1);
		ctrl_set(off);      // (the handler gave the permission back)
		cperm_set(p);
		icache_inval();
		ctrl_set(c);
	} else {
		if (kase == 1) icache_inval();
		else k(p);          // warm: the kernel's line in the I-cache
		k(p_off);
		cperm_set(p);
	}
	*nabt = oq_abt_n;
	if (!oq_abt_n) return -1;
	return (int)((oq_abt_lr - 4) - ((u32)k + 4)) / 4;
}

static void mpu(void)
{
	static const char* const kname[3] = { "ctrl", "perm_cold", "perm_warm" };
	vu32* vec = (vu32*)0x01FF800C;   // ITCM word 0x0C (the prefetch-abort vector), writable through region 5
	u32 h = (u32)oq_pabt;
	buf_printf(&s_csv, "mpu,info,0,%08lx,vector %08lx handler %08lx control %08lx cperm %08lx\n", (unsigned long)(u32)k_ctrl,
	           (unsigned long)*vec, (unsigned long)h, (unsigned long)ctrl_get(), (unsigned long)cperm_get());
	for (int kase = 0; kase < 3; kase++)
		for (int t = 0; t < 8; t++) {
			ArmIrqState st = armIrqLockByPsr();
			u32 sp = abt_sp(0, 0), saved = *vec, n = 0;
			*vec = 0xEA000000 | (((h - (0x0C + 8)) >> 2) & 0xFFFFFF);   // b oq_pabt
			int idx = trial(kase, &n);
			*vec = saved;
			abt_sp(1, sp);
			armIrqUnlockByPsr(st);
			buf_printf(&s_csv, "mpu,%s,%d,%d,aborts %lu lr %08lx\n", kname[kase], t, idx, (unsigned long)n,
			           (unsigned long)oq_abt_lr);
		}
}

// ---- progress, resume
static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/openq_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

#define NSTEP 2
static char s_skip[NSTEP + 1][16];
static int s_nskip;
static bool s_resume;
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/openq_progress.txt", "r");
	if (!f) return;
	char line[96], open_t[16] = "";
	bool ours = false, all = false;
	while (fgets(line, sizeof line, f)) {
		char nm[16];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;
		else if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %15s", nm) == 1) strcpy(open_t, nm);
		else if (sscanf(line, "done %15s", nm) == 1) { if (s_nskip < NSTEP) strcpy(s_skip[s_nskip++], nm); open_t[0] = 0; }
	}
	fclose(f);
	if (!ours || all) { s_nskip = 0; return; }
	s_resume = true;
	if (open_t[0] && s_nskip <= NSTEP) strcpy(s_skip[s_nskip++], open_t);
}
static bool skipped(const char* t)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], t)) return true;
	return false;
}

int main(void)
{
	hw_init(VERSION " - open questions");
	iprintf(VERSION " - open questions\n\n");
	if (hw_fat_ok) load_progress();
	if (!s_resume) {
		remove(HWREF_DIR "/openq_progress.txt");
		progress("V " VERSION);
		Buf h = {0};
		buf_printf(&h, "test,case,trial,value,detail\n");
		buf_write(&h, "openq.csv");
	}
	static const struct { const char* name; void (*fn)(void); } st[NSTEP] = { { "cascade", cascade }, { "mpu", mpu } };
	for (int k = 0; k < NSTEP; k++) {
		if (skipped(st[k].name)) continue;
		progress("start %s", st[k].name);
		iprintf("\x1b[6;0H%-12s", st[k].name);
		st[k].fn();
		if (hw_fat_ok) {
			FILE* f = fopen(HWREF_DIR "/openq.csv", "a");
			if (f) { fwrite(s_csv.p, 1, s_csv.len, f); fclose(f); }
		}
		free(s_csv.p);
		s_csv = (Buf){0};
		progress("done %s", st[k].name);
	}
	progress("all done");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_write(&info, "openq_info.txt");
	hw_done();
}
