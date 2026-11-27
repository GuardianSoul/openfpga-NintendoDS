// Hardware-reference support: see hwref.h.
#include "hwref.h"
#include <fat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/iosupport.h>
#include <errno.h>
#include <fcntl.h>

bool hw_fat_ok;
bool hw_new_only;
static bool s_write_failed;
jmp_buf* hw_chain;
static bool s_fat_tried;

// ---------------------------------------------------------------------------
// Save-memory "fat:" device (the maintainer 2026-11-27: one ROM on the DS and on the
// Pocket, like openfpga-PlayStation's timing disc writes its memory card). With no FAT
// (the Pocket core has no DLDI), a "fat" devoptab backed by the cartridge's
// FLASH save takes every fopen/fwrite/remove of every probe unchanged. The
// save is a log: "HWRFSAV1", then records {tag 'W' (the file's whole new
// contents) or 'A' (appended), name length, name, u32 length LE, data}, ended
// by blank 0xFF. tools/hwref/sav_extract.py rebuilds the files from
// Saves/nds/common/hwref.sav. The core sizes an unknown game's save from the
// loaded .sav: a blank 1 MiB file gives FLASH 1 MiB (sw/boot/boot9.s step 3).
// The chip is two 512 KiB halves, each "HWRFSAV2" + u32 generation + 4 spare,
// then records; the valid half with the higher generation is the log.
// Page write 0x0A (erase + program) on 256-byte pages.
#define AUXSPICNT  REG16(0x040001A0)
#define AUXSPIDATA REG16(0x040001A2)
#define EXMEMCNT   REG16(0x04000204)
#define SV_MAGIC "HWRFSAV2"
#define SV_HALF  (1u << 19)     // two 512 KiB halves: compaction copies the live files into the other one
#define SV_HDR   16             // per half: magic, u32 generation, 4 spare
bool hw_save_ok;
static u32 s_sv_base;           // the active half
static u32 s_sv_end;
static u32 s_sv_gen;

static u8 sv_xfer(u8 v)
{
	AUXSPIDATA = v;
	while (AUXSPICNT & 0x80) {}
	return (u8)AUXSPIDATA;
}
static void sv_begin(void) { AUXSPICNT = 0xA040; }                     // enable, SPI, hold
static u8 sv_last(u8 v) { AUXSPICNT = 0xA000; return sv_xfer(v); }     // chip select off after it
static void sv_wait_ready(void)
{
	for (int i = 0; i < 1000000; i++) {     // bounded: a missing chip must not hang
		sv_begin(); sv_xfer(0x05);
		if (!(sv_last(0) & 1)) return;
	}
}
static void sv_read(u32 a, void* dst, u32 n)
{
	u8* d = dst;
	if (!n) return;
	sv_begin(); sv_xfer(0x03); sv_xfer(a >> 16); sv_xfer(a >> 8); sv_xfer(a);
	for (u32 i = 0; i + 1 < n; i++) d[i] = sv_xfer(0);
	d[n - 1] = sv_last(0);
}
static void sv_write(u32 a, const void* src, u32 n)
{
	const u8* p = src;
	while (n) {
		u32 k = 256 - (a & 255);
		if (k > n) k = n;
		sv_begin(); sv_last(0x06);                                   // WREN
		sv_begin(); sv_xfer(0x0A); sv_xfer(a >> 16); sv_xfer(a >> 8); sv_xfer(a);
		for (u32 i = 0; i + 1 < k; i++) sv_xfer(p[i]);
		sv_last(p[k - 1]);
		sv_wait_ready();
		a += k; p += k; n -= k;
	}
}
// Walk the active half and return its end. With want, rebuild that file:
// its length into *len and, when out, its bytes (W resets, A appends).
static u32 sv_walk(const char* want, char* out, u32* len, bool* found)
{
	u32 a = s_sv_base + SV_HDR, lim = s_sv_base + SV_HALF;
	if (len) *len = 0;
	if (found) *found = false;
	while (a + 6 < lim) {
		u8 h[2]; char name[256]; u32 n;
		sv_read(a, h, 2);
		if (h[0] != 'W' && h[0] != 'A') break;
		sv_read(a + 2, name, h[1]); name[h[1]] = 0;
		sv_read(a + 2 + h[1], &n, 4);
		u32 body = a + 6 + h[1];
		if (body + n > lim) break;
		if (want && !strcmp(name, want)) {
			*found = true;
			if (h[0] == 'W') *len = 0;
			if (out) sv_read(body, out + *len, n);
			*len += n;
		}
		a = body + n;
	}
	return a;
}
static void sv_header(u32 base, u32 gen)
{
	u8 h[SV_HDR];
	memcpy(h, SV_MAGIC, 8); memcpy(h + 8, &gen, 4); memset(h + 12, 0xFF, 4);
	sv_write(base, h, SV_HDR);
}
// Copy each live file's latest contents into the other half (Pocket runs 2-3:
// probes rewrite whole CSVs after every case, and an in-RAM copy of the log
// needs RAM the probes hold). Reads come from the old half only, through a
// small buffer; the old half stays valid until the new header is written.
typedef struct { char name[80]; u32 last_w, len; } SvName;
static SvName s_names[160];
static bool sv_compact(void)
{
	u32 from = s_sv_base, to = s_sv_base ^ SV_HALF, end = s_sv_end;
	int nn = 0;
	static const u8 zero[8];
	for (u32 a = from + SV_HDR; a < end;) {
		u8 h[2]; char name[256]; u32 n;
		sv_read(a, h, 2); sv_read(a + 2, name, h[1]); name[h[1]] = 0; sv_read(a + 2 + h[1], &n, 4);
		int k = 0;
		while (k < nn && strcmp(s_names[k].name, name)) k++;
		if (k == nn) {
			if (nn == (int)(sizeof s_names / sizeof s_names[0]) || h[1] >= sizeof s_names[0].name) {
				iprintf("SAVE COMPACT: TOO MANY FILES\n"); return false;
			}
			strcpy(s_names[k].name, name); s_names[k].last_w = a; s_names[k].len = 0; nn++;
		}
		if (h[0] == 'W') { s_names[k].last_w = a; s_names[k].len = n; } else s_names[k].len += n;
		a += 6 + h[1] + n;
	}
	sv_write(to, zero, 8);                   // the other half invalid while it is written
	u32 out = to + SV_HDR;
	for (int k = 0; k < nn; k++) {
		u32 len = s_names[k].len;
		u8 nl = strlen(s_names[k].name);
		if (!len) continue;                   // removed (or empty) files are dropped
		if (out + 6 + nl + len + 1 > to + SV_HALF) { iprintf("SAVE FULL (live files)\n"); return false; }
		u32 at = out + 6 + nl;
		sv_write(out + 2, s_names[k].name, nl);
		sv_write(out + 2 + nl, &len, 4);
		for (u32 a = s_names[k].last_w; a < end;) {
			u8 h[2]; char name[256]; u32 n;
			sv_read(a, h, 2); sv_read(a + 2, name, h[1]); name[h[1]] = 0; sv_read(a + 2 + h[1], &n, 4);
			if (!strcmp(name, s_names[k].name))
				for (u32 o = 0; o < n;) {
					u8 buf[256];
					u32 c = n - o > sizeof buf ? sizeof buf : n - o;
					sv_read(a + 6 + h[1] + o, buf, c); sv_write(at, buf, c);
					at += c; o += c;
				}
			a += 6 + h[1] + n;
		}
		u8 t[2] = { 'W', nl };
		sv_write(out, t, 2);
		out = at;
	}
	u8 blank[256];
	memset(blank, 0xFF, sizeof blank);
	sv_write(out, blank, out + sizeof blank <= to + SV_HALF ? sizeof blank : to + SV_HALF - out);
	sv_header(to, ++s_sv_gen);               // the new half valid
	sv_write(from, zero, 8);                 // then the old one invalid
	iprintf("save compacted: %luK -> %luK\n", (unsigned long)((end - from) >> 10), (unsigned long)((out - to) >> 10));
	s_sv_base = to; s_sv_end = out;
	return true;
}
static bool sv_put(char tag, const char* name, const void* data, u32 n)
{
	u8 h[2] = { (u8)tag, (u8)strlen(name) };
	u32 need = 6 + h[1] + n;
	if (strlen(name) > 255) return false;
	if (s_sv_end + need + 1 > s_sv_base + SV_HALF && !sv_compact()) return false;
	if (s_sv_end + need + 1 > s_sv_base + SV_HALF) { iprintf("SAVE FULL %s\n", name); return false; }
	sv_write(s_sv_end + 2, name, h[1]);
	sv_write(s_sv_end + 2 + h[1], &n, 4);
	if (n) sv_write(s_sv_end + 6 + h[1], data, n);
	sv_write(s_sv_end, h, 2);       // the tag last: a record cut off by a hang stays invisible
	s_sv_end += need;
	return true;
}

typedef struct { char name[96]; char* buf; u32 len, cap, pos; bool wr, trunc; } SvFile;
static const char* sv_name(const char* path)
{
	const char* p = strchr(path, ':');
	p = p ? p + 1 : path;
	while (*p == '/') p++;
	if (!strncmp(p, "hwref/", 6)) p += 6;
	return p;
}
static int sv_open(struct _reent* r, void* fs, const char* path, int flags, int mode)
{
	SvFile* f = fs;
	const char* n = sv_name(path);
	memset(f, 0, sizeof *f);
	if (strlen(n) >= sizeof f->name) { r->_errno = ENAMETOOLONG; return -1; }
	strcpy(f->name, n);
	int acc = flags & O_ACCMODE;
	f->wr = acc != O_RDONLY;
	f->trunc = (flags & O_TRUNC) != 0;
	if (!f->wr || !(flags & O_APPEND)) {          // a read, or a write that rewrites: load the file
		bool found; u32 len;
		sv_walk(f->name, NULL, &len, &found);
		if (!found && !(flags & O_CREAT)) { r->_errno = ENOENT; return -1; }
		if (!f->wr || !f->trunc) {
			f->buf = malloc(len + 1); f->cap = len + 1;
			if (!f->buf) { r->_errno = ENOMEM; return -1; }
			sv_walk(f->name, f->buf, &f->len, &found);
			if (f->wr) f->trunc = true;               // r+ / w without O_TRUNC: write the whole file back
		}
	}
	return (int)f;
}
static ssize_t sv_fwrite(struct _reent* r, void* fd, const char* p, size_t n)
{
	SvFile* f = fd;
	if (!f->wr) { r->_errno = EBADF; return -1; }
	u32 at = f->trunc ? f->pos : f->len;
	if (at + n > f->cap) {
		u32 c = f->cap ? f->cap : 4096;
		while (c < at + n) c *= 2;
		char* nb = realloc(f->buf, c);
		if (!nb) { r->_errno = ENOMEM; return -1; }
		f->buf = nb; f->cap = c;
	}
	memcpy(f->buf + at, p, n);
	if (at + n > f->len) f->len = at + n;
	if (f->trunc) f->pos = at + n;
	return n;
}
static ssize_t sv_fread(struct _reent* r, void* fd, char* p, size_t n)
{
	SvFile* f = fd;
	if (f->pos >= f->len) return 0;
	if (n > f->len - f->pos) n = f->len - f->pos;
	memcpy(p, f->buf + f->pos, n);
	f->pos += n;
	return n;
}
static off_t sv_seek(struct _reent* r, void* fd, off_t pos, int dir)
{
	SvFile* f = fd;
	off_t b = dir == SEEK_SET ? 0 : dir == SEEK_CUR ? (off_t)f->pos : (off_t)f->len;
	if (b + pos < 0) { r->_errno = EINVAL; return -1; }
	f->pos = b + pos;
	return f->pos;
}
// Files above this, and every .bin capture, stay off the save: picture and
// sound captures and raw event logs (cap3d 6 x 96 KiB, gxtime_events 300 KiB,
// sndcap dozens of 16 KiB) fill the chip; every timing result is a CSV or text
// file (Pocket runs 1 and 4).
#define SV_MAX_FILE (32u << 10)
static int sv_close(struct _reent* r, void* fd)
{
	SvFile* f = fd;
	bool ok = true;
	size_t nl = strlen(f->name);
	bool capture = nl > 4 && !strcmp(f->name + nl - 4, ".bin");   // sndcap writes dozens of 16 KiB captures (run 4)
	if (f->wr && (f->len > SV_MAX_FILE || capture)) {
		iprintf("not saved: %s %luK\n", f->name, (unsigned long)(f->len >> 10));
		free(f->buf);
		return 0;
	}
	if (f->wr) ok = sv_put(f->trunc ? 'W' : 'A', f->name, f->buf, f->len);
	free(f->buf);
	if (!ok) { r->_errno = ENOSPC; return -1; }
	return 0;
}
static int sv_fstat(struct _reent* r, void* fd, struct stat* st)
{
	SvFile* f = fd;
	memset(st, 0, sizeof *st);
	st->st_size = f->len; st->st_mode = S_IFREG | 0666;
	return 0;
}
static int sv_stat(struct _reent* r, const char* path, struct stat* st)
{
	bool found; u32 len;
	const char* n = sv_name(path);
	memset(st, 0, sizeof *st);
	if (!*n || !strcmp(n, "hwref")) { st->st_mode = S_IFDIR | 0777; return 0; }
	sv_walk(n, NULL, &len, &found);
	if (!found) { r->_errno = ENOENT; return -1; }
	st->st_size = len; st->st_mode = S_IFREG | 0666;
	return 0;
}
static int sv_unlink(struct _reent* r, const char* path)
{
	return sv_put('W', sv_name(path), "", 0) ? 0 : (r->_errno = ENOSPC, -1);
}
static int sv_mkdir(struct _reent* r, const char* path, int mode) { return 0; }
static const devoptab_t s_sv_dev = {
	.name = "fat", .structSize = sizeof(SvFile),
	.open_r = sv_open, .close_r = sv_close, .write_r = sv_fwrite, .read_r = sv_fread,
	.seek_r = sv_seek, .fstat_r = sv_fstat, .stat_r = sv_stat, .unlink_r = sv_unlink,
	.mkdir_r = sv_mkdir,
};
static bool sv_init(void)
{
	u8 h[2][SV_HDR];
	EXMEMCNT &= ~(1 << 11);         // the NDS slot to the ARM9
	sv_read(0, h[0], SV_HDR);
	sv_read(SV_HALF, h[1], SV_HDR);
	int best = -1; u32 g[2] = { 0, 0 };
	for (int k = 0; k < 2; k++)
		if (!memcmp(h[k], SV_MAGIC, 8)) { memcpy(&g[k], h[k] + 8, 4); if (best < 0 || g[k] > g[best]) best = k; }
	if (best < 0) {                 // blank or foreign: start half 0
		u8 blank[240];
		memset(blank, 0xFF, sizeof blank);
		sv_write(SV_HDR, blank, sizeof blank);  // a stale save must not read as records
		sv_header(0, 1);
		sv_read(0, h[0], SV_HDR);
		if (memcmp(h[0], SV_MAGIC, 8)) return false;   // no writable save chip
		best = 0; g[0] = 1;
	}
	s_sv_base = best ? SV_HALF : 0; s_sv_gen = g[best];
	s_sv_end = sv_walk(NULL, NULL, NULL, NULL);
	return AddDevice(&s_sv_dev) >= 0;
}

void hw_init(const char* title)
{
	consoleDemoInit();   // bottom screen, VRAM C
	R_POWCNT1 |= (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 9);  // LCD, 2D A, 3D render, 3D geometry, 2D B
	R_TM0CNT = 0;
	R_TM1CNT = 0;
	R_TM0 = 0;
	R_TM1 = 0;
	R_TM1CNT = (1 << 7) | (1 << 2);  // enable, cascade
	R_TM0CNT = (1 << 7);             // enable, F/1
	iprintf("%s\n", title);
	iprintf("hwref build " __DATE__ "\n\n");
#ifdef HWREF_HEADLESS
	// tb_ds / no SD: calico runs DLDI on the ARM7 and fatInitDefault() waits
	// for it over PXI; skip it, so results go only to RAM (cputime's block)
	s_fat_tried = true;
	hw_fat_ok = false;
#else
	if (!s_fat_tried) {
		s_fat_tried = true;
		hw_fat_ok = fatInitDefault();
		if (!hw_fat_ok) hw_fat_ok = hw_save_ok = sv_init();   // the Pocket: results to the save
	}
#endif
	if (hw_fat_ok) {
		mkdir("fat:/hwref", 0777);
		mkdir(HWREF_DIR, 0777);
		iprintf(hw_save_ok ? "No SD: results to the save\n(quit via the Pocket menu)\n" : "SD: OK\n");
	} else {
		iprintf("SD: FAT init FAILED\n(no DLDI patch?)\n");
	}
}

void hw_status(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	viprintf(fmt, ap);
	va_end(ap);
	iprintf("\n");
}

bool hw_write(const char* name, const void* data, size_t len)
{
	if (!hw_fat_ok) { s_write_failed = true; return false; }
	char path[160];
	int n = snprintf(path, sizeof path, HWREF_DIR "/%s", name);
	if (n < 0 || (size_t)n >= sizeof path) { s_write_failed = true; return false; }
	FILE* f = fopen(path, "wb");
	bool ok = f && fwrite(data, 1, len, f) == len;
	if (f && fclose(f) != 0) ok = false;
	if (!ok) { s_write_failed = true; iprintf("WRITE FAILED %s\n", name); }
	return ok;
}

bool hw_append(const char* name, const void* data, size_t len)
{
	if (!hw_fat_ok) { s_write_failed = true; return false; }
	char path[160];
	int n = snprintf(path, sizeof path, HWREF_DIR "/%s", name);
	if (n < 0 || (size_t)n >= sizeof path) { s_write_failed = true; return false; }
	FILE* f = fopen(path, "ab");
	bool ok = f && fwrite(data, 1, len, f) == len;
	if (f && fclose(f) != 0) ok = false;
	if (!ok) { s_write_failed = true; iprintf("APPEND FAILED %s\n", name); }
	return ok;
}

bool hw_csv_header(const char* name, const char* header)
{
	char path[160];
	int n = snprintf(path, sizeof path, HWREF_DIR "/%s", name);
	if (n < 0 || (size_t)n >= sizeof path) { s_write_failed = true; return false; }
	FILE* f = fopen(path, "rb");
	if (f) {
		int c = fgetc(f);
		fclose(f);
		if (c != EOF) return true;
	}
	return hw_append(name, header, strlen(header));
}

bool hw_step_begin(const char* progress_file, const char* key)
{
	char path[160], line[192], verb[16], old[80];
	int n = snprintf(path, sizeof path, HWREF_DIR "/%s", progress_file);
	if (n < 0 || (size_t)n >= sizeof path || strlen(key) >= sizeof old) {
		s_write_failed = true; return false;
	}
	FILE* f = fopen(path, "rb");
	if (f) {
		while (fgets(line, sizeof line, f))
			if (sscanf(line, "%15s %79s", verb, old) == 2 && !strcmp(old, key) &&
			    (!strcmp(verb, "start") || !strcmp(verb, "done"))) {
				fclose(f); return false; // console writes could alter a 2D workload
			}
		fclose(f);
	}
	n = snprintf(line, sizeof line, "start %s\n", key);
	return n > 0 && (size_t)n < sizeof line && hw_append(progress_file, line, n);
}

bool hw_step_done(const char* progress_file, const char* key)
{
	char line[192];
	int n = snprintf(line, sizeof line, "done %s\n", key);
	return n > 0 && (size_t)n < sizeof line && hw_append(progress_file, line, n);
}

void hw_done(void)
{
	if (hw_chain) {
		iprintf("\nstep done%s\n", (hw_fat_ok && !s_write_failed) ? "" : " (SD WRITES FAILED)");
		longjmp(*hw_chain, 1);
	}
	if (hw_fat_ok && !s_write_failed)
		iprintf(hw_save_ok ? "\nDONE - results in the save:\nquit via the Pocket menu\n" : "\nDONE - results in /hwref/\n");
	else
		iprintf("\nFINISHED, BUT SD WRITES FAILED\n");
	for (;;) swiWaitForVBlank();
}

void buf_printf(Buf* b, const char* fmt, ...)
{
	for (;;) {
		va_list ap;
		va_start(ap, fmt);
		size_t room = b->cap - b->len;
		int n = b->p ? vsnprintf(b->p + b->len, room, fmt, ap) : -1;
		va_end(ap);
		if (n >= 0 && (size_t)n < room) { b->len += n; return; }
		size_t ncap = b->cap ? b->cap * 2 : 65536;
		while (n >= 0 && ncap - b->len <= (size_t)n) ncap *= 2;
		char* np = realloc(b->p, ncap);
		if (!np) { iprintf("OUT OF MEMORY\n"); return; }
		b->p = np;
		b->cap = ncap;
	}
}

bool buf_write(Buf* b, const char* name)
{
	bool ok = hw_write(name, b->p ? b->p : "", b->len);
	free(b->p);
	b->p = NULL;
	b->len = b->cap = 0;
	return ok;
}

bool buf_append(Buf* b, const char* name)
{
	bool ok = hw_append(name, b->p ? b->p : "", b->len);
	free(b->p); b->p = NULL; b->len = b->cap = 0;
	return ok;
}

void wait_vcount(int line)
{
	while (R_VCOUNT == line) {}
	while (R_VCOUNT != line) {}
}
