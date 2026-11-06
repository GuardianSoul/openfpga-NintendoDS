// Real-game frame replay (docs/hw-reference.md "replay3d"). Every file
// named in fat:/hwref/replay/list.txt (new.txt in "new only") is a trimmed census GX trace
// (tools/hwref/mkreplay.py): one 'V' record (VRAMCNT and banks), a short
// prologue, then the game's FIFO entries for a few warm-up flushes and the
// target flush, each SWAP followed by its 'F' record (render registers).
// The same file runs through gx2scene for the RTL and through this ROM in
// melonDS, so all three render identical input.
//
// Texture and palette banks (MST 3) get the game's mapping and contents; the
// rest of A-G is unmapped. The capture goes to a bank among A-D that the
// game doesn't map for 3D, or else to a texture bank whose slot no
// TEXIMAGE_PARAM (or rear-plane bitmap) in the file touches. The polygon and
// vertex counts before the last SWAP are logged next to the census counts.
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "replay3d 5"
#define REPLAY_DIR HWREF_DIR "/replay"
#define MAX_FILES 64

static const u32 s_bank_size[9] = { 0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000 };
static const u32 s_bank_lcdc[7] = { 0x06800000, 0x06820000, 0x06840000, 0x06860000, 0x06880000, 0x06890000, 0x06894000 };
static u16* s_cap;   // on the heap while replay3d runs (see rand3d/main.c)

static u32 rd32(const u8* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24); }

static bool is_3d_bank(int b, u8 cnt) { return b < 7 && (cnt & 0x80) && (cnt & 7) == 3; }

static void progress(const char* s)
{
	FILE* f = fopen(HWREF_DIR "/replay3d_progress.txt", "a");
	if (f) { fputs(s, f); fputc('\n', f); fclose(f); }
}

// Texture slots any TEXIMAGE_PARAM (or the rear-plane bitmap) in the file reaches.
static u32 slots_used(const u8* d, size_t len)
{
	static const u8 bpp[8] = { 0, 8, 2, 4, 8, 2, 8, 16 };
	u32 used = 0;
	for (size_t i = 8; i < len;) {
		u8 t = d[i++];
		if (t == 'C') {
			u8 c = d[i];
			u32 v = rd32(d + i + 1);
			i += 5;
			u32 fmt = (v >> 26) & 7;
			if (c != 0x2A || !fmt) continue;
			u32 a = (v & 0xFFFF) * 8, n = (8u << ((v >> 20) & 7)) * (8u << ((v >> 23) & 7)) * bpp[fmt] / 8;
			for (u32 s = a >> 17; s <= (a + n - 1) >> 17; s++) used |= 1u << (s & 3);
			if (fmt == 5) used |= 2;
		} else if (t == 'F') {
			if (rd32(d + i + 12) & (1 << 14)) used |= 0xC;
			i += GXP_FREC_SIZE;
		} else if (t == 'V') {
			i += 13;
			for (int b = 0; b < 9; b++) i += s_bank_size[b];
		} else
			return ~0u;   // corrupt
	}
	return used;
}

// Count mode (v4, geometry session): replay/variants.txt lists "<file.gxb>
// <file.var>" (tools/hwref/mkvariants.py). For every variant the frame is
// fed up to the quad strip's BEGIN (warm-up swaps included), RAM_COUNT is
// read, the variant's entries are sent, and RAM_COUNT is read again. No VRAM,
// no capture. Rows go to replay3d_variants.csv.
static bool settle(void);

static u8* load(const char* path, long* len)
{
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	*len = ftell(f);
	fseek(f, 0, SEEK_SET);
	u8* d = malloc(*len);
	if (d && fread(d, 1, *len, f) != (size_t)*len) { free(d); d = NULL; }
	fclose(f);
	return d;
}

static void feed_until(const u8* d, long len, u32 stop)
{
	GxpRegs r = {0};
	for (size_t i = 8; i < (size_t)len && i < stop && !gxp_timeouts;) {
		u8 t = d[i++];
		if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; continue; }
		if (t == 'F') { i += GXP_FREC_SIZE; continue; }
		u8 c = d[i];
		u32 v = rd32(d + i + 1);
		i += 5;
		if (!gxp_valid_cmd(c) || (c >= 0x70 && c <= 0x72)) continue;
		if (c != 0x50) { gxp_put(c, v); continue; }
		if (i < (size_t)len && d[i] == 'F') { gxp_parse_regs(&r, d + i + 1); i += 1 + GXP_FREC_SIZE; }
		gxp_set_regs(&r);
		gxp_swap(v);
	}
}

static void replay_variants(const char* gxb, const char* var, Buf* csv)
{
	char path[128];
	long len, vlen;
	snprintf(path, sizeof path, REPLAY_DIR "/%s", gxb);
	u8* d = load(path, &len);
	snprintf(path, sizeof path, REPLAY_DIR "/%s", var);
	u8* v = load(path, &vlen);
	if (!d || !v || vlen < 12 || memcmp(v, "HWVAR001", 8)) {
		buf_printf(csv, "%s,%s,load failed\n", gxb, var);
		free(d); free(v);
		return;
	}
	u32 nrec = rd32(v + 8);
	size_t o = 12;
	for (u32 k = 0; k < nrec && o + 16 <= (size_t)vlen; k++) {
		u32 place = rd32(v + o), vid = rd32(v + o + 4), start = rd32(v + o + 8), n = rd32(v + o + 12);
		o += 16;
		gxp_reset_geometry();
		gxp_timeouts = 0;
		feed_until(d, len, start);
		settle();
		u32 before = gxp_ramcount();
		for (u32 e = 0; e < n && o + 8 <= (size_t)vlen; e++, o += 8) {
			u8 c = rd32(v + o);
			if (gxp_valid_cmd(c) && !(c >= 0x70 && c <= 0x72)) gxp_put(c, rd32(v + o + 4));
		}
		settle();
		u32 after = gxp_ramcount();
		gxp_swap(0);
		buf_printf(csv, "%s,%lu,%lu,%lu,%lu,%lu,%lu,%lu\n", gxb, (unsigned long)place, (unsigned long)vid,
		           (unsigned long)(before & 0xFFF), (unsigned long)((before >> 16) & 0x1FFF),
		           (unsigned long)(after & 0xFFF), (unsigned long)((after >> 16) & 0x1FFF),
		           (unsigned long)gxp_timeouts);
	}
	free(d);
	free(v);
}

static int cmp_str(const void* a, const void* b) { return strcmp(*(char* const*)a, *(char* const*)b); }

// probe pass (v2, geometry session): no capture; while the target flush is
// fed, the polygon/vertex counts are read after every BEGIN, END and vertex
// command, once the command FIFO is empty plus 1,024 cycles (v3: on the DS,
// busy stays set inside an unfinished polygon, and the counter can lag).
// replay3d_<name>_counts.bin: per checkpoint, u32 byte offset of the entry
// in the .gxb, u32 RAM_COUNT. tools/hwref/vtxbisect.py finds the first
// entry where DS and melonDS differ.
static Buf s_cnt;
// Not gxp_wait_idle(): on the DS, GXSTAT busy stays set inside an
// unfinished polygon (run 17 timed out right there), so wait for the
// command FIFO to empty (bit 26), then let the last command finish.
static bool settle(void)
{
	for (u32 i = 0; !(R_GXSTAT & (1u << 26)); i++)
		if (i > 4000000) { gxp_timeouts++; return false; }
	u32 t = now32();
	while (now32() - t < 1024) {}
	return true;
}

static void checkpoint(u32 off)
{
	if (!settle()) return;
	u32 rec[2] = { off, gxp_ramcount() };
	if (s_cnt.len + 8 > s_cnt.cap) {
		size_t ncap = s_cnt.cap ? s_cnt.cap * 2 : 65536;
		char* np = realloc(s_cnt.p, ncap);
		if (!np) return;
		s_cnt.p = np;
		s_cnt.cap = ncap;
	}
	memcpy(s_cnt.p + s_cnt.len, rec, 8);
	s_cnt.len += 8;
}

static void replay(const char* name, Buf* info, bool probe)
{
	char path[128];
	snprintf(path, sizeof path, REPLAY_DIR "/%s", name);
	FILE* f = fopen(path, "rb");
	if (!f) { buf_printf(info, "%s,open failed\n", name); return; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	u8* d = malloc(len);
	if (!d) { fclose(f); buf_printf(info, "%s,out of memory (%ld bytes)\n", name, len); return; }
	bool ok = fread(d, 1, len, f) == (size_t)len;
	fclose(f);
	if (!ok || len < 8 || memcmp(d, "NDSGX001", 8) || d[8] != 'V') {
		buf_printf(info, "%s,bad file\n", name);
		free(d);
		return;
	}
	const u8* cnt = d + 9 + 4;
	u32 used = slots_used(d, len);
	int cap = -1;
	for (int b = 0; b < 4 && cap < 0; b++)
		if (!is_3d_bank(b, cnt[b])) cap = b;
	for (int b = 0; b < 4 && cap < 0; b++)
		if (!(used & (1u << ((cnt[b] >> 3) & 3)))) cap = b;
	int nflush = 0;
	for (size_t i = 8; i < (size_t)len;) {
		u8 t = d[i++];
		if (t == 'C') i += 5;
		else if (t == 'F') { nflush++; i += GXP_FREC_SIZE; }
		else if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; }
	}
	if (cap < 0 || used == ~0u || !nflush) {
		buf_printf(info, "%s,no capture bank (slots %lx) or no flush\n", name, (unsigned long)used);
		free(d);
		return;
	}

	// VRAM: 3D banks from the file, the capture bank LCDC, the rest of A-G off.
	const u8* bank = d + 9 + 4 + 9;
	for (int b = 0; b < 7; b++) {
		R_VRAMCNT(b) = 0;
		if (is_3d_bank(b, cnt[b]) && b != cap) {
			R_VRAMCNT(b) = 0x80;
			vu32* dst = (vu32*)s_bank_lcdc[b];
			for (u32 k = 0; k < s_bank_size[b] / 4; k++) dst[k] = rd32(bank + 4 * k);
		}
		bank += s_bank_size[b];
	}
	for (int b = 0; b < 7; b++)
		R_VRAMCNT(b) = b == cap ? 0x80 : is_3d_bank(b, cnt[b]) ? cnt[b] : 0;

	gxp_reset_geometry();
	gxp_timeouts = 0;
	GxpRegs r = {0};
	u32 rc = 0, skipped = 0, entries = 0;
	int flush = 0;
	for (size_t i = 8; i < (size_t)len && !gxp_timeouts;) {
		u8 t = d[i++];
		if (t == 'V') { i += 13; for (int b = 0; b < 9; b++) i += s_bank_size[b]; continue; }
		if (t == 'F') { i += GXP_FREC_SIZE; continue; }   // only after a SWAP, handled there
		u8 c = d[i];
		u32 v = rd32(d + i + 1);
		i += 5;
		if (!gxp_valid_cmd(c) || (c >= 0x70 && c <= 0x72)) { skipped++; continue; }
		entries++;
		if (c != 0x50) {
			gxp_put(c, v);
			if (probe && flush == nflush - 1 && (c == 0x40 || c == 0x41 || (c >= 0x23 && c <= 0x28)))
				checkpoint(i - 6);
			continue;
		}
		// SWAP: its 'F' record follows (nothing executes between the two).
		if (i < (size_t)len && d[i] == 'F') {
			gxp_parse_regs(&r, d + i + 1);
			i += 1 + GXP_FREC_SIZE;
		}
		gxp_set_regs(&r);
		bool last = ++flush == nflush;
		if (last) { gxp_wait_idle(); rc = gxp_ramcount(); }
		gxp_swap(v);
		if (last && !probe) {
			gxp_capture_start(cap);
			gxp_capture_finish(cap, s_cap);
		}
	}
	char fn[96];
	snprintf(fn, sizeof fn, "replay3d_%.*s_3d.bin", (int)(strlen(name) - 4), name);
	if (probe) {
		snprintf(fn, sizeof fn, "replay3d_%.*s_counts.bin", (int)(strlen(name) - 4), name);
		hw_write(fn, s_cnt.p ? s_cnt.p : "", s_cnt.len);   // partial on a timeout
		free(s_cnt.p);
		s_cnt.p = NULL;
		s_cnt.len = s_cnt.cap = 0;
	} else if (flush == nflush && !gxp_timeouts) hw_write(fn, s_cap, 256 * 192 * 2);
	buf_printf(info, "%s%s,%lu,%lu,%lu,%lu,%lu,%d,%lx,%lu,%lu,%08lx,%lu\n", name, probe ? ":probe" : "", (unsigned long)r.frame,
	           (unsigned long)r.polys, (unsigned long)r.verts, (unsigned long)(rc & 0xFFF),
	           (unsigned long)((rc >> 16) & 0x1FFF), cap, (unsigned long)used, (unsigned long)entries,
	           (unsigned long)skipped, (unsigned long)R_GXSTAT, (unsigned long)gxp_timeouts);
	free(d);
}

int main(void)
{
	hw_init(VERSION " - game frame replay");
	gxp_console_on_h();
	iprintf(VERSION " - game frame replay\n\n");
	videoSetMode(MODE_0_3D);
	glInit();
	remove(HWREF_DIR "/replay3d_progress.txt");
	s_cap = malloc(256 * 192 * 2);
	if (!s_cap) { iprintf("OUT OF MEMORY\n"); hw_done(); }

	char* names[MAX_FILES];
	int n = 0;
	// The file names come from replay/list.txt, or in hwref.nds's "new only"
	// from replay/new.txt (files not yet run on the DS; none if it's
	// missing). The list file avoids opendir() (see "sndcap's lost rows").
	const char* list = hw_new_only ? REPLAY_DIR "/new.txt" : REPLAY_DIR "/list.txt";
	FILE* lf = fopen(list, "r");
	if (lf) {
		char line[64];
		while (fgets(line, sizeof line, lf) && n < MAX_FILES) {
			line[strcspn(line, "\r\n")] = 0;
			size_t l = strlen(line);
			if (l > 4 && !strcasecmp(line + l - 4, ".gxb")) names[n++] = strdup(line);
		}
		fclose(lf);
	}
	qsort(names, n, sizeof names[0], cmp_str);

	// Count mode (replay/variants.txt), then the files.

	FILE* vf = fopen(REPLAY_DIR "/variants.txt", "r");
	if (vf) {
		Buf csv = {0};
		buf_printf(&csv, "gxb,place,variant,before_polys,before_verts,after_polys,after_verts,timeouts\n");
		char a[64], b[64];
		while (fscanf(vf, "%63s %63s", a, b) == 2) {
			iprintf("\x1b[4;0Hvariants %-20.20s", a);
			replay_variants(a, b, &csv);
		}
		fclose(vf);
		buf_write(&csv, "replay3d_variants.csv");
	}

	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\nformat: replay3d_<name>_3d.bin, 256x192 u16 LE, 3D only\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "file,frame,census_polys,census_verts,ds_polys,ds_verts,capture_bank,slots_used,entries,skipped,gxstat,timeouts\n");
	for (int i = 0; i < n; i++) {
		iprintf("\x1b[4;0H%2d/%d %-24.24s", i + 1, n, names[i]);
		char line[96];
		snprintf(line, sizeof line, "start %s", names[i]);
		progress(line);
		replay(names[i], &info, false);
		if (gxp_timeouts) { buf_printf(&info, "stopped: geometry engine timeout\n"); free(names[i]); break; }
		replay(names[i], &info, true);   // a probe timeout loses only this file's counts
		gxp_timeouts = 0;
		free(names[i]);
	}
	if (!n) buf_printf(&info, "no files in %s\n", list);
	buf_write(&info, "replay3d_info.txt");
	progress("done");
	free(s_cap);
	hw_done();
}
