// Private WRAM, IRQ masked. All timed stores go to private WRAM too.
.syntax unified
.arch armv4t
.arm
.section .text.tp_timer,"ax",%progbits
.balign 32
.global tp_timer,tp_timer_end,tp_joint_read
.type tp_timer,%function
// r0=private-WRAM rows, r1=MAIN result header (outside observation windows)
tp_timer:
 push {r4-r11,lr}
 mov r8,r0
 mov r7,r1
 ldr r9,.Lio
 add r10,r9,#0x114
 mov r0,#0
 strh r0,[r9,#2]
 strh r0,[r9,#6]
 strh r0,[r9,#10]
 strh r0,[r9,#14]
 strh r0,[r9,#8]
 strh r0,[r9,#12]
 mov r0,#0x84
 strh r0,[r9,#14]
 mov r0,#0x80
 strh r0,[r9,#10]
 ldr r0,.Lffff
 strh r0,[r9]
 strh r0,[r9,#4]
 mov r1,#0xc1
 ldrh r0,[r9,#8]
 str r0,[r7,#100]
 strh r1,[r9,#2]
 ldrh r0,[r9,#8]
 str r0,[r7,#104]
 ldrh r0,[r9,#8]
 str r0,[r7,#108]
 strh r1,[r9,#6]
 ldrh r0,[r9,#8]
 str r0,[r7,#112]
 ldrh r1,[r9,#8]
 str r1,[r7,#116]
 mov r6,#4096
1:
 ldrh r0,[r9,#8]
 sub r0,r0,r1
 mov r0,r0,lsl#16
 mov r0,r0,lsr#16
 cmp r0,#512
 bhs 4f
 subs r6,r6,#1
 bne 1b
 mov r0,#8
 str r0,[r7,#8]
 pop {r4-r11,lr}
 bx lr
4:
 ldrh r0,[r9,#8]
 str r0,[r7,#120]
 mov r11,#0x18
 mov r12,#512
2:
 // Fixed instruction cadence avoids the sparse triangular residues from
 // a varying loop delay. Coverage is proved from returned anchors, never
 // from an assumed ARM instruction price.
 mov r0,r0
 ldrh r5,[r9,#12]
 ldrh r0,[r9,#8]
 str r11,[r10]       // one W1C write clears both sticky overflow flags
 ldrh r1,[r9,#8]
 ldrh r2,[r9,#8]
tp_joint_read:
 ldr r3,[r10]        // one 32-bit word samples both banks at the same time
 ldrh r4,[r9,#8]
 ldrh r6,[r9,#12]
 ldr r7,.Lguard
 stmia r8!,{r0-r7}   // no stores between any timestamp and its IF operation
 subs r12,r12,#1
 bne 2b
 mov r0,#0
 strh r0,[r9,#2]
 strh r0,[r9,#6]
 str r11,[r10]
 pop {r4-r11,lr}
 bx lr
.balign 4
.Lio: .word 0x04000100
.Lffff: .word 0x0000ffff
.Lguard: .word 0x5aa55aa5
tp_timer_end:
.size tp_timer,.-tp_timer
