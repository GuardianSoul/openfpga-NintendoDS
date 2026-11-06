.syntax unified
.arch armv4t
.thumb
.section .text.at_kernels,"ax",%progbits

.balign 32
.global at_alu,at_alu_body,at_alu_body_end,at_alu_literal,at_alu_end
.type at_alu,%function
.thumb_func
at_alu:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_alu
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_alu_body:
1:
 .rept 64
 adds r0,#1
 .endr
at_alu_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_alu:
at_alu_literal:
 .word 0x13579bdf
at_alu_end:
.size at_alu,.-at_alu

.balign 32
.global at_branch,at_branch_body,at_branch_body_end,at_branch_literal,at_branch_end
.type at_branch,%function
.thumb_func
at_branch:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_branch
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_branch_body:
1:
 .rept 64
 b 2f
 .hword 0x46c0
2:
 .endr
at_branch_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_branch:
at_branch_literal:
 .word 0x13579bdf
at_branch_end:
.size at_branch,.-at_branch

.balign 32
.global at_ldr_sp,at_ldr_sp_body,at_ldr_sp_body_end,at_ldr_sp_literal,at_ldr_sp_end
.type at_ldr_sp,%function
.thumb_func
at_ldr_sp:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_ldr_sp
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_ldr_sp_body:
1:
 .rept 64
 ldr r0,[sp,#0]
 .endr
at_ldr_sp_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_ldr_sp:
at_ldr_sp_literal:
 .word 0x13579bdf
at_ldr_sp_end:
.size at_ldr_sp,.-at_ldr_sp

.balign 32
.global at_str_sp,at_str_sp_body,at_str_sp_body_end,at_str_sp_literal,at_str_sp_end
.type at_str_sp,%function
.thumb_func
at_str_sp:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_str_sp
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_str_sp_body:
1:
 .rept 64
 str r2,[sp,#0]
 .endr
at_str_sp_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_str_sp:
at_str_sp_literal:
 .word 0x13579bdf
at_str_sp_end:
.size at_str_sp,.-at_str_sp

.balign 32
.global at_ldr_pc,at_ldr_pc_body,at_ldr_pc_body_end,at_ldr_pc_literal,at_ldr_pc_end
.type at_ldr_pc,%function
.thumb_func
at_ldr_pc:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_ldr_pc
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_ldr_pc_body:
1:
 .rept 64
 ldr r0,.Lvalue_ldr_pc
 .endr
at_ldr_pc_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_ldr_pc:
at_ldr_pc_literal:
 .word 0x13579bdf
at_ldr_pc_end:
.size at_ldr_pc,.-at_ldr_pc

.balign 32
.global at_str_reg,at_str_reg_body,at_str_reg_body_end,at_str_reg_literal,at_str_reg_end
.type at_str_reg,%function
.thumb_func
at_str_reg:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_str_reg
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_str_reg_body:
1:
 .rept 64
 str r2,[r6,r3]
 .endr
at_str_reg_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_str_reg:
at_str_reg_literal:
 .word 0x13579bdf
at_str_reg_end:
.size at_str_reg,.-at_str_reg

.balign 32
.global at_ldrh,at_ldrh_body,at_ldrh_body_end,at_ldrh_literal,at_ldrh_end
.type at_ldrh,%function
.thumb_func
at_ldrh:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_ldrh
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_ldrh_body:
1:
 .rept 64
 ldrh r0,[r6,r3]
 .endr
at_ldrh_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_ldrh:
at_ldrh_literal:
 .word 0x13579bdf
at_ldrh_end:
.size at_ldrh,.-at_ldrh

.balign 32
.global at_strh,at_strh_body,at_strh_body_end,at_strh_literal,at_strh_end
.type at_strh,%function
.thumb_func
at_strh:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_strh
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_strh_body:
1:
 .rept 64
 strh r2,[r6,r3]
 .endr
at_strh_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_strh:
at_strh_literal:
 .word 0x13579bdf
at_strh_end:
.size at_strh,.-at_strh

.balign 32
.global at_stm1,at_stm1_body,at_stm1_body_end,at_stm1_literal,at_stm1_end
.type at_stm1,%function
.thumb_func
at_stm1:
 push {r4-r7,lr}
 mov r4,sp
 movs r5,r0
 movs r6,r1
 movs r7,r2
 ldr r2,.Lvalue_stm1
 movs r3,#0
 movs r0,#0x12
 mov sp,r6
 .balign 4
at_stm1_body:
1:
 .rept 64
 stmia r6!,{r2}
 .endr
at_stm1_body_end:
 subs r5,#1
 beq 3f
 b 1b
3:
 cmp r7,#0
 beq 4f
 stmia r7!,{r0-r6}
4:
 mov sp,r4
 pop {r4-r7}
 pop {r1}
 bx r1
 .balign 4
.Lvalue_stm1:
at_stm1_literal:
 .word 0x13579bdf
at_stm1_end:
.size at_stm1,.-at_stm1
