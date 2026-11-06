// lat2d (docs/hw-reference.md "lat2d"): when do 2D register writes take
// effect within a line? BG0 is an 8-bpp layer whose pixel at source x has
// palette index (x % 255) + 1, palette i = RGB(i & 31, i >> 5, 16), so a
// capture shows the BG0HOFS in effect at every pixel. At line 96, d system
// cycles after VCOUNT changes, one write is made:
//   hofs: BG0HOFS 0 -> 64
//   pal:  palette entry 0 (backdrop, BG0 off) blue -> red
//   bgon: DISPCNT BG0 off -> on
// The frame is captured (DISPCAPCNT source A, composited) into VRAM D and
// rows 88-103 are kept (lat2d_rows.bin: per test 16 x 256 u16). Also per
// line: cycles from the VCOUNT change to the HBlank flag (DISPSTAT bit 1)
// and to the HBlank IRQ handler's first instruction (lat2d_hblank.csv).
// melonDS latches 2D registers once per line at HBlank and delays DISPCNT
// layer enables by two lines (2D session, docs/2d-engine.md).
// v2 (2D session): HBlank DMA. DMA0, HBlank start, repeat, 16-bit, one unit
// per HBlank to BG0HOFS (fixed), source a table with entry i = 7i mod 255 (the layer encodes x mod 255),
// in main RAM or in VRAM B. Started in VBlank; lat2d_dma.bin keeps rows
// 0-191 (16-bit row x = 0 only is needed: the HOFS each line shows).
// v3 (2D session), more mid-line writes at line 96, same d sweep:
//   bg0cnt: BG0CNT map base 31 -> 29 (map 29 is map 31 shifted by 4 tiles)
//   win0h:  WIN0H (200, 201) -> (0, 255), BG0 inside WIN0 only
//   oam:    OBJ 0 (64x64, 8 bpp, solid OBJ palette 1 = red, BG0 off) X 0 -> 128
//   mosaic: BG0 mosaic on, MOSAIC BG H size 1 -> 8
//   bg2x:   mode 2, BG2 affine (same tiles, byte map base 28, identity
//           matrix), BG2X 0 -> 64.0
// v4 (2D session): bgon_fine, the DISPCNT BG0 enable at d = 1500..2120 in
// steps of 20, appended to lat2d_writes.csv and lat2d_rows.bin.
// and CPU wait states in VRAM (A as BG), palette and OAM, 256 LDRH and 256
// STRH, during line 96 (display) and line 200 (VBlank): lat2d_vramwait.csv.
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "lat2d 5"
#define LINE 96
#define ROW0 88
#define NROWS 16
#define R_BG0CNT  REG16(0x04000008)
#define R_BG0HOFS REG16(0x04000010)
#define R_DISPSTAT REG16(0x04000004)
#define R_BG2CNT  REG16(0x0400000C)
#define R_WIN0H   REG16(0x04000040)
#define R_WIN0V   REG16(0x04000044)
#define R_WININ   REG16(0x04000048)
#define R_WINOUT  REG16(0x0400004A)
#define R_MOSAIC  REG16(0x0400004C)
#define OAMW ((vu16*)0x07000000)
#define PAL ((vu16*)0x05000000)

static void wait_vblank_start(void) { while (R_VCOUNT != 192) {} }

// Waits for VCOUNT to become `line`, then d ticks; returns the ticks from the
// VCOUNT change to just before the write (the write follows at once).
static inline u32 at_line(int line, u32 d, u32* tv)
{
	while (R_VCOUNT == line) {}
	while (R_VCOUNT != line) {}
	u32 t0 = now32();
	while (now32() - t0 < d) {}
	*tv = t0;
	return now32() - t0;
}

static u32 s_hb[16] DTCM_BSS;
static volatile u32 s_nhb DTCM_BSS;
static void hblank_irq(void) { if (s_nhb < 16) s_hb[s_nhb++] = now32(); }

// ---- v5 (2D and integration sessions), the only part that runs in hwref.nds
// "new only". Same write sweep at line 96 (rows 88-103 captured):
//  1. blend/window registers mid-line, over BG0 solid red (palette 201, map
//     27, priority 0) and BG1 solid green (palette 200, map 26, priority 1),
//     blue backdrop: bldcnt (none -> BG0 alpha over BG1, EVA = EVB = 8),
//     bldalpha (EVA 16 EVB 0 -> 8/8), bldy (brightness up, EVY 0 -> 16),
//     winin (WIN0 = whole screen, inside BG0+BG1 -> BG1 only), winout (WIN0
//     empty, outside BG0+BG1 -> BG1 only)
//  2. bg0off (DISPCNT BG0 on -> off, BG1 behind) and fblank (DISPCNT bit 7 0 -> 1)
//     d = 50, 400, 800, 1200, 1500, 1600, 1700, 1900, 2100
//  3. win0h_fine and bg2x_fine (as v3's win0h and bg2x) at d = 1980..2140 step 8
//  rows: lat2d_v5_rows.bin (per test 16 x 256 u16), lat2d_v5_writes.csv
//  4. CPU loads from VRAM in VBlank (line 192) and mid-display (line 96, both
//     engines on, BG0-3 and OBJ on engine A reading bank A): LDR x16, LDRH x16,
//     LDMIA x4 and x8 from bank A at 0x06000000 (BG), LDR x16 from bank B at
//     LCDC 0x06820000; per kernel n = 16 and 64 iterations, 64 runs each,
//     ARM9 cycles per op from the difference (min and mean): lat2d_vramload.csv.
//     Code runs from main RAM, I-cache warm (ITCM is full in hwref.nds).
#define KV(name, body) \
	__attribute__((target("arm"), noinline, aligned(32))) static void name(u32 n, u32 p) \
	{ __asm__ volatile("1:\n" body "subs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p) : "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "cc", "memory"); }
#define R16X(s) s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n" s "\n"
KV(kv_ldr, R16X("ldr r1, [%1]"))
KV(kv_ldrh, R16X("ldrh r1, [%1]"))
KV(kv_ldm4, R16X("ldmia %1, {r1-r4}"))
KV(kv_ldm8, R16X("ldmia %1, {r1-r8}"))
typedef void (*KvFn)(u32 n, u32 p);

static u32 kv_time(KvFn k, u32 n, u32 p, int line)
{
	u32 tv;
	ArmIrqState st = armIrqLockByPsr();
	k(1, p);                        // warm the I-cache lines
	at_line(line, 100, &tv);
	u32 t0 = now32();
	k(n, p);
	u32 t = now32() - t0;
	armIrqUnlockByPsr(st);
	return t;
}

static void v5_part(u16* rows, Buf* csv, const u32 base_on, const u32 base_off)
{
	static const u32 dv[] = { 50, 400, 800, 1200, 1500, 1600, 1700, 1900, 2100 };
	const int nd = sizeof dv / sizeof dv[0];
	static const char* kinds[] = { "bldcnt", "bldalpha", "bldy", "winin", "winout", "bg0off", "fblank" };
	const int nk = 7;
	// solid tiles: 32 = palette 201 (red), 33 = 200 (green); maps 27 (BG0) and 26 (BG1)
	vu16* tiles = (vu16*)0x06000000;
	for (int i = 0; i < 32; i++) { tiles[32 * 32 + i] = 201 | 201 << 8; tiles[33 * 32 + i] = 200 | 200 << 8; }
	vu16* m27 = (vu16*)0x0600D800, *m26 = (vu16*)0x0600D000;
	for (int i = 0; i < 1024; i++) { m27[i] = 32; m26[i] = 33; }
	PAL[201] = 31;
	PAL[200] = 31 << 5;
	int n = 0;
	for (int k = 0; k < nk; k++)
		for (int i = 0; i < nd; i++, n++) {
			wait_vblank_start();
			PAL[0] = 31 << 10;
			R_BG0HOFS = 0;
			REG16(0x04000014) = 0;
			R_BG0CNT = (1 << 7) | (27 << 8) | 0;
			REG16(0x0400000A) = (1 << 7) | (26 << 8) | 1;   // BG1CNT, priority 1
			u32 disp = 0x10000 | (1 << 8) | (1 << 9);
			REG16(0x04000050) = 0;
			REG16(0x04000052) = 16;
			REG16(0x04000054) = 0;
			if (k == 0) REG16(0x04000052) = 8 | 8 << 8;
			if (k == 1) REG16(0x04000050) = 1 | 1 << 6 | 1 << 9;
			if (k == 2) REG16(0x04000050) = 1 | 2 << 6;
			if (k == 3 || k == 4) {
				disp |= 1 << 13;
				R_WIN0H = k == 3 ? (0 << 8) | 255 : 0;
				R_WIN0V = k == 3 ? (0 << 8) | 192 : 0;
				R_WININ = 3;
				R_WINOUT = 3;
			}
			R_DISPCNT = disp;
			R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_COMPOSITED) |
			            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(3);
			ArmIrqState st = armIrqLockByPsr();
			u32 tv, w = at_line(LINE, dv[i], &tv);
			if (k == 0) REG16(0x04000050) = 1 | 1 << 6 | 1 << 9;
			else if (k == 1) REG16(0x04000052) = 8 | 8 << 8;
			else if (k == 2) REG16(0x04000054) = 16;
			else if (k == 3) R_WININ = 2;
			else if (k == 4) R_WINOUT = 2;
			else if (k == 5) R_DISPCNT = disp & ~(1u << 8);
			else R_DISPCNT = disp | (1 << 7);
			armIrqUnlockByPsr(st);
			buf_printf(csv, "%s,%lu,%lu\n", kinds[k], (unsigned long)dv[i], (unsigned long)w);
			for (u32 t = 0; !gxp_capture_done() && t < 20000000; t++) {}
			memcpy(rows + n * NROWS * 256, (void*)(0x06860000 + ROW0 * 512), NROWS * 512);
			iprintf("\x1b[4;0H%s %2d/%d    ", kinds[k], i + 1, nd);
		}
	REG16(0x04000050) = 0;
	R_DISPCNT = base_on;
	R_BG0CNT = (1 << 7) | (31 << 8);
	PAL[200] = (200 & 31) | ((200 >> 5) << 5) | (16 << 10);
	PAL[201] = (201 & 31) | ((201 >> 5) << 5) | (16 << 10);
	// 3. the WIN0H / BG2X latch edge, as v3's win0h and bg2x
	for (int k = 0; k < 2; k++)
		for (u32 d = 1980; d <= 2140; d += 8, n++) {
			wait_vblank_start();
			R_DISPCNT = base_on;
			R_BG0HOFS = 0;
			PAL[0] = 31 << 10;
			R_BG0CNT = (1 << 7) | (31 << 8);
			if (k == 0) {
				R_DISPCNT = base_on | (1 << 13);
				R_WIN0H = (200 << 8) | 201;
				R_WIN0V = (0 << 8) | 192;
				R_WININ = 1;
				R_WINOUT = 0;
			} else {
				R_DISPCNT = 0x10000 | 2 | (1 << 10);
				R_BG2CNT = (1 << 13) | (28 << 8) | (1 << 14);
				REG16(0x04000020) = 0x100; REG16(0x04000022) = 0;
				REG16(0x04000024) = 0;     REG16(0x04000026) = 0x100;
				REG32(0x04000028) = 0;     REG32(0x0400002C) = 0;
			}
			R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_COMPOSITED) |
			            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(3);
			ArmIrqState st = armIrqLockByPsr();
			u32 tv, w = at_line(LINE, d, &tv);
			if (k == 0) R_WIN0H = (0 << 8) | 255;
			else REG32(0x04000028) = 64 << 8;
			armIrqUnlockByPsr(st);
			buf_printf(csv, "%s,%lu,%lu\n", k ? "bg2x_fine" : "win0h_fine", (unsigned long)d, (unsigned long)w);
			for (u32 t = 0; !gxp_capture_done() && t < 20000000; t++) {}
			memcpy(rows + n * NROWS * 256, (void*)(0x06860000 + ROW0 * 512), NROWS * 512);
		}
	R_DISPCNT = base_on;
	(void)base_off;
}

static void v5_vramload(const u32 base_on)
{
	Buf c = {0};
	buf_printf(&c, "kernel,line,ops_per_iter,min_cycles_per_op_x100,mean_cycles_per_op_x100\n");
	// display load: engine A mode 0 with BG0-3 (bank A tiles/maps) and OBJ 0; engine B BG0 on bank C
	R_VRAMCNT(1) = 0x80;     // B: LCDC (kernel d)
	R_VRAMCNT(2) = 0x84;     // C: sub BG
	for (int i = 1; i < 4; i++) REG16(0x04000008 + 2 * i) = (1 << 7) | (31 << 8) | i;
	REG32(0x04001000) = 0x10000 | (1 << 8);
	REG16(0x04001008) = 0;
	OAMW[0] = 0x2000 | ROW0;
	OAMW[1] = 0xC000;
	OAMW[2] = 0;
	R_DISPCNT = base_on | (0xF << 8) | (1 << 12);
	static const struct { const char* name; KvFn k; u32 addr; u32 ops; } kk[] = {
		{ "ldr_bg_a", kv_ldr, 0x06000100, 16 }, { "ldrh_bg_a", kv_ldrh, 0x06000100, 16 },
		{ "ldm4_bg_a", kv_ldm4, 0x06000100, 64 }, { "ldm8_bg_a", kv_ldm8, 0x06000100, 128 },
		{ "ldr_lcdc_b", kv_ldr, 0x06820100, 16 },
	};
	for (unsigned k = 0; k < sizeof kk / sizeof kk[0]; k++)
		for (int ln = 0; ln < 2; ln++) {
			int line = ln ? 192 : LINE;
			u32 mn = ~0u, sum = 0;
			for (int r = 0; r < 64; r++) {
				u32 a = kv_time(kk[k].k, 16, kk[k].addr, line), b = kv_time(kk[k].k, 64, kk[k].addr, line);
				u32 v = (b - a) * 2 * 100 / (48 * kk[k].ops);   // ARM9 cycles per op x 100 (ldm: per word)
				if (v < mn) mn = v;
				sum += v;
			}
			buf_printf(&c, "%s,%d,%lu,%lu,%lu\n", kk[k].name, line, (unsigned long)kk[k].ops, (unsigned long)mn,
			           (unsigned long)(sum / 64));
		}
	OAMW[0] = 1 << 9;
	R_DISPCNT = base_on;
	buf_write(&c, "lat2d_vramload.csv");
}

static void v5(const u32 base_on, const u32 base_off)
{
	const int ntests = 7 * 9 + 2 * 21;
	u16* rows = malloc(ntests * NROWS * 256 * 2);
	if (!rows) { iprintf("OUT OF MEMORY\n"); return; }
	Buf csv = {0};
	buf_printf(&csv, "kind,d_ticks,write_ticks_after_vcount\n");
	v5_part(rows, &csv, base_on, base_off);
	buf_write(&csv, "lat2d_v5_writes.csv");
	hw_write("lat2d_v5_rows.bin", rows, ntests * NROWS * 512);
	free(rows);
	v5_vramload(base_on);
}

int main(void)
{
	hw_init(VERSION " - 2D latch timing");
	gxp_console_on_h();
	iprintf(VERSION " - 2D latch timing\n\n");
	// BG0: 8-bpp text, map base 31 (0x6000F800), tiles at base 0, VRAM A as main BG
	R_VRAMCNT(0) = 0x81;
	R_VRAMCNT(3) = 0x80;   // D: LCDC, capture
	vu16* tiles = (vu16*)0x06000000;
	for (int c = 0; c < 32; c++)
		for (int py = 0; py < 8; py++)
			for (int px = 0; px < 8; px += 2) {
				int x = c * 8 + px;
				tiles[(c * 64 + py * 8 + px) / 2] = ((x % 255) + 1) | ((((x + 1) % 255) + 1) << 8);
			}
	vu16* map = (vu16*)0x0600F800;
	for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) map[y * 32 + x] = x;
	for (int i = 1; i < 256; i++) PAL[i] = (i & 31) | ((i >> 5) << 5) | (16 << 10);
	R_BG0CNT = (1 << 7) | (31 << 8);   // 8 bpp, map base 31
	// v3: map 29 = map 31 shifted by 4 tiles; affine byte map at base 28
	vu16* map29 = (vu16*)0x0600E800;
	for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) map29[y * 32 + x] = (x + 4) & 31;
	vu16* amap = (vu16*)0x0600E000;
	for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x += 2) amap[(y * 32 + x) / 2] = x | ((x + 1) << 8);
	// OBJ: VRAM B as main OBJ, 16 KiB of palette index 1; OBJ palette 1 red
	R_VRAMCNT(1) = 0x80;
	for (int i = 0; i < 0x2000; i++) ((vu16*)0x06820000)[i] = 0x0101;
	R_VRAMCNT(1) = 0x82;
	((vu16*)0x05000200)[1] = 31;
	for (int i = 1; i < 128; i++) OAMW[i * 4] = 1 << 9;   // hidden
	const u32 base_on = 0x10000 | (1 << 8), base_off = 0x10000;   // mode 0, display on; BG0
	if (hw_new_only) {   // hwref.nds "new only": v5 alone
		v5(base_on, base_off);
		Buf info = {0};
		buf_printf(&info, "%s\nbuilt %s %s\nnew only: v5 (lat2d_v5_writes.csv, lat2d_v5_rows.bin, lat2d_vramload.csv)\n",
		           VERSION, __DATE__, __TIME__);
		buf_write(&info, "lat2d_info.txt");
		hw_done();
	}

	static const u32 ds[] = { 0, 150, 300, 450, 600, 750, 900, 1050, 1200, 1350, 1500, 1575, 1650,
	                          1725, 1800, 1875, 1950, 2025, 2100 };
	const int nd = sizeof ds / sizeof ds[0];
#define NKINDS 8
	const char* kinds[NKINDS] = { "hofs", "pal", "bgon", "bg0cnt", "win0h", "oam", "mosaic", "bg2x" };
#define NFINE 32
	u16* rows = malloc((NKINDS * nd + NFINE) * NROWS * 256 * 2);
	if (!rows) { iprintf("OUT OF MEMORY\n"); hw_done(); }
	Buf csv = {0};
	buf_printf(&csv, "kind,d_ticks,write_ticks_after_vcount\n");
	for (int k = 0; k < NKINDS; k++)
		for (int i = 0; i < nd; i++) {
			wait_vblank_start();
			R_DISPCNT = k == 0 || k == 3 || k == 6 ? base_on : base_off;
			R_BG0HOFS = 0;
			PAL[0] = 31 << 10;
			R_BG0CNT = (1 << 7) | (31 << 8) | (k == 6 ? 1 << 6 : 0);
			R_MOSAIC = 0;
			if (k == 4) {   // WIN0 on, BG0 inside only
				R_DISPCNT = base_on | (1 << 13);
				R_WIN0H = (200 << 8) | 201;
				R_WIN0V = (0 << 8) | 192;
				R_WININ = 1;
				R_WINOUT = 0;
			}
			if (k == 5) {   // OBJ on, BG0 off
				R_DISPCNT = base_off | (1 << 12);
				OAMW[0] = 0x2000 | ROW0;
				OAMW[1] = 0xC000 | 0;
				OAMW[2] = 0;
			}
			if (k == 7) {   // mode 2 (BG2 and BG3 affine on the DS; mode 1's affine layer is BG3)
				R_DISPCNT = 0x10000 | 2 | (1 << 10);
				R_BG2CNT = (1 << 13) | (28 << 8) | (1 << 14);
				REG16(0x04000020) = 0x100; REG16(0x04000022) = 0;
				REG16(0x04000024) = 0;     REG16(0x04000026) = 0x100;
				REG32(0x04000028) = 0;     REG32(0x0400002C) = 0;
			}
			R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_COMPOSITED) |
			            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(3);
			ArmIrqState st = armIrqLockByPsr();
			u32 tv, w = at_line(LINE, ds[i], &tv);
			if (k == 0) R_BG0HOFS = 64;
			else if (k == 1) PAL[0] = 31;
			else if (k == 2) R_DISPCNT = base_on;
			else if (k == 3) R_BG0CNT = (1 << 7) | (29 << 8);
			else if (k == 4) R_WIN0H = (0 << 8) | 255;
			else if (k == 5) OAMW[1] = 0xC000 | 128;
			else if (k == 6) R_MOSAIC = 7;
			else REG32(0x04000028) = 64 << 8;
			armIrqUnlockByPsr(st);
			buf_printf(&csv, "%s,%lu,%lu\n", kinds[k], (unsigned long)ds[i], (unsigned long)w);
			for (u32 t = 0; !gxp_capture_done() && t < 20000000; t++) {}
			memcpy(rows + (k * nd + i) * NROWS * 256, (void*)(0x06860000 + ROW0 * 512), NROWS * 512);
			iprintf("\x1b[4;0H%s %2d/%d ", kinds[k], i + 1, nd);
		}
	for (int i = 0; i < NFINE && rows; i++) {   // v4: bgon_fine
		u32 d = 1500 + 20 * i;
		wait_vblank_start();
		R_DISPCNT = base_off;
		R_BG0HOFS = 0;
		PAL[0] = 31 << 10;
		R_BG0CNT = (1 << 7) | (31 << 8);
		R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_COMPOSITED) |
		            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(3);
		ArmIrqState st = armIrqLockByPsr();
		u32 tv, w = at_line(LINE, d, &tv);
		R_DISPCNT = base_on;
		armIrqUnlockByPsr(st);
		buf_printf(&csv, "bgon_fine,%lu,%lu\n", (unsigned long)d, (unsigned long)w);
		for (u32 t = 0; !gxp_capture_done() && t < 20000000; t++) {}
		memcpy(rows + (NKINDS * nd + i) * NROWS * 256, (void*)(0x06860000 + ROW0 * 512), NROWS * 512);
	}
	buf_write(&csv, "lat2d_writes.csv");
	OAMW[0] = 1 << 9;
	R_DISPCNT = base_on;
	R_BG0CNT = (1 << 7) | (31 << 8);
	hw_write("lat2d_rows.bin", rows, (NKINDS * nd + NFINE) * NROWS * 512);
	free(rows);

	// HBlank DMA to BG0HOFS: which table entry does each line show?
	{
		u16* tbl = aligned_alloc(32, 512);
		u16* out = malloc(2 * 192 * 2);
		R_VRAMCNT(1) = 0x80;   // B: LCDC, the second table
		vu16* vt = (vu16*)0x06820000;
		for (int i = 0; i < 256; i++) { tbl[i] = (7 * i) % 255; vt[i] = (7 * i) % 255; }
		DC_FlushRange(tbl, 512);
		for (int src = 0; src < 2 && out; src++) {
			wait_vblank_start();
			R_DISPCNT = base_on;
			R_BG0HOFS = 0;
			REG32(0x040000B0) = src ? 0x06820000 : (u32)tbl;
			REG32(0x040000B4) = 0x04000010;
			REG32(0x040000B8) = 1 | (2u << 21) | (1u << 25) | (2u << 27) | (1u << 31);   // fixed dest, repeat, 16-bit, HBlank
			R_DISPCAP = DCAP_ENABLE | DCAP_MODE(DCAP_MODE_A) | DCAP_SRC_A(DCAP_SRC_A_COMPOSITED) |
			            DCAP_SIZE(DCAP_SIZE_256x192) | DCAP_BANK(3);
			while (R_VCOUNT != 1) {}
			for (u32 t = 0; !gxp_capture_done() && t < 20000000; t++) {}
			REG32(0x040000B8) = 0;
			for (int y = 0; y < 192; y++) out[src * 192 + y] = ((vu16*)0x06860000)[y * 256];   // pixel x = 0
		}
		if (out) hw_write("lat2d_dma.bin", out, 2 * 192 * 2);
		free(out);
		free(tbl);
	}

	// CPU wait states in VRAM (A, as main BG), palette and OAM: 256 LDRH and
	// 256 STRH, starting 200 ticks into line 96 (display) or line 200 (VBlank)
	{
		Buf vw = {0};
		buf_printf(&vw, "target,op,line,ticks_for_256\n");
		static const u32 tgt[3] = { 0x06000000, 0x05000000, 0x07000000 };
		static const char* tn[3] = { "vram_a_bg", "palette", "oam" };
		R_DISPCNT = base_on | (1 << 12);
		for (int t = 0; t < 3; t++)
			for (int op = 0; op < 2; op++)
				for (int ln = 0; ln < 2; ln++) {
					vu16* q = (vu16*)(tgt[t] + 0x100);   // clear of OBJ 0, palette entry 0 and BG0's tiles' first bytes
					u32 best = ~0u;
					for (int r = 0; r < 3; r++) {
						ArmIrqState st = armIrqLockByPsr();
						u32 tv, sum = 0;
						at_line(ln ? 200 : LINE, 200, &tv);
						u32 t0 = now32();
						if (op) for (int i = 0; i < 256; i++) q[i & 15] = q[i & 15];
						else for (int i = 0; i < 256; i++) sum += q[i & 15];
						u32 dt = now32() - t0;
						armIrqUnlockByPsr(st);
						(void)sum;
						if (dt < best) best = dt;
					}
					buf_printf(&vw, "%s,%s,%d,%lu\n", tn[t], op ? "ldrh_strh" : "ldrh", ln ? 200 : LINE, (unsigned long)best);
				}
		buf_write(&vw, "lat2d_vramwait.csv");
	}

	// HBlank flag and IRQ, relative to the VCOUNT change, lines 96..111
	Buf hb = {0};
	buf_printf(&hb, "line,vcount_to_hblank_flag,vcount_to_hblank_irq\n");
	u32 tv0[16], tflag[16];
	ArmIrqState st = armIrqLockByPsr();
	for (int l = 0; l < 16; l++) {
		while (R_VCOUNT != 96 + l) {}
		tv0[l] = now32();
		while (!(R_DISPSTAT & 2)) {}
		tflag[l] = now32();
	}
	armIrqUnlockByPsr(st);
	wait_vblank_start();
	s_nhb = 0;
	irqSet(IRQ_HBLANK, hblank_irq);
	u32 tv1[16];
	while (R_VCOUNT != 95) {}
	R_DISPSTAT |= 1 << 4;
	irqEnable(IRQ_HBLANK);
	for (int l = 0; l < 16; l++) { while (R_VCOUNT != 96 + l) {} tv1[l] = now32(); }
	irqDisable(IRQ_HBLANK);
	for (int l = 0; l < 16; l++)
		buf_printf(&hb, "%d,%lu,%ld\n", 96 + l, (unsigned long)(tflag[l] - tv0[l]),
		           l < (int)s_nhb ? (long)(s_hb[l + 1 < (int)s_nhb ? l + 1 : l] - tv1[l]) : -1L);
	buf_write(&hb, "lat2d_hblank.csv");

	v5(base_on, base_off);
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nlat2d_dma.bin: for source main RAM then VRAM B, pixel x = 0 of rows 0-191 (u16); table entry i = 7i mod 255\nwrite at line %d, d ticks after the VCOUNT change (1 tick = 1 system cycle, 2130 per line);"
	           " rows %d..%d of each capture in lat2d_rows.bin, order kind (hofs, pal, bgon, bg0cnt, win0h, oam, mosaic, bg2x) then d; %d d values\n"
	           "BG0 pixel at source x = palette index (x %% 255) + 1 = RGB(i & 31, i >> 5, 16); backdrop blue 0x7C00 -> red 0x001F\n",
	           VERSION, __DATE__, __TIME__, LINE, ROW0, ROW0 + NROWS - 1, nd);
	buf_write(&info, "lat2d_info.txt");
	hw_done();
}
