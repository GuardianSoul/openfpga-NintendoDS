// vramcnt: when does a VRAM access see a new VRAMCNT bank mapping, and what
// does the access cost? (docs/hw-reference.md "vramcnt")
#pragma once
#include "../common/hwref.h"

// Kernels (ITCM, ARM): TM0 read, STRB val -> [cnt], n NOPs, then LDR [addr]
// (read) or STR 0x12345678 -> [addr] (write), TM0 read. *out = the loaded
// value. Returns the TM0 ticks between the two reads (16 bits).
typedef u32 (*vk_fn)(u32 val, vu8* cnt, u32 addr, u32* out);
#define VK_NS 7
extern const u8 vk_n[VK_NS];            // 0, 1, 2, 3, 4, 6, 8
extern const vk_fn vk_read[VK_NS], vk_write[VK_NS];
