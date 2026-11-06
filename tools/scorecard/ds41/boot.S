.syntax unified
.arm
.section .boot,"ax"
.global _start,adapter_done
_start:
 msr cpsr_c,#0xd3
 ldr r0,=0x04000208
 mov r1,#0
 str r1,[r0]
 ldr r0,=0x00002078
 mcr p15,0,r0,c1,c0,0
 mcr p15,0,r1,c7,c5,0
 mcr p15,0,r1,c7,c6,0
 mcr p15,0,r1,c7,c10,4
 ldr r0,=0x02ff000a
 mcr p15,0,r0,c9,c1,0
 mov r0,#0x20
 mcr p15,0,r0,c9,c1,1
 ldr r0,=0x00052078
 mcr p15,0,r0,c1,c0,0
 ldr r0,=0x02ff0000
 ldr r2,=0x02ff4000
1: str r1,[r0],#4
 cmp r0,r2
 blo 1b
 msr cpsr_c,#0xdf
 ldr sp,=0x02ff3e00
 ldr r0,=0x04000033
 mcr p15,0,r0,c6,c0,0
 ldr r0,=0x0200002b
 mcr p15,0,r0,c6,c1,0
 mov r0,#0
 mcr p15,0,r0,c6,c2,0
 mcr p15,0,r0,c6,c3,0
 ldr r0,=0x02ff001f
 mcr p15,0,r0,c6,c4,0
 ldr r0,=0x01ff801d
 mcr p15,0,r0,c6,c5,0
 ldr r0,=0xffff001d
 mcr p15,0,r0,c6,c6,0
 mov r0,#0x17
 mcr p15,0,r0,c6,c7,0
 mov r0,#0x42
 mcr p15,0,r0,c2,c0,0
 mcr p15,0,r0,c2,c0,1
 mov r0,#2
 mcr p15,0,r0,c3,c0,0
 ldr r0,=0x06330033
 mcr p15,0,r0,c5,c0,2
 ldr r0,=0x66600060
 mcr p15,0,r0,c5,c0,3
 ldr r0,=0x0005507d
 mcr p15,0,r0,c1,c0,0
 b driver
adapter_done:
 b adapter_done
.ltorg
