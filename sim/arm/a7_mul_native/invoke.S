.syntax unified
.arm
.text
.global native_invoke
.type native_invoke,%function
native_invoke:
 push {r4-r8,lr}
 ldr r6,[sp,#24]
 mov r7,sp
 ldr sp,=0x0380fd10
 str r6,[sp]
 ldr r12,=0x03800850
 adr lr,1f
 bx r12
1:
 mov sp,r7
 pop {r4-r8,lr}
 bx lr
.size native_invoke,.-native_invoke
.pool
