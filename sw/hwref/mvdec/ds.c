// <tag>_ds.nds for the DS (calico + libfat): run.h. tools/hwref/mkmvdec.py
// links calico into the main RAM range the game's calls never touch and
// leaves the game's files on the SD card; this loads them, runs the calls
// with the movie on screen, caches warm (v2: no flush between calls; runs
// 25/26 measured them cold), and writes fat:/hwref/<tag>_warm.csv and
// <tag>_warm_table.bin (the kres_t rows, as tb.c leaves them at 0x023F2000).
#include "../common/hwref.h"
#include "run.h"
#include <stdio.h>

#define DIR "fat:/hwref/" MV_TAG

static kres_t res[MV_MAX_CALLS];
static u8 save[0xC000];
static u32 stack[4096] __attribute__((aligned(8)));

// <tag>_main.bin: "MVDCIMG1", u32 n, then n x {u32 addr, u32 len, data}
static bool load_image(const char* name)
{
	FILE* f = fopen(name, "rb");
	if (!f) { hw_status("missing %s", name); return false; }
	u32 hdr[3], total = 0;
	bool ok = fread(hdr, 4, 3, f) == 3 && hdr[0] == 0x4344564D && hdr[1] == 0x31474D49;
	for (u32 i = 0; ok && i < hdr[2]; i++) {
		u32 seg[2];
		ok = fread(seg, 4, 2, f) == 2 && fread((void*)seg[0], 1, seg[1], f) == seg[1];
		DC_InvalidateRange((void*)seg[0], seg[1]);
		total += seg[1];
	}
	fclose(f);
	hw_status("%s: %s, %lu bytes", name, ok ? "ok" : "BAD", (unsigned long)total);
	return ok;
}

static bool load(const char* name, u32 dst, u32 max)
{
	FILE* f = fopen(name, "rb");
	if (!f) { hw_status("missing %s", name); return false; }
	size_t n = fread((void*)dst, 1, max, f);
	fclose(f);
	hw_status("%s: %u bytes", name, (unsigned)n);
	DC_InvalidateRange((void*)dst, max);
	return n > 0;
}

int main(void)
{
	hw_init(MV_TAG ": movie decode");
	if (!hw_fat_ok || !load_image(DIR "_main.bin") || !load(DIR "_calls.bin", MV_BLOB, MV_BLOB_MAX))
		hw_done();
	swiWaitForVBlank();
	// v2 (CPU session): the warm pass only; runs 25 and 26 have the cold one
	mvdec_flush_each = 0;
	int n = mvdec_run((const u8*)MV_BLOB, res, MV_MAX_CALLS, save, stack + 4096);
	consoleDemoInit();
	R_POWCNT1 |= 0x020F;
	hw_status(MV_TAG ": %d calls", n);
	if (n <= 0) hw_done();

	Buf b = {0};
	buf_printf(&b, "call,func,target_ticks,start_ticks,end_ticks,vcount_start,vcount_end,arm9_cycles,"
	               "melonds_arm9_cycles,cksum,game_cksum,same\n");
	int bad = 0;
	for (int i = 0; i < n; i++) {
		const kres_t* r = &res[i];
		int same = r->cksum == r->game_cksum;
		bad += !same;
		buf_printf(&b, "%d,%08lx,%lu,%lu,%lu,%u,%u,%lu,%lu,%08lx,%08lx,%d\n", i, (unsigned long)r->func,
		           (unsigned long)r->target, (unsigned long)r->start, (unsigned long)r->end, r->vc0, r->vc1,
		           (unsigned long)(2 * (r->end - r->start)), (unsigned long)(2 * r->game_ticks),
		           (unsigned long)r->cksum, (unsigned long)r->game_cksum, same);
	}
	buf_write(&b, MV_TAG "_warm.csv");
	hw_write(MV_TAG "_warm_table.bin", res, n * sizeof(kres_t));
	hw_status("%d of %d pictures differ", bad, n);
	hw_done();
}
