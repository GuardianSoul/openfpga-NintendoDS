// ARM9 memory and DMA timing reference. docs/hw-reference.md "memtime".
//
// Every number is a difference of two loop lengths: (t(n2) - t(n1)) /
// (n2 - n1), best of REPS runs each, so the timer reads, the call and the
// loop entry cancel. 1 tick = 1 system cycle (33.514 MHz) = 2 ARM9 cycles.
// The kernels and the loops that time them run from ITCM with IRQs off.
#include "memtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "memtime 2"
#define REPS 5
#define N1 256
#define N2 1024

#define ITCM_DATA __attribute__((section(".itcm")))
#define R_WRAMCNT   REG8(0x04000247)
#define R_EXMEMCNT  REG16(0x04000204)
#define R_BG0OFS    REG32(0x04000010)

static u32 s_main[96 * 1024 / 4] __attribute__((aligned(32)));   // main RAM .bss
static u32 s_itcm[256] ITCM_DATA __attribute__((aligned(32)));
static u32 s_dtcm[256] DTCM_BSS __attribute__((aligned(32)));
static u32 s_save_pal[256], s_save_oam[256], s_save_wram[256];

static Buf s_csv, s_info, s_skip;
static int s_rmain = -1, s_rsled = -1;
static bool s_wram_ok, s_gba_ok;

static const char* const s_opname[OP_COUNT] = { "ldr", "ldrh", "ldrb", "ldm8", "str", "strh", "strb", "stm8" };
static const int s_opwidth[OP_COUNT] = { 32, 16, 8, 32, 32, 16, 8, 32 };

// Progress on fixed console rows (5: group, 6: item).
static void show(const char* group, const char* item)
{
	if (group) iprintf("\x1b[5;0H%-31s", group);
	iprintf("\x1b[6;0H%-31s", item);
}

static void cp32(volatile u32* d, const volatile u32* s, int n)
{
	for (int i = 0; i < n; i++) d[i] = s[i];
}

static s32 x100(u32 t1, u32 t2, u32 n1, u32 n2)
{
	s64 num = (s64)(s32)(t2 - t1) * 100, den = (s64)(n2 - n1);
	return (s32)((num >= 0 ? num + den / 2 : num - den / 2) / den);
}

static void row(const char* test, const char* region, int width, const char* op,
                u32 n1, u32 n2, u32 t1, u32 t2)
{
	buf_printf(&s_csv, "%s,%s,%d,%s,%lu,%lu,%lu,%lu,%ld\n", test, region, width, op,
	           (unsigned long)n1, (unsigned long)n2, (unsigned long)t1, (unsigned long)t2,
	           (long)x100(t1, t2, n1, n2));
}

static u32 best(KFn f, u32 base, u32 it, bool flush)
{
	u32 m = ~0u;
	if (!flush) mt_time(f, base, it, false);   // warm-up
	for (int r = 0; r < REPS; r++) {
		u32 t = mt_time(f, base, it, flush);
		if (t < m) m = t;
	}
	return m;
}

static void kern_row(const char* test, const char* region, const char* op, int width,
                     KFn f, u32 base, u32 per_iter, bool flush)
{
	u32 t1 = best(f, base, N1 / per_iter, flush);
	u32 t2 = best(f, base, N2 / per_iter, flush);
	row(test, region, width, op, N1, N2, t1, t2);
}

// ---- loads and stores ----
#define LOADS  0x0F
#define STORES 0xF0
#define ALL    0xFF
enum { NEED_NONE, NEED_MAIN, NEED_WRAM, NEED_GBA };
typedef struct {
	const char* region;
	u32 base;
	int mode;      // KM_*
	int cb;        // main-RAM region C/B bits (2*C + B), -1 = as found
	u8 ops;
	bool flush;    // D-cache flushed before each timed run
	int need;
} Region;

static void access_tests(void)
{
	const u32 m = (u32)s_main;
	const Region regs[] = {
		{ "itcm",           (u32)s_itcm, KM_SEQ,   -1, ALL, false, NEED_NONE },
		{ "dtcm",           (u32)s_dtcm, KM_SEQ,   -1, ALL, false, NEED_NONE },
		{ "main_c1b1_warm", m,           KM_SEQ,    3, ALL, false, NEED_MAIN },
		{ "main_c1b1_miss", m,           KM_ADV32,  3, ALL, true,  NEED_MAIN },
		{ "main_c1b0_warm", m,           KM_SEQ,    2, ALL, false, NEED_MAIN },
		{ "main_c1b0_miss", m,           KM_ADV32,  2, ALL, true,  NEED_MAIN },
		{ "main_c0b1_seq",  m,           KM_SEQ,    1, ALL, false, NEED_MAIN },
		{ "main_c0b1_s32",  m,           KM_S32,    1, ALL, false, NEED_MAIN },
		{ "main_c0b0_seq",  m,           KM_SEQ,    0, ALL, false, NEED_MAIN },
		{ "main_c0b0_s32",  m,           KM_S32,    0, ALL, false, NEED_MAIN },
		{ "wram",           0x03000000,  KM_SEQ,   -1, ALL, false, NEED_WRAM },
		{ "vram_b_lcdc",    0x06820000,  KM_SEQ,   -1, ALL, false, NEED_NONE },
		{ "palette",        0x05000000,  KM_SEQ,   -1, ALL, false, NEED_NONE },
		{ "oam",            0x07000000,  KM_SEQ,   -1, ALL, false, NEED_NONE },
		{ "io_dispstat",    0x04000004,  KM_FIX,   -1, LOADS, false, NEED_NONE },
		{ "io_bg0ofs",      0x04000010,  KM_FIX,   -1, STORES, false, NEED_NONE },
		{ "gba_rom",        0x08000000,  KM_SEQ,   -1, LOADS, false, NEED_GBA },
	};
	for (unsigned k = 0; k < sizeof regs / sizeof regs[0]; k++) {
		const Region* g = &regs[k];
		if ((g->need == NEED_MAIN && s_rmain < 0) || (g->need == NEED_WRAM && !s_wram_ok) ||
		    (g->need == NEED_GBA && !s_gba_ok)) {
			buf_printf(&s_skip, "skipped %s (not accessible)\n", g->region);
			continue;
		}
		if (mt_region_of(g->base) < 0) {
			buf_printf(&s_skip, "skipped %s (no MPU region)\n", g->region);
			continue;
		}
		show(NULL, g->region);
		if (g->cb >= 0) mt_cfg_set(s_rmain, g->cb >> 1, g->cb & 1);
		for (int op = 0; op < OP_COUNT; op++) {
			KFn f = g_kern[op][g->mode];
			if (!(g->ops & (1u << op)) || !f) continue;
			kern_row(op < OP_STR ? "load" : "store", g->region, s_opname[op], s_opwidth[op],
			         f, g->base, PER_ITER(op), g->flush);
		}
		if (g->cb >= 0) mt_cfg_restore();
	}
}

// ---- line fill and read-after-write (main RAM) ----
static void fill_raw_tests(void)
{
	if (s_rmain < 0) {
		buf_printf(&s_skip, "skipped fill, raw (main RAM not in an MPU region)\n");
		return;
	}
	show("fill / read-after-write", "");
	// fill: n1 = 0 lines missing (t1, warm), n2 = 1 (t2, after a flush),
	// so cyc_per_access = the miss penalty in cycles.
	static const char* const fname[4] = { "ldr_w0", "ldr_w7", "ldr_w0_w1", "ldr_w0_w7" };
	mt_cfg_set(s_rmain, 1, 1);
	for (int k = 0; k < 4; k++) {
		u32 base = (u32)s_main + 0x4000;
		u32 t1 = ~0u, t2 = ~0u;
		for (int r = 0; r < REPS; r++) {
			u32 a = mt_fill(g_k_fill[k], base, false), b = mt_fill(g_k_fill[k], base, true);
			if (a < t1) t1 = a;
			if (b < t2) t2 = b;
		}
		row("fill", "main_c1b1", 32, fname[k], 0, 1, t1, t2);
	}
	mt_cfg_restore();
	// raw: STR then LDR of the same word, 64 pairs (stride 32) per iteration;
	// cyc_per_access is per pair.
	static const struct { const char* region; int cb; } rr[] = {
		{ "main_c1b1_warm", 3 }, { "main_c1b0_warm", 2 }, { "main_c0b1_s32", 1 }, { "main_c0b0_s32", 0 },
	};
	for (int k = 0; k < 4; k++) {
		mt_cfg_set(s_rmain, rr[k].cb >> 1, rr[k].cb & 1);
		kern_row("raw", rr[k].region, "str_ldr", 32, g_k_raw, (u32)s_main, 64, false);
		mt_cfg_restore();
	}
}

// ---- instruction fetch ----
static void ifetch_tests(void)
{
	show("instruction fetch", "");
	struct { const char* region; const u32* sled; int mode; int icache_off; } t[] = {
		{ "itcm",             mt_sled_itcm, 0, 0 },
		{ "main_icache_warm", mt_sled_main, 0, 0 },
		{ "main_icache_cold", mt_sled_main, 1, 0 },
		{ "main_icache_off",  mt_sled_main, 1, 1 },
	};
	for (unsigned k = 0; k < sizeof t / sizeof t[0]; k++) {
		if (t[k].icache_off && s_rsled < 0) {
			buf_printf(&s_skip, "skipped ifetch %s (no MPU region)\n", t[k].region);
			continue;
		}
		show(NULL, t[k].region);
		if (t[k].icache_off) mt_cfg_set_icache(s_rsled, 0);
		u32 tt[2];
		for (int j = 0; j < 2; j++) {
			tt[j] = ~0u;
			for (int r = 0; r < REPS; r++) {
				u32 v = mt_ifetch(t[k].sled, j ? N2 : N1, t[k].mode);
				if (v < tt[j]) tt[j] = v;
			}
		}
		if (t[k].icache_off) mt_cfg_restore();
		row("ifetch", t[k].region, 32, "nop", N1, N2, tt[0], tt[1]);
	}
	// The kernels' loop: 64 NOPs + subs + bne per iteration, in ITCM.
	kern_row("calib", "itcm", "loop64_nop", 32, g_k_nop64, 0, 64, false);
}

// ---- DMA3, immediate start ----
static void dma_tests(void)
{
	show("DMA3", "");
	const u32 m = (u32)s_main, m2 = (u32)s_main + 0x8000;
	struct { const char* route; u32 src, dst, n1, n2; int need; } d[] = {
		{ "main_to_main", m, m2, N1, N2, NEED_MAIN },
		{ "main_to_vram", m, 0x06820000, N1, N2, NEED_MAIN },
		{ "vram_to_main", 0x06820000, m2, N1, N2, NEED_MAIN },
		{ "vram_to_vram", 0x06820000, 0x06830000, N1, N2, NEED_NONE },
		{ "main_to_pal",  m, 0x05000000, 64, 256, NEED_MAIN },
		{ "main_to_oam",  m, 0x07000000, 64, 256, NEED_MAIN },
		{ "main_to_wram", m, 0x03000000, 64, 256, NEED_WRAM },
		{ "wram_to_main", 0x03000000, m2, 64, 256, NEED_WRAM },
		{ "gba_to_main",  0x08000000, m2, N1, N2, NEED_GBA },
		// v2: a fixed I/O destination (BG0HOFS/BG0VOFS, the route of an HBlank
		// scroll table), destination control 2 below; zeroed again afterwards
		{ "main_to_io",   m, 0x04000010, N1, N2, NEED_MAIN },
	};
	for (unsigned k = 0; k < sizeof d / sizeof d[0]; k++) {
		if ((d[k].need == NEED_WRAM && !s_wram_ok) || (d[k].need == NEED_GBA && !s_gba_ok)) {
			buf_printf(&s_skip, "skipped dma %s (not accessible)\n", d[k].route);
			continue;
		}
		show(NULL, d[k].route);
		for (int w = 0; w < 2; w++) {
			u32 width = w ? 32 : 16, flags = w ? (1u << 26) : 0;
			if (d[k].dst >> 24 == 4) flags |= 2u << 21;      // I/O: fixed destination
			u32 tt[2];
			for (int j = 0; j < 2; j++) {
				u32 n = j ? d[k].n2 : d[k].n1;
				tt[j] = ~0u;
				for (int r = 0; r < REPS; r++) {
					armDCacheFlushAll();
					u32 v = mt_dma(d[k].src, d[k].dst, flags | n);
					if (v < tt[j]) tt[j] = v;
				}
			}
			row("dma", d[k].route, width, "dma3_imm", d[k].n1, d[k].n2, tt[0], tt[1]);
		}
	}
	R_BG0OFS = 0;
	buf_printf(&s_skip, "skipped dma itcm/dtcm routes (TCMs are not on the bus)\n");
}

// ---- v2: DMA3 into the geometry engine, last and in a file of its own ----
// The per-word cost of main RAM -> GX: the command port MTX_IDENTITY (0x454,
// one FIFO entry per word, the value ignored) and GXFIFO (0x400) with words
// packing four MTX_IDENTITY each. The counts stay at or under 160 entries, so
// the 256-entry FIFO can't fill even if the engine took none; every wait is
// bounded and the engine must be idle and empty before each run, or the GX
// rows stop there (a timeout row says so).
static Buf s_gx;
static u32 s_gx_timeouts;

static bool gx_idle(void)
{
	for (u32 i = 0; i < 2000000; i++) {
		u32 st = R_GXSTAT;
		if (!(st & GXSTAT_BUSY) && GXSTAT_LEVEL(st) == 0) return true;
	}
	s_gx_timeouts++;
	return false;
}

static void gx_tests(void)
{
	show("DMA3 to GX", "");
	u16 powcnt = R_POWCNT1;
	R_POWCNT1 = powcnt | (1u << 2) | (1u << 3);     // 3D rendering and geometry on
	u32* src = &s_main[0x4000 / 4];
	for (int i = 0; i < 160; i++) src[i] = 0x15151515u;  // MTX_IDENTITY x4 (also fine as port data)
	armDCacheFlushAll();
	struct { const char* route; u32 dst, n1, n2; } d[] = {
		{ "main_to_gxport", 0x04000454, 32, 128 },
		{ "main_to_gxfifo", 0x04000400, 8, 40 },
	};
	buf_printf(&s_gx, "test,region,width,op,n1,n2,t1,t2,cyc_per_access_x100\n");
	bool ok = gx_idle();
	for (unsigned k = 0; k < sizeof d / sizeof d[0] && ok; k++) {
		show(NULL, d[k].route);
		u32 tt[2];
		for (int j = 0; j < 2 && ok; j++) {
			u32 n = j ? d[k].n2 : d[k].n1;
			tt[j] = ~0u;
			for (int r = 0; r < REPS && ok; r++) {
				ok = gx_idle();
				if (!ok) break;
				u32 v = mt_dma((u32)src, d[k].dst, (1u << 26) | (2u << 21) | n);
				if (v < tt[j]) tt[j] = v;
			}
		}
		if (ok) buf_printf(&s_gx, "dma,%s,32,dma3_imm,%lu,%lu,%lu,%lu,%ld\n", d[k].route,
		                   (unsigned long)d[k].n1, (unsigned long)d[k].n2, (unsigned long)tt[0],
		                   (unsigned long)tt[1], (long)x100(tt[0], tt[1], d[k].n1, d[k].n2));
	}
	gx_idle();
	buf_printf(&s_gx, "info,gx_timeouts,0,none,0,0,0,0,%lu\n", (unsigned long)s_gx_timeouts);
	buf_printf(&s_gx, "info,dma_timeouts,0,none,0,0,0,0,%lu\n", (unsigned long)g_dma_timeouts);
	R_POWCNT1 = powcnt;
}

// ---- configuration dump ----
static const char* size_str(u32 n, char* buf)
{
	u64 sz = 2ull << n;
	if (sz >= (1ull << 20)) sprintf(buf, "%luM", (unsigned long)(sz >> 20));
	else sprintf(buf, "%luK", (unsigned long)(sz >> 10));
	return buf;
}

static void dump_cp15(Buf* b)
{
	Cp15 c;
	mt_cp15_read(&c);
	buf_printf(b, "cp15 control %08lx (MPU %lu, D-cache %lu, I-cache %lu, round-robin %lu, DTCM %lu, ITCM %lu)\n",
	           (unsigned long)c.ctrl, (unsigned long)(c.ctrl & 1), (unsigned long)(c.ctrl >> 2 & 1),
	           (unsigned long)(c.ctrl >> 12 & 1), (unsigned long)(c.ctrl >> 14 & 1),
	           (unsigned long)(c.ctrl >> 16 & 1), (unsigned long)(c.ctrl >> 18 & 1));
	buf_printf(b, "dcache_config %02lx icache_config %02lx wrbuf_config %02lx data_perm %08lx code_perm %08lx\n",
	           (unsigned long)c.dcache, (unsigned long)c.icache, (unsigned long)c.wrbuf,
	           (unsigned long)c.dperm, (unsigned long)c.iperm);
	buf_printf(b, "dtcm_region %08lx itcm_region %08lx\n", (unsigned long)c.dtcm, (unsigned long)c.itcm);
	buf_printf(b, "region,raw,enabled,base,size,dcache,wrbuf,icache,data_perm,code_perm\n");
	for (int i = 0; i < 8; i++) {
		u32 r = c.region[i];
		char sb[16];
		buf_printf(b, "%d,%08lx,%lu,%08lx,%s,%lu,%lu,%lu,%lu,%lu\n", i, (unsigned long)r,
		           (unsigned long)(r & 1), (unsigned long)(r & ~0xFFFu), size_str((r >> 1) & 0x1F, sb),
		           (unsigned long)(c.dcache >> i & 1), (unsigned long)(c.wrbuf >> i & 1),
		           (unsigned long)(c.icache >> i & 1), (unsigned long)(c.dperm >> (4 * i) & 15),
		           (unsigned long)(c.iperm >> (4 * i) & 15));
	}
	static const struct { const char* name; u32 a; } probe[] = {
		{ "itcm_buf", 0 }, { "dtcm_buf", 0 }, { "main_buf", 0 }, { "sled_main", 0 },
		{ "wram", 0x03000000 }, { "io", 0x04000000 }, { "palette", 0x05000000 },
		{ "vram_b", 0x06820000 }, { "oam", 0x07000000 }, { "gba_rom", 0x08000000 },
	};
	for (unsigned k = 0; k < sizeof probe / sizeof probe[0]; k++) {
		u32 a = probe[k].a;
		if (k == 0) a = (u32)s_itcm;
		if (k == 1) a = (u32)s_dtcm;
		if (k == 2) a = (u32)s_main;
		if (k == 3) a = (u32)mt_sled_main;
		buf_printf(b, "addr %-9s %08lx region %d\n", probe[k].name, (unsigned long)a, mt_region_of(a));
	}
}

int main(void)
{
	hw_init(VERSION " - memory timing");
	u32 t_start = now32();
	mt_cfg_save();
	s_rmain = mt_region_of((u32)s_main);
	s_rsled = mt_region_of((u32)mt_sled_main);

	u8 wramcnt = R_WRAMCNT, vramcnt_b = R_VRAMCNT(1);
	u16 exmemcnt = R_EXMEMCNT;
	s_wram_ok = (wramcnt & 3) != 3;
	s_gba_ok = true;

	buf_printf(&s_info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&s_info, "clock: TM0+TM1 cascade, 33513982 Hz (1 tick = 1 system cycle = 2 ARM9 cycles)\n");
	buf_printf(&s_info, "reps %d (best of), n1 %d n2 %d unless the row says otherwise\n", REPS, N1, N2);
	buf_printf(&s_info, "WRAMCNT %02x (ARM9 %s) EXMEMCNT %04x VRAMCNT_B %02x POWCNT1 %04x\n", wramcnt,
	           s_wram_ok ? "has shared WRAM" : "has none: ARM7 owns all 32K", exmemcnt, vramcnt_b, R_POWCNT1);
	dump_cp15(&s_info);
	buf_printf(&s_info, "main_region %d sled_region %d\n", s_rmain, s_rsled);

	// Areas the tests write: saved here, restored at the end.
	cp32(s_save_pal, (vu32*)0x05000000, 256);
	cp32(s_save_oam, (vu32*)0x07000000, 256);
	if (s_wram_ok) cp32(s_save_wram, (vu32*)0x03000000, 256);
	R_VRAMCNT(1) = 0x80;                       // bank B: LCDC at 0x06820000
	R_EXMEMCNT = exmemcnt & ~(1u << 7);        // GBA slot to the ARM9
	for (unsigned i = 0; i < sizeof s_main / 4; i++) s_main[i] = i * 0x9E3779B9u;

	buf_printf(&s_csv, "test,region,width,op,n1,n2,t1,t2,cyc_per_access_x100\n");
	show("loads / stores", "");
	access_tests();
	fill_raw_tests();
	ifetch_tests();
	dma_tests();
	show("all tests done", "");

	if (s_wram_ok) cp32((vu32*)0x03000000, s_save_wram, 256);
	cp32((vu32*)0x05000000, s_save_pal, 256);
	cp32((vu32*)0x07000000, s_save_oam, 256);
	R_EXMEMCNT = exmemcnt;
	R_VRAMCNT(1) = vramcnt_b;

	// Restored config, checked against what was found.
	Cp15 c;
	mt_cp15_read(&c);
	buf_printf(&s_info, "after restore: dcache_config %02lx icache_config %02lx wrbuf_config %02lx\n",
	           (unsigned long)c.dcache, (unsigned long)c.icache, (unsigned long)c.wrbuf);
	buf_printf(&s_info, "dma_timeouts %lu\n", (unsigned long)g_dma_timeouts);
	if (s_skip.p) buf_printf(&s_info, "%s", s_skip.p);
	buf_printf(&s_info, "total_cycles %lu\n", (unsigned long)(now32() - t_start));
	iprintf("\x1b[8;0Hwriting files...\n");
	buf_write(&s_csv, "memtime.csv");
	buf_write(&s_info, "memtime_info.txt");
	gx_tests();                                  // v2: last, after the files above are safe
	buf_write(&s_gx, "memtime_gx.csv");
	free(s_skip.p);
	hw_done();
}
