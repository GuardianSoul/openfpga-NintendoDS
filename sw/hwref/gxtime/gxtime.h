// GX timing reference: timing loops (run.itcm.c, in ITCM) and their data.
#pragma once
#include "../common/hwref.h"

typedef struct { vu32* a; u32 v; } Wr;        // one write to a GX port
typedef struct { u32 s; u32 t; } Sample;      // GXSTAT (+ flags), TM0

// Sample flags in GXSTAT's unused bits 28/29 (extended loop only).
#define SF_IF   (1u << 28)   // IF bit 21 (GX FIFO IRQ request)
#define SF_DMA  (1u << 29)   // DMA1 enable bit (DMA still running)

#ifndef MAX_SAMPLES
#define MAX_SAMPLES 1536
#endif
#define MAX_STALL   320
extern Sample g_samples[MAX_SAMPLES];
extern u32 g_stall[MAX_STALL + 1];
extern u32 g_iters;
extern u32 g_timeouts, g_timeout_gxstat, g_resets, g_reset_fail, g_dropped;  // bounded waits that ran out
bool gx_wait(u32 mask);
void gx_put(vu32* port, u32 v);
void gx_note_timeout(void);   // main.c: shows it on screen at once          // sample loop iterations of the last run

// SWAP_BUFFERS(swap) at VCOUNT 16, then the writes queue behind it while the
// engine waits for VBlank; then GXSTAT is sampled until the engine is idle
// (and DMA1 is done when ext). irqmode != 0 sets GXSTAT's FIFO IRQ mode
// after the writes. dma_words != 0 starts DMA1 in GX FIFO mode from dma_src
// after the writes. Returns the sample count.
int gx_run_drain(const Wr* w, int nw, u32 swap, int ext, u32 irqmode,
                 const u32* dma_src, u32 dma_words, bool stall_first);
// From idle: TM0 ticks from the first write until (GXSTAT & mask) clears
// (bit 27 = busy, bit 0 = BOX/POS/VEC test busy).
u32 gx_run_iso(const Wr* w, int nw, u32 mask);
// SWAP_BUFFERS at VCOUNT `line`: cycles until busy clears, VCOUNT then.
u32 gx_run_swap(int line, u32 param, u16* vc_end);
// Behind a SWAP: n writes of v to port, g_stall[i] = now32() before write i.
void gx_run_stall(vu32* port, u32 v, int n);
