.syntax unified
.arm
.global _start,compare_end
.equ EXIT,0x0f000000
.include "cp15.inc"
_start:
 CP15_REGIONS
 CP15_ENABLE
 ldr sp,=0x0b003e00
 mov r1,#0x10
 ldr r0,=0xe51ff004
 str r0,[r1]
 ldr r0,=handler
 str r0,[r1,#4]
 // A refused self-base load must read its old base again, not a younger value.
 ldr r12,=0x04000008
 ldr r3,=0x04000020
 str r3,[r12]
 mov r4,r12
 ldr r4,[r4]
 cmp r4,r3
 bne fail
 // Immediate base production and returned-data use keep the ordinary RF bypass.
 mov r4,r12
 ldr r5,[r4]
 add r6,r5,#1
 add r7,r3,#1
 cmp r6,r7
 bne fail
 ldr r2,=0x01020304
 str r2,[r12,#4]
 ldr r5,[r12]
 ldr r6,[r12,#4]
 cmp r5,r3
 bne fail
 cmp r6,r2
 bne fail
 // Conditional/Thumb/post-index forms remain on the original retry path.
 cmp r3,r3
 ldrne r5,[r12,#4]
 mov r4,r12
 ldr r6,[r4],#4
 cmp r6,r3
 bne fail
 add r7,r12,#4
 cmp r4,r7
 bne fail
 adr r0,thumb+1
 bx r0
.thumb
thumb:
 mov r4,r12
 ldr r6,[r4]
 cmp r6,r3
 bne thumb_fail
 ldr r0,=arm_return
 bx r0
thumb_fail:
 ldr r0,=fail
 bx r0
.ltorg
.align 2
.arm
arm_return:
 mov r0,#0
 str r0,[r12,#4]
 // Region 6 denies this exact I/O word. No pending read may bypass the abort.
 ldr r0,=0x04000017
 mcr p15,0,r0,c6,c6,0
 mov r11,#0
 ldr r8,=0x76543210
 ldr r8,[r12]
 str r3,[r12,#4] // skipped by the abort handler, and must never reach the bus
after_abort:
 cmp r11,#1
 bne fail
 ldr r0,=0x76543210
 cmp r8,r0
 bne fail
 mov r0,#0
 mcr p15,0,r0,c6,c6,0
 ldr r0,[r12,#4]
 cmp r0,#0
 bne fail
compare_end:
 ldr r0,=EXIT
 mov r1,#0
 str r1,[r0]
 b .
handler:
 mov r11,#1
 subs pc,lr,#0
fail:
 ldr r0,=EXIT
 mov r1,#117
 str r1,[r0]
 b .
.ltorg
