@ Directed test: a consumer two instructions after a load from uncached memory (ldr; other; cmp) sees the
@ loaded value. Exit code 0 = pass, else 0x80000000 + the value the compare saw.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ UNC, 0x00400000
.equ AREA, 0x02040000
.global _start
_start:
    mov     r11, #0
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE
    ldr     r4, =AREA + UNC
    mov     r0, #0x100
    str     r0, [r4]                        @ memory = 0x100 (uncached)
    mcr     p15, 0, r0, c7, c10, 4
    mov     r5, #0
    ldr     r2, =0xFFFF
1:  ldr     r1, [r4]
    add     r6, r5, #1                      @ some other instruction
    cmp     r1, r0                          @ the use, two after the load
    bne     fail
    add     r5, r5, #1
    cmp     r5, #16
    bne     1b
    mov     r11, #0
    ldr     r3, =EXIT
    str     r11, [r3]
    b       .
fail:
    orr     r11, r1, #0x80000000
    ldr     r3, =EXIT
    str     r11, [r3]
    b       .
.ltorg
