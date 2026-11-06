.syntax unified
.arm
.section .text.mm_mul,"ax",%progbits
.balign 32
.global mm_mul,mm_mul_body,mm_mul_end
.type mm_mul,%function
mm_mul:
 mov r1,#3
mm_mul_body:
 .rept 32
 mul r3,r1,r2
 mul r3,r1,r6
 .endr
 subs r0,r0,#1
 bne mm_mul_body
 bx lr
mm_mul_end:
.size mm_mul,.-mm_mul

// AAPCS wrapper. All observation stores are private WRAM and fixed per call;
// no store is inserted into the 64-MUL body or its SUBS/BNE loop.
.section .text.mm_invoke,"ax",%progbits
.balign 4
.global mm_invoke,mm_return
.type mm_invoke,%function
mm_invoke:
 push {r4-r11,r12,lr}
 mov r4,r0
 mov r5,r3
 mov r0,r1
 mov r1,#3
 ldr r6,[sp,#40] // fifth AAPCS argument, above the ten saved registers
 adr lr,mm_return
 stmia r5,{r0-r12}
 // Capture the base explicitly; do not depend on a base-in-list STM value.
 str r5,[r5,#20]
 str sp,[r5,#52]
 str lr,[r5,#56]
 mrs r12,cpsr
 str r12,[r5,#60]
 ldr r12,[r5,#48]
 bx r4
mm_return:
 str r12,[r5,#112]
 add r12,r5,#64
 stmia r12,{r0-r11}
 str sp,[r5,#116]
 str lr,[r5,#120]
 mrs r12,cpsr
 str r12,[r5,#124]
 mov r0,r3
 pop {r4-r11,r12,lr}
 bx lr
.size mm_invoke,.-mm_invoke
