// Simulation-only endpoint, entered by original buf_write after all timing rows.
// All timed code, Calico startup and the ARM9 mailbox wait stay in place.
.syntax unified
.arm
.section .text,"ax"
.global capture_start,adapter_done
capture_start:
 mov r8,r0
 mov r9,r1
 mrs r10,cpsr
 orr r2,r10,#0xc0
 msr cpsr_c,r2
 ldr r4,=0x023d0000
 ldr r0,=0x30335441
 str r0,[r4,#0]
 mov r0,#1
 str r0,[r4,#4]
 mov r0,#0
 str r0,[r4,#8]
 ldr r5,[r8]
 ldr r6,[r8,#4]
 cmp r6,#4096
 movhi r6,#0
 movhi r0,#1
 cmp r5,#0
 moveq r6,#0
 moveq r0,#2
 str r0,[r4,#8]
 str r6,[r4,#12]
 str r5,[r4,#16]
 str r8,[r4,#20]
 str r9,[r4,#24]
 str r10,[r4,#28]
 str sp,[r4,#32]
 mrc p15,0,r0,c1,c0,0
 str r0,[r4,#36]
 mrc p15,0,r0,c2,c0,0
 str r0,[r4,#40]
 mrc p15,0,r0,c2,c0,1
 str r0,[r4,#44]
 mrc p15,0,r0,c3,c0,0
 str r0,[r4,#48]
 mrc p15,0,r0,c5,c0,2
 str r0,[r4,#52]
 mrc p15,0,r0,c5,c0,3
 str r0,[r4,#56]
 mrc p15,0,r0,c9,c1,0
 str r0,[r4,#60]
 mrc p15,0,r0,c9,c1,1
 str r0,[r4,#64]
.macro REGION n
 mrc p15,0,r0,c6,c\n,0
 str r0,[r4,#(68+4*\n)]
.endm
 REGION 0
 REGION 1
 REGION 2
 REGION 3
 REGION 4
 REGION 5
 REGION 6
 REGION 7
 ldr r1,=0x04000204
 ldrh r0,[r1]
 str r0,[r4,#100]
 ldr r1,=0x04000240
 ldr r0,[r1]
 str r0,[r4,#104]
 ldr r0,[r1,#4]
 str r0,[r4,#108]
 ldr r1,=0x04000304
 ldrh r0,[r1]
 str r0,[r4,#112]
 ldr r1,=0x04000000
 ldr r0,[r1]
 str r0,[r4,#116]
 ldr r1,=0x04001000
 ldr r0,[r1]
 str r0,[r4,#120]
 ldr r1,=0x04000208
 ldr r0,[r1]
 str r0,[r4,#124]
 ldr r0,[r1,#8]
 str r0,[r4,#128]
 add r7,r4,#256
 mov r0,#0
1:
 cmp r0,r6
 bhs 2f
 ldrb r1,[r5,r0]
 strb r1,[r7,r0]
 add r0,r0,#1
 b 1b
2:
 ldr r3,=0x01ff85c0 // original armDCacheFlushAll in retained ITCM
 blx r3
 mov r0,#0
 mcr p15,0,r0,c7,c10,4
adapter_done:
 b adapter_done
.ltorg
