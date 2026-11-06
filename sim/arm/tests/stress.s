@ Long-running block transfers with writeback, to run on both contexts at
@ once (ARM9 cached build + ARM7 build with CTXOFF=64): the per-context
@ temporaries of LDM/STM must never mix. ARMv4T code. Exit 0 = pass.
.syntax unified
.arm
.include "cp15.inc"
.ifndef CTXOFF
.set CTXOFF, 0
.endif
.equ EXIT, 0x0F000000
.global _start
_start:
.ifdef CACHED
    CP15_REGIONS
    CP15_ENABLE
.endif
    ldr     r12, =buf + CTXOFF
    ldr     r11, =400                       @ iterations
    mov     r1, #1
1:  mov     r0, r12
    add     r2, r1, #1
    add     r3, r1, #2
    add     r4, r1, #3
    stmia   r0!, {r1-r4}
    stmia   r0!, {r1-r4}
    ldmdb   r0!, {r5-r8}
    ldmdb   r0!, {r5-r8}
    cmp     r0, r12                         @ base back where it started
    bne     fail
    add     r5, r5, r8
    add     r6, r6, r7
    cmp     r5, r6                          @ (r1 + r1+3) == (r1+1 + r1+2)
    bne     fail
    add     r1, r1, #4
    subs    r11, r11, #1
    bne     1b
    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .
fail:
    ldr     r2, =EXIT
    mov     r1, #1
    str     r1, [r2]
    b       .
.ltorg
.align 5
buf:
    .space  160
