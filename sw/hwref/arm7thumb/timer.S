// ARM7-only timer-bank discriminator. Code runs in private WRAM, IRQ masked.
// F/1 TM0 is the timestamp anchor. Polls retain last-miss/first-hit bounds;
// no polling or instruction cost is subtracted from the returned raw counts.
.syntax unified
.arch armv4t
.arm
.section .text.at_timer,"ax",%progbits
.balign 32
.global at_timer,at_timer_end
.type at_timer,%function
// r0=IRQ-enabled prescaler control; r1=mode; r2=delay; r3=result
at_timer:
 push {r4-r11,lr}
 mov r4,r3
 mov r5,r0
 mov r6,r1
 mov r7,r2
 ldr r8,.Lio
 mov r0,#0
 strh r0,[r8,#10]
 strh r0,[r8,#14]
 mov r0,#0x60
 str r0,[r8,#0x114] // only clear TM2/TM3 IF bits
 ldr r0,.Lffff
 cmp r6,#0
 subne r0,r0,#15 // running reload and bank: start FFF0, not FFFF
 strh r0,[r8,#8]
 strh r0,[r8,#12]
 cmp r6,#0
 bne 2f
1: // start mode phase delay before enabling
 cmp r7,#0
 beq 2f
 mov r11,r11
 subs r7,r7,#1
 b 1b
2:
 ldrh r0,[r8]
 str r0,[r4,#16]
 str r0,[r4,#48]
 strh r5,[r8,#10]
 ldrh r0,[r8]
 str r0,[r4,#20]
 ldrh r0,[r8,#8]
 str r0,[r4,#32]
 cmp r6,#0
 beq 5f
3: // reload/bank mode: phase delay after enabling TM2
 cmp r7,#0
 beq 4f
 mov r11,r11
 subs r7,r7,#1
 b 3b
4:
 ldr r0,[r8,#0x114]
 str r0,[r4,#44]
 ldrh r0,[r8]
 str r0,[r4,#24]
 str r0,[r4,#56]
 cmp r6,#1
 ldreq r0,.Lffff
 strheq r0,[r8,#8] // enabled low-register write: reload latch only
 strhne r5,[r8,#14] // bank: TM3 starts later, same prescaler
 ldrh r0,[r8]
 str r0,[r4,#28]
5:
 ldrh r0,[r8,#8]
 str r0,[r4,#36]
 ldrh r0,[r8,#8]
 str r0,[r4,#40]
 ldrh r9,[r8] // sample-local bounded timeout, modulo16-bit TM0
 mov r10,#0
 ldr r11,.Llimit
6:
 ldrh r7,[r8]
 ldr r1,[r8,#0x114]
 tst r10,#1
 bne 8f
 tst r1,#0x20
 streq r7,[r4,#48] // last miss timestamp
 beq 8f
 ldrh r0,[r8]
 str r0,[r4,#52] // first hit timestamp
 orr r10,r10,#1
8:
 cmp r6,#2
 orrne r10,r10,#2
 bne 9f
 tst r10,#2
 bne 9f
 tst r1,#0x40
 streq r7,[r4,#56]
 beq 9f
 ldrh r0,[r8]
 str r0,[r4,#60]
 orr r10,r10,#2
9:
 cmp r10,#3
 beq 10f
 ldrh r0,[r8]
 sub r0,r0,r9
 mov r0,r0,lsl#16
 mov r0,r0,lsr#16
 cmp r0,r11
 blo 6b
 mov r0,#1
 str r0,[r4,#76]
10:
 ldr r0,[r8,#0x114]
 str r0,[r4,#64]
 ldrh r0,[r8,#10]
 str r0,[r4,#68]
 ldrh r0,[r8,#14]
 str r0,[r4,#72]
 mov r0,#0
 strh r0,[r8,#10]
 strh r0,[r8,#14]
 ldrh r0,[r8,#8]
 str r0,[r4,#80]
 ldrh r0,[r8,#8]
 str r0,[r4,#84]
 ldrh r0,[r8,#12]
 str r0,[r4,#88]
 ldrh r0,[r8,#12]
 str r0,[r4,#92]
 mov r0,#0x60
 str r0,[r8,#0x114]
 pop {r4-r11,lr}
 bx lr
.balign 4
.Lio: .word 0x04000100
.Lffff: .word 0x0000ffff
.Llimit: .word 32768
at_timer_end:
.size at_timer,.-at_timer
