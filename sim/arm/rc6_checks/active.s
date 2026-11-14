.syntax unified
.arm
.global _start
_start:
    mov r0, #0
    mov r1, #3
    mov r2, #1
    mov r3, r1, lsl r2
    cmp r0, #0
    moveq r3, r1, lsr r2
    cmp r3, #1
    movne r0, #1
    mov r4, #0x0f000000
    str r0, [r4]
1:  b 1b
