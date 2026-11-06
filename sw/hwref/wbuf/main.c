// wbuf (docs/hw-reference.md "wbuf"; integration session): does the
// ARM946E-S write buffer let main-RAM stores overlap the instructions after
// them, and how deep is it? ds-rules has STR to C=1 B=1 main RAM at 18 ARM9
// cycles back to back; this spaces the stores out and counts them.
//
// Each pattern is ARM code written into a 512-byte ITCM buffer (no fetches
// on the bus) and run 256 times, IRQs locked, timed with TM0 (F/1, system
// cycles = 33.5 MHz). The store buffer is 4 KiB of main RAM under MPU region
// 3, set per step to one cache/buffer mode:
//   nostore    every pattern with its stores left out (the baseline)
//   c1b1_miss  write-back, lines not cached (stores miss, no write-allocate)
//   c1b1_hit   write-back, lines cached (stores hit)
//   c1b0_miss  write-through, lines not cached;  c1b0_hit  lines cached
//   c0b1       uncached, bufferable;  c0b0  uncached, unbuffered
// Modes: iso = each repeat starts with the write buffer drained (CP15 c7,c10,4)
// and is timed alone: issue = TM0 read after the pattern, drained = TM0 read
// after a second drain; loop = 256 repeats back to back, timed as a whole.
// Patterns (integration's numbering): 1 STR + N NOPs; 2 K STRs (consecutive
// words) + 64 NOPs, or + a 1,024-cycle ALU loop instead; 3 as 2 to one word
// (same) or one per 32-byte line (lines); 4 STR + 0/4 NOPs + LDR from DTCM or
// a cached main-RAM line (region 1); 5 the same with that line cleaned and
// invalidated first (a fill behind the store); 6 STRH/STRB + 0/8 NOPs.
// wbuf.csv: case,pattern,mode,op,k,addr,nops,delay,load,reps,issue_x100,
// drained_x100,post (system cycles per repeat x 100, raw; net = minus the
// nostore row of the same pattern; post = NOPs after the load). v3 adds
// pattern 7 (STR, LDR from DTCM or a cached line, 32 NOPs: does the load
// wait for the store?) and K = 9-11; hwref.nds "new only" runs only those.
//
// Hang-safe: no waits on hardware state (fixed code, fixed loops); each step's
// rows written as it ends; wbuf_progress.txt ("V <version>", "start <case>",
// "done <case>"): a restart on the same card skips the steps that ended and
// the one that began without ending.
#include "../common/hwref.h"
#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "wbuf 3"
#define REPS 256
#define CODE_WORDS 128
#define ITCM_DATA __attribute__((section(".itcm")))

typedef struct { u32 timer, ld, buf, pad, sum1, sum2; } Ctx;
static Ctx s_ctx DTCM_BSS __attribute__((aligned(32)));
static u32 s_dtcm_word DTCM_BSS;
static u32 s_code[CODE_WORDS] ITCM_DATA __attribute__((aligned(32)));
static u32 s_line[8] __attribute__((aligned(32)));   // region 1: the load target of patterns 4, 5

enum { M_ISO, M_LOOP };
enum { OP_NONE, OP_STR, OP_STRH, OP_STRB };
enum { A_SEQ, A_SAME, A_LINES };
enum { L_NONE, L_DTCM, L_HIT, L_MISS };
static const char* const s_mode[] = { "iso", "loop" };
static const char* const s_op[] = { "none", "str", "strh", "strb" };
static const char* const s_addr[] = { "seq", "same", "lines" };
static const char* const s_load[] = { "none", "dtcm", "hit", "miss" };
typedef struct { u8 pattern, mode, op, k, addr, nops, delay, load, post; } Spec;

// ---- code generation (ARM). r0 repeats, r1 Ctx, r2 TM0, r3 load address,
// r4 store value, r5 store buffer, r6-r8 TM0 reads, r9/r10 sums, r11, r12 scratch.
static u32* s_pc;
static void emit(u32 w) { if (s_pc < s_code + CODE_WORDS) *s_pc = w; s_pc++; }
static void emit_b(u32 cond, const u32* to) { emit(cond | 0x0A000000 | (((u32)(to - (s_pc + 2))) & 0xFFFFFF)); }
#define NOP     0xE1A00000
#define DRAIN   0xEE07BF9A   // mcr p15, 0, r11, c7, c10, 4
#define CLINV3  0xEE073F3E   // mcr p15, 0, r3, c7, c14, 1 (clean and invalidate the line at r3)
#define LDRH_T(rd) (0xE1D200B0 | (rd) << 12)   // ldrh rd, [r2]

static void body(const Spec* s)
{
	for (int i = 0; i < s->k && s->op != OP_NONE; i++) {
		u32 off = s->addr == A_SEQ ? 4 * i : s->addr == A_LINES ? 32 * i : 0;
		if (s->op == OP_STR) emit(0xE5854000 | off);
		else if (s->op == OP_STRB) emit(0xE5C54000 | off);
		else emit(0xE1C540B0 | (off >> 4) << 8 | (off & 15));
	}
	for (int i = 0; i < s->nops; i++) emit(NOP);
	if (s->delay) {   // 256 x (subs 1 + bne taken 3) = 1,024 ARM9 cycles
		emit(0xE3A0CC01);   // mov r12, #256
		emit(0xE25CC001);   // subs r12, r12, #1
		emit(0x1AFFFFFD);   // bne .-4
	}
	if (s->load != L_NONE) emit(0xE593B000);   // ldr r11, [r3]
	for (int i = 0; i < s->post; i++) emit(NOP);
}

static bool gen(const Spec* s)
{
	s_pc = s_code;
	emit(0xE92D4FF0);   // push {r4-r11, lr}
	emit(0xE5912000); emit(0xE5913004); emit(0xE5915008);   // ldr r2/r3/r5, [r1, #0/4/8]
	emit(0xE3A04000); emit(0xE3A09000); emit(0xE3A0A000);   // mov r4/r9/r10, #0
	if (s->mode == M_ISO) {
		u32* top = s_pc;
		// odd repeats start 1 ARM9 cycle later (an executed ADD with a register
		// shift takes 2, a skipped one 1): TM0 counts in 2-cycle steps, so the
		// average then resolves half a system cycle
		emit(0xE3100001);   // tst r0, #1
		emit(0x108CCC1C);   // addne r12, r12, r12, lsl r12
		if (s->load == L_MISS) emit(CLINV3);
		emit(DRAIN);
		emit(LDRH_T(6));
		body(s);
		emit(LDRH_T(7));
		emit(DRAIN);
		emit(LDRH_T(8));
		emit(0xE0477006); emit(0xE0488006);   // sub r7, r7, r6; sub r8, r8, r6
		emit(0xE1A07807); emit(0xE0899827);   // r9 += (u16)r7
		emit(0xE1A08808); emit(0xE08AA828);   // r10 += (u16)r8
		emit(0xE2500001);                     // subs r0, r0, #1
		emit_b(0x10000000, top);              // bne top
	} else {
		emit(DRAIN);
		emit(LDRH_T(6));
		u32* top = s_pc;
		body(s);
		emit(0xE2500001);
		emit_b(0x10000000, top);
		emit(LDRH_T(7));
		emit(DRAIN);
		emit(LDRH_T(8));
		emit(0xE0477006); emit(0xE0488006);
		emit(0xE1A07807); emit(0xE0899827);
		emit(0xE1A08808); emit(0xE08AA828);
	}
	emit(0xE5819010); emit(0xE581A014);   // str r9/r10, [r1, #16/20]
	emit(0xE8BD8FF0);                     // pop {r4-r11, pc}
	return s_pc <= s_code + CODE_WORDS;
}

typedef void (*KFn)(u32 reps, Ctx* c);
static void run(u32 reps, u32* t1, u32* t2)
{
	ArmIrqState st = armIrqLockByPsr();
	((KFn)(void*)s_code)(reps, &s_ctx);
	armIrqUnlockByPsr(st);
	*t1 = s_ctx.sum1;
	*t2 = s_ctx.sum2;
}

// ---- the patterns
#define MAXSPEC 96
static Spec s_spec[MAXSPEC];
static int s_nspec;
static void add(u8 pattern, u8 mode, u8 op, u8 k, u8 addr, u8 nops, u8 delay, u8 load)
{
	if (s_nspec < MAXSPEC) s_spec[s_nspec++] = (Spec){ pattern, mode, op, k, addr, nops, delay, load, 0 };
}
static void specs(bool v3_only)
{
	// v3 (run 35 left these open): does a load wait for a pending store?
	// STR, LDR, then 32 NOPs (16 system cycles, longer than the ~8-cycle
	// drain): if the load doesn't wait, the NOPs cover the drain and the
	// final TM0 read (which waits for the buffer) costs nothing extra; if it
	// waits, +8. And the depth between 8 and 12 stores.
	for (int l = L_DTCM; l <= L_HIT; l++) {
		add(7, M_ISO, OP_STR, 1, A_SEQ, 0, 0, l);
		s_spec[s_nspec - 1].post = 32;
	}
	add(7, M_ISO, OP_STR, 1, A_SEQ, 32, 0, L_NONE);   // the same without the load
	for (int k = 9; k <= 11; k++) add(2, M_ISO, OP_STR, k, A_SEQ, 0, 1, L_NONE);
	if (v3_only) return;
	static const u8 ns[] = { 0, 1, 2, 4, 8, 16, 32 }, ks[] = { 1, 2, 4, 8, 12, 16, 20, 32 };
	for (int m = 0; m < 2; m++)
		for (unsigned i = 0; i < sizeof ns; i++) add(1, m, OP_STR, 1, A_SEQ, ns[i], 0, L_NONE);
	for (int a = A_SEQ; a <= A_LINES; a++)
		for (unsigned i = 0; i < sizeof ks; i++) {
			add(a == A_SEQ ? 2 : 3, M_ISO, OP_STR, ks[i], a, 64, 0, L_NONE);
			add(a == A_SEQ ? 2 : 3, M_ISO, OP_STR, ks[i], a, 0, 1, L_NONE);
		}
	for (int n = 0; n <= 4; n += 4) {
		add(4, M_ISO, OP_STR, 1, A_SEQ, n, 0, L_DTCM);
		add(4, M_ISO, OP_STR, 1, A_SEQ, n, 0, L_HIT);
		add(5, M_ISO, OP_STR, 1, A_SEQ, n, 0, L_MISS);
	}
	for (int op = OP_STRH; op <= OP_STRB; op++)
		for (int m = 0; m < 2; m++) {
			add(6, m, op, 1, A_SEQ, 0, 0, L_NONE);
			add(6, m, op, 1, A_SEQ, 8, 0, L_NONE);
		}
}

// ---- the cases: MPU region 3 over the store buffer
typedef struct { const char* name; s8 c, b; bool hit; } Case;
static const Case s_case[] = {
	{ "nostore",   -1, -1, false },
	{ "c0b0",       0,  0, false },
	{ "c0b1",       0,  1, false },
	{ "c1b0_miss",  1,  0, false },
	{ "c1b0_hit",   1,  0, true },
	{ "c1b1_miss",  1,  1, false },
	{ "c1b1_hit",   1,  1, true },
};
#define NCASE (int)(sizeof s_case / sizeof s_case[0])
#define RG 3
static u8* s_buf;   // 4 KiB, 4 KiB aligned
static u32 s_rg_saved, s_dc_saved, s_wb_saved, s_dp_saved, s_cp_saved;

static void region_set(int c, int b)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetRegionDataPerm(RG, CP15_PU_PERM_RW);
	armMpuSetRegionDCacheEnable(RG, c);
	armMpuSetRegionWrBufEnable(RG, b);
	armMpuSetRegion(RG, armMpuDefineRegion((uptr)s_buf, CP15_PU_4K));
	armIrqUnlockByPsr(st);
}
static void region_restore(void)
{
	ArmIrqState st = armIrqLockByPsr();
	armDCacheFlushAll();
	armMpuSetRegion(RG, s_rg_saved);
	armMpuSetDCacheConfig(s_dc_saved);
	armMpuSetWrBufConfig(s_wb_saved);
	armMpuSetDataPerm(s_dp_saved);
	armMpuSetCodePerm(s_cp_saved);
	armIrqUnlockByPsr(st);
}

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/wbuf_progress.txt", "a");
	if (!f) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(f, fmt, ap);
	va_end(ap);
	fputc('\n', f);
	fclose(f);
}

static char s_skip[NCASE + 1][16];
static int s_nskip;
static bool s_resume;
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/wbuf_progress.txt", "r");
	if (!f) return;
	char line[96], open_t[16] = "";
	bool ours = false, all = false;
	while (fgets(line, sizeof line, f)) {
		char nm[16];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;
		else if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %15s", nm) == 1) strcpy(open_t, nm);
		else if (sscanf(line, "done %15s", nm) == 1) { if (s_nskip < NCASE) strcpy(s_skip[s_nskip++], nm); open_t[0] = 0; }
	}
	fclose(f);
	if (!ours || all) { s_nskip = 0; return; }
	s_resume = true;
	if (open_t[0] && s_nskip <= NCASE) strcpy(s_skip[s_nskip++], open_t);
}
static bool skipped(const char* t)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], t)) return true;
	return false;
}

static void one_case(const Case* cs)
{
	if (skipped(cs->name)) return;
	progress("start %s", cs->name);
	iprintf("\x1b[6;0H%-12s            ", cs->name);
	if (cs->c >= 0) region_set(cs->c, cs->b);
	Buf csv = {0};
	for (int i = 0; i < s_nspec; i++) {
		Spec s = s_spec[i];
		if (cs->c < 0) s.op = OP_NONE;
		if (!gen(&s)) {
			buf_printf(&csv, "%s,%d,%s,%s,%d,%s,%d,%d,%s,0,,,%d\n", cs->name, s.pattern, s_mode[s.mode], s_op[s_spec[i].op], s.k,
			           s_addr[s.addr], s.nops, s.delay, s_load[s.load], s.post);
			continue;
		}
		if (cs->hit)   // the store targets cached (region 3 with C=1)
			for (u32 a = 0; a < 0x400; a += 32) (void)*(vu32*)(s_buf + a);
		s_ctx.ld = s.load == L_DTCM ? (u32)&s_dtcm_word : (u32)s_line;
		u32 t1, t2;
		run(2, &t1, &t2);   // the load line cached
		run(REPS, &t1, &t2);
		buf_printf(&csv, "%s,%d,%s,%s,%d,%s,%d,%d,%s,%d,%lu,%lu,%d\n", cs->name, s.pattern, s_mode[s.mode], s_op[s_spec[i].op], s.k,
		           s_addr[s.addr], s.nops, s.delay, s_load[s.load], REPS, (unsigned long)(t1 * 100 / REPS),
		           (unsigned long)(t2 * 100 / REPS), s.post);
	}
	if (cs->c >= 0) region_restore();
	if (hw_fat_ok) {
		FILE* f = fopen(HWREF_DIR "/wbuf.csv", "a");
		if (f) { fwrite(csv.p, 1, csv.len, f); fclose(f); }
	}
	free(csv.p);
	progress("done %s", cs->name);
}

int main(void)
{
	hw_init(VERSION " - ARM9 write buffer");
	iprintf(VERSION " - ARM9 write buffer\n\n");
	s_rg_saved = armMpuGetRegion(RG);
	s_dc_saved = armMpuGetDCacheConfig();
	s_wb_saved = armMpuGetWrBufConfig();
	s_dp_saved = armMpuGetDataPerm();
	s_cp_saved = armMpuGetCodePerm();
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nregion %d before %08lx; dcache %08lx wrbuf %08lx dperm %08lx cperm %08lx\n", VERSION,
	           __DATE__, __TIME__, RG, (unsigned long)s_rg_saved, (unsigned long)s_dc_saved, (unsigned long)s_wb_saved,
	           (unsigned long)s_dp_saved, (unsigned long)s_cp_saved);
	for (int i = 0; i < 8; i++) buf_printf(&info, "region %d %08lx\n", i, (unsigned long)armMpuGetRegion(i));
	s_buf = memalign(4096, 4096);
	bool ok = s_buf && !(s_rg_saved & 1);
	if (ok) {
		memset(s_buf, 0, 4096);
		s_ctx.timer = 0x04000100;
		s_ctx.buf = (u32)s_buf;
		specs(hw_new_only);   // new only: the v3 rows
		if (hw_fat_ok) load_progress();
		if (!s_resume) {
			remove(HWREF_DIR "/wbuf_progress.txt");
			progress("V " VERSION);
			Buf h = {0};
			buf_printf(&h, "case,pattern,mode,op,k,addr,nops,delay,load,reps,issue_x100,drained_x100,post\n");
			buf_write(&h, "wbuf.csv");
		}
		s_line[0] = 1;
		for (int c = 0; c < NCASE; c++) one_case(&s_case[c]);
		progress("all done");
	}
	buf_printf(&info, "buffer %08lx%s; code %08lx (ITCM); %d patterns x %d cases, %d repeats\n", (unsigned long)(u32)s_buf,
	           ok ? "" : " NOT RUN (no buffer or region 3 in use)", (unsigned long)(u32)s_code, s_nspec, NCASE, REPS);
	buf_write(&info, "wbuf_info.txt");
	hw_done();
}
