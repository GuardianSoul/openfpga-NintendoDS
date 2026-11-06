// vramcnt (docs/hw-reference.md "vramcnt"; integration session): after an
// ARM9 STRB to VRAMCNT_A, does the next VRAM access see the new mapping, and
// does it pay extra cycles? GBATEK ("DS Memory Control - VRAM") gives no
// delay; melonDS remaps at once (GPU::MapVRAM_AB), so "new" at every N.
//
// Kernels in ITCM, IRQs locked, no DMA; region 0 (I/O, VRAM) uncached
// under calico's MPU. Bank A filled with 0xAAAA5555 (LCDC), bank B with
// 0xBBBB6666. Per case and N NOPs between the STRB and the access, 64 runs
// of the remap and of a baseline whose STRB writes the value VRAMCNT_A
// already has:
//   read_unmap  A at LCDC (0x80), STRB 0x81 (A -> ABG), LDR 0x06800000
//               old 0xAAAA5555, new: unmapped (0 or open bus)
//   read_map    A at ABG (0x81), STRB 0x80, LDR 0x06800000: old unmapped, new 0xAAAA5555
//   write_map   A at ABG (0x81), STRB 0x80, STR 0x12345678 -> 0x06800004;
//               then through LCDC: 0x12345678 = the new mapping took it
// vramcnt.csv: case,n,kind,mapped,unmapped,other,min_cycles,
// mean_cycles_x100,first_value: how many of the 64 accesses reached bank A
// through LCDC 0x06800000 (read: 0xAAAA5555; write: the marker landed),
// found it unmapped (read 0; write: the old fill survived), or saw something
// else (ARM9 cycles = 2 x TM0 ticks, including the two timer reads). New
// mapping: read_unmap -> unmapped, read_map and write_map -> mapped.
#include "vramcnt.h"
#include <stdio.h>

#define VERSION "vramcnt 1"
#define REPS 64
#define A_FILL 0xAAAA5555u
#define B_FILL 0xBBBB6666u

static vu8* const cntA = (vu8*)0x04000240;

static void fill(void)
{
	R_VRAMCNT(0) = 0x80;
	R_VRAMCNT(1) = 0x80;
	for (u32 i = 0; i < 256; i++) {
		((vu32*)0x06800000)[i] = A_FILL;
		((vu32*)0x06820000)[i] = B_FILL;
	}
}

int main(void)
{
	hw_init(VERSION " - VRAMCNT remap timing");
	R_TM0CNT = 0;
	R_TM0 = 0;
	R_TM0CNT = 1 << 7;   // TM0 F/1 free-running (TM1 cascade still counts above it)
	fill();
	Buf csv = {0};
	buf_printf(&csv, "case,n,kind,mapped,unmapped,other,min_cycles,mean_cycles_x100,first_value\n");
	static const char* names[3] = { "read_unmap", "read_map", "write_map" };
	for (int c = 0; c < 3; c++)
		for (int ni = 0; ni < VK_NS; ni++)
			for (int kind = 0; kind < 2; kind++) {   // 0 remap, 1 baseline
				u8 setup = c == 0 ? 0x80 : 0x81;
				u8 to = kind ? setup : (c == 0 ? 0x81 : 0x80);
				u32 mn = ~0u, sum = 0, nmap = 0, nun = 0, noth = 0, first = 0;
				for (int r = 0; r < REPS; r++) {
					if (c == 2) { R_VRAMCNT(0) = 0x80; ((vu32*)0x06800000)[1] = A_FILL; }
					R_VRAMCNT(0) = setup;
					u32 v = 0;
					ArmIrqState st = armIrqLockByPsr();
					u32 t = c == 2 ? vk_write[ni](to, cntA, 0x06800004, &v) : vk_read[ni](to, cntA, 0x06800000, &v);
					armIrqUnlockByPsr(st);
					if (c == 2) { R_VRAMCNT(0) = 0x80; v = ((vu32*)0x06800000)[1]; }
					t *= 2;
					if (t < mn) mn = t;
					sum += t;
					if (!r) first = v;
					// the access went to bank A (mapped at LCDC) or found nothing there
					if (c == 2 ? v == 0x12345678 : v == A_FILL) nmap++;
					else if (c == 2 ? v == A_FILL : v == 0) nun++;
					else noth++;
				}
				buf_printf(&csv, "%s,%u,%s,%lu,%lu,%lu,%lu,%lu,%08lx\n", names[c], vk_n[ni], kind ? "baseline" : "remap",
				           (unsigned long)nmap, (unsigned long)nun, (unsigned long)noth, (unsigned long)mn,
				           (unsigned long)(sum * 100 / REPS), (unsigned long)first);
			}
	fill();
	R_VRAMCNT(0) = 0x80;
	buf_write(&csv, "vramcnt.csv");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt " __DATE__ " " __TIME__ "\nARM9 STRB VRAMCNT_A, n NOPs, LDR/STR VRAM, from ITCM, IRQs locked;"
	           " cycles = 2 x TM0 ticks incl. the two timer reads; baseline STRB writes the unchanged value\n", VERSION);
	buf_write(&info, "vramcnt_info.txt");
	hw_done();
}
