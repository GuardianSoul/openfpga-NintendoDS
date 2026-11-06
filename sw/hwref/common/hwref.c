// Hardware-reference support: see hwref.h.
#include "hwref.h"
#include <fat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

bool hw_fat_ok;
bool hw_new_only;
static bool s_write_failed;
jmp_buf* hw_chain;
static bool s_fat_tried;

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
	if (!s_fat_tried) { s_fat_tried = true; hw_fat_ok = fatInitDefault(); }
#endif
	if (hw_fat_ok) {
		mkdir("fat:/hwref", 0777);
		mkdir(HWREF_DIR, 0777);
		iprintf("SD: OK\n");
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
		iprintf("\nDONE - results in /hwref/\n");
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
