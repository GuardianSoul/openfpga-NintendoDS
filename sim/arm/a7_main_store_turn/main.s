.syntax unified
.arm
.section .text
.global _start, loop_count, finished, failed, irq_handler
_start:
 mov r12,#0
 mrs r0,cpsr
 bic r0,r0,#0x80
 msr cpsr_c,r0
 ldr sp,stack
 ldr r8,main_base
 mov r1,#17
 mov r2,#34
 mov r3,#51
 mov r4,#68
loop_count:
 mov r10,#4
loop:
 mov r0,r8
 stmia r0!,{r1-r4}
 ldmdb r0!,{r5-r7,r11}
 cmp r5,r1
 bne failed
 cmp r6,r2
 bne failed
 cmp r7,r3
 bne failed
 cmp r11,r4
 bne failed
 add r1,r1,#1
 add r2,r2,#1
 add r3,r3,#1
 add r4,r4,#1
 subs r10,r10,#1
 bne loop
 strb r2,[r8,#1]
 strh r3,[r8,#2]
 ldrb r5,[r8,#1]
 cmp r5,r2
 bne failed
 ldrh r5,[r8,#2]
 cmp r5,r3
 bne failed
 swp r5,r4,[r8]
 ldr r6,[r8]
 cmp r6,r4
 bne failed
 ldr r0,mmio
 str r6,[r0]
 ldr r7,[r0]
finished:
 b finished
failed:
 b failed
.balign 4
stack:.word 0x03809000
main_base:.word 0x02010200
mmio:.word 0x04000408
irq_handler:
 add r12,r12,#1
 subs pc,lr,#4
