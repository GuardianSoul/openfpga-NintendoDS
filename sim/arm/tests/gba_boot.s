@ Stand-in for the GBA BIOS boot: set the stacks the way the BIOS leaves
@ them and enter the cartridge at 0x08000000 in System mode.
.syntax unified
.arm
.include "cp15.inc"
.global _start
_start:
    b       reset
    b       .               @ undefined
    b       swi
    b       .               @ prefetch abort
    b       .               @ data abort
    b       .
    b       .               @ IRQ
    b       .               @ FIQ
reset:
.ifdef CACHED
    CP15_REGIONS            @ ARM9 build: GBA ROM area cached (region 7), but no
    mov     r0, #0          @ ITCM, which would hide this stub at 0
    mcr     p15, 0, r0, c7, c5, 0
    mcr     p15, 0, r0, c7, c6, 0
    ldr     r0, =CP15_CTRL_ON & ~0x40000
    mcr     p15, 0, r0, c1, c0, 0
    mrc     p15, 0, r1, c1, c0, 0   @ check it took (else exit with 0xC15)
    cmp     r0, r1
    ldrne   r2, =0x0F000000
    ldrne   r1, =0xC15
    strne   r1, [r2]
.endif
    msr     cpsr_c, #0xD2   @ IRQ
    ldr     sp, =0x03007FA0
    msr     cpsr_c, #0xD3   @ SVC
    ldr     sp, =0x03007FE0
    msr     cpsr_c, #0x1F   @ System
    ldr     sp, =0x03007F00
    mov     r0, #0
    mov     r1, #0
    mov     r2, #0
    mov     r3, #0
    mov     r12, #0
    mov     lr, #0x08000000
    bx      lr

@ BIOS Div (SWI 6), which gba-tests uses to print a failing test number:
@ r0 = r0 / r1, r1 = r0 % r1, r3 = |r0 / r1|. Other SWIs return at once.
swi:
    stmfd   sp!, {r2, r4, r5, lr}
    mov     r4, r0
    mov     r5, r1
    mov     r0, #0
    cmp     r5, #0
    beq     2f
1:  cmp     r4, r5
    blo     2f
    sub     r4, r4, r5
    add     r0, r0, #1
    b       1b
2:  mov     r1, r4
    mov     r3, r0
    ldmfd   sp!, {r2, r4, r5, lr}
    movs    pc, lr
.ltorg
