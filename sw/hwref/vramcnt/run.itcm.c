// vramcnt kernels, in ITCM (ARM state): see vramcnt.h.
#include "vramcnt.h"

#define VK(name, n, access)                                                     \
	__attribute__((naked, target("arm"), noinline)) static u32 name(u32 val, vu8* cnt, u32 addr, u32* out) \
	{                                                                           \
		__asm__ volatile(                                                       \
			"push {r4-r6}\n"                                                    \
			"ldr r12, =0x04000100\n"                                            \
			"ldr r6, =0x12345678\n"                                             \
			"mov r5, #0\n"                                                      \
			"ldrh r4, [r12]\n"                                                  \
			"strb r0, [r1]\n"                                                   \
			".rept " #n "\n mov r0, r0\n .endr\n"                               \
			access "\n"                                                         \
			"ldrh r1, [r12]\n"                                                  \
			"str r5, [r3]\n"                                                    \
			"sub r0, r1, r4\n"                                                  \
			"lsl r0, r0, #16\n"                                                 \
			"lsr r0, r0, #16\n"                                                 \
			"pop {r4-r6}\n"                                                     \
			"bx lr\n"                                                           \
			".pool\n");                                                         \
	}
#define RD "ldr r5, [r2]"
#define WR "str r6, [r2]"
VK(r0_, 0, RD) VK(r1_, 1, RD) VK(r2_, 2, RD) VK(r3_, 3, RD) VK(r4_, 4, RD) VK(r6_, 6, RD) VK(r8_, 8, RD)
VK(w0_, 0, WR) VK(w1_, 1, WR) VK(w2_, 2, WR) VK(w3_, 3, WR) VK(w4_, 4, WR) VK(w6_, 6, WR) VK(w8_, 8, WR)

const u8 vk_n[VK_NS] = { 0, 1, 2, 3, 4, 6, 8 };
const vk_fn vk_read[VK_NS] = { r0_, r1_, r2_, r3_, r4_, r6_, r8_ };
const vk_fn vk_write[VK_NS] = { w0_, w1_, w2_, w3_, w4_, w6_, w8_ };
