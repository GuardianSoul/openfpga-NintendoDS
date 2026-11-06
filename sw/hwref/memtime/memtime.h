// ARM9 memory and DMA timing reference: kernels in ITCM (run.itcm.c), the
// test list and output in main.c. docs/hw-reference.md "memtime".
#pragma once
#include "../common/hwref.h"

// A measuring kernel: `it` iterations of an unrolled block (64 single
// accesses or 16 LDM/STM per iteration), base address b.
typedef void (*KFn)(u32 b, u32 it);

// Kernel modes: the address pattern of one block.
enum { KM_SEQ, KM_S32, KM_ADV32, KM_FIX, KM_COUNT };
// Ops.
enum { OP_LDR, OP_LDRH, OP_LDRB, OP_LDM, OP_STR, OP_STRH, OP_STRB, OP_STM, OP_COUNT };
extern const KFn g_kern[OP_COUNT][KM_COUNT];   // NULL where not built
extern const KFn g_k_raw;      // STR then LDR of the same word, stride 32 (per pair)
extern const KFn g_k_nop64;    // 64 NOPs per iteration (loop calibration)
extern const KFn g_k_fill[4];  // single shots: w0, w7, w0+w1, w0+w7
#define PER_ITER(op) (((op) == OP_LDM || (op) == OP_STM) ? 16 : 64)

// Best-effort timing of one kernel run, IRQs off; flush = D-cache flush
// (clean + invalidate) right before t0.
u32 mt_time(KFn f, u32 base, u32 it, bool flush);
// Single shot: warm (load once first) or miss (D-cache flushed).
u32 mt_fill(KFn f, u32 base, bool miss);

// CP15 state.
typedef struct {
	u32 ctrl, dcache, icache, wrbuf, dperm, iperm, region[8], dtcm, itcm;
} Cp15;
void mt_cp15_read(Cp15* c);
int mt_region_of(u32 addr);     // highest enabled MPU region covering addr, -1 if none
// Region `r`'s D-cache (C) and write-buffer (B) bits, and I-cache bit; the
// D-cache is flushed first, IRQs off. mt_cfg_restore puts back what
// mt_cfg_save saw.
void mt_cfg_save(void);
void mt_cfg_set(int r, int c, int b);
void mt_cfg_set_icache(int r, int i);
void mt_cfg_restore(void);

// Instruction fetch: n NOPs (n <= SLED_N) of a sled; warm calls it once
// first; cold invalidates the I-cache first.
#define SLED_N 1024
extern const u32 mt_sled_itcm[], mt_sled_main[];
u32 mt_ifetch(const u32* sled, u32 n, int mode);   // 0 warm, 1 cold
// DMA3 immediate: cycles from the CNT write until the enable bit clears
// (bounded; 0xFFFFFFFF on a timeout).
u32 mt_dma(u32 src, u32 dst, u32 cnt);
extern u32 g_dma_timeouts;
