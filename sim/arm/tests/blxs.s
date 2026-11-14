@ ARM9: a Thumb BLX suffix on its own (lr set by hand, then a branch to the suffix halfword), as after an interrupt
@ between the BL prefix and the BLX suffix: it calls ARM code at lr + offset, and the CPSR's T bit must be clear there
@ (arm9_core cleared only the fetch state: White 2's import). Exit code 0 = pass, else 0x100 + check.
.syntax unified
.equ EXIT, 0x0F000000
.global _start
.arm
_start:
    msr     cpsr_c, #0xD3
    ldr     r12, =0x101
    adr     r0, thumb + 1
    bx      r0
.thumb
.align 2
thumb:
    ldr     r1, =target - 0x40          @ lr = the target minus the suffix's offset (0x20 halfwords)
    mov     lr, r1
    b       suffix
.align 2
suffix:
    .hword  0xE800 | 0x20               @ BLX suffix: pc = (lr + 0x40) & ~3, lr = next | 1, ARM state
back:
    ldr     r1, =0x5A5A
    cmp     r4, r1
    bne     tfail
    mov     r0, r12                     @ r12 = 0 on success (set in ARM)
    b       texit
tfail:
    mov     r0, r12
texit:
    ldr     r1, =EXIT
    str     r0, [r1]
1:  b       1b
.ltorg
.arm
.align 4
target:
    mrs     r2, cpsr
    tst     r2, #0x20                   @ check 1: T clear
    bne     afail
    add     r12, r12, #1
    ldr     r4, =0x5A5A                 @ check 2: ARM code runs as ARM across a later redirect (a taken branch)
    b       1f
    mov     r4, #0
1:  mov     r3, lr
    sub     r3, r3, #1
    ldr     r5, =back
    cmp     r3, r5                      @ check 3: lr = the halfword after the suffix, Thumb bit set
    bne     afail
    mov     r12, #0
    bx      lr
afail:
    ldr     r1, =EXIT
    str     r12, [r1]
2:  b       2b
.ltorg
