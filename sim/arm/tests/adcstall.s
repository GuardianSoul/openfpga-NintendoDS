@ Directed test: a flag-setting ADCS waits in E behind an uncached load that stalls M. The CPSR must not take its
@ flags before E commits: an early carry would feed the held ADCS's own carry-in (0xFFFFFFFF + 1 + C: 0 with C 0,
@ 1 with C 1). arm9_core's CPSR writer gate (!stall, last level; ARM9_CPSR_STALL_MUT drops it).
@ Exit code 0 = pass, else 0x80000000 + the iteration, 0x40000000 + the wrong sum, or 0x20000000 + the wrong flags.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ UNC, 0x00400000
.equ AREA, 0x02040000
.global _start
_start:
    mov     r11, #0
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE
    ldr     r4, =AREA + UNC
    mov     r0, #0x100
    str     r0, [r4]                        @ memory = 0x100 (uncached)
    mcr     p15, 0, r0, c7, c10, 4
    mov     r5, #0
    mvn     r7, #0                          @ 0xFFFFFFFF
    mov     r8, #1
    mov     r10, #0
1:  adds    r9, r10, #0                     @ C = 0, Z = 1
    ldr     r1, [r4]                        @ uncached: M stalls
    adcs    r6, r7, r8                      @ in E during the stall: 0xFFFFFFFF + 1 + 0 = 0, C = 1, Z = 1
    mrs     r2, cpsr
    cmp     r6, #0
    bne     bad_sum
    and     r2, r2, #0xF0000000
    cmp     r2, #0x60000000                 @ Z and C
    bne     bad_flags
    cmp     r1, r0
    bne     fail
    add     r5, r5, #1
    cmp     r5, #16
    bne     1b
    mov     r11, #0
    ldr     r3, =EXIT
    str     r11, [r3]
    b       .
bad_sum:
    orr     r11, r6, #0x40000000
    b       out
bad_flags:
    lsr     r2, r2, #28
    orr     r11, r2, #0x20000000
    b       out
fail:
    orr     r11, r5, #0x80000000
out:
    ldr     r3, =EXIT
    str     r11, [r3]
    b       .
.ltorg
