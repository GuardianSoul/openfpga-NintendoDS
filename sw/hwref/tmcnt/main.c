// tmcnt (docs/hw-reference.md "tmcnt"; sound/sys session): what TMCNT_H
// reads back. GBATEK marks bits 3-5 and 8-15 unused; melonDS stores and
// returns all 16 bits (NDS::TimerStart keeps cnt as written). If the DS
// reads them as 0, the core needs to store only bits 0-2, 6 and 7 (88 flops
// in sys_timers). Also: byte writes to TMCNT_H (the core and melonDS ignore
// them) and a 32-bit write's high half.
//
// ARM9 timers 2 and 3 only (TM0/TM1 are hwref's clock). No waits, no IRQs
// (bit 6 never set): every case is a few stores and loads, so nothing can
// hang. Each timer is stopped (0) for every case and then set back to
// calico's setting and count (hwref merge: calico owns TM2/TM3).
// tmcnt.csv: case,timer,written,read16,read32_hi,read32_lo_changed
#include "../common/hwref.h"
#include <stdio.h>

#define VERSION "tmcnt 1"

static vu16* cnt16(int t) { return (vu16*)(0x04000102 + 4 * t); }
static vu8*  cnt8(int t, int b) { return (vu8*)(0x04000102 + 4 * t + b); }
static vu32* tm32(int t) { return (vu32*)(0x04000100 + 4 * t); }

int main(void)
{
	hw_init(VERSION " - TMCNT_H read-back");
	Buf csv = {0};
	buf_printf(&csv, "case,timer,written,read16,read32_hi,read32_lo\n");
	for (int t = 2; t < 4; t++) {
		static const struct { const char* name; int kind; u32 v; } cs[] = {
			{ "h16_stopped",  0, 0xFF38 },   // unused bits set, bit 7 clear
			{ "h16_started",  0, 0xFFBB },   // + start, F/1024, no IRQ, no cascade
			{ "h16_used",     0, 0x0083 },   // only used bits: start, F/1024
			{ "h8_high",      1, 0xFF },     // STRB 0xFF to TMCNT_H bits 8-15
			{ "h8_low",       2, 0xB8 },     // STRB 0xB8 to TMCNT_H bits 0-7 (start, bits 3-5)
			{ "w32",          3, 0xFF381234 },   // STR {cnt 0xFF38, reload 0x1234}
		};
		for (unsigned c = 0; c < sizeof cs / sizeof cs[0]; c++) {
			// calico owns TM2/TM3: keep its setting and count, put them back after
			ArmIrqState st = armIrqLockByPsr();
			u16 saved_cnt = *cnt16(t), saved_val = *(vu16*)(0x04000100 + 4 * t);
			*cnt16(t) = 0;
			switch (cs[c].kind) {
			case 0: *cnt16(t) = (u16)cs[c].v; break;
			case 1: *cnt8(t, 1) = (u8)cs[c].v; break;
			case 2: *cnt8(t, 0) = (u8)cs[c].v; break;
			default: *tm32(t) = cs[c].v; break;
			}
			u16 r16 = *cnt16(t);
			u32 r32 = *tm32(t);
			*cnt16(t) = 0;
			*(vu16*)(0x04000100 + 4 * t) = saved_val;   // reload = the count it had
			*cnt16(t) = saved_cnt;
			armIrqUnlockByPsr(st);
			buf_printf(&csv, "%s,%d,%08lx,%04x,%04lx,%04lx\n", cs[c].name, t, (unsigned long)cs[c].v, r16,
			           (unsigned long)(r32 >> 16), (unsigned long)(r32 & 0xFFFF));
		}
	}
	buf_write(&csv, "tmcnt.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt " __DATE__ " " __TIME__ "\nARM9 TM2/TM3: write TMCNT_H (16-bit, byte, 32-bit), read it back 16- and 32-bit;"
	           " timer stopped before and after each case, IRQs locked, bit 6 never set\n", VERSION);
	buf_write(&info, "tmcnt_info.txt");
	hw_done();
}
