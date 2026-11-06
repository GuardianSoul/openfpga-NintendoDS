// arm7time (docs/hw-reference.md "arm7time"): commands from the ARM9 to our
// own ARM7 program over PXI user channel 0. A command is a 26-bit packet:
// bits 0-7 the kernel (A7K_*), bits 8-23 an argument. The ARM7 answers on the
// same channel with one packet: the result (26 bits), or A7_BAD.
#pragma once

#define A7_CH PxiChannel_User0
#define A7_BAD 0x3FFFFFF

enum {
	// cycles per op x 100 (ARM7 cycles, 33.514 MHz): 64 ops per iteration,
	// 16 and 64 iterations, best of 5, IRQs off
	A7K_ALU, A7K_ALU_SHIFTREG, A7K_B, A7K_MUL8, A7K_MUL16, A7K_MUL24, A7K_MUL32,
	A7K_MLA8, A7K_MLA16, A7K_MLA24, A7K_MLA32,
	A7K_LDR_WRAM, A7K_STR_WRAM, A7K_LDM4_WRAM, A7K_STM4_WRAM, A7K_SWP_WRAM,
	A7K_LDR_MAIN, A7K_STR_MAIN, A7K_LDM4_MAIN, A7K_STM4_MAIN, A7K_SWP_MAIN,
	// the same, the code in main RAM (data in WRAM)
	A7K_M_ALU, A7K_M_ALU_SHIFTREG, A7K_M_B, A7K_M_MUL32, A7K_M_LDR_WRAM, A7K_M_STR_WRAM,
	// VRAM C as ARM7 WRAM (the ARM9 sets VRAMCNT_C = 0x82): argument 0 starts
	// at VCOUNT 192, 1 at VCOUNT 96
	A7K_LDR_VRAMC, A7K_STR_VRAMC,
	A7K_NKERNELS,
	// main-RAM load loop of (argument x 64) loads: ticks (contention test)
	A7K_MAINLOAD = 0x80,
	A7K_PING = 0x81,
};
