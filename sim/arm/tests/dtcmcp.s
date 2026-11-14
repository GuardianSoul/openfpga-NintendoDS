@ ARM9: the state-import stub's table copy into the DTCM (sw/stateload/stateload.s, op 4: subs/ldrge/strge/bgt),
@ with its control setting (MPU and caches off, TCMs on), the DTCM at White 2's base 0x02FE0000. White 2's import
@ on arm9_core left the DTCM's last word (the IRQ vector, 0x3FFC) unwritten. Exit code 0 = pass, else 0x100 + check.
.syntax unified
.arm
.equ EXIT, 0x0F000000
.equ SRC, 0x02010000
.equ DTCM, 0x02FE0000
.global _start
_start:
    msr     cpsr_c, #0xD3
    ldr     r0, =0x02FE000A                 @ DTCM 16 KB at 0x02FE0000
    mcr     p15, 0, r0, c9, c1, 0
    mov     r0, #0x0C                       @ ITCM 32 KB
    mcr     p15, 0, r0, c9, c1, 1
    ldr     r0, =0x00050078                 @ TCMs on, MPU and caches off (the stub's copy setting)
    mcr     p15, 0, r0, c1, c0, 0
    ldr     r3, =SRC                        @ source: word k = k + 0x1000
    mov     r2, #0
1:  add     r1, r2, #0x1000
    str     r1, [r3, r2, lsl #2]
    add     r2, r2, #1
    cmp     r2, #4096
    bne     1b
    adr     r4, table
    @ the stub's table loop, as written
op: ldr     r2, [r4], #4
    cmp     r2, #0
    beq     done
    cmp     r2, #4
    beq     copy
    b       done
copy:
    ldmia   r4!, {r3, r5, r6}               @ dst, src, bytes
1:  subs    r6, r6, #4
    ldrge   r7, [r5], #4
    strge   r7, [r3], #4
    bgt     1b
    b       op
done:
    ldr     r3, =DTCM
    ldr     r12, =0x101
    ldr     r0, [r3]                        @ word 0
    ldr     r1, =0x1000
    cmp     r0, r1
    bne     fail
    add     r12, r12, #1
    add     r2, r3, #0x3F00
    ldr     r0, [r2, #0xF8]                 @ word 4094
    ldr     r1, =0x1FFE
    cmp     r0, r1
    bne     fail
    add     r12, r12, #1
    add     r2, r3, #0x3F00
    ldr     r0, [r2, #0xFC]                 @ word 4095, the last
    ldr     r1, =0x1FFF
    cmp     r0, r1
    bne     fail
    add     r12, r12, #1                    @ the small copy: 4 bytes (one pass, subs gives 0 at once)
    adr     r4, table2
    ldmia   r4!, {r3, r5, r6}
1:  subs    r6, r6, #4
    ldrge   r7, [r5], #4
    strge   r7, [r3], #4
    bgt     1b
    ldr     r3, =DTCM
    ldr     r0, [r3, #0x100]
    ldr     r1, =0x1000
    cmp     r0, r1
    bne     fail
    mov     r12, #0
fail:
    mov     r0, r12
    ldr     r1, =EXIT
    str     r0, [r1]
2:  b       2b
    .ltorg
table:
    .word   4, DTCM, SRC, 0x4000, 0
table2:
    .word   DTCM + 0x100, SRC, 4
