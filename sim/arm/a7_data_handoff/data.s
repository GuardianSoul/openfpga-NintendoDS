.syntax unified
.arm
.section .text
.global _start, patch_ptr, target, compare_end
_start:
 mov r2,#42
 ldr sp,stack_ptr
 adr lr,target
 adr r4,thumb_data
 orr r4,r4,#1
 bx r4
target:
 cmp r0,#15
 bne failed
 ldr r3,done_ptr
 mov r7,#0x5a
compare_end:
 str r7,[r3]
dead: b dead
failed:
 ldr r3,done_ptr
 mov r7,#0x44
 str r7,[r3]
 b dead
.thumb
.balign 2
thumb_data:
 sub sp,#16
 movs r1,#67
 str r1,[sp,#0]
 ldr r0,[sp,#0]
 cmp r0,r1
 bne thumb_fail
 ldr r4,sound_ptr
 str r1,[r4,#0]
 strh r1,[r4,#2]
 ldr r0,[r4,#4]
 ldr r7,expected_word
 cmp r0,r7
 bne thumb_fail
 ldrh r0,[r4,#4]
 ldr r7,expected_half
 cmp r0,r7
 bne thumb_fail
 ldrb r0,[r4,#7]
 cmp r0,#0xf3
 bne thumb_fail
 movs r3,#7
 ldrsb r0,[r4,r3]
 movs r7,#13
 negs r7,r7
 cmp r0,r7
 bne thumb_fail
 ldr r6,scratch_ptr
 stmia r6!,{r1}
 subs r6,#4
 ldr r0,[r6,#0]
 cmp r0,r1
 bne thumb_fail
 add sp,#16
 movs r0,#15
 bx lr
thumb_fail:
 movs r0,#0
 bx lr
.arm
.balign 4
patch_ptr:.word target
done_ptr:.word 0x040003f0
stack_ptr:.word 0x03800400
sound_ptr:.word 0x04000400
expected_word:.word 0xf381a567
expected_half:.word 0x0000a567
scratch_ptr:.word 0x03800100
