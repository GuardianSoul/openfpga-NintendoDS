@ ARM9 D-cache dirty half-lines (arm9_mem MEM1; docs/game-faults.md, Dawn of Sorrow): a store dirties only its
@ half of the line (words 0-3 or 4-7), and a write-back (clean, clean and invalidate, eviction) writes only the
@ dirty halves, so memory a DMA wrote into the clean half since the line was filled survives. The "DMA" here is a
@ store through the uncached alias. 32 lines a pass:
@   A: load (allocate), store word 0 (lower half dirty), alias-store word 4; clean+invalidate (c7,c14,1) on even
@      lines, eviction by 64 KB of other reads on odd lines; then both words read through the alias
@   B: the same with the halves swapped (upper dirty, lower "DMA"), clean (c7,c10,1) on even lines
@ The testbench writes 0x48444952 at 0x0203FFFC when the build has MEM1 (SLOW, A9_OPT bit 19), the only form with
@ half-line dirty bits; elsewhere the test exits 0 at once.
@ Exit code 0 = pass; 0x100 + line: A's DMA word lost, 0x200: A's stored word lost, 0x300/0x400 the same for B.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ BUF,  0x02018000                       @ cached, write-back (region 1)
.equ ALIAS, 0x02418000                      @ the same memory, uncached (region 2)
.equ FAR,  0x02100000                       @ 64 KB of other lines to read (aliases the low test memory: reads only)
.equ FEAT, 0x0243FFFC
.global _start
_start:
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    ldr     r0, =FEAT
    ldr     r0, [r0]
    ldr     r1, =0x48444952
    cmp     r0, r1
    bne     pass
    CP15_REGIONS
    CP15_ENABLE
    @ ---- A: lower half dirty, "DMA" into the upper half
    ldr     r8, =BUF
    ldr     r9, =ALIAS
    mov     r4, #0
1:  add     r10, r8, r4, lsl #5
    add     r11, r9, r4, lsl #5
    ldr     r5, [r10]                       @ allocate
    orr     r2, r4, #0xAA000000
    str     r2, [r10]                       @ lower half dirty
    orr     r3, r4, #0xDD000000
    str     r3, [r11, #16]                  @ the "DMA" into the upper half (memory, behind the cache)
    tst     r4, #1
    mcreq   p15, 0, r10, c7, c14, 1         @ even lines: clean and invalidate
    add     r4, r4, #1
    cmp     r4, #32
    bne     1b
    bl      evict
    mov     r4, #0
2:  add     r11, r9, r4, lsl #5
    ldr     r5, [r11, #16]
    orr     r3, r4, #0xDD000000
    cmp     r5, r3
    addne   r0, r4, #0x100
    bne     fail
    ldr     r5, [r11]
    orr     r2, r4, #0xAA000000
    cmp     r5, r2
    addne   r0, r4, #0x200
    bne     fail
    add     r4, r4, #1
    cmp     r4, #32
    bne     2b
    @ ---- B: upper half dirty, "DMA" into the lower half
    mov     r4, #0
3:  add     r10, r8, r4, lsl #5
    add     r11, r9, r4, lsl #5
    ldr     r5, [r10, #16]                  @ allocate
    orr     r2, r4, #0xBB000000
    str     r2, [r10, #16]                  @ upper half dirty
    orr     r3, r4, #0xEE000000
    str     r3, [r11]                       @ the "DMA" into the lower half
    tst     r4, #1
    mcreq   p15, 0, r10, c7, c10, 1         @ even lines: clean (the line stays, clean)
    add     r4, r4, #1
    cmp     r4, #32
    bne     3b
    bl      evict
    mov     r4, #0
4:  add     r11, r9, r4, lsl #5
    ldr     r5, [r11]
    orr     r3, r4, #0xEE000000
    cmp     r5, r3
    addne   r0, r4, #0x300
    bne     fail
    ldr     r5, [r11, #16]
    orr     r2, r4, #0xBB000000
    cmp     r5, r2
    addne   r0, r4, #0x400
    bne     fail
    add     r4, r4, #1
    cmp     r4, #32
    bne     4b
pass:
    mov     r0, #0
fail:
    ldr     r1, =EXIT
    str     r0, [r1]
9:  b       9b
@ read 64 KB of other lines: every D line of BUF is evicted (more than any D-cache form here)
evict:
    ldr     r6, =FAR
    mov     r7, #0
5:  ldr     r5, [r6, r7, lsl #5]
    add     r7, r7, #1
    cmp     r7, #2048
    bne     5b
    bx      lr
