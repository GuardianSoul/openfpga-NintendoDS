@ Directed test: DC_FlushAll (clean and invalidate the D-cache by set/way, looping over the DS's 4 ways and
@ 32 sets) must reach every dirty line also when the D cache holds more than the DS's 128 lines (A9_XD > 0):
@ 512 lines are dirtied in write-back memory (16 KB: all resident in a 4x cache), then flushed, then read
@ back through the uncached mirror. Exit code 0 = pass, else the failing step (r11) with 0x1000 + the line.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ UNC, 0x00400000                        @ offset to the uncached mirror
.equ AREA, 0x02040000
.equ LINES, 512
.global _start
_start:
    mov     r11, #0
    msr     cpsr_c, #0xD7
    ldr     sp, =0x020F8000
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE

    mov     r11, #1                         @ dirty 512 lines (the load allocates the line)
    ldr     r4, =AREA
    mov     r5, #0
1:  ldr     r1, [r4]
    add     r0, r5, #0x100
    str     r0, [r4]
    add     r4, r4, #32
    add     r5, r5, #1
    cmp     r5, #LINES
    bne     1b

    mov     r11, #2                         @ DC_FlushAll as the DS's libraries do it
    mov     r1, #0                          @ way
4:  mov     r2, #0                          @ set
5:  orr     r3, r2, r1
    mcr     p15, 0, r3, c7, c14, 2
    add     r2, r2, #0x20
    cmp     r2, #0x400
    bne     5b
    adds    r1, r1, #0x40000000
    bne     4b
    mcr     p15, 0, r0, c7, c10, 4          @ drain

    mov     r11, #3                         @ every line is in memory
    ldr     r4, =AREA + UNC
    mov     r5, #0
6:  add     r0, r5, #0x100
    ldr     r1, [r4]
    cmp     r1, r0
    orrne   r11, r1, r5, lsl #16
    orrne   r11, r11, #0x80000000
    bne     fail
    add     r4, r4, #32
    add     r5, r5, #1
    cmp     r5, #LINES
    bne     6b
    mov     r11, #4                         @ the flush also invalidated every line: a few lines (spread over the
    ldr     r7, =AREA                       @ sets, most beyond the DS's 128) get new data through the uncached
    mov     r5, #64                         @ mirror, and the cached read must see it
7:  add     r4, r7, r5, lsl #5
    add     r4, r4, #UNC
    add     r0, r5, #0x300
    str     r0, [r4]
    add     r5, r5, #37
    cmp     r5, #LINES
    blt     7b
    mcr     p15, 0, r0, c7, c10, 4
    mov     r5, #64
8:  add     r4, r7, r5, lsl #5
    add     r0, r5, #0x300
    ldr     r1, [r4]
    cmp     r1, r0
    orrne   r11, r1, r5, lsl #16
    orrne   r11, r11, #0x80000000
    bne     fail
    add     r5, r5, #37
    cmp     r5, #LINES
    blt     8b
    mov     r11, #0
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .
fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .
.ltorg
