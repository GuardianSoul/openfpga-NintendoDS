/* unita7.nds, ARM7: the hwref arm7time kernels (docs/hw-reference.md
   "arm7time"; DS values in run 30, arm7time.csv) for the core's scorecard
   (docs/unit-scorecard.md). Waits for MB->cmd == 1 (the ARM9 has mapped VRAM
   C to the ARM7), runs every kernel, writes ARM7 cycles per op x 100 to
   MB->val[], then sets IPCSYNC output to 1 (the ARM9 polls IPCSYNC, an I/O
   register, so it stays off main RAM while the ARM7 measures). Kernels run
   from WRAM (this ROM: ARM7 binary at 0x037F8000); the code_main rows run a
   copy in main RAM. TM0 F/1 + TM1 cascade: one tick = one ARM7 cycle. */
#include "../common/ds.h"
#include "../common/ipc.h"

static inline u32 now32(void)
{
    u16 h = R16(0x04000104), l = R16(0x04000100), h2 = R16(0x04000104);
    if (h != h2) { l = R16(0x04000100); h = h2; }
    return ((u32)h << 16) | l;
}

#define K __attribute__((target("arm"), noinline, aligned(32)))
#define LOOP(setup, body, ...) \
    __asm__ volatile(setup "1:\n.rept 64\n" body "\n.endr\nsubs %0, %0, #1\nbne 1b\n" : "+r"(n) : "r"(p), "r"(q) : __VA_ARGS__); return n;
typedef u32 (*Kern)(u32 n, u32 p, u32 q);

K static u32 k_alu(u32 n, u32 p, u32 q)    { LOOP("mov r1, #1\n", "add r0, r0, r1", "r0", "r1", "cc") }
K static u32 k_alu_sr(u32 n, u32 p, u32 q) { LOOP("mov r1, #1\nmov r2, #2\n", "add r0, r0, r1, lsl r2", "r0", "r1", "r2", "cc") }
K static u32 k_b(u32 n, u32 p, u32 q)      { LOOP("", "b 2f\n2:", "cc") }
K static u32 k_mul(u32 n, u32 p, u32 q)    { LOOP("mov r1, #3\n", "mul r3, r1, %2", "r1", "r3", "cc") }
K static u32 k_mla(u32 n, u32 p, u32 q)    { LOOP("mov r1, #3\nmov r4, #7\n", "mla r3, r1, %2, r4", "r1", "r3", "r4", "cc") }
K static u32 k_ldr(u32 n, u32 p, u32 q)    { LOOP("", "ldr r0, [%1]", "r0", "cc") }
K static u32 k_str(u32 n, u32 p, u32 q)    { LOOP("mov r0, #0\n", "str r0, [%1]", "r0", "cc", "memory") }
K static u32 k_ldm4(u32 n, u32 p, u32 q)   { LOOP("", "ldmia %1, {r2-r5}", "r2", "r3", "r4", "r5", "cc") }
K static u32 k_stm4(u32 n, u32 p, u32 q)   { LOOP("", "stmia %1, {r2-r5}", "r2", "r3", "r4", "r5", "cc", "memory") }
K static u32 k_swp(u32 n, u32 p, u32 q)    { LOOP("mov r1, #0\n", "swp r0, r1, [%1]", "r0", "r1", "cc", "memory") }

static u32 s_wram[16] __attribute__((aligned(32)));
#define MAIN_DATA 0x023E0000u   /* main RAM, away from the result block and mailbox */
#define MAIN_CODE 0x023E1000u   /* kernel copies (position-independent: registers and local branches) */

static Kern in_main(Kern k, int slot)
{
    u32 *d = (u32 *)(MAIN_CODE + slot * 0x200), *s = (u32 *)(u32)k;
    for (int i = 0; i < 0x80; i++) d[i] = s[i];
    return (Kern)(u32)d;
}

static u32 measure(Kern k, u32 p, u32 q)
{
    u32 b1 = ~0u, b2 = ~0u;
    for (int r = 0; r < 5; r++) {
        k(1, p, q);
        u32 t0 = now32();
        k(4, p, q);
        u32 t1 = now32() - t0;
        t0 = now32();
        k(16, p, q);
        u32 t2 = now32() - t0;
        if (t1 < b1) b1 = t1;
        if (t2 < b2) b2 = t2;
    }
    return b2 > b1 ? (b2 - b1) * 100 / (12 * 64) : 0;
}

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    R16(0x04000102) = 0; R16(0x04000106) = 0; R16(0x04000104) = 0; R16(0x04000100) = 0;
    R16(0x04000106) = (1 << 7) | (1 << 2);
    R16(0x04000102) = 1 << 7;
    IPCSYNC = A7_READY << 8;
    while (MB->cmd != 1) {}
    u32 w = (u32)s_wram, m = MAIN_DATA, v = 0x06000100;
    const struct { Kern k; u32 p, q; } t[] = {
        /* DS run 30 (ARM7 cycles x 100) in the comment */
        { k_alu, w, 0 },                       /* 0 ALU 106 */
        { k_alu_sr, w, 0 },                    /* 1 ALU shift by reg 206 */
        { k_b, w, 0 },                         /* 2 B 306 */
        { k_mul, w, 0x7F },                    /* 3 MUL rs8 206 */
        { k_mul, w, 0x7FFFFFFF },              /* 4 MUL rs32 506 */
        { k_mla, w, 0x7FFFFFFF },              /* 5 MLA rs32 606 */
        { k_ldr, w, 0 },                       /* 6 LDR WRAM 306 */
        { k_str, w, 0 },                       /* 7 STR WRAM 306 */
        { k_ldm4, w, 0 },                      /* 8 LDM4 WRAM 606 */
        { k_stm4, w, 0 },                      /* 9 STM4 WRAM 606 */
        { k_ldr, m, 0 },                       /* 10 LDR main 904 */
        { k_str, m, 0 },                       /* 11 STR main 900 */
        { k_ldm4, m, 0 },                      /* 12 LDM4 main 1504 */
        { k_stm4, m, 0 },                      /* 13 STM4 main 1500 */
        { k_swp, m, 0 },                       /* 14 SWP main 1801 */
        { in_main(k_alu, 0), w, 0 },           /* 15 code in main: ALU 223 */
        { in_main(k_b, 1), w, 0 },             /* 16 code in main: B 1410 */
        { in_main(k_ldr, 2), w, 0 },           /* 17 code in main: LDR WRAM 922 */
        { in_main(k_str, 3), w, 0 },           /* 18 code in main: STR WRAM 923 */
        { k_ldr, v, 0 },                       /* 19 LDR VRAM C (ARM7) 406 */
        { k_str, v, 0 },                       /* 20 STR VRAM C 306 */
    };
    for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) MB->val[i] = measure(t[i].k, t[i].p, t[i].q);
    MB->ack = 1;
    IPCSYNC = 1 << 8;
    for (;;)
        ;
}
