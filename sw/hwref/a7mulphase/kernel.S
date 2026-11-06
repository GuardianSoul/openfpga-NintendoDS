.syntax unified
.arm
.section .text.mp_mul,"ax",%progbits
.balign 32
.global mp_mul,mp_mul_body,mp_mul_end
.type mp_mul,%function
mp_mul:
 mov r1,#3
mp_mul_body:
 .rept 64
 mul r3,r1,r2
 .endr
 subs r0,r0,#1
 bne mp_mul_body
 bx lr
mp_mul_end:
.size mp_mul,.-mp_mul

// AAPCS wrapper. All observation stores are private WRAM and fixed per call;
// no store is inserted into the 64-MUL body or its SUBS/BNE loop.
.section .text.mp_invoke,"ax",%progbits
.balign 4
.global mp_invoke,mp_return
.type mp_invoke,%function
mp_invoke:
 push {r4-r11,r12,lr}
 mov r4,r0
 mov r5,r3
 mov r0,r1
 mov r1,#3
 adr lr,mp_return
 stmia r5,{r0-r12}
 // Capture the base explicitly; do not depend on a base-in-list STM value.
 str r5,[r5,#20]
 str sp,[r5,#52]
 str lr,[r5,#56]
 mrs r12,cpsr
 str r12,[r5,#60]
 ldr r12,[r5,#48]
 bx r4
mp_return:
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
.size mp_invoke,.-mp_invoke
