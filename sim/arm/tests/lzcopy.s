@ ARM9 write-back D-cache under an LZ-style workload (NSMB's in-place file
@ decompression broke on it, docs/phase2-integration.md): the same sequence of
@ backward byte copies with short displacements and literal byte stores runs
@ on a cached write-back buffer and on an uncached reference buffer; every
@ byte must agree. Exit code 0 = pass, else 0x100 + the first bad offset.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ BUF,  0x02060000                       @ cached, write-back (region 1)
.equ REF,  0x02470000                       @ uncached (region 2: mirror of 0x02070000)
.equ N,    0x1000
.global _start
_start:
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE
    ldr     r0, =BUF
    bl      run
    ldr     r0, =REF
    bl      run
    @ compare (BUF through the cache, REF uncached)
    ldr     r1, =BUF
    ldr     r2, =REF
    mov     r3, #0
1:  ldrb    r4, [r1, r3]
    ldrb    r5, [r2, r3]
    cmp     r4, r5
    bne     bad
    add     r3, r3, #1
    cmp     r3, #N
    bne     1b
    mov     r0, #0
    ldr     r1, =EXIT
    str     r0, [r1]
2:  b       2b
bad:
    add     r0, r3, #0x100
    ldr     r1, =EXIT
    str     r0, [r1]
3:  b       3b

@ r0 = buffer: fill with an LCG, then from the top down: a literal byte, or a
@ copy of 3..18 bytes from 1..64 bytes above (as backward LZ decoding does)
run:
    push    {r4-r9, lr}
    ldr     r7, =0x12345678                 @ LCG state
    ldr     r8, =1103515245
    mov     r1, #0
1:  mul     r9, r7, r8
    add     r7, r9, #0x3000
    add     r7, r7, #0x39
    strb    r7, [r0, r1]
    add     r1, r1, #1
    cmp     r1, #N
    bne     1b
    ldr     r1, =N - 0x80                   @ write position (going down)
2:  mul     r9, r7, r8
    add     r7, r9, #0x3000
    add     r7, r7, #0x39
    tst     r7, #0x10000
    beq     4f
    mov     r2, r7, lsr #18
    and     r2, r2, #0x3F                   @ displacement - 1
    add     r2, r2, #1
    mov     r3, r7, lsr #24
    and     r3, r3, #0x0F
    add     r3, r3, #3                      @ length
3:  sub     r1, r1, #1
    add     r4, r1, r2
    ldrb    r5, [r0, r4]
    strb    r5, [r0, r1]
    subs    r3, r3, #1
    cmpne   r1, #0x40
    bhi     3b
    b       5f
4:  sub     r1, r1, #1
    mov     r5, r7, lsr #8
    strb    r5, [r0, r1]
5:  cmp     r1, #0x40
    bhi     2b
    pop     {r4-r9, pc}
