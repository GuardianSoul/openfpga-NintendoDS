@ ARM7 halt (HALTCNT) for the testbench: a byte store of 0x80 to HALTCNT
@ (0x04000301) halts the context until the wake line (IE & IF) rises, which
@ 0x0F00000C sets or schedules. The testbench fails the run if the ARM7 keeps retiring while
@ halted. IRQs stay masked (CPSR I), as in the BIOS's IntrWait: the wake
@ line ends a halt by itself. ARMv4T. Exit code 0 = pass, else the step.
.syntax unified
.arm
.equ EXIT, 0x0F000000
.equ HALT, 0x04000301                      @ HALTCNT
.equ WAKE, 0x0F00000C
.global _start
_start:
    msr     cpsr_c, #0xD3                   @ SVC, IRQ and FIQ masked
    ldr     r4, =HALT
    ldr     r5, =WAKE
    mov     r7, #0x80                       @ HALTCNT: halt

    @ 1: halt, woken 300 cycles later; the code after it runs once awake
    mov     r11, #1
    mov     r0, #0
    str     r0, [r5]                        @ wake low
    ldr     r0, =0x8000012C                 @ wake in 300 cycles
    str     r0, [r5]
    mov     r1, #0
    strb    r7, [r4]                        @ halt
    add     r1, r1, #1
    add     r1, r1, #1
    add     r1, r1, #1
    cmp     r1, #3
    bne     fail

    @ 2: halt with the wake line already high: no stop
    mov     r11, #2
    mov     r0, #1
    str     r0, [r5]
    strb    r7, [r4]
    add     r1, r1, #1
    cmp     r1, #4
    bne     fail

    @ 3: a halt loop like the BIOS's IntrWait: halt again while a flag says
    @ the wake was not for us (here: twice)
    mov     r11, #3
    mov     r0, #0
    str     r0, [r5]
    mov     r6, #0
1:  mov     r0, #0
    str     r0, [r5]                        @ wake low
    ldr     r0, =0x80000064                 @ wake in 100 cycles
    str     r0, [r5]
    strb    r7, [r4]                        @ halt
    add     r6, r6, #1
    cmp     r6, #3
    bne     1b

    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .
fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .
.ltorg
