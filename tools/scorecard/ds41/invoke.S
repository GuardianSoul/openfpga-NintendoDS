// Adapter caller only; ALL77/78/78/79 measured words come from DS41 CSV.
// Saved CPSR was captured before the original memset/call. Use it as a
// controlled seed; do not claim its unobserved NZCV equals DS leaf entry.
.syntax unified
.arm
.text
.global invoke
.type invoke,%function
invoke:
 push {r4-r8,lr}
 mov r8,r0
 ldr r4,=0x04000108
 mov r5,#0
 mov r6,#0x80
 ldr r7,=0x02ff0000
 msr cpsr_fsxc,r8
 mrs r0,cpsr
 str r0,[r7,#20]
 strh r5,[r4,#2]
 strh r5,[r4]
 strh r6,[r4,#2]
 mov r0,r7
 ldr r12,=0x01ff8020
 blx r12
 ldrh r0,[r4,#2]
 str r0,[r7,#24]
 pop {r4-r8,lr}
 bx lr
.size invoke,.-invoke
.ltorg
