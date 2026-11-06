.syntax unified
.arm
.global _start
.include "cp15.inc"
_start:
 CP15_REGIONS
 CP15_ENABLE
 mov r0,#0x86
 mcr p15,0,r0,c3,c0,0   // uncached region2 C0B1, ordinary MAIN keeps C1B1
 ldr r1,=kernel
 ldr r2,=kernel_end
 mov r3,#0x1000
copy:
 ldr r0,[r1],#4
 str r0,[r3],#4
 cmp r1,r2
 blo copy
 mov r10,#0
 mov r11,#12
round:
 ldr r1,=0x02410000
 mov r0,#0
 mov r12,#0x1000
 blx r12
 // Change future stores to C0B0 while older buffered words still drain.
 mov r0,#0x82
 mcr p15,0,r0,c3,c0,0
 ldr r4,=0x04000108
 ldr r3,=0x37a1
 strh r3,[r4,#2]
 ldrh r2,[r4,#2]
 cmp r2,r3
 bne fail
 mov r0,#0
 mcr p15,0,r0,c7,c10,4
 ldr r1,=0x02410000
 mov r3,#0
check:
 ldr r2,[r1],#4
 cmp r2,r3
 bne fail
 add r3,r3,#1
 cmp r3,#128
 bne check
 // Partial descriptor payload/BE is not inferred from the write address.
 ldr r1,=0x02410210
 ldr r0,=0x35a6e7c8
 str r0,[r1]
 mov r0,#0x19
 strb r0,[r1,#1]
 ldr r0,=0x7d42
 strh r0,[r1,#2]
 ldr r2,[r1]
 ldr r3,=0x7d4219c8
 cmp r2,r3
 bne fail
 mov r0,#0x86
 mcr p15,0,r0,c3,c0,0
 add r10,r10,#1
 cmp r10,r11
 bne round
compare_end:
 mov r0,#0
 ldr r1,=0x0f000000
 str r0,[r1]
 b .
fail:
 mov r0,#1
 ldr r1,=0x0f000000
 str r0,[r1]
 b .
.align 2
kernel:
 .rept 128
 str r0,[r1],#4
 add r0,r0,#1
 .endr
 bx lr
kernel_end:
.ltorg
