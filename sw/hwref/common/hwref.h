// Hardware-reference test programs: shared support (docs/hw-reference.md).
// Console on the bottom screen, results to fat:/hwref/ through DLDI, the
// TM0+TM1 cascade as a 32-bit system-cycle clock (33.513982 MHz).
#pragma once
#include <nds.h>
#include <stdarg.h>

#ifndef HWREF_DIR
#define HWREF_DIR "fat:/hwref"
#endif

#define REG8(a)  (*(vu8*)(a))
#define REG16(a) (*(vu16*)(a))
#define REG32(a) (*(vu32*)(a))

#define R_DISPCNT   REG32(0x04000000)
#define R_VCOUNT    REG16(0x04000006)
#define R_DISP3DCNT REG16(0x04000060)
#define R_DISPCAP   REG32(0x04000064)
#define R_POWCNT1   REG16(0x04000304)
#define R_GXSTAT    REG32(0x04000600)
#define R_GXFIFO    REG32(0x04000400)
#define R_TM0       REG16(0x04000100)
#define R_TM0CNT    REG16(0x04000102)
#define R_TM1       REG16(0x04000104)
#define R_TM1CNT    REG16(0x04000106)
#define R_IF        REG32(0x04000214)
#define R_VRAMCNT(n) REG8(0x04000240 + (n))   // A..G = 0..6, H = 8, I = 9

// Direct geometry command port: 0x04000400 + cmd * 4 (MTX_MODE 0x10 -> 0x440).
#define GXPORT(cmd) ((vu32*)(0x04000400 + ((cmd) << 2)))
#define GXSTAT_BUSY  (1u << 27)
#define GXSTAT_LEVEL(s) (((s) >> 16) & 0x1FF)

// Free-running TM0 (F/1) + TM1 (cascade). Reading TM1, TM0, TM1 makes the
// 32-bit value consistent across a TM0 overflow.
static inline u32 now32(void)
{
	u16 h = R_TM1, l = R_TM0, h2 = R_TM1;
	if (h != h2) { l = R_TM0; h = h2; }
	return ((u32)h << 16) | l;
}

void hw_init(const char* title);           // console, timers, FAT, mkdir /hwref
void hw_status(const char* fmt, ...);      // a line on the console
bool hw_write(const char* name, const void* data, size_t len);  // fat:/hwref/<name>
bool hw_append(const char* name, const void* data, size_t len);
bool hw_csv_header(const char* name, const char* header);
// An interrupted start is skipped on reboot, preserving later independent
// cases. Completeness checking must still report that case as unmeasured.
bool hw_step_begin(const char* progress_file, const char* key);
bool hw_step_done(const char* progress_file, const char* key);
void hw_done(void) __attribute__((noreturn));
// Chained mode (hwref.nds runs every program in turn): hw_done() returns to
// the runner instead of halting, and hw_init() mounts the SD card once.
#include <setjmp.h>
extern jmp_buf* hw_chain;
extern bool hw_fat_ok;
// hwref.nds menu: "new only". Programs with panels already captured on the
// DS (rules3d) then run only their new ones.
extern bool hw_new_only;

// Growable text buffer in main RAM for CSV output.
typedef struct { char* p; size_t len, cap; } Buf;
void buf_printf(Buf* b, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
bool buf_write(Buf* b, const char* name);  // writes and frees
bool buf_append(Buf* b, const char* name); // appends and frees

void wait_vcount(int line);                // until VCOUNT becomes `line` (edge)
