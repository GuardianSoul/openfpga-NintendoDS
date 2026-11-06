// ARM code blobs: copied into memtime's existing ITCM data buffer before use.
// No extra ITCM allocation changes the retained timer/anchor placement.
.syntax unified
.arm
.section .rodata.ldm_blobs,"a",%progbits
.macro begin name
.balign 4
.global \name, \name\()_end
.type \name,%object
\name:
push {r4-r9}
mov ip,r0
mov r2,#0
mov r3,#0
mov r4,#0
mov r5,#0
mov r6,#0
mov r7,#0
mov r8,#0
mov r9,#0
1: mov ip,r0
.endm
.macro finish name
subs r1,r1,#1
bne 1b
pop {r4-r9}
bx lr
\name\()_end:
.size \name,.-\name
.endm
.macro loads name, regs, fixed=0
begin \name
.rept 16
.if \fixed
mov ip,r0
.endif
ldmia ip!, {\regs}
.endr
finish \name
.endm
loads ldm1,r2
loads ldm2,r2-r3
loads ldm4,r2-r5
loads fixed1,r2,1
loads fixed2,r2-r3,1
loads fixed4,r2-r5,1
loads fixed8,r2-r9,1
begin split4
.rept 16
ldmia ip!,{r2-r5}
ldmia ip!,{r6-r9}
.endr
finish split4
begin split2
.rept 16
ldmia ip!,{r2-r3}
ldmia ip!,{r4-r5}
ldmia ip!,{r6-r7}
ldmia ip!,{r8-r9}
.endr
finish split2
begin scalar8
.rept 16
ldr r2,[ip],#4
ldr r3,[ip],#4
ldr r4,[ip],#4
ldr r5,[ip],#4
ldr r6,[ip],#4
ldr r7,[ip],#4
ldr r8,[ip],#4
ldr r9,[ip],#4
.endr
finish scalar8
begin gap4
.rept 16
ldmia ip!,{r2-r9}
.rept 4
nop
.endr
.endr
finish gap4
begin dep4
.rept 16
ldmia ip!,{r2-r9}
.rept 4
add r2,r2,#0
.endr
.endr
finish dep4
begin nop16
.rept 16
nop
.endr
finish nop16
