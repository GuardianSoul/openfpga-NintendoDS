@ Directed test for back-to-back dependencies in the pipeline: flag and
@ register results used by the very next instruction, load-use, RRX after a
@ carry-setting instruction, branches right after compares, and Thumb.
@ ARMv4T code. Built twice, with CTXOFF = 0 and 64, so the two contexts run
@ block transfers on different addresses at the same time (per-context
@ temporaries must not mix). Exit code 0 = pass, else the failing step.
.ifndef CTXOFF
.set CTXOFF, 0
.endif
.syntax unified
.arm
.equ EXIT, 0x0F000000
.include "cp15.inc"
.global _start
_start:
.ifdef CACHED
    CP15_REGIONS                            @ ARM9 build with caches/MPU/TCMs on
    CP15_ENABLE
.endif
    ldr     sp, =0x02010000
    mov     r11, #0

    @ 1: RRX directly after an ADDS that sets C
    mov     r11, #1
    mvn     r0, #0
    mov     r1, #1
    mov     r2, #0
    adds    r0, r0, r1              @ C = 1
    mov     r3, r2, rrx             @ r3 = 0x80000000
    cmp     r3, #0x80000000
    bne     fail
    adds    r0, r1, r1              @ C = 0
    movs    r3, r1, rrx             @ r3 = 0, C = 1 (bit 0 of r1)
    bne     fail
    bcc     fail

    @ 2: RRX after a shift that sets C, and MOVS carry from a register shift
    mov     r11, #2
    mov     r0, #3
    movs    r0, r0, lsr #1          @ r0 = 1, C = 1
    mov     r4, #0
    mov     r4, r4, rrx
    cmp     r4, #0x80000000
    bne     fail
    mov     r5, #33
    mov     r6, #1
    movs    r6, r6, lsl r5          @ LSL by 33: result 0, C = 0
    bcs     fail
    bne     fail

    @ 3: ADC/SBC using the C just set
    mov     r11, #3
    mvn     r0, #0
    adds    r1, r0, #1              @ r1 = 0, C = 1
    adc     r2, r1, #5              @ 6
    cmp     r2, #6
    bne     fail
    subs    r1, r1, #1              @ 0 - 1: C = 0
    sbc     r2, r1, #0              @ -1 - 0 - 1 = -2
    cmn     r2, #2
    bne     fail

    @ 4: result chains (each instruction uses the previous result)
    mov     r11, #4
    mov     r0, #1
    add     r0, r0, r0
    add     r0, r0, r0, lsl #1      @ 6
    sub     r0, r0, #1              @ 5
    rsb     r0, r0, r0, lsl #4      @ 75
    cmp     r0, #75
    bne     fail

    @ 5: load-use, at distances 1 and 2, as address and as data
    mov     r11, #5
    adr     r0, data
    ldr     r1, [r0]                @ address of data + 8
    ldr     r2, [r1]                @ load-use as address: 0xFF
    add     r3, r2, #1              @ load-use as data
    ldr     r4, [r0, #4]
    mov     r5, #0
    add     r5, r5, r4, lsl #2      @ load-use through the shifter (distance 2)
    ldr     r6, [r0, #4]
    mov     r7, r6, lsl #1          @ load-use through the shifter (distance 1)
    ldr     r8, [r0, #4]
    mov     r9, #1
    mov     r9, r9, lsl r8          @ load-use as a shift amount
    cmp     r3, #0x100
    bne     fail
    cmp     r5, #12
    bne     fail
    cmp     r7, #6
    bne     fail
    cmp     r9, #8
    bne     fail
    mov     r10, r0
    ldr     r10, [r10]              @ load into its own base (replays must not see the new value)
    cmp     r10, r1
    bne     fail

    @ 6: store of a value computed or loaded just before
    mov     r11, #6
    add     r1, r0, #12
    mov     r2, #0x55
    str     r2, [r1]
    ldr     r3, [r0, #4]
    str     r3, [r1, #4]
    ldr     r4, [r1]
    ldr     r5, [r1, #4]
    cmp     r4, #0x55
    bne     fail
    cmp     r5, #3
    bne     fail

    @ 7: branches right after compares, both directions, and a loop
    mov     r11, #7
    mov     r0, #5
    mov     r1, #0
1:  add     r1, r1, r0
    subs    r0, r0, #1
    bne     1b                      @ backward, taken 4 times
    cmp     r1, #15
    bne     fail
    cmp     r1, #15
    beq     2f                      @ forward, taken
    b       fail
2:  cmp     r1, #16
    beq     fail                    @ forward, not taken
    mov     r2, #0
    cmp     r2, #0
3:  bne     3b                      @ backward, not taken
    bl      sub1
    cmp     r0, #0x77
    bne     fail

    @ 9: block transfers with writeback, back to back, on a per-build base
    mov     r11, #9
    ldr     r0, =buf + CTXOFF
    mov     r5, r0
    mov     r1, #1
    mov     r2, #2
    mov     r3, #3
    stmia   r0!, {r1-r3}
    stmia   r0!, {r1-r3}
    add     r6, r5, #24
    cmp     r0, r6
    bne     fail
    ldmdb   r0!, {r7-r9}
    ldmdb   r0!, {r2-r4}
    cmp     r0, r5
    bne     fail
    add     r7, r7, r8
    add     r7, r7, r9
    cmp     r7, #6
    bne     fail
    stmdb   sp!, {r1-r9}
    ldmia   sp!, {r1-r9}
    ldr     r6, =0x02010000
    cmp     sp, r6
    bne     fail

    @ 8: the same in Thumb
    mov     r11, #8
    adr     r1, thumb_part + 1
    bx      r1
.thumb
.thumb_func
thumb_part:
    movs    r0, #3
    movs    r1, #0
1:  adds    r1, r1, r0
    subs    r0, #1
    bne     1b
    cmp     r1, #6
    bne     tfail
    ldr     r2, =data
    ldr     r3, [r2, #4]
    adds    r3, r3, r3
    lsls    r3, r3, #1
    cmp     r3, #12
    bne     tfail
    mvns    r4, r0                  @ r4 = -1
    adds    r4, r4, #1              @ C = 1
    adcs    r4, r3                  @ 13
    cmp     r4, #13
    bne     tfail
    adr     r1, arm_back
    bx      r1
tfail:
    ldr     r1, =fail
    bx      r1
.align 2
.ltorg
.arm
arm_back:
    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .

sub1:
    mov     r0, #0x77
    bx      lr

fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .

.align 2
data:
    .word   data + 8
    .word   3
    .word   0xFF
    .word   0, 0, 0
.ltorg
buf:
    .space  160
