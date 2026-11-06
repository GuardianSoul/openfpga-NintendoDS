.syntax unified
.arm
.global _start
.equ EXIT,0x0F000000
.equ CTXOFF,0
.include "cp15.inc"
_start:
 CP15_REGIONS
 CP15_ENABLE
 ldr sp,=0x02010000
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

 // Ordinary low-I/O read widths and unaligned ownership, with nonzero payload.
 mov r14,#89
 mov r11,#89
 ldr r12,=0x04000008
 ldr r3,=0xa55a0102
 str r3,[r12]
 ldr r0,[r12]
 cmp r0,r3
 bne fail
 ldrb r0,[r12,#1]
 cmp r0,#1
 bne fail
 ldrh r0,[r12,#2]
 ldr r2,=0xa55a
 cmp r0,r2
 bne fail
 ldrsb r0,[r12,#3]
 mvn r2,#90
 cmp r0,r2
 bne fail
 ldrsh r0,[r12,#2]
 ldr r2,=0xffffa55a
 cmp r0,r2
 bne fail
 ldr r0,[r12,#1]
 ldr r2,=0x02a55a01
 cmp r0,r2
 bne fail
 // A returned load followed immediately by an I/O store/read keeps order.
 ldr r0,[r12]
 str r0,[r12,#4]
 ldr r1,[r12,#4]
 cmp r1,r3
 bne fail

 ldr r2,=EXIT
 mov r1,#0
 str r1,[r2]
 b .
fail:
 ldr r2,=EXIT
 str r11,[r2]
 b .
 .ltorg
 .balign 32
buf:
 .space 160
