@ Directed test for exception entry and return, banked registers and the
@ IRQ line (none of the test ROMs cover these). ARMv4T code, so the same
@ image runs on both contexts. Exit code 0 = pass, else the failing step.
.syntax unified
.arm
.equ EXIT, 0x0F000000
.equ IRQLINE, 0x0F000004
.global _start
_start:
    b       reset
    b       und_handler
    b       swi_handler
    b       fail
    b       fail
    b       fail
    b       irq_handler
    b       fail

reset:
    msr     cpsr_c, #0xD2
    ldr     sp, =0x02010000
    msr     cpsr_c, #0xDB
    ldr     sp, =0x02011000
    msr     cpsr_c, #0xD1           @ FIQ: banked r8-r12
    mov     r8, #0x88
    mov     r12, #0xCC
    msr     cpsr_c, #0xD3
    ldr     sp, =0x02012000
    msr     cpsr_c, #0xDF           @ System
    ldr     sp, =0x02020000
    mov     r8, #8
    mov     r12, #12

    @ 1: banked FIQ registers kept apart from the user ones
    mov     r11, #1
    cmp     r8, #8
    bne     fail
    msr     cpsr_c, #0xD1
    cmp     r8, #0x88
    bne     fail
    cmp     r12, #0xCC
    bne     fail
    msr     cpsr_c, #0xDF

    @ 2: SWI enters SVC with LR = next instruction, SPSR = old CPSR
    mov     r11, #2
    mov     r0, #0
    msr     cpsr_f, #0x60000000     @ Z and C set, to check they come back
    swi     #0x42
swi_ret:
    bne     fail                    @ Z must be restored
    bcc     fail
    cmp     r0, #0x5A
    bne     fail
    mrs     r1, cpsr
    and     r1, r1, #0x1F
    cmp     r1, #0x1F
    bne     fail

    @ 3: undefined instruction
    mov     r11, #3
    mov     r0, #0
    .word   0xE7F000F0              @ permanently undefined
und_ret:
    cmp     r0, #0x77
    bne     fail

    @ 4: IRQ taken only when enabled, returns with SUBS pc, lr, #4
    mov     r11, #4
    mov     r5, #0
    ldr     r2, =IRQLINE
    mov     r1, #1
    str     r1, [r2]                @ raise the line, I still set
    mov     r3, #100
1:  subs    r3, r3, #1
    bne     1b
    cmp     r5, #0
    bne     fail                    @ masked: not taken
    msr     cpsr_c, #0x5F           @ enable IRQ
    mov     r3, #100
2:  cmp     r5, #0
    bne     3f
    subs    r3, r3, #1
    bne     2b
    b       fail
3:  cmp     r5, #1
    bne     fail
    @ IRQs raised while loads run: with +rwait the testbench checks that a
    @ refused load is re-issued before the IRQ is taken
    mov     r3, #200
    ldr     r6, =exc_data
4:  str     r1, [r2]                @ raise the line (r1 = 1)
    ldr     r0, [r6]
    ldr     r0, [r6, #4]
    ldr     r0, [r6]
    ldr     r0, [r6, #4]
    subs    r3, r3, #1
    bne     4b
    nop
    nop
    nop
    nop
    cmp     r5, #201
    bne     fail
    msr     cpsr_c, #0xDF

    @ 5: SWI from Thumb returns to Thumb
    mov     r11, #5
    mov     r0, #0
    adr     r1, thumb_part + 1
    bx      r1
.thumb
.thumb_func
thumb_part:
    movs    r0, #0
    swi     #1
    adds    r0, r0, #1              @ handler sets r0 = 0x5A
    adr     r1, arm_back
    bx      r1
.align 2
.arm
arm_back:
    cmp     r0, #0x5B
    bne     fail

    @ 6: LDM with S bit restores CPSR from SPSR on exception return
    mov     r11, #6
    mov     r0, #0
    swi     #2
    cmp     r0, #0x5A
    bne     fail

    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .

fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .

swi_handler:
    @ check mode, SPSR and LR
    mrs     r1, cpsr
    and     r1, r1, #0x1F
    cmp     r1, #0x13
    bne     fail
    mrs     r1, spsr
    tst     r1, #0x20
    bne     swi_thumb
    and     r1, r1, #0x1F
    cmp     r1, #0x1F
    bne     fail
    cmp     r11, #6
    beq     swi_ldm
    adr     r1, swi_ret
    cmp     lr, r1
    bne     fail
    mov     r0, #0x5A
    movs    pc, lr
swi_thumb:
    mov     r0, #0x5A
    movs    pc, lr
swi_ldm:
    stmfd   sp!, {r1, lr}
    mov     r0, #0x5A
    ldmfd   sp!, {r1, pc}^

und_handler:
    mrs     r1, cpsr
    and     r1, r1, #0x1F
    cmp     r1, #0x1B
    bne     fail
    adr     r1, und_ret
    cmp     lr, r1
    bne     fail
    mov     r0, #0x77
    movs    pc, lr

exc_data:
    .word   0x11111111, 0x22222222

irq_handler:
    stmfd   sp!, {r1, r2}
    mrs     r1, cpsr
    and     r1, r1, #0x1F
    cmp     r1, #0x12
    bne     fail
    ldr     r2, =IRQLINE
    mov     r1, #0
    str     r1, [r2]                @ acknowledge
    add     r5, r5, #1
    ldmfd   sp!, {r1, r2}
    subs    pc, lr, #4
.ltorg
