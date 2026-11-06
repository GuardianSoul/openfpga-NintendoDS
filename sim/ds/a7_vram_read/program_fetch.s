.syntax unified
.arm
.global _start,body_begin,done,fail
_start:
 msr cpsr_c,#0xdf
 ldr sp,=0x0380ff00
 ldr r0,=0x06000800
 ldr r1,=0xe3a0605a
 str r1,[r0]
 ldr r1,=0xe12fff1e
 str r1,[r0,#4]
 ldr r0,=0x06000840
 ldr r1,=0x47702636
 str r1,[r0]
 ldr r4,[r0]
 cmp r4,r1
 bne fail
 ldr r0,=0x06000100
 ldr r1,=0x89abc000
 mov r2,#32
body_begin:
 ldr r12,=0x06000800
 adr lr,arm_return
 bx r12
arm_return:
 cmp r6,#0x5a
 bne fail
 ldr r12,=0x06000841
 adr lr,thumb_return
 bx r12
thumb_return:
 cmp r6,#0x36
 bne fail
 // Read before any store: verify actual data from the pinned VRAM endpoint.
 mov r8,r8
 ldr r1,=0xd34a8000
0:
 ldr r4,[r0],#4
 cmp r4,r1
 bne fail
 add r1,r1,#1
 subs r2,r2,#1
 bne 0b
 ldr r0,=0x06000100
 ldrb r4,[r0,#1]
 cmp r4,#0x80
 bne fail
 ldrh r4,[r0,#2]
 ldr r5,=0xd34a
 cmp r4,r5
 bne fail
 ldr r4,[r0,#1]
 ldr r5,=0x00d34a80
 cmp r4,r5
 bne fail
 ldr r1,=0x89abc000
 mov r2,#32
 mov r8,r8
1:
 str r1,[r0],#4
 add r1,r1,#1
 subs r2,r2,#1
 bne 1b
 // A MAIN data read cannot pass the posted VRAM stores in P7.
 ldr r3,=0x02001000
 ldr r4,[r3]
 ldr r5,=0x11578bdf
 cmp r4,r5
 bne fail
 ldr r0,=0x06000100
 ldr r1,=0x89abc000
 mov r2,#32
2:
 ldr r4,[r0],#4
 cmp r4,r1
 bne fail
 add r1,r1,#1
 subs r2,r2,#1
 bne 2b
 // Narrow writes remain on the original shared path.
 ldr r0,=0x06000100
 ldr r1,=0x2468
 strh r1,[r0]
 ldr r1,=0x1357
 strh r1,[r0,#2]
 ldr r4,[r0]
 ldr r5,=0x13572468
 cmp r4,r5
 bne fail
done:
 b done
fail:
 b fail
.ltorg
