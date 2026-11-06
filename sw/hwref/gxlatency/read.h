#pragma once
#include "../gxtime/gxtime.h"
typedef struct { u32 before, value, after, elapsed; } GxRead;
void gxlat_read(int load, int delay, u32 address, GxRead* result);
typedef struct { u32 dma_sys, idle_sys, dma_stat, idle_stat, timeout; } GxDmaTime;
void gxlat_dma(const u32* words, u32 count, GxDmaTime* result);
