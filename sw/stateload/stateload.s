@ State import restore stub (docs/state-import.md). The boot ROM's import9 /
@ import7 (sw/boot/import.s) jump here with r0 = its trampoline for a
@ running CPU, r2 = for a halted one, r1 = this CPU's table. The stub is
@ position independent and generic: sim/ds/state_import.py writes the
@ tables. It runs with the ARM9's caches and protection unit off.
@
@ The ARM9 does not return through the boot ROM's trampolines but through
@ its own copies below (tail9_run / tail9_halt), here in main RAM: writing
@ the state's control register turns its protection unit on, and the boot
@ ROM (0xFFFF9xxx) is outside a game's regions, so the MOVS after it must be
@ fetched from memory the state maps. Which map the instruction after the
@ MCR is fetched with is timing (the ARM9 alone in A9_SOLO aborted there,
@ docs/arm-pipeline.md "A9_SOLO cost"; docs/ds-rules.md).
@
@ Table: operations, then the register block.
@   1 addr val    STRB      2 addr val    STRH      3 addr val    STR
@   4 dst src n   copy n bytes (a multiple of 4), words
@   5 idx val     CP15 register idx (the list below) = val
@   6 addr m v    wait until (word at addr & m) == v
@   0             end: the register block follows (words):
@     0 CPSR  1 PC  2 halted  3 CP15 control (ARM9)
@     4-10 FIQ r8-r14  11 SPSR_fiq     12,13 IRQ r13,r14  14 SPSR_irq
@     15,16 SVC r13,r14  17 SPSR_svc   18,19 ABT r13,r14  20 SPSR_abt
@     21,22 UND r13,r14  23 SPSR_und   24-30 user r8-r14  31-38 r0-r7
        .syntax unified
        .arm
        .text
        .global _start
_start:
        b       entry9                  @ offset 0: ARM9
        b       entry                   @ offset 4: ARM7
entry9: adr     r0, tail9_run           @ the ARM9 returns through this stub's own tails
        adr     r2, tail9_halt
entry:
        mov     r11, r0
        mov     r12, r2
        mov     r4, r1
op:     ldr     r2, [r4], #4
        cmp     r2, #0
        beq     regs
        cmp     r2, #4
        beq     copy
        cmp     r2, #5
        beq     cp15
        cmp     r2, #6
        beq     wait
        ldmia   r4!, {r3, r5}
        cmp     r2, #1
        strbeq  r5, [r3]
        cmp     r2, #2
        strheq  r5, [r3]
        cmp     r2, #3
        streq   r5, [r3]
        b       op
copy:   ldmia   r4!, {r3, r5, r6}       @ dst, src, bytes
1:      subs    r6, r6, #4
        ldrge   r7, [r5], #4
        strge   r7, [r3], #4
        bgt     1b
        b       op
wait:   ldmia   r4!, {r3, r5, r6}       @ address, mask, value
1:      ldr     r7, [r3]
        and     r7, r7, r5
        cmp     r7, r6
        bne     1b
        b       op
cp15:   ldmia   r4!, {r3, r5}           @ index, value
        add     pc, pc, r3, lsl #3      @ two instructions an entry
        nop
        mcr     p15, 0, r5, c1, c0, 0   @ 0  control
        b       op
        mcr     p15, 0, r5, c2, c0, 0   @ 1  DCache cachable regions
        b       op
        mcr     p15, 0, r5, c2, c0, 1   @ 2  ICache cachable regions
        b       op
        mcr     p15, 0, r5, c3, c0, 0   @ 3  write buffer
        b       op
        mcr     p15, 0, r5, c5, c0, 2   @ 4  data access permissions
        b       op
        mcr     p15, 0, r5, c5, c0, 3   @ 5  instruction access permissions
        b       op
        mcr     p15, 0, r5, c6, c0, 0   @ 6-13 protection regions 0-7
        b       op
        mcr     p15, 0, r5, c6, c1, 0
        b       op
        mcr     p15, 0, r5, c6, c2, 0
        b       op
        mcr     p15, 0, r5, c6, c3, 0
        b       op
        mcr     p15, 0, r5, c6, c4, 0
        b       op
        mcr     p15, 0, r5, c6, c5, 0
        b       op
        mcr     p15, 0, r5, c6, c6, 0
        b       op
        mcr     p15, 0, r5, c6, c7, 0
        b       op
        mcr     p15, 0, r5, c9, c1, 0   @ 14 DTCM region
        b       op
        mcr     p15, 0, r5, c9, c1, 1   @ 15 ITCM region
        b       op

regs:   ldr     r0, [r4, #8]            @ halted?
        cmp     r0, #0
        moveq   r0, r11
        movne   r0, r12
        str     r0, tramp
        msr     cpsr_c, #0xD1           @ FIQ, IRQ/FIQ off
        add     r0, r4, #16
        ldmia   r0, {r8-r14}
        ldr     r0, [r4, #44]
        msr     spsr_fsxc, r0
        msr     cpsr_c, #0xD2           @ IRQ
        ldr     r13, [r4, #48]
        ldr     r14, [r4, #52]
        ldr     r0, [r4, #56]
        msr     spsr_fsxc, r0
        msr     cpsr_c, #0xD3           @ SVC
        ldr     r13, [r4, #60]
        ldr     r14, [r4, #64]
        ldr     r0, [r4, #68]
        msr     spsr_fsxc, r0
        msr     cpsr_c, #0xDB           @ UND (the trampoline's scratch: overwritten)
        ldr     r13, [r4, #84]
        ldr     r14, [r4, #88]
        ldr     r0, [r4, #92]
        msr     spsr_fsxc, r0
        msr     cpsr_c, #0xDF           @ system: user r8-r14
        add     r0, r4, #96
        ldmia   r0, {r8-r14}
        msr     cpsr_c, #0xD7           @ ABT: the trampoline's mode
        ldr     r14, [r4, #4]           @ the state's PC
        ldr     r0, [r4, #0]
        msr     spsr_fsxc, r0           @ its CPSR
        ldr     r13, [r4, #12]          @ (ARM9) its control register
        add     r0, r4, #124
        ldmia   r0, {r0-r7}
        ldr     pc, tramp
tramp:  .word   0

        @ ---- the ARM9's trampolines, as sw/boot/import.s's tramp9_run /
        @ tramp9_halt (r13_und/r14_und scratch; r13_abt = control, r14_abt = PC)
        .macro  release
        msr     cpsr_c, #0xDB           @ undefined mode, IRQ/FIQ off
2:      mov     r13, #0x04000000
        add     r13, r13, #0x100        @ (r13 = 0x04000100 from here on)
        ldrh    r14, [r13, #0x30]       @ KEYINPUT: 0 is tb_ds's release
        cmp     r14, #0
        bne     2b
        mvn     r14, #0
        str     r14, [r13, #0x114]      @ IF: drop what latched while waiting
        .endm
tail9_run:
        release
        mov     r14, #0
        mcr     p15, 0, r14, c7, c5, 0  @ invalidate the ICache
        mcr     p15, 0, r14, c7, c6, 0  @ and the DCache (both off until now)
        msr     cpsr_c, #0xD7           @ abort mode
        mcr     p15, 0, r13, c1, c0, 0  @ the state's control register
        movs    pc, r14
tail9_halt:
        release
        mov     r14, #0
        mcr     p15, 0, r14, c7, c5, 0
        mcr     p15, 0, r14, c7, c6, 0
        mcr     p15, 0, r14, c7, c0, 4  @ wait for interrupt, as the state was
        msr     cpsr_c, #0xD7
        mcr     p15, 0, r13, c1, c0, 0
        movs    pc, r14
