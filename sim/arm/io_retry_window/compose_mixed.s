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
 ldr r12,=0x04000108
 ldr r0,=0x1234
 strh r0,[r12]
 mov r1,#0x84 // enable/cascade; timer1 is disabled, so the live count stays at reload
 strh r1,[r12,#2]
 // Seed real PSRAM using actual CPU writes; replay retention must observe poison.
 ldr r8,=0x02410000
 str r12,[r8]
 ldr r0,=0x11223344
 str r0,[r8,#4]
 ldr r0,=0x55667788
 str r0,[r8,#8]
 ldr r0,=0x99aabbcc
 str r0,[r8,#12]
 mov r9,#16
loop:
 ldr r8,=0x02410000
 ldmia r8!,{r4-r7}
 // A real LDM destination supplies the base of the refused ordinary I/O read.
 ldrh r0,[r4]
 // This younger LDM must be flushed/reissued with no extra physical word.
 ldmia r8!,{r1-r3}
 ldr r10,=0x1234
 cmp r0,r10
 bne fail
 ldr r10,=0x0241001c
 cmp r8,r10
 bne fail
 ldr r10,=0x11223344
 cmp r5,r10
 bne fail
 // Returned I/O data precedes the ordered MAIN store and subsequent cache reuse.
 str r0,[r8,#-12]
 strh r0,[r12]
 subs r9,r9,#1
 bne loop
 // Precise I/O abort must leave both its destination and younger LDM base intact.
 ldr r0,=0x04000017
 mcr p15,0,r0,c6,c6,0
 mov r11,#0
 ldr r8,=0x76543210
 ldr r10,=0x02410000
 ldr r8,[r12]
 ldmia r10!,{r4-r7}
 cmp r11,#1
 bne fail
 ldr r0,=0x76543210
 cmp r8,r0
 bne fail
 ldr r0,=0x02410000
 cmp r10,r0
 bne fail
 mov r0,#0
 mcr p15,0,r0,c6,c6,0
 ldrh r0,[r12]
 ldr r1,=0x1234
 cmp r0,r1
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
 mov r1,#118
 str r1,[r0]
 b .
.ltorg
