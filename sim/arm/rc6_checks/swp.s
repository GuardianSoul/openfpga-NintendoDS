.syntax unified
.arm
.global _start
_start:
    mov r0, #7
    ldr r5, =0x02010000
    mov r6, #0x55
    str r6, [r5]
    mov r7, #0xaa
    swp r3, r7, [r5]
    ldr r4, [r5]
    cmp r3, #0x55
    bne fail
    cmp r4, #0xaa
    bne fail
    mov r0, #0
    b quit
fail:
    mov r0, #1
quit:
    mov r1, #0x0f000000
    str r0, [r1]
1:  b 1b
.ltorg
