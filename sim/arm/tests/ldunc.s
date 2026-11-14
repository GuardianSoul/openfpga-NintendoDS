@ ARM9: back-to-back uncached loads (the C0B0 main RAM alias), for the replay/turnaround timeline: 16 LDRs, each
@ result used two instructions later. Exit code 0 = pass, else 0x100 + the load whose value was wrong.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ ALIAS, 0x02400000                      @ region 2: main RAM, uncached
.global _start
_start:
    msr     cpsr_c, #0xD3
    CP15_REGIONS
    CP15_ENABLE
    ldr     r0, =ALIAS + 0x10000
    mov     r2, #0
1:  str     r2, [r0, r2, lsl #2]            @ word k = k
    add     r2, r2, #1
    cmp     r2, #16
    bne     1b
    mov     r4, #0
    ldr     r1, [r0]
    ldr     r2, [r0, #4]
    ldr     r3, [r0, #8]
    ldr     r5, [r0, #12]
    ldr     r6, [r0, #16]
    ldr     r7, [r0, #20]
    ldr     r8, [r0, #24]
    ldr     r9, [r0, #28]
    cmp     r1, #0
    cmpeq   r2, #1
    cmpeq   r3, #2
    cmpeq   r5, #3
    cmpeq   r6, #4
    cmpeq   r7, #5
    cmpeq   r8, #6
    cmpeq   r9, #7
    movne   r4, #0x100
    mov     r0, r4
    ldr     r1, =EXIT
    str     r0, [r1]
2:  b       2b
