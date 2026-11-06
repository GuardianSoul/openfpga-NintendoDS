// dmacpu (docs/hw-reference.md "dmacpu"): does the ARM9 keep executing from
// ITCM/DTCM (or its caches) while an ARM9 DMA owns the bus? GBATEK ("DS
// DMA"): "The CPU can be kept running during DMA, provided that it is
// accessing only TCM (or cached memory), otherwise the CPU is halted until
// DMA finishes." melonDS stops the ARM9 for any ARM9 DMA (CPUStop_DMA9).
//
// DMA3, 32-bit, immediate, 0x8000 words, main RAM -> main RAM or VRAM A ->
// VRAM B (LCDC). Meanwhile a loop of k reads; then a timer read (I/O, so it
// waits for the DMA). Per variant and k: DMA + loop, loop alone, DMA alone
// (min of 3). Running alongside: DMA + loop ~ max(DMA, loop); halted:
// ~ DMA + loop.
// v2 (CPU session), dmacpu_collide.csv: uncached loads from (or stores to)
// the DMA destination right after the DMA start, at offsets near its start,
// middle and end. The destination is filled with 0xAAAAAAAA and the source
// with 0x55000000 | word index. A load that sees the old fill ran before
// the DMA reached that word, so it interleaved; seeing the new value at
// every offset means it waited for the DMA. A store marker (0xC0DE0000 |
// offset) the DMA overwrote got in early; one that survives waited.
#include "dmacpu.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "dmacpu 2"
#define WORDS 0x8000

// The same loop in main RAM (ARM state), for the instruction-cache variants.
__attribute__((target("arm"), noinline)) static u32 dk_loop_main(const vu32* d, u32 k)
{
	u32 s = 0;
	for (u32 i = 0; i < k; i++) s += d[i & 7];
	return s;
}

static u32 s_dtcm[8] DTCM_BSS __attribute__((aligned(32)));
static u32 s_mdata[8] __attribute__((aligned(32)));

typedef struct { const char* name; dk_loop_fn fn; const vu32* data; u32 clear; } Variant;

int main(void)
{
	hw_init(VERSION " - CPU during DMA");
	u32* a = malloc(WORDS * 4), *b = malloc(WORDS * 4);
	if (!a || !b) { iprintf("OUT OF MEMORY\n"); hw_done(); }
	R_VRAMCNT(0) = 0x80;
	R_VRAMCNT(1) = 0x80;
	for (int i = 0; i < 8; i++) { s_dtcm[i] = i; s_mdata[i] = i; }
	const Variant vs[] = {
		{ "itcm_code_dtcm_data",   dk_loop_itcm, s_dtcm,  0 },
		{ "itcm_code_main_dc_on",  dk_loop_itcm, s_mdata, 0 },
		{ "itcm_code_main_dc_off", dk_loop_itcm, s_mdata, 1u << 2 },
		{ "main_code_ic_on_dtcm",  dk_loop_main, s_dtcm,  0 },
		{ "main_code_ic_off_dtcm", dk_loop_main, s_dtcm,  1u << 12 },
	};
	static const u32 ks[] = { 0, 1000, 4000, 16000, 64000 };
	Buf csv = {0};
	buf_printf(&csv, "variant,dma,k,dma_plus_loop,loop_alone,dma_alone,sum\n");
	for (int v = 0; v < (int)(sizeof vs / sizeof vs[0]); v++)
		for (int m = 0; m < 2; m++) {
			u32 src = m ? 0x06800000 : (u32)a, dst = m ? 0x06820000 : (u32)b;
			for (int j = 0; j < 5; j++) {
				u32 best[3] = { ~0u, ~0u, ~0u }, sum = 0;
				for (int r = 0; r < 4; r++) {   // r = 0 warms caches; min of 1..3
					u32 t[3];
					t[0] = dk_measure(src, dst, WORDS, vs[v].fn, vs[v].data, ks[j], vs[v].clear, &sum);
					t[1] = dk_measure(src, dst, 0, vs[v].fn, vs[v].data, ks[j], vs[v].clear, &sum);
					t[2] = dk_measure(src, dst, WORDS, vs[v].fn, vs[v].data, 0, vs[v].clear, &sum);
					if (r) for (int q = 0; q < 3; q++) if (t[q] < best[q]) best[q] = t[q];
				}
				buf_printf(&csv, "%s,%s,%lu,%lu,%lu,%lu,%lu\n", vs[v].name, m ? "vram" : "main",
				           (unsigned long)ks[j], (unsigned long)best[0], (unsigned long)best[1],
				           (unsigned long)best[2], (unsigned long)sum);
			}
			iprintf("\x1b[4;0H%-24s %s ", vs[v].name, m ? "vram" : "main");
		}
	static const u32 offs[6] = { 8, 0x400, 0x2000, 0x4000, 0x6000, 0x7FF0 };
	static u32 seen[6] DTCM_BSS;
	Buf col = {0};
	buf_printf(&col, "case,dma,offset,value,meaning\n");
	for (int m = 0; m < 2; m++)
		for (int st = 0; st < 2; st++) {
			u32* sp = m ? (u32*)0x06800000 : a;
			u32* dp = m ? (u32*)0x06820000 : b;
			for (u32 i = 0; i < WORDS; i++) { sp[i] = 0x55000000 | i; dp[i] = 0xAAAAAAAA; }
			DC_FlushAll();
			dk_collide((u32)sp, (u32)dp, WORDS, offs, 6, seen, st);
			DC_InvalidateRange(dp, WORDS * 4);
			for (int i = 0; i < 6; i++) {
				u32 v = st ? dp[offs[i]] : seen[i];
				const char* mean = st ? (v == (0xC0DE0000 | offs[i]) ? "store_after_dma" : v == (0x55000000 | offs[i]) ? "store_before_dma_reached" : "other")
				                      : (v == 0xAAAAAAAA ? "load_before_dma_reached" : v == (0x55000000 | offs[i]) ? "load_after_dma_reached" : "other");
				buf_printf(&col, "%s,%s,%lu,%08lx,%s\n", st ? "store" : "load", m ? "vram" : "main",
				           (unsigned long)offs[i], (unsigned long)v, mean);
			}
		}
	buf_write(&col, "dmacpu_collide.csv");
	free(a);
	free(b);
	buf_write(&csv, "dmacpu.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nDMA3 32-bit immediate, %d words; cycles at 33.513982 MHz; min of 3 after a warm-up\n"
	           "running alongside: dma_plus_loop ~ max(dma_alone, loop_alone); halted: ~ dma_alone + loop_alone\n",
	           VERSION, __DATE__, __TIME__, WORDS);
	buf_write(&info, "dmacpu_info.txt");
	hw_done();
}
