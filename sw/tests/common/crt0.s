@ Shared minimal crt0 for the DS test ROMs. Assembled twice: with
@ -defsym ARM9=1 for the ARM9 and without for the ARM7.
@
@ ARM9: makes no assumption about what the loader left in CP15. It turns the
@ MPU and caches off (so main RAM is uncached and the two CPUs see each
@ other's writes), maps DTCM at 0x0B000000 (16 KiB) and ITCM at 0 (32 KiB,
@ mirrored over 32 MiB), selects the high exception vectors (BIOS at
@ 0xFFFF0000), and puts every mode's stack in DTCM. The BIOS IRQ handler
@ jumps through [DTCM+0x3FFC]; IntrWait checks the flags at [DTCM+0x3FF8].
@
@ ARM7: stacks at the top of ARM7 WRAM (0x0380xxxx); the BIOS IRQ handler
@ jumps through [0x0380FFFC]; IntrWait flags at [0x0380FFF8]. Copies the
@ .iwram section (code that must keep running while the ARM9 changes
@ WRAMCNT) from its load address to 0x0380C000.
@
@ Both: clear BSS, run main() in System mode with CPSR.I set and IME = 0.

    .syntax unified
    .arm
    .section .crt0, "ax"
    .global _start
_start:
    msr     cpsr_c, #0xD3           @ SVC, IRQ+FIQ off
    mov     r0, #0x04000000
    mov     r1, #0
    str     r1, [r0, #0x208]        @ IME = 0

.ifdef ARM9
    @ control: MPU/caches off, high vectors, then DTCM/ITCM on after setup
    ldr     r0, =0x00002078
    mcr     p15, 0, r0, c1, c0, 0
    mov     r0, #0
    mcr     p15, 0, r0, c7, c5, 0   @ invalidate I-cache
    mcr     p15, 0, r0, c7, c6, 0   @ invalidate D-cache
    mcr     p15, 0, r0, c7, c10, 4  @ drain write buffer
    ldr     r0, =0x0B00000A         @ DTCM base 0x0B000000, size 16 KiB
    mcr     p15, 0, r0, c9, c1, 0
    mov     r0, #0x20               @ ITCM base 0, size field 0x10 (32 MiB)
    mcr     p15, 0, r0, c9, c1, 1
    ldr     r0, =0x00052078         @ + DTCM enable (16) + ITCM enable (18)
    mcr     p15, 0, r0, c1, c0, 0
    ldr     r4, =0x0B000000         @ stack base = DTCM
.else
    ldr     r4, =0x0380C000         @ ARM7 WRAM: stacks in the top 16 KiB
.endif

    msr     cpsr_c, #0xD2           @ IRQ mode
    add     sp, r4, #0x3F00
    add     sp, sp, #0x80           @ +0x3F80
    msr     cpsr_c, #0xD3           @ SVC mode
    add     sp, r4, #0x3F00
    add     sp, sp, #0xC0           @ +0x3FC0
    msr     cpsr_c, #0xDF           @ System mode
    add     sp, r4, #0x3E00         @ +0x3E00 (user stack grows down)

    @ clear the BIOS IRQ handler pointer and IntrWait flags
    add     r0, r4, #0x3F00
    mov     r1, #0
    str     r1, [r0, #0xF8]
    str     r1, [r0, #0xFC]

.ifndef ARM9
    @ copy .iwram from its load address
    ldr     r0, =__iwram_lma
    ldr     r1, =__iwram_start
    ldr     r2, =__iwram_end
1:  cmp     r1, r2
    ldrlo   r3, [r0], #4
    strlo   r3, [r1], #4
    blo     1b
.endif

    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    mov     r2, #0
2:  cmp     r0, r1
    strlo   r2, [r0], #4
    blo     2b

    bl      main
3:  b       3b

    .global irq_enable_cpu
irq_enable_cpu:
    mrs     r0, cpsr
    bic     r0, r0, #0x80
    msr     cpsr_c, r0
    bx      lr

@ ---- library helpers clang may call ----
    .text
    .global memcpy, memset, memmove, __aeabi_memcpy, __aeabi_memcpy4, __aeabi_memcpy8
    .global __aeabi_memset, __aeabi_memset4, __aeabi_memset8
    .global __aeabi_memclr, __aeabi_memclr4, __aeabi_memclr8
    .global __aeabi_memmove, __aeabi_memmove4, __aeabi_memmove8
memmove:
__aeabi_memmove:
__aeabi_memmove4:
__aeabi_memmove8:
    cmp     r1, r0
    bhs     memcpy
    @ copy backwards
    mov     r12, r0
1:  subs    r2, r2, #1
    ldrbhs  r3, [r1, r2]
    strbhs  r3, [r12, r2]
    bhi     1b
    bx      lr
memcpy:
__aeabi_memcpy:
__aeabi_memcpy4:
__aeabi_memcpy8:
    mov     r12, r0
1:  subs    r2, r2, #1
    ldrbhs  r3, [r1], #1
    strbhs  r3, [r12], #1
    bhi     1b
    bx      lr
memset:                             @ (dst, c, n)
    mov     r3, r1
    mov     r1, r2
    mov     r2, r3
__aeabi_memset:                     @ (dst, n, c)
__aeabi_memset4:
__aeabi_memset8:
    mov     r12, r0
1:  subs    r1, r1, #1
    strbhs  r2, [r12], #1
    bhi     1b
    bx      lr
__aeabi_memclr:
__aeabi_memclr4:
__aeabi_memclr8:
    mov     r2, #0
    b       __aeabi_memset

@ unsigned 32/32 divide: r0 / r1 -> r0 quotient, r1 remainder
    .global __aeabi_uidiv, __aeabi_uidivmod, __aeabi_idiv, __aeabi_idivmod
__aeabi_uidiv:
__aeabi_uidivmod:
    mov     r2, #0                  @ quotient
    mov     r3, #1                  @ bit
    cmp     r1, #0
    beq     9f
1:  cmp     r1, #0x80000000
    cmplo   r1, r0
    movlo   r1, r1, lsl #1
    movlo   r3, r3, lsl #1
    blo     1b
2:  cmp     r0, r1
    subhs   r0, r0, r1
    orrhs   r2, r2, r3
    movs    r3, r3, lsr #1
    movne   r1, r1, lsr #1
    bne     2b
    mov     r1, r0
    mov     r0, r2
    bx      lr
9:  mov     r1, r0
    mvn     r0, #0
    bx      lr

__aeabi_idiv:
__aeabi_idivmod:
    push    {r4, lr}
    eor     r4, r0, r1              @ sign of quotient in bit 31
    and     r4, r4, #0x80000000
    orr     r4, r4, r0, lsr #31     @ sign of remainder (numerator) in bit 0
    cmp     r0, #0
    rsblt   r0, r0, #0
    cmp     r1, #0
    rsblt   r1, r1, #0
    bl      __aeabi_uidivmod
    tst     r4, #0x80000000
    rsbne   r0, r0, #0
    tst     r4, #1
    rsbne   r1, r1, #0
    pop     {r4, lr}
    bx      lr

    .pool
