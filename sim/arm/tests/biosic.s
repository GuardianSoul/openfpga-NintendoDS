@ The ARM9 I-cache on BIOS lines (track C0: HeartGold's c2 I = 0x42 caches region 6, the BIOS at 0xFFFF0000, as
@ the DS does). Runs on the ARM9 from 0x02000000 with cp15.inc's map, except r6: 0xFFFF0000, 32 KB, I-cacheable,
@ not D-cacheable (stores reach memory), full access. The testbench's memory index ignores address bits 31:28 and
@ 23:18, so code stored at 0xFFFF0100 runs from there.
@   1  a routine copied to the BIOS runs (cold: the fill)
@   2  ... 50 times in a row (cached)
@   3  a main-RAM routine on the same I-cache set and the same address bits 21:5 (0x023F0100), interleaved with the
@      BIOS one, each answers its own value (no alias between main RAM and BIOS lines)
@   4  the BIOS routine rewritten without an invalidate still answers the old value (its line is cached, as on the DS)
@   5  ... and after an invalidate by address the new one
@   6  a routine run from main RAM's uncached mirror (0x02400000 + x, cp15.inc r2) sees a rewrite at once
@ Exit code 0 = pass, else the failing step (r11).
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ BIOSR, 0xFFFF0100
.equ MAINR, 0x023F0100
.equ MIRR,  0x02480100                      @ main RAM 0x02080100 through the uncached mirror
.global _start
_start:
    mov     r11, #0
    ldr     sp, =0x020FC000
    CP15_REGIONS
    ldr     r0, =0xFFFF001D                 @ r6: 0xFFFF0000, 32 KB, on
    mcr     p15, 0, r0, c6, c6, 0
    mov     r0, #0xC2                       @ I cacheable: r1, r6, r7
    mcr     p15, 0, r0, c2, c0, 1
    ldr     r0, =0x33333333                 @ D and I access: everyone, every region
    mcr     p15, 0, r0, c5, c0, 2
    mcr     p15, 0, r0, c5, c0, 3
    ldr     r0, =CP15_CTRL_ON
    mcr     p15, 0, r0, c1, c0, 0

    @ 1: the routine to the BIOS (marker 0x100), then run it
    mov     r11, #1
    ldr     r5, =BIOSR
    ldr     r1, =rtn
    mov     r2, #0x100
    bl      place
    mov     r0, #0
    mcr     p15, 0, r0, c7, c10, 4          @ drain the write buffer
    mcr     p15, 0, r0, c7, c5, 0           @ invalidate the I-cache
    blx     r5
    ldr     r1, =820 + 0x100
    cmp     r0, r1
    bne     fail

    @ 2: 50 times
    mov     r11, #2
    mov     r6, #50
    mov     r7, #0
1:  blx     r5
    add     r7, r7, r0
    subs    r6, r6, #1
    bne     1b
    ldr     r1, =50 * (820 + 0x100)
    cmp     r7, r1
    bne     fail

    @ 3: the main-RAM routine on the same set and bits 21:5 (marker 0x300), interleaved
    mov     r11, #3
    ldr     r8, =MAINR
    mov     r5, r8
    ldr     r1, =rtn
    mov     r2, #0x300
    bl      place
    mcr     p15, 0, r8, c7, c10, 1          @ clean its two lines (main RAM is write-back) so the I side sees them
    add     r0, r8, #32
    mcr     p15, 0, r0, c7, c10, 1
    ldr     r5, =BIOSR
    mov     r0, #0
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r0, c7, c5, 0
    mov     r6, #20
2:  blx     r8
    ldr     r1, =820 + 0x300
    cmp     r0, r1
    bne     fail
    blx     r5
    ldr     r1, =820 + 0x100
    cmp     r0, r1
    bne     fail
    subs    r6, r6, #1
    bne     2b

    @ 4: rewrite the BIOS routine (marker 0x200), no invalidate: the cached lines answer
    mov     r11, #4
    ldr     r1, =rtn
    mov     r2, #0x200
    bl      place
    mov     r0, #0
    mcr     p15, 0, r0, c7, c10, 4
    blx     r5
    ldr     r1, =820 + 0x100
    cmp     r0, r1
    bne     fail

    @ 5: invalidate its lines by address: the new routine
    mov     r11, #5
    mcr     p15, 0, r5, c7, c5, 1
    add     r0, r5, #32
    mcr     p15, 0, r0, c7, c5, 1
    blx     r5
    ldr     r1, =820 + 0x200
    cmp     r0, r1
    bne     fail

    @ 6: main RAM's uncached mirror: a rewrite shows at once
    mov     r11, #6
    ldr     r5, =MIRR
    ldr     r1, =rtn
    mov     r2, #0x400
    bl      place
    mov     r0, #0
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r0, c7, c5, 0
    blx     r5
    ldr     r1, =820 + 0x400
    cmp     r0, r1
    bne     fail
    ldr     r1, =rtn
    mov     r2, #0x500
    bl      place
    mov     r0, #0
    mcr     p15, 0, r0, c7, c10, 4
    blx     r5
    ldr     r1, =820 + 0x500
    cmp     r0, r1
    bne     fail

    mov     r11, #0
fail:
    ldr     r0, =EXIT
    str     r11, [r0]
3:  b       3b

@ place: copy the 16-word routine at r1 to r5, its marker (the add's immediate) set to r2 (0x100..0x500, a rotated
@ immediate: 0xE2800C01 | n is add r0, r0, #n * 0x100)
place:
    push    {r1-r4, lr}
    mov     r3, #0
1:  ldr     r4, [r1, r3, lsl #2]
    cmp     r3, #5
    ldreq   r4, =0xE2800C00
    orreq   r4, r4, r2, lsr #8
    str     r4, [r5, r3, lsl #2]
    add     r3, r3, #1
    cmp     r3, #16
    bne     1b
    pop     {r1-r4, pc}

@ the routine: r0 = 40 + 39 + ... + 1 (820) + the marker; position independent, two cache lines
.balign 32
rtn:
    mov     r0, #0
    mov     r2, #40
1:  add     r0, r0, r2
    subs    r2, r2, #1
    bne     1b
    add     r0, r0, #0x100                  @ (word 5: the marker, set by place)
    bx      lr
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
.pool
