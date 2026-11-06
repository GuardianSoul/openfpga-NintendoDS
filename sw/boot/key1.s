@ KEY1 decryption of a DS cartridge's ARM9 secure area, for the direct-boot
@ program (ARMv4T, ARM state; runs on the ARM7). Written from GBATEK "DS
@ Encryption by Gamecode/Idcode (KEY1)"; it gives the same result as melonDS's
@ direct boot (NDSCartSlot::DecryptSecureArea). Model: sim/boot/key1_ref.c.
@
@   r0 = key1_secure_area(u8 *area, u32 gamecode, u32 *keybuf, const u32 *table)
@     area     the 0x800 encrypted bytes, word aligned; decrypted in place
@     gamecode cartridge header 0x0C as a little-endian word
@     keybuf   0x1048 bytes of word-aligned scratch
@     table    the ARM7 BIOS KEY1 table (ARM7 BIOS + 0x30, 0x1048 bytes)
@   returns 0 if the decrypted area began with "encryObj" (those 8 bytes become
@   0xE7FFDEFF twice), else 1 (the whole area becomes 0xE7FFDEFF).
@   AAPCS: r0-r3, r12 and the flags are clobbered; 56 bytes of stack.
@
@ Steps (melonDS's level-2 then level-3 init both start from the BIOS table and
@ share their first two keycode applications, so this does them once):
@   keybuf = table; keycode = {gamecode, gamecode >> 1, gamecode << 1}
@   apply keycode twice                        (level 2, modulo 2)
@   decrypt the first 8-byte block
@   keycode[1] <<= 1; keycode[2] >>= 1; apply  (level 3)
@   decrypt all 0x100 blocks; check for "encryObj"
@
@ Position independent: no absolute addresses, no literal pool.
@
@ Register use inside the cipher (enc/dec): r0/r1 the two halves of the block,
@ r2 = keybuf (the 18-word P array), r3..r6 = the four S-boxes, r8..r12 temps.
@ r7 is left to the callers of enc/dec as their loop pointer.

        .syntax unified
        .arm
        .text
        .align  2
        .global key1_secure_area
        .type   key1_secure_area, %function

@ Stack frame (from sp, after the 9-register push)
        .equ    F_CODE0, 0              @ keycode[0..2]
        .equ    F_CODE1, 4
        .equ    F_CODE2, 8
        .equ    F_AREA,  12             @ area pointer
        .equ    F_SIZE,  16

key1_secure_area:
        push    {r4-r11, lr}
        sub     sp, sp, #F_SIZE
        str     r0, [sp, #F_AREA]

        @ keycode = {id, id >> 1, id << 1}
        mov     r4, r1, lsr #1
        mov     r5, r1, lsl #1
        stmia   sp, {r1, r4, r5}

        @ keybuf = BIOS table: 130 x 32 bytes, then 8 more (0x1048 bytes)
        mov     r1, r2
        add     r0, r2, #0x1040
1:      ldmia   r3!, {r4-r11}
        stmia   r1!, {r4-r11}
        cmp     r1, r0
        bne     1b
        ldmia   r3, {r4, r5}
        stmia   r1, {r4, r5}

        @ S-box pointers
        add     r3, r2, #0x48
        add     r4, r3, #0x400
        add     r5, r4, #0x400
        add     r6, r5, #0x400

        bl      apply_keycode
        bl      apply_keycode

        @ level 2: decrypt the first block
        ldr     r7, [sp, #F_AREA]
        ldr     r1, [r7]
        ldr     r0, [r7, #4]
        bl      dec
        stmia   r7, {r0, r1}

        @ level 3
        ldr     r0, [sp, #F_CODE1]
        ldr     r1, [sp, #F_CODE2]
        mov     r0, r0, lsl #1
        mov     r1, r1, lsr #1
        str     r0, [sp, #F_CODE1]
        str     r1, [sp, #F_CODE2]
        bl      apply_keycode

        @ decrypt all 0x100 blocks
        ldr     r7, [sp, #F_AREA]
2:      ldr     r1, [r7]
        ldr     r0, [r7, #4]
        bl      dec
        stmia   r7!, {r0, r1}
        ldr     r8, [sp, #F_AREA]
        add     r8, r8, #0x800
        cmp     r7, r8
        bne     2b

        @ "encryObj" = 0x72636E65, 0x6A624F79
        ldr     r7, [sp, #F_AREA]
        ldmia   r7, {r0, r1}
        mov     r2, #0x72000000
        orr     r2, r2, #0x00630000
        orr     r2, r2, #0x00006E00
        orr     r2, r2, #0x00000065
        mov     r3, #0x6A000000
        orr     r3, r3, #0x00620000
        orr     r3, r3, #0x00004F00
        orr     r3, r3, #0x00000079
        mvn     r4, #0x18000000         @ r4 = 0xE7FFDEFF
        bic     r4, r4, #0x00002100
        mov     r5, r4
        cmp     r0, r2
        cmpeq   r1, r3
        moveq   r0, #0
        stmiaeq r7, {r4, r5}
        beq     4f
        @ not found: fill the area
        mov     r6, r4
        mov     r8, r4
        add     r0, r7, #0x800
3:      stmia   r7!, {r4, r5, r6, r8}
        cmp     r7, r0
        bne     3b
        mov     r0, #1

4:      add     sp, sp, #F_SIZE
        pop     {r4-r11, lr}
        bx      lr
        .size   key1_secure_area, . - key1_secure_area

@ ---- apply_keycode (modulo 2). The keycode is in the caller's frame at sp.
@ Clobbers r0, r1, r7-r12.
        .type   apply_keycode, %function
apply_keycode:
        push    {lr}
        @ encrypt keycode[1..2], then keycode[0..1]
        ldr     r1, [sp, #4 + F_CODE1]
        ldr     r0, [sp, #4 + F_CODE2]
        bl      enc
        str     r0, [sp, #4 + F_CODE1]
        str     r1, [sp, #4 + F_CODE2]
        ldr     r1, [sp, #4 + F_CODE0]
        ldr     r0, [sp, #4 + F_CODE1]
        bl      enc
        str     r0, [sp, #4 + F_CODE0]
        str     r1, [sp, #4 + F_CODE1]

        @ P[i] ^= bswap(keycode[i % 2]), i = 0..17
        .irp    v, r0, r1
        eor     r8, \v, \v, ror #16
        bic     r8, r8, #0x00FF0000
        mov     \v, \v, ror #8
        eor     \v, \v, r8, lsr #8
        .endr
        .irp    o, 0, 8, 16, 24, 32, 40, 48, 56, 64
        ldr     r8, [r2, #\o]
        ldr     r9, [r2, #\o + 4]
        eor     r8, r8, r0
        eor     r9, r9, r1
        str     r8, [r2, #\o]
        str     r9, [r2, #\o + 4]
        .endr

        @ re-key: encrypt a running block from zero, storing it swapped
        @ into each word pair of the key buffer (0x209 pairs)
        mov     r0, #0
        mov     r1, #0
        mov     r7, r2
1:      bl      enc
        str     r1, [r7], #4
        str     r0, [r7], #4
        eor     r0, r0, r1              @ swap: next input lo in r1, hi in r0
        eor     r1, r1, r0
        eor     r0, r0, r1
        add     r8, r2, #0x1000
        add     r8, r8, #0x48
        cmp     r7, r8
        bne     1b
        pop     {lr}
        bx      lr
        .size   apply_keycode, . - apply_keycode

@ ---- one Feistel round. Z holds z = P[i] ^ x; A holds y and becomes
@ F(z) ^ y ^ P[next], i.e. the next round's z (or, after the last round,
@ the first output word).
        .macro  round z, a, pnext
        and     r8, \z, #0xFF000000
        and     r9, \z, #0x00FF0000
        ldr     r8, [r3, r8, lsr #22]
        and     r10, \z, #0x0000FF00
        ldr     r9, [r4, r9, lsr #14]
        and     r11, \z, #0x000000FF
        ldr     r10, [r5, r10, lsr #6]
        ldr     r11, [r6, r11, lsl #2]
        ldr     r12, [r2, #(\pnext)*4]
        add     r8, r8, r9
        eor     r8, r8, r10
        add     r8, r8, r11
        eor     \a, \a, r8
        eor     \a, \a, r12
        .endm

@ ---- enc / dec: one 64-bit block.
@ In:  r1 = low word, r0 = high word.  Out: r0 = low word, r1 = high word
@ (so ldr r1,[p]; ldr r0,[p,#4] ... stmia p,{r0,r1} works in place).
@ Clobbers r8-r12.
        .type   enc, %function
enc:
        ldr     r12, [r2, #0]
        eor     r0, r0, r12
        .irp    i, 0, 2, 4, 6, 8, 10, 12, 14
        round   r0, r1, (\i+1)
        round   r1, r0, (\i+2)
        .endr
        ldr     r12, [r2, #17 * 4]
        eor     r1, r1, r12
        bx      lr
        .size   enc, . - enc

        .type   dec, %function
dec:
        ldr     r12, [r2, #17 * 4]
        eor     r0, r0, r12
        .irp    i, 0, 2, 4, 6, 8, 10, 12, 14
        round   r0, r1, (16-\i)
        round   r1, r0, (15-\i)
        .endr
        ldr     r12, [r2, #0]
        eor     r1, r1, r12
        bx      lr
        .size   dec, . - dec
