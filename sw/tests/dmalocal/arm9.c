/* Eventual results also pass with DMA9_RUN=0. The simulation's optional
   --dma-local-check observes the marked R10 sequence while DMA is busy. */
#include "../common/con.h"
#include "../common/results.h"

enum { WORDS = 1024, ITERATIONS = 4096 };
static u32 src[WORDS], dst[WORDS];
extern const u32 local_start[], local_end[];

/* Copied, including its literal pool, to ITCM at 0x1000. Stack is DTCM.
   Between enabling DMA3 and finishing the increment loop, all instruction
   fetches, registers, and data are local. External polling happens later. */
__asm__(
    ".pushsection .text.dmalocal,\"ax\",%progbits\n"
    ".balign 4\n.global local_start, local_end\n"
    "local_start:\n"
    "push {r4,r5,r10,lr}\n"
    "ldr r4, =0x040000d4\n"
    "str r0, [r4]\n"
    "str r1, [r4, #4]\n"
    "mov r10, #0xd1000000\n"
    "ldr r5, =0x84000400\n" /* enable, 32-bit, 1024 words */
    "str r5, [r4, #8]\n"
    "1: add r10, r10, #1\n"
    "subs r3, r3, #1\n"
    "bne 1b\n"
    "2: ldr r5, [r4, #8]\n"
    "tst r5, #0x80000000\n"
    "bne 2b\n"
    "sub r0, r10, #0xd1000000\n"
    "pop {r4,r5,r10,pc}\n"
    ".ltorg\n"
    "local_end:\n.popsection\n");

int main(void)
{
    con_init();
    res_begin("DMA LOCAL PROGRESS", 3);
    for (u32 i = 0; i < WORDS; i++) {
        src[i] = 0x9e3779b9u * (i + 7) ^ i << 24;
        dst[i] = ~src[i];
    }
    volatile u32 *code = (volatile u32 *)0x1000;
    for (const u32 *p = local_start; p < local_end; p++)
        *code++ = *p;
    u32 zero = 0;
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4\n"
                     "mcr p15, 0, %0, c7, c5, 0" :: "r"(zero) : "memory");
    typedef u32 (*local_fn)(u32 *, u32 *, u32, u32);
    u32 count = ((local_fn)0x1000)(src, dst, WORDS, ITERATIONS);
    u32 bad = 0, actual = 0, expected = 0;
    for (u32 i = 0; i < WORDS; i++) {
        bad += dst[i] != src[i];
        actual += dst[i] * (2 * i + 1);
        expected += src[i] * (2 * i + 1);
    }
    res_check(0, "LOCALCOUNT", count, ITERATIONS);
    res_check(1, "COPYWORDS", bad, 0);
    res_check(2, "COPYORDER", actual, expected);
    res_finish();
    for (;;)
        __asm__ volatile("nop");
}
