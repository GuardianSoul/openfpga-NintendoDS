@ ARM9 loads during a D fill (arm9_mem ERD/HUM): per set, lines X, Y and Z (32 KB multiples apart, so one set in any
@ cache geometry; tb_arm's main RAM mirrors every 256 KB) are read into the cache, then line Z of the same set is read (its fill evicts X or Y) and, right
@ behind it, word 0 of X and of Y: the evicted one's tag still matches until the fill's tag write, so it must
@ wait for the fill instead of hitting (its data RAM is being overwritten with Z's). Then Z's other words.
@ Every word holds its address XOR 0x5A5A5A5A, written through the uncached alias. 32 sets.
@ Exit code 0 = pass, else 0x100 + the set, 0x200 + the set (X), 0x300 + the set (Y), 0x400 + the set (Z words).
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ X,    0x02010000                       @ cached, write-back (region 1)
.equ ALIAS, 0x00400000                      @ + this: the same memory, uncached (region 2)
.equ YOFF, 0x8000                           @ Y = X + YOFF
.equ ZOFF, 0x18000                          @ Z = X + ZOFF
.equ PAT,  0x5A5A5A5A
.global _start
_start:
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE
    @ the three lines of each set, through the alias
    ldr     r0, =X + ALIAS
    ldr     r2, =PAT
    mov     r1, #0                          @ byte offset in the 32 sets' 1 KB
    mov     r6, #YOFF
    mov     r7, #ZOFF
1:  add     r3, r0, r1
    sub     r4, r3, #ALIAS
    eor     r5, r4, r2
    str     r5, [r3]
    add     r4, r4, #YOFF
    eor     r5, r4, r2
    str     r5, [r3, r6]
    add     r4, r4, #ZOFF - YOFF
    eor     r5, r4, r2
    str     r5, [r3, r7]
    add     r1, r1, #4
    cmp     r1, #1024
    bne     1b
    ldr     r8, =X
    ldr     r2, =PAT
    mov     r4, #0                          @ set
2:  add     r9, r8, r4, lsl #5              @ X of this set
    add     r10, r9, #YOFF                  @ Y
    add     r11, r9, #ZOFF                  @ Z
    ldr     r3, [r9, #4]                    @ X and Y into the cache
    ldr     r3, [r10, #4]
    ldr     r5, [r11, #8]                   @ Z word 2: answered while the fill runs on (ERD)
    ldr     r6, [r9]                        @ X word 0, Y word 0 right behind it
    ldr     r7, [r10]
    add     r3, r11, #8
    eor     r3, r3, r2
    cmp     r5, r3
    bne     bad1
    eor     r3, r9, r2
    cmp     r6, r3
    bne     bad2
    eor     r3, r10, r2
    cmp     r7, r3
    bne     bad3
    mov     r1, #0                          @ Z's words
3:  ldr     r5, [r11, r1]
    add     r3, r11, r1
    eor     r3, r3, r2
    cmp     r5, r3
    bne     bad4
    add     r1, r1, #4
    cmp     r1, #32
    bne     3b
    add     r4, r4, #1
    cmp     r4, #32
    bne     2b
    mov     r0, #0
    ldr     r1, =EXIT
    str     r0, [r1]
4:  b       4b
bad1:
    add     r0, r4, #0x100
    b       9f
bad2:
    add     r0, r4, #0x200
    b       9f
bad3:
    add     r0, r4, #0x300
    b       9f
bad4:
    add     r0, r4, #0x400
9:  ldr     r1, =EXIT
    str     r0, [r1]
5:  b       5b
