.syntax unified
.arm
.global _start,body_begin,body_end,loop_count,data_address,done,fail
_start:
 msr cpsr_c,#0xdf
 ldr sp,=0x0380ff00
 ldr r0,data_address
 mov r8,#0
loop_count:
 mov r10,#4
body_begin:
 ldmia r0,{r1-r4}
 add r8,r8,r1
 eor r8,r8,r2
 add r8,r8,r3
 eor r8,r8,r4
 subs r10,r10,#1
 bne body_begin
body_end:
 // A real write must invalidate the prior hit; P7 fences its following read.
 ldr r5,=0x24681357
 str r5,[r0]
 ldr r6,[r0]
 cmp r5,r6
 bne fail
 // Narrow reads retain the original scalar service.
 ldrh r6,[r0,#2]
 ldr r5,=0x2468
 cmp r5,r6
 bne fail
 ldrb r6,[r0,#1]
 cmp r6,#0x13
 bne fail
 adr r7,thumb_part
 orr r7,r7,#1
 adr lr,thumb_return
 bx r7
thumb_return:
done:
 b done
fail:
 b fail
.thumb
.thumb_func
thumb_part:
 ldmia r0!,{r1-r4}
 subs r0,#16
 bx lr
.arm
.balign 4
data_address:.word 0x02010000
.ltorg
