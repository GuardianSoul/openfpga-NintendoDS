@ RTL harness for sw/boot/key1.s on the ARM7 context of sim/arm/tb_arm.sv.
@ Linked at 0x00008000; the image (sim/boot/run.py) holds
@   0x00000000  ARM7 BIOS (the key table is at +0x30)
@   0x02000000  the encrypted secure area (0x800 bytes)
@   0x02000800  the expected result from sim/boot/key1_ref.c (0x800 bytes)
@   0x02001000  params: gamecode, expected return value, skip flag
@   0x02002000  key buffer scratch (0x1048 bytes)
@ Exit code (store to 0x0F000000): 0 = pass, else bit 31 = return value wrong,
@ bit 30 = r4-r11/sp not preserved, bits 15:0 = number of words that differ.
@ With the skip flag set the call is left out (a baseline for cycle counts).

        .syntax unified
        .arm
        .text
        .global _start
_start:
        mov     sp, #0x03000000
        add     sp, sp, #0x1000
        mov     r0, #0x02000000
        add     r1, r0, #0x1000
        ldr     r9, [r1, #8]            @ skip flag
        ldr     r1, [r1]                @ gamecode
        add     r2, r0, #0x2000
        mov     r3, #0x30
        @ canaries in r4-r11
        mov     r4, #0x44
        mov     r5, #0x55
        mov     r6, #0x66
        mov     r7, #0x77
        mov     r8, #0x88
        mov     r10, #0xAA
        mov     r11, #0xBB
        mov     r12, sp
        str     r12, [sp, #-4]!         @ remember sp
        cmp     r9, #0
        movne   r0, #0
        bne     1f
        mov     r9, #0x99
        bl      key1_secure_area
        cmp     r9, #0x99
        moveq   r9, #0                  @ keep the skip flag in r9 (0 when called)
        movne   r9, #0x40000000
1:      mov     r12, #0
        cmp     r4, #0x44
        cmpeq   r5, #0x55
        cmpeq   r6, #0x66
        cmpeq   r7, #0x77
        cmpeq   r8, #0x88
        cmpeq   r10, #0xAA
        cmpeq   r11, #0xBB
        ldreq   r3, [sp], #4        @ the sp saved before the call
        cmpeq   r3, sp
        orrne   r12, r12, #0x40000000
        orr     r12, r12, r9
        @ return value
        mov     r1, #0x02000000
        add     r1, r1, #0x1000
        ldr     r2, [r1, #4]
        cmp     r0, r2
        orrne   r12, r12, #0x80000000
        @ compare all 0x200 words (no early exit, so the time is fixed)
        mov     r1, #0x02000000
        add     r2, r1, #0x800
        mov     r4, r2
2:      ldr     r5, [r1], #4
        ldr     r6, [r2], #4
        cmp     r5, r6
        addne   r12, r12, #1
        cmp     r1, r4
        bne     2b
        mov     r0, #0x0F000000
        str     r12, [r0]
3:      b       3b
