@ Direct-boot program, ARM9 half (docs/phase2-integration.md, "Boot").
@ Runs from the boot ROM at 0xFFFF8000 (the ARM9's view of rtl/ds's boot
@ RAM); the ARM7 half (boot7.s) runs from the same ROM at 0x00008000.
@ Together they leave the machine as melonDS's NDS::SetupDirectBoot does:
@   ARM9: CP15 (MPU regions, TCMs) as melonDS writes them, WRAMCNT = 3,
@         the cart header (0x170 bytes) at 0x027FFE00, chip ID and header
@         CRCs at 0x027FF800/0x027FFC00, the ARM9 binary at its RAM address,
@         EXMEMCNT = 0xE880 (card and GBA slot to the ARM7), POSTFLG = 1,
@         POWCNT1 = 0x820F
@   ARM7: secure area KEY1 decryption (only if the dump has it encrypted),
@         firmware header fields and user settings at 0x027FF864..0x027FFCEF,
@         touch calibration for nds_spi, BIOSPROT = 0x1204, POSTFLG,
@         POWCNT2 = 1, RCNT, AUXSPICNT, SOUNDBIAS, the ARM7 binary
@ then both start their entry points in SVC mode with melonDS's r12/r13/r14
@ and IRQ-mode r13, all other registers zero.
@ Handshake through the core's scratch register (0x04000F04): the ARM9
@ writes 1 (+ 0x100 if the secure area is encrypted) when the ARM7 may go,
@ the ARM7 writes 2 when it is done, the ARM9 answers 3 and both jump.
@ Position independent (the two CPUs see the ROM at different addresses).

        .syntax unified
        .arm
        .section .text.vectors, "ax"
        .global _start
_start:
        b       arm9_main               @ 0xFFFF8000: ARM9 reset
        b       arm7_main               @ 0x00008004: ARM7 reset

        .text
        .align  2
        .global arm9_main
arm9_main:
        b       import9                 @ a state import (simulation; import.s) or on
        .global arm9_boot
arm9_boot:
        @ ---- CP15 as melonDS's direct boot leaves it
        ldr     r0, =0x00052078
        mcr     p15, 0, r0, c1, c0, 0
        mov     r0, #0x42
        mcr     p15, 0, r0, c2, c0, 0
        mcr     p15, 0, r0, c2, c0, 1
        mov     r0, #0x02
        mcr     p15, 0, r0, c3, c0, 0
        ldr     r0, =0x15111011
        mcr     p15, 0, r0, c5, c0, 2
        ldr     r0, =0x05100011
        mcr     p15, 0, r0, c5, c0, 3
        ldr     r0, =0x04000033
        mcr     p15, 0, r0, c6, c0, 0
        ldr     r0, =0x0200002B
        mcr     p15, 0, r0, c6, c1, 0
        mov     r0, #0
        mcr     p15, 0, r0, c6, c2, 0
        ldr     r0, =0x08000035
        mcr     p15, 0, r0, c6, c3, 0
        ldr     r0, =0x0300001B
        mcr     p15, 0, r0, c6, c4, 0
        mov     r0, #0
        mcr     p15, 0, r0, c6, c5, 0
        ldr     r0, =0xFFFF001D
        mcr     p15, 0, r0, c6, c6, 0
        ldr     r0, =0x027FF017
        mcr     p15, 0, r0, c6, c7, 0
        ldr     r0, =0x0300000A
        mcr     p15, 0, r0, c9, c1, 0
        mov     r0, #0x20
        mcr     p15, 0, r0, c9, c1, 1

        mov     r10, #0x04000000        @ I/O
        add     r9, r10, #0xF00         @ core registers

        @ ---- main RAM and VRAM cleared, as melonDS's reset leaves them (the
        @ Pocket's PSRAM and SDRAM power up with random contents; games read
        @ memory they never wrote). The ARM7 waits for the go below. Core
        @ register 0xF18 bit 0 says whether they need it (0 in the simulation,
        @ whose models start zeroed).
        ldr     r0, [r9, #0x18]
        tst     r0, #1
        beq     3f
        mov     r1, #0
        mov     r2, #0
        mov     r3, #0
        mov     r4, #0
        mov     r5, #0
        mov     r6, #0
        mov     r7, #0
        mov     r8, #0
        mov     r0, #0x02000000
        add     r11, r0, #0x00400000
1:      stmia   r0!, {r1-r8}
        cmp     r0, r11
        blo     1b
        add     r11, r10, #0x240        @ VRAMCNT A-I: all banks to the LCDC view
        mov     r12, #0x80
        strb    r12, [r11, #0]
        strb    r12, [r11, #1]
        strb    r12, [r11, #2]
        strb    r12, [r11, #3]
        strb    r12, [r11, #4]
        strb    r12, [r11, #5]
        strb    r12, [r11, #6]
        strb    r12, [r11, #8]
        strb    r12, [r11, #9]
        mov     r0, #0x06800000
        add     r12, r0, #0x000A4000    @ 656 KiB
2:      stmia   r0!, {r1-r8}
        cmp     r0, r12
        blo     2b
        str     r1, [r11, #0]           @ VRAMCNT A-I back to 0
        strh    r1, [r11, #4]
        strb    r1, [r11, #6]
        strh    r1, [r11, #8]
3:
        mov     r0, #3                  @ WRAMCNT: all shared WRAM to the ARM7
        strb    r0, [r10, #0x247]
        mov     r0, #1                  @ BOOTCTL: raw card reads
        str     r0, [r9]

        @ ---- header: 0x170 bytes to 0x027FFE00
        ldr     r12, =0x027FFE00
        mov     r0, #0
        mov     r1, r12
        mov     r2, #0x170
        bl      cardread
        @ BOOTCTL: raw reads (bit 0), infrared cart (bit 1: gamecode 'I...'),
        @ save type in bits 6:4 (melonDS SaveMemType): none for homebrew
        @ (ARM9 binary below 0x4000), else (docs/saves.md) the ROM tables'
        @ type, else from savetab by the gamecode's first three letters, else
        @ the loaded .sav's size, else EEPROM 8 KiB (melonDS's default).
        @ 0xF1C from the shell: [7] tables valid, [6:4] tables type, [3] size
        @ valid, [2:0] size type
        mov     r3, #1
        ldrb    r0, [r12, #0x0C]
        cmp     r0, #'I'
        orreq   r3, r3, #2
        ldr     r0, [r12, #0x20]
        cmp     r0, #0x4000
        blo     7f
        ldr     r0, [r12, #0x0C]
        bic     r0, r0, #0xFF000000
        mov     r2, #2
        ldr     r4, [r9, #0x1C]
        tst     r4, #0x80
        movne   r2, r4, lsr #4
        andne   r2, r2, #7
        bne     6f
        adr     r1, savetab             @ PC-relative: the boot ROM runs at 0xFFFF8000, linked at 0
5:      ldr     r5, [r1], #4
        cmp     r5, #0
        beq     8f
        bic     r6, r5, #0xFF000000
        cmp     r6, r0
        bne     5b
        mov     r2, r5, lsr #24
        b       6f
8:      tst     r4, #0x08
        andne   r2, r4, #7
6:      orr     r3, r3, r2, lsl #4
7:      str     r3, [r9]

        @ ---- chip ID
        mov     r0, #0xB8
        str     r0, [r10, #0x1A8]
        mov     r0, #0
        str     r0, [r10, #0x1AC]
        ldr     r0, =0xA7000000
        str     r0, [r10, #0x1A4]
        add     r8, r10, #0x00100000
1:      ldr     r0, [r10, #0x1A4]
        tst     r0, #0x00800000
        beq     1b
        ldr     r11, [r8, #0x10]
2:      ldr     r0, [r10, #0x1A4]
        tst     r0, #0x80000000
        bne     2b

        @ ---- IDs and CRCs (melonDS order of values)
        ldr     r0, =0x027FF800
        str     r11, [r0]
        str     r11, [r0, #4]
        add     r1, r12, #0x100
        ldrh    r1, [r1, #0x5E]         @ header CRC16 (0x15E)
        strh    r1, [r0, #8]
        ldrh    r2, [r12, #0x6C]        @ secure area CRC16
        strh    r2, [r0, #0x0A]
        ldr     r3, =0x5835
        strh    r3, [r0, #0x50]
        add     r0, r0, #0x400          @ 0x027FFC00
        str     r11, [r0]
        str     r11, [r0, #4]
        strh    r1, [r0, #8]
        strh    r2, [r0, #0x0A]
        strh    r3, [r0, #0x10]
        ldr     r1, =0xFFFF
        strh    r1, [r0, #0x30]
        mov     r1, #1
        strh    r1, [r0, #0x40]

        @ ---- ARM9 binary
        ldr     r0, [r12, #0x20]        @ ROM offset
        ldr     r1, [r12, #0x28]        @ RAM address
        ldr     r2, [r12, #0x2C]        @ size
        add     r2, r2, #3
        bic     r2, r2, #3
        bl      cardread
        @ secure area: encrypted if it doesn't start with melonDS's
        @ decrypted marker (0xE7FFDEFF; decrypted dumps already have it)
        mov     r4, #0
        ldr     r0, [r12, #0x20]
        cmp     r0, #0x4000
        blo     3f
        cmp     r0, #0x8000
        bhs     3f
        ldr     r1, [r12, #0x28]
        ldr     r1, [r1]
        ldr     r2, =0xE7FFDEFF
        cmp     r1, r2
        movne   r4, #0x100
3:
        @ ---- hand the card and GBA slot to the ARM7, power, POSTFLG
        add     r1, r10, #0x200
        ldr     r0, =0xE880
        strh    r0, [r1, #0x04]         @ EXMEMCNT
        add     r1, r10, #0x300
        mov     r0, #1
        strb    r0, [r1]                @ POSTFLG
        ldr     r0, =0x820F
        strh    r0, [r1, #0x04]         @ POWCNT1

        orr     r0, r4, #1              @ ARM7: go
        str     r0, [r9, #4]
4:      ldr     r0, [r9, #4]
        cmp     r0, #2
        bne     4b
        mov     r0, #3
        str     r0, [r9, #4]

        @ ---- registers and jump (SVC mode, IRQs off, as after reset)
        ldr     r12, [r12, #0x24]       @ entry point
        msr     cpsr_c, #0xD2           @ IRQ mode
        ldr     sp, =0x03003F80
        msr     cpsr_c, #0xDF           @ System (= user) mode: melonDS's R_SVC[0]
        ldr     sp, =0x03003FC0
        mov     lr, #0
        msr     cpsr_c, #0xD3           @ SVC mode
        ldr     sp, =0x03002F7C
        mov     lr, r12
        mov     r0, #0
        mov     r1, #0
        mov     r2, #0
        mov     r3, #0
        mov     r4, #0
        mov     r5, #0
        mov     r6, #0
        mov     r7, #0
        mov     r8, #0
        mov     r9, #0
        mov     r10, #0
        mov     r11, #0
        msr     cpsr_f, #0              @ flags clear, as after reset
        bx      r12
        .ltorg

@ Save chips (melonDS's ROM list: 1 EEPROM 512 B, 2/3/4 EEPROM 8/64/128 KiB,
@ 5/6/7 FLASH 256/512/1024 KiB) of the games tested so far, by the first
@ three letters of the gamecode.
.macro save c0, c1, c2, t
        .word   \c0 | (\c1 << 8) | (\c2 << 16) | (\t << 24)
.endm
        .align  2
savetab:
        save    'A','2','D', 2          @ New Super Mario Bros.
        save    'A','S','M', 2          @ Super Mario 64 DS
        save    'A','T','R', 2          @ Tetris DS
        save    'A','R','M', 2          @ Mario & Luigi: Partners in Time
        save    'A','F','F', 3          @ Final Fantasy III
        save    'A','J','U', 3          @ Jump Ultimate Stars
        save    'Y','K','G', 3          @ Kingdom Hearts 358/2 Days
        save    'B','K','9', 3          @ Kingdom Hearts Re:coded
        save    'Y','K','W', 3          @ Kirby Super Star Ultra
        save    'Y','B','U', 3          @ Blue Dragon: Awakened Shadow
        save    'B','S','K', 3          @ 999
        save    'C','3','J', 3          @ Professor Layton and the Unwound Future
        save    'C','2','S', 4          @ Pokemon Mystery Dungeon: Explorers of Sky
        save    'A','D','M', 5          @ Animal Crossing: Wild World
        save    'A','M','C', 5          @ Mario Kart DS
        save    'B','O','5', 5          @ Golden Sun: Dark Dawn
        save    'A','D','A', 6          @ Pokemon Diamond
        save    'A','P','A', 6          @ Pokemon Pearl
        save    'C','P','U', 6          @ Pokemon Platinum
        save    'I','P','K', 6          @ Pokemon HeartGold
        save    'I','P','G', 6          @ Pokemon SoulSilver
        save    'I','R','B', 6          @ Pokemon Black
        save    'I','R','A', 6          @ Pokemon White
        save    'I','R','E', 6          @ Pokemon Black 2
        save    'I','R','D', 6          @ Pokemon White 2
        save    'C','C','U', 6          @ Tomodachi Collection
        .word   0
