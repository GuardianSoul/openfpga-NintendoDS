@ Direct-boot program, ARM7 half, and the routines both halves share
@ (ARMv4T only: the ARM7 runs this). See boot9.s for the whole sequence.
@ The ARM7 sees the boot ROM at 0x00008000; its reset vector is
@ 0x00008004 (boot9.s _start).

        .syntax unified
        .arm
        .text
        .align  2

        .equ    BUF, 0x03800000         @ ARM7 WRAM scratch (before the ARM7 binary lands)

        .global arm7_main
arm7_main:
        b       import7                 @ a state import (simulation; import.s) or on
        .global arm7_boot
arm7_boot:
        mov     r10, #0x04000000
        add     r9, r10, #0xF00
        ldr     sp, =0x0380FF00
1:      ldr     r0, [r9, #4]            @ wait for the ARM9
        and     r1, r0, #0xFF
        cmp     r1, #1
        bne     1b
        ldr     r12, =0x027FFE00        @ header copy

        @ ---- secure area, only if the dump has it encrypted
        tst     r0, #0x100
        beq     2f
        ldr     r0, [r12, #0x28]
        ldr     r1, [r12, #0x0C]
        mov     r2, #BUF
        mov     r3, #0x30               @ BIOS7 KEY1 table
        bl      key1_secure_area
        ldr     r12, =0x027FFE00
2:
        @ ---- firmware header fields
        mov     r0, #0
        mov     r1, #BUF
        mov     r2, #0x30
        bl      fwread
        mov     r11, #BUF
        ldrh    r4, [r11, #0x20]        @ user settings offset / 8
        mov     r4, r4, lsl #3
        ldr     r0, =0x027FF864
        mov     r1, #0
        str     r1, [r0]
        str     r4, [r0, #4]            @ 0x027FF868
        ldrh    r1, [r11, #0x26]        @ data/gfx CRC16
        strh    r1, [r0, #0x10]         @ 0x027FF874
        ldrh    r1, [r11, #0x04]        @ GUI/wifi code CRC16
        strh    r1, [r0, #0x12]         @ 0x027FF876

        @ ---- both user settings copies (0x74 bytes each)
        mov     r0, r4
        add     r1, r11, #0x100
        mov     r2, #0x74
        bl      fwread
        add     r0, r4, #0x100
        add     r1, r11, #0x200
        mov     r2, #0x74
        bl      fwread
        @ valid = CRC16(0x70 bytes, 0xFFFF) == stored; both valid: higher
        @ update counter (copy 0 on a tie); one valid: that one; none: copy 0
        add     r0, r11, #0x100
        bl      ucrc
        mov     r5, r0                  @ copy 0 valid
        add     r0, r11, #0x200
        bl      ucrc
        mov     r6, r0                  @ copy 1 valid
        add     r7, r11, #0x100         @ chosen copy
        cmp     r5, #0
        beq     3f
        cmp     r6, #0
        beq     4f
        add     r0, r11, #0x100
        ldrh    r0, [r0, #0x70]
        add     r1, r11, #0x200
        ldrh    r1, [r1, #0x70]
        cmp     r0, r1
        addlo   r7, r11, #0x200
        b       4f
3:      cmp     r6, #0
        addne   r7, r11, #0x200
4:      ldr     r0, =0x027FFC80         @ the 0x70 bytes
        mov     r1, #0
5:      ldr     r2, [r7, r1]
        str     r2, [r0, r1]
        add     r1, r1, #4
        cmp     r1, #0x70
        bne     5b

        @ ---- touch calibration: nds_spi's raw = pixel * 16 + 8, whatever the firmware's
        @ (r0 = the user settings' copy; games read it there)
        ldr     r1, =0x01880208         @ adc x1, y1: pixel (32, 24)
        str     r1, [r0, #0x58]
        ldr     r1, =0x0E081820         @ screen x1, y1; adc x2
        str     r1, [r0, #0x5C]
        ldr     r1, =0xA8E00A88         @ adc y2; screen x2, y2: pixel (224, 168)
        str     r1, [r0, #0x60]

        @ ---- registers melonDS sets for the ARM7
        add     r1, r10, #0x300
        ldr     r0, =0x1204
        strh    r0, [r1, #0x08]         @ BIOSPROT
        mov     r0, #1
        strb    r0, [r1]                @ POSTFLG
        strh    r0, [r1, #0x04]         @ POWCNT2: sound on, wifi off
        add     r1, r10, #0x100
        ldr     r0, =0x8000
        strh    r0, [r1, #0x34]         @ RCNT
        add     r1, r10, #0x500
        ldr     r0, =0x0200
        strh    r0, [r1, #0x04]         @ SOUNDBIAS

        @ ---- the RTC from the APF's date and time (nds_rtc no longer loads it)
        bl      rtcset
        ldr     r12, =0x027FFE00        @ header copy (rtcset clobbers r12)

        @ ---- the ARM7 binary (last: it may overwrite the scratch)
        ldr     r0, [r12, #0x30]
        ldr     r1, [r12, #0x38]
        ldr     r2, [r12, #0x3C]
        add     r2, r2, #3
        bic     r2, r2, #3
        bl      cardread
        add     r1, r10, #0x100
        ldr     r0, =0x8000
        strh    r0, [r1, #0xA0]         @ AUXSPICNT
        ldr     r0, [r9]
        bic     r0, r0, #1              @ BOOTCTL: raw reads off, keep the IR flag and save type
        str     r0, [r9]

        mov     r0, #2                  @ done; wait for the ARM9's answer
        str     r0, [r9, #4]
6:      ldr     r0, [r9, #4]
        cmp     r0, #3
        bne     6b

        ldr     r12, [r12, #0x34]       @ entry point
        msr     cpsr_c, #0xD2
        ldr     sp, =0x0380FF80
        msr     cpsr_c, #0xDF
        ldr     sp, =0x0380FFC0
        mov     lr, #0
        msr     cpsr_c, #0xD3
        ldr     sp, =0x0380FD80
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

@ ---------------------------------------------------------------- rtcset
@ The RTC (0x04000138, nds_rtc) set from the APF's date and time, core
@ registers 0xF20 (BCD 0xYYYYMMDD) and 0xF24 ({valid, 0x00HHMMSS}), as a
@ game would set it: the date+time command (0x26, the register form of a
@ write), year, month, day, day of week, hour, minute, second, in the
@ 24-hour mode the chip is in after reset; then status 1 is read, which
@ clears its power-on bit (as the hardware load before 2026-10-28 did).
@ Day of week, 0 = Sunday: (5 + y + (y + 3) / 4 + cm[month] + (leap year
@ and month > 2) + day) mod 7 for 2000-2099 (every day checked against a
@ calendar). The time comes once, early; it is waited for up to about
@ 0.1 s, and without it the clock stays at 2000-01-01 00:00:00. Every
@ register write is followed by about 5 us (RTCDLY: 48 loops, as libnds's
@ swiDelay(48)): the core takes writes 3 clocks apart, a real chip's serial
@ clock is much slower (docs/ds-rules.md, ARM7 peripherals: not measured).
@ r9 = 0x04000F00, r10 = 0x04000000. Clobbers r0-r3, r12.
        .equ    RTC_WAIT, 0x50000
        .macro  RTCDLY  r
        mov     \r, #48
88:     subs    \r, \r, #1
        bne     88b
        .endm
rtcset:
        push    {r4-r8, lr}
        ldr     r3, =RTC_WAIT
1:      ldr     r5, [r9, #0x24]         @ {valid, time}
        tst     r5, #0x80000000
        bne     2f
        subs    r3, r3, #1
        bne     1b
        b       9f
2:      ldr     r4, [r9, #0x20]         @ date
        mov     r0, r4, lsr #16
        and     r0, r0, #0xFF
        bl      bcdbin
        mov     r6, r0                  @ y
        mov     r0, r4, lsr #8
        and     r0, r0, #0xFF
        bl      bcdbin
        mov     r7, r0                  @ month
        and     r0, r4, #0xFF
        bl      bcdbin                  @ day
        add     r1, r0, #5
        add     r1, r1, r6
        add     r2, r6, #3
        add     r1, r1, r2, lsr #2
        adr     r2, rtc_cm
        sub     r3, r7, #1
        ldrb    r2, [r2, r3]
        add     r1, r1, r2
        tst     r6, #3
        bne     3f
        cmp     r7, #2
        addhi   r1, r1, #1
3:      subs    r1, r1, #7
        bhs     3b
        add     r8, r1, #7              @ day of week
        add     r12, r10, #0x100
        mov     r0, #0x62               @ CS low
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        mov     r0, #0x66               @ CS high: the transfer starts
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        mov     r0, #0x26
        bl      rtcbyte
        mov     r0, r4, lsr #16
        bl      rtcbyte                 @ year
        mov     r0, r4, lsr #8
        bl      rtcbyte                 @ month
        mov     r0, r4
        bl      rtcbyte                 @ day
        mov     r0, r8
        bl      rtcbyte                 @ day of week
        mov     r0, r5, lsr #16
        bl      rtcbyte                 @ hour
        mov     r0, r5, lsr #8
        bl      rtcbyte                 @ minute
        mov     r0, r5
        bl      rtcbyte                 @ second
        mov     r0, #0x62
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        mov     r0, #0x66
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        mov     r0, #0x86               @ status 1, read
        bl      rtcbyte
        mov     r1, #8
4:      mov     r0, #0x64               @ an input bit: SCK low, then high
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        mov     r0, #0x66
        strh    r0, [r12, #0x38]
        RTCDLY  r3
        subs    r1, r1, #1
        bne     4b
        mov     r0, #0x62               @ CS low: the power-on bit clears
        strh    r0, [r12, #0x38]
        RTCDLY  r3
9:      pop     {r4-r8, lr}
        bx      lr
rtc_cm: .byte   0, 3, 3, 6, 1, 4, 6, 2, 5, 0, 3, 5   @ days before the month, mod 7
        .align  2
@ r0 = BCD byte -> binary (clobbers r1)
bcdbin:
        and     r1, r0, #0x0F
        mov     r0, r0, lsr #4
        add     r1, r1, r0, lsl #3
        add     r0, r1, r0, lsl #1
        bx      lr
@ r0[7:0] -> the RTC, LSB first (r12 = 0x04000100; clobbers r0-r3)
rtcbyte:
        mov     r1, #8
1:      and     r2, r0, #1
        orr     r3, r2, #0x74           @ CS, SCK low, data out
        strh    r3, [r12, #0x38]
        RTCDLY  r3
        orr     r3, r2, #0x76           @ SCK high
        strh    r3, [r12, #0x38]
        RTCDLY  r3
        mov     r0, r0, lsr #1
        subs    r1, r1, #1
        bne     1b
        bx      lr

@ ---------------------------------------------------------------- cardread
@ r0 = card byte address (word aligned), r1 = destination, r2 = byte count
@ (multiple of 4). Reads whole 0x200 blocks with 0xB7 and keeps the words
@ inside [r0, r0 + r2). r10 = 0x04000000. Clobbers r3-r8.
        .global cardread
cardread:
        bic     r3, r0, #0xFF
        bic     r3, r3, #0x100          @ block start
        add     r4, r0, r2              @ end
        add     r8, r10, #0x00100000
1:      cmp     r3, r4
        bxhs    lr
        mov     r5, #0xB7
        mov     r6, r3, lsr #24
        orr     r5, r5, r6, lsl #8
        mov     r6, r3, lsr #16
        and     r6, r6, #0xFF
        orr     r5, r5, r6, lsl #16
        mov     r6, r3, lsr #8
        and     r6, r6, #0xFF
        orr     r5, r5, r6, lsl #24
        str     r5, [r10, #0x1A8]
        and     r6, r3, #0xFF
        str     r6, [r10, #0x1AC]
        mov     r5, #0xA1000000
        str     r5, [r10, #0x1A4]
        mov     r7, #0x200
2:      ldr     r5, [r10, #0x1A4]
        tst     r5, #0x00800000
        beq     2b
        ldr     r6, [r8, #0x10]
        cmp     r3, r0
        blo     3f
        cmp     r3, r4
        bhs     3f
        sub     r5, r3, r0
        str     r6, [r1, r5]
3:      add     r3, r3, #4
        subs    r7, r7, #4
        bne     2b
4:      ldr     r5, [r10, #0x1A4]
        tst     r5, #0x80000000
        bne     4b
        b       1b

@ ---------------------------------------------------------------- fwread
@ r0 = firmware byte address, r1 = destination, r2 = byte count (> 0).
@ SPI READ (0x03) with chip select held until the last byte. Clobbers r3, r5-r8.
        .macro  SPIX val
        strh    \val, [r3, #0xC2]
91:     ldrh    r8, [r3, #0xC0]
        tst     r8, #0x80
        bne     91b
        .endm
fwread:
        add     r3, r10, #0x100         @ SPI registers at r3 + 0xC0
        ldr     r5, =0x8900             @ enable, firmware, hold, 4 MHz
        strh    r5, [r3, #0xC0]
        mov     r5, #3
        SPIX    r5
        mov     r5, r0, lsr #16
        and     r5, r5, #0xFF
        SPIX    r5
        mov     r5, r0, lsr #8
        and     r5, r5, #0xFF
        SPIX    r5
        and     r5, r0, #0xFF
        SPIX    r5
        mov     r6, #0
1:      cmp     r6, r2
        bxhs    lr
        sub     r7, r2, r6
        cmp     r7, #1
        ldreq   r5, =0x8100             @ last byte: release chip select after it
        strheq  r5, [r3, #0xC0]
        mov     r5, #0
        SPIX    r5
        ldrh    r5, [r3, #0xC2]
        strb    r5, [r1, r6]
        add     r6, r6, #1
        b       1b

@ ---------------------------------------------------------------- ucrc
@ r0 = user settings copy: returns r0 = 1 if CRC16(bytes 0..0x6F, 0xFFFF)
@ equals the halfword at 0x72 (BIOS CRC16: reflected, polynomial 0xA001).
@ Clobbers r1-r3, r8.
ucrc:
        ldr     r1, =0xFFFF
        mov     r2, #0
1:      ldrb    r3, [r0, r2]
        eor     r1, r1, r3
        mov     r3, #8
2:      movs    r1, r1, lsr #1
        ldrcs   r8, =0xA001
        eorcs   r1, r1, r8
        subs    r3, r3, #1
        bne     2b
        add     r2, r2, #1
        cmp     r2, #0x70
        bne     1b
        ldrh    r3, [r0, #0x72]
        cmp     r1, r3
        moveq   r0, #1
        movne   r0, #0
        bx      lr

        .ltorg
