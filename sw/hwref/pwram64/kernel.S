.syntax unified
.cpu arm7tdmi
.arm
.text
.balign 32
.global pw_chain,pw_chase,pw_chain_end
.type pw_chase,%function
pw_chain:
pw_chase:
 mov r3,#0
1: ldr r0,[r0]
 eor r3,r0,r3,ror #1
 subs r1,r1,#1
 bne 1b
 str r0,[r2]
 mov r0,r3
 bx lr
pw_chain_end:
.balign 32
.global pw_store,pw_stores,pw_store_end
.type pw_stores,%function
pw_store:
pw_stores:
 push {r4,lr}
 mov r2,#0x03800000
 ldr r4,=0x12341234
 cmp r1,#0
 beq 5f
 cmp r0,#16
 blo 3f
1:
 str r4,[r2,#0]
 str r4,[r2,#32]
 str r4,[r2,#64]
 str r4,[r2,#96]
 str r4,[r2,#128]
 str r4,[r2,#160]
 str r4,[r2,#192]
 str r4,[r2,#224]
 str r4,[r2,#256]
 str r4,[r2,#288]
 str r4,[r2,#320]
 str r4,[r2,#352]
 str r4,[r2,#384]
 str r4,[r2,#416]
 str r4,[r2,#448]
 str r4,[r2,#480]
 add r2,r2,#512
 tst r2,#0x10000
 subne r2,r2,#0x10000
 addne r2,r2,#4
 subs r0,r0,#16
 bne 1b
 b 4f
3: cmp r0,#9
 str r4,[r2,#0]
 str r4,[r2,#32]
 str r4,[r2,#64]
 str r4,[r2,#96]
 str r4,[r2,#128]
 str r4,[r2,#160]
 str r4,[r2,#192]
 str r4,[r2,#224]
 streq r4,[r2,#256]
 add r2,r2,r0,lsl #5
 b 4f
5:
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 str r4,[r2]
 subs r0,r0,#16
 bne 5b
4: sub r0,r2,#0x03800000
 pop {r4,lr}
 bx lr
 .ltorg
pw_store_end:
.balign 32
.global pw_read,pw_reads,pw_read_end
.type pw_reads,%function
pw_read:
pw_reads:
 push {r4,lr}
 mov r2,#0x03800000
 mov r4,#0
1: cmp r1,#0
 ldreq ip,[r2]
 ldrne ip,[r2],#32
 eor r4,ip,r4,ror #1
 tst r2,#0x10000
 subne r2,r2,#0x10000
 addne r2,r2,#4
 subs r0,r0,#1
 bne 1b
 mov r0,r4
 pop {r4,lr}
 bx lr
pw_read_end:
.balign 32
.global pw_switch,pw_switch_end
.type pw_switch,%function
pw_switch:
 push {r4-r11,lr}
 sub sp,sp,#4
 mov r10,sp
 mrs r11,cpsr
 orr r0,r11,#0xc0
 msr cpsr_c,r0
 ldr sp,=pw_stack+4096
 bl pw_run_shared
 mov sp,r10
 msr cpsr_c,r11
 add sp,sp,#4
 pop {r4-r11,lr}
 bx lr
 .ltorg
pw_switch_end:
