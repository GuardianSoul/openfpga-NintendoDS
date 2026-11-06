.syntax unified
.arm
.text
.global native_invoke
.type native_invoke,%function
native_invoke:
 push {r4-r8,lr}
 mov r4,sp
 mov r12,r0
 mov r0,r1
 mov r1,r2
 mov r2,r3
 ldr sp,=0x0380fd88
 ldr r3,=native_sp_before
 str sp,[r3]
 ldr r3,=native_cpsr
 mrs r5,cpsr
 str r5,[r3]
 adr lr,1f
 bx r12
1:
 ldr r3,=native_sp_after
 str sp,[r3]
 mov sp,r4
 pop {r4-r8,lr}
 bx lr
.size native_invoke,.-native_invoke
.pool
