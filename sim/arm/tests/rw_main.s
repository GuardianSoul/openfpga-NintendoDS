@ Harness for rockwrestler's ARMv4/ARMv5 CPU tests (src9/tests/armv4.s and
@ armv5.s), without the DS menu framework. Runs every test function in turn.
@ Exit code: 0 = all passed; otherwise 0x80000000 | (function index << 16) |
@ the failing test number that rockwrestler passes in r0.
.syntax unified
.arm
.include "cp15.inc"
.global _start, fail_test
_start:
.ifdef CACHED
    CP15_REGIONS                            @ caches, MPU and TCMs on (cp15.inc)
    CP15_ENABLE
.endif
    msr     cpsr_c, #0xD2           @ IRQ stack
    ldr     sp, =0x020F0000
    msr     cpsr_c, #0xD7           @ ABT stack
    ldr     sp, =0x020F8000
    msr     cpsr_c, #0xDB           @ UND stack
    ldr     sp, =0x020FA000
    msr     cpsr_c, #0xD3           @ SVC stack
    ldr     sp, =0x020FC000
    msr     cpsr_c, #0xDF           @ System
    ldr     sp, =0x020E0000
    mov     r0, #0                  @ registers are not reset; avoid X in 4-state sims
    mov     r1, #0
    mov     r2, #0
    mov     r3, #0
    mov     r4, #0
    mov     r5, #0
    mov     r6, #0
    mov     r7, #0
    mov     r8, #0
    mov     r11, #0
    mov     r12, #0
    mov     lr, #0
    mov     r9, #0
    ldr     r10, =tests
next:
    ldr     r1, [r10], #4
    cmp     r1, #0
    beq     pass
    add     r9, r9, #1
    stmfd   sp!, {r9, r10}
    blx     r1
    ldmfd   sp!, {r9, r10}
    msr     cpsr_c, #0xDF
    b       next
pass:
    ldr     r2, =0x0F000000
    mov     r1, #0
    str     r1, [r2]
    b       .
fail_test:
    msr     cpsr_c, #0xDF
    ldr     sp, =0x020E0000 - 8
    ldmia   sp, {r9, r10}
    ldr     r2, =0x0F000000
    orr     r1, r0, r9, lsl #16
    orr     r1, r1, #0x80000000
    str     r1, [r2]
    b       .
.ltorg
.align 2
tests:
    .word run_tests_armv4_conditioncodes
    .word run_tests_armv5_clz
    .word run_tests_armv5_qadd_qsub
    .word run_tests_armv5_qdadd_qdsub
    .word run_tests_armv5_SMULxy
    .word run_tests_armv5_SMLAxy
    .word run_tests_armv5_SMULWy
    .word run_tests_armv5_SMLAWy
    .word run_tests_armv5_SMLALxy
    .word run_tests_armv5_blx
    .word run_tests_armv5_ldrpopr15
    .word run_tests_armv5_ldm_stm
    .word 0
