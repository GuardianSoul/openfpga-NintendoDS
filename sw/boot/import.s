@ State import (docs/state-import.md): in the simulation only, tb_ds
@ --import-state starts the core from a melonDS state. It loads the external
@ memories, overlays a restore stub and its tables (sw/stateload, made by
@ sim/ds/state_import.py) on unused main RAM, and puts a block at
@ 0x02000000:
@   'SLOD' 'NDSI' entry9 entry7 table9 table7
@ Each CPU's reset code comes here first. With core register 0xF18 bit 0
@ clear (the simulation: memories start zeroed; the Pocket sets it) and the
@ block present, it jumps to its stub with r0 = this ROM's trampoline for a
@ running CPU, r2 = for a halted one, r1 = its table. Otherwise it goes on
@ with the normal boot.
@
@ The trampolines are entered in abort mode with r0-r12 and every other
@ mode's registers already as the state has them, r14_abt = the state's PC,
@ SPSR_abt = its CPSR, and (ARM9) r13_abt = its CP15 control register.
@ Using undefined mode's r13/r14 as scratch, they wait for tb_ds's release
@ (KEYINPUT = 0: all keys pressed). Then they clear IF (interrupts latched
@ while waiting), and on the ARM9 invalidate the caches (off until now) and
@ write the control register. A halted CPU halts again. Finally they return
@ into the state with MOVS pc, lr. Abort and undefined modes' r13/r14 and
@ SPSR_abt are not restored.

        .syntax unified
        .arm
        .text
        .align  2

        .equ    MAGIC0, 0x444F4C53      @ 'SLOD'
        .equ    MAGIC1, 0x49534E44      @ 'NDSI'

        .global import9
import9:
        mov     r10, #0x04000000
        ldr     r0, [r10, #0xF18]
        tst     r0, #1
        bne     arm9_boot
        mov     r1, #0x02000000
        ldmia   r1, {r2-r7}
        ldr     r0, =MAGIC0
        cmp     r2, r0
        ldreq   r0, =MAGIC1
        cmpeq   r3, r0
        bne     arm9_boot
        mov     r1, r6
        adr     r0, tramp9_run
        adr     r2, tramp9_halt
        bx      r4

        .global import7
import7:
        mov     r10, #0x04000000
        ldr     r0, [r10, #0xF18]
        tst     r0, #1
        bne     arm7_boot
        mov     r1, #0x02000000
        ldmia   r1, {r2-r7}
        ldr     r0, =MAGIC0
        cmp     r2, r0
        ldreq   r0, =MAGIC1
        cmpeq   r3, r0
        bne     arm7_boot
        mov     r1, r7
        adr     r0, tramp7_run
        adr     r2, tramp7_halt
        bx      r5

        @ ---- the trampolines (r13_und/r14_und scratch; r13_abt = control, r14_abt = PC)
        .macro  release
        msr     cpsr_c, #0xDB           @ undefined mode, IRQ/FIQ off
1:      mov     r13, #0x04000000
        add     r13, r13, #0x100        @ (r13 = 0x04000100 from here on)
        ldrh    r14, [r13, #0x30]       @ KEYINPUT: 0 is tb_ds's release
        cmp     r14, #0
        bne     1b
        mvn     r14, #0
        str     r14, [r13, #0x114]      @ IF: drop what latched while waiting
        .endm

tramp9_run:
        release
        mov     r14, #0
        mcr     p15, 0, r14, c7, c5, 0  @ invalidate the ICache
        mcr     p15, 0, r14, c7, c6, 0  @ and the DCache (both off until now)
        msr     cpsr_c, #0xD7           @ abort mode
        mcr     p15, 0, r13, c1, c0, 0  @ the state's control register
        movs    pc, r14
tramp9_halt:
        release
        mov     r14, #0
        mcr     p15, 0, r14, c7, c5, 0
        mcr     p15, 0, r14, c7, c6, 0
        mcr     p15, 0, r14, c7, c0, 4  @ wait for interrupt, as the state was
        msr     cpsr_c, #0xD7
        mcr     p15, 0, r13, c1, c0, 0
        movs    pc, r14

        @ ---- ARM7
tramp7_run:
        release
        msr     cpsr_c, #0xD7
        movs    pc, r14
tramp7_halt:
        release
        mov     r14, #0x80
        strb    r14, [r13, #0x201]      @ HALTCNT: halted, as the state was
        msr     cpsr_c, #0xD7
        movs    pc, r14

        .ltorg
