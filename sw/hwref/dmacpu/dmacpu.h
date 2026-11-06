// dmacpu: does the ARM9 run during an ARM9 DMA? (docs/hw-reference.md "dmacpu")
#pragma once
#include "../common/hwref.h"

typedef u32 (*dk_loop_fn)(const vu32* d, u32 k);
u32 dk_loop_itcm(const vu32* d, u32 k);
u32 dk_measure(u32 src, u32 dst, u32 words, dk_loop_fn fn, const vu32* d, u32 k, u32 clear, u32* sum);
void dk_collide(u32 src, u32 dst, u32 words, const u32* offs, u32 n, u32* out, bool store);
