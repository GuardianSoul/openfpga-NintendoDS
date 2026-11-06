.syntax unified
.arm
.global _start
.equ EXIT,0x0F000000
.include "cp15.inc"
_start:
 CP15_REGIONS
 CP15_ENABLE
 ldr sp,=0x0B003E00
 // Install a precise-abort return in the existing low ITCM vector.
 mov r1,#0x10
 ldr r0,=0xe51ff004
 str r0,[r1]
 ldr r0,=abort_handler
 str r0,[r1,#4]
 // Negative opcode controls: uncached scalar, LDRD and SWP must be untagged.
 mov r14,#90
 ldr r12,=0x02410000
 ldr r0,[r12]
 ldr r10,=0x13240000
 cmp r0,r10
 bne fail
 mov r14,#91
 ldrd r0,r1,[r12]
 cmp r0,r10
 bne fail
 add r10,r10,#1
 cmp r1,r10
 bne fail
 mov r14,#92
 ldr r2,=0x13240000
 swp r0,r2,[r12]
 cmp r0,r2
 bne fail
 // A cached LDM may fill its line, but none of those bus words is a demand tag.
 mov r14,#93
 ldr r12,=0x02010100
 ldmia r12,{r0-r7}
 ldr r10,=0x13240040
 cmp r0,r10
 bne fail
 add r10,r10,#7
 cmp r7,r10
 bne fail
 // Thumb LDMIA and POP use the same permitted uncached per-word class.
 mov r14,#94
 ldr r0,=thumb_cases+1
 bx r0
.thumb
thumb_cases:
 ldr r4,=0x024100c0
 ldmia r4!,{r0-r3}
 ldr r6,=0x13240030
 cmp r0,r6
 bne thumb_fail
 adds r6,#3
 cmp r3,r6
 bne thumb_fail
 ldr r0,=0x024100d0
 mov sp,r0
 pop {r0-r3}
 adds r6,#1
 cmp r0,r6
 bne thumb_fail
 adds r6,#3
 cmp r3,r6
 bne thumb_fail
 ldr r0,=thumb_return
 bx r0
thumb_fail:
 ldr r0,=fail
 bx r0
.ltorg
.align 2
.arm
thumb_return:
 ldr sp,=0x0B003E00
 // All four ARM addressing modes, with writeback.
 mov r14,#101
 ldr r12,=0x2410040
 ldmia r12!,{r0-r7}
 ldr r10,=0x13240010
 cmp r0,r10
 bne fail
 ldr r10,=0x13240011
 cmp r1,r10
 bne fail
 ldr r10,=0x13240012
 cmp r2,r10
 bne fail
 ldr r10,=0x13240013
 cmp r3,r10
 bne fail
 ldr r10,=0x13240014
 cmp r4,r10
 bne fail
 ldr r10,=0x13240015
 cmp r5,r10
 bne fail
 ldr r10,=0x13240016
 cmp r6,r10
 bne fail
 ldr r10,=0x13240017
 cmp r7,r10
 bne fail
 ldr r10,=0x2410060
 cmp r12,r10
 bne fail
 // All four ARM addressing modes, with writeback.
 mov r14,#102
 ldr r12,=0x241003c
 ldmib r12!,{r0-r7}
 ldr r10,=0x13240010
 cmp r0,r10
 bne fail
 ldr r10,=0x13240011
 cmp r1,r10
 bne fail
 ldr r10,=0x13240012
 cmp r2,r10
 bne fail
 ldr r10,=0x13240013
 cmp r3,r10
 bne fail
 ldr r10,=0x13240014
 cmp r4,r10
 bne fail
 ldr r10,=0x13240015
 cmp r5,r10
 bne fail
 ldr r10,=0x13240016
 cmp r6,r10
 bne fail
 ldr r10,=0x13240017
 cmp r7,r10
 bne fail
 ldr r10,=0x241005c
 cmp r12,r10
 bne fail
 // All four ARM addressing modes, with writeback.
 mov r14,#103
 ldr r12,=0x241005c
 ldmda r12!,{r0-r7}
 ldr r10,=0x13240010
 cmp r0,r10
 bne fail
 ldr r10,=0x13240011
 cmp r1,r10
 bne fail
 ldr r10,=0x13240012
 cmp r2,r10
 bne fail
 ldr r10,=0x13240013
 cmp r3,r10
 bne fail
 ldr r10,=0x13240014
 cmp r4,r10
 bne fail
 ldr r10,=0x13240015
 cmp r5,r10
 bne fail
 ldr r10,=0x13240016
 cmp r6,r10
 bne fail
 ldr r10,=0x13240017
 cmp r7,r10
 bne fail
 ldr r10,=0x241003c
 cmp r12,r10
 bne fail
 // All four ARM addressing modes, with writeback.
 mov r14,#104
 ldr r12,=0x2410060
 ldmdb r12!,{r0-r7}
 ldr r10,=0x13240010
 cmp r0,r10
 bne fail
 ldr r10,=0x13240011
 cmp r1,r10
 bne fail
 ldr r10,=0x13240012
 cmp r2,r10
 bne fail
 ldr r10,=0x13240013
 cmp r3,r10
 bne fail
 ldr r10,=0x13240014
 cmp r4,r10
 bne fail
 ldr r10,=0x13240015
 cmp r5,r10
 bne fail
 ldr r10,=0x13240016
 cmp r6,r10
 bne fail
 ldr r10,=0x13240017
 cmp r7,r10
 bne fail
 ldr r10,=0x2410040
 cmp r12,r10
 bne fail
 // Sparse list across a32-byte boundary.
 mov r14,#105
 ldr r12,=0x0241007c
 ldmia r12!,{r0,r2,r5,r7,r8,r9,r10,r11}
 ldr r3,=0x1324001f
 cmp r0,r3
 bne fail
 ldr r3,=0x13240020
 cmp r2,r3
 bne fail
 ldr r3,=0x13240021
 cmp r5,r3
 bne fail
 ldr r3,=0x13240022
 cmp r7,r3
 bne fail
 ldr r3,=0x13240023
 cmp r8,r3
 bne fail
 ldr r3,=0x13240024
 cmp r9,r3
 bne fail
 ldr r3,=0x13240025
 cmp r10,r3
 bne fail
 ldr r3,=0x13240026
 cmp r11,r3
 bne fail
 ldr r3,=0x241009c
 cmp r12,r3
 bne fail
 // ARMv5 base-in-list low and high cases keep their existing semantics.
 mov r14,#106
 ldr r4,=0x024100a0
 .word 0xe8b40030 // ldmia r4!,{r4,r5}: ARMv5 base-in-list case
 ldr r10,=0x24100a8
 cmp r4,r10
 bne fail
 ldr r10,=0x13240029
 cmp r5,r10
 bne fail
 mov r14,#107
 ldr r5,=0x024100a0
 .word 0xe8b50030 // ldmia r5!,{r4,r5}: ARMv5 base-in-list case
 ldr r10,=0x13240028
 cmp r4,r10
 bne fail
 ldr r10,=0x13240029
 cmp r5,r10
 bne fail
 // Failed condition must not issue a data read.
 mov r14,#108
 ldr r12,=0x02410000
 cmp r0,r0
 ldmiane r12!,{r0-r7}
 ldr r10,=0x2410000
 cmp r12,r10
 bne fail
 // Pending word writes drain before the demanded LDM reads.
 mov r14,#109
 ldr r12,=0x02410000
 ldr r3,=0x13579bdf
 str r3,[r12]
 ldmia r12,{r0-r7}
 ldr r10,=0x13579bdf
 cmp r0,r10
 bne fail
 ldr r10,=0x13240001
 cmp r1,r10
 bne fail
 ldr r10,=0x13240002
 cmp r2,r10
 bne fail
 ldr r10,=0x13240003
 cmp r3,r10
 bne fail
 ldr r10,=0x13240004
 cmp r4,r10
 bne fail
 ldr r10,=0x13240005
 cmp r5,r10
 bne fail
 ldr r10,=0x13240006
 cmp r6,r10
 bne fail
 ldr r10,=0x13240007
 cmp r7,r10
 bne fail
 ldr r3,=0x13240000
 str r3,[r12]
 // A PC-load return follows the last granted word, with no extra read.
 mov r14,#110
 ldr r12,=0x02410200
 ldr r0,=0x24681357
 str r0,[r12]
 ldr r0,=pc_target
 str r0,[r12,#4]
 mov r0,#0
 ldmia r12!,{r0,pc}
 b fail
pc_target:
 ldr r10,=0x24681357
 cmp r0,r10
 bne fail
 ldr r10,=0x2410208
 cmp r12,r10
 bne fail
 // Multiply pipeline and younger ALU dependencies survive the wait.
 mov r14,#111
 ldr r12,=0x02410000
 mov r0,#4
 mov r1,#8
 mul r10,r0,r1
 ldmia r12,{r0-r7}
 cmp r10,#32
 bne fail
 adds r8,r7,#1
 ldr r10,=0x13240008
 cmp r8,r10
 bne fail
 // Non-MAIN MMIO loads retain the legacy individually ordered path.
 mov r14,#112
 ldr r12,=0x04004000
 ldmia r12,{r0,r1}
 cmp r0,#0
 bne fail
 cmp r1,#0
 bne fail
 // Third word faults: only two grants, original partial state and base.
 mov r14,#113
 ldr r0,=0x02411017
 mcr p15,0,r0,c6,c6,0
 mov r11,#0
 ldr r12,=0x02410ff8
 ldmia r12!,{r0-r7}
 cmp r11,#1
 bne fail
 ldr r10,=0x132403fe
 cmp r0,r10
 bne fail
 ldr r10,=0x132403ff
 cmp r1,r10
 bne fail
 // A fresh first follows an aborted group whose last DATA never issued.
 ldr r12,=0x02410300
 ldmia r12!,{r2,r3}
 ldr r12,=0x02410310
 ldmia r12!,{r2}
 ldr r12,=0x02410320
 ldmia r12!,{r2-r5}
 // Repeated address is a new singleton, not a continuation/address heuristic.
 ldr r12,=0x02410340
 ldmia r12!,{r2}
 ldr r12,=0x02410340
 ldmia r12!,{r2}
 // ARMv5 empty list has no DATA transfer.
 ldr r12,=0x02410380
 .word 0xe8bc0000
 // Original count16; final DATA loads PC after an independent base writeback.
 ldr r12,=0x02410400
 ldr r0,=full_list_target
 str r0,[r12,#60]
 .word 0xe8bcffff
 b fail
full_list_target:
 ldr sp,=0x0B003e00
compare_end:
 ldr r0,=EXIT
 mov r1,#0
 str r1,[r0]
 b .
abort_handler:
 mov r11,#1
 subs pc,lr,#4
fail:
 ldr r0,=EXIT
 str r14,[r0]
 b .
.ltorg
