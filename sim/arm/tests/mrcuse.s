@ ARM9: an MRC whose result the next instructions use at once, right behind a store multiple, then a load into the
@ PC through that result: the DS BIOS's IRQ handler (0xFFFF0274: STMFD; MRC p15 c9,c1; MOV lsr/lsl #12; ADD #0x4000;
@ ADD lr, pc; LDR pc, [r0, #-4]), which reads the game's IRQ handler from the end of DTCM. arm9_core jumped to 0
@ there (pkw2-city2w, 2026-11-07). Exit code 0 = pass, else 0x100 + the iteration that went wrong.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.global _start
_start:
    msr     cpsr_c, #0xD3
    CP15_REGIONS
    CP15_ENABLE
    ldr     sp, =0x0B003F00                 @ the stack in DTCM, as the BIOS's
    ldr     r1, =0x0B003FFC                 @ the handler slot at the end of DTCM
    adr     r2, handler
    str     r2, [r1]
    mov     r4, #0                          @ iteration
1:  mov     r5, r4                          @ (the BIOS sequence, with r0-r3, r12, lr live)
    mov     r12, #0x55
    stmfd   sp!, {r0-r3, r12, lr}
    mrc     p15, 0, r0, c9, c1, 0
    mov     r0, r0, lsr #12
    mov     r0, r0, lsl #12
    add     r0, r0, #0x4000
    add     lr, pc, #0
    ldr     pc, [r0, #-4]
    b       bad                             @ (lr points here + 4: the handler returns past it)
back:
    ldmfd   sp!, {r0-r3, r12, lr}
    cmp     r5, r4
    bne     bad
    add     r4, r4, #1
    cmp     r4, #64
    bne     1b
    mov     r0, #0
    ldr     r1, =EXIT
    str     r0, [r1]
2:  b       2b
handler:
    add     r6, r6, #1
    b       back
bad:
    add     r0, r4, #0x100
    ldr     r1, =EXIT
    str     r0, [r1]
3:  b       3b
