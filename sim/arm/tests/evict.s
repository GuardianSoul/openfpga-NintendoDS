@ ARM9 dirty-line evictions (a write-back cache allocates on reads only: each word is read, then stored) (arm9_mem EVB): 10 KB of distinct words written through the write-back D-cache
@ (every line is evicted dirty many times over), then 8 KB read from elsewhere to push the last dirty lines
@ out, then every word compared through the uncached alias of the same memory. Exit code 0 = pass, else
@ 0x100 + the failing word.
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ BUF,  0x02010000                       @ cached, write-back (region 1)
.equ ALIAS, 0x02410000                      @ the same memory, uncached (region 2)
.equ OTHER, 0x02050000
.equ BUF2, 0x02060000                      @ cached: 40 lines + the set's other ways (1 KB strides)
.equ ALIAS2, 0x02460000                     @ its uncached alias
.equ FAR,  0x02090000                       @ other lines to read
.equ N,    2560                             @ words (10 KB, more than twice the D-cache)
.global _start
_start:
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000
    CP15_REGIONS
    CP15_ENABLE
    ldr     r0, =BUF
    ldr     r2, =0x9E3779B9
    mov     r1, #0
1:  ldr     r5, [r0, r1, lsl #2]            @ (a store miss does not allocate: read first, then the store dirties the line)
    str     r2, [r0, r1, lsl #2]
    add     r2, r2, r2, ror #7
    eor     r2, r2, r1
    add     r1, r1, #1
    ldr     r3, =N
    cmp     r1, r3
    bne     1b
    @ push the last dirty lines out: read 6 KB elsewhere
    ldr     r4, =OTHER
    mov     r1, #0
2:  ldr     r3, [r4, r1, lsl #2]
    add     r1, r1, #1
    cmp     r1, #1536
    bne     2b
    @ compare through the alias
    ldr     r0, =ALIAS
    ldr     r2, =0x9E3779B9
    mov     r1, #0
3:  ldr     r3, [r0, r1, lsl #2]
    cmp     r3, r2
    bne     bad
    add     r2, r2, r2, ror #7
    eor     r2, r2, r1
    add     r1, r1, #1
    ldr     r3, =N
    cmp     r1, r3
    bne     3b
    @ 4. the four lines of one set are made dirty; four other lines of the set are read (each fill evicts one
    @ dirty line, round-robin); right after each fill the four lines are read through the uncached alias:
    @ the evicted ones must already show their data (a read of an evicted line waits for the drain), so
    @ after fill j exactly j + 1 of them do. 32 sets.
    ldr     r8, =BUF2
    ldr     r9, =ALIAS2
    mov     r4, #0
6:  add     r11, r8, r4, lsl #5             @ the set's first line (the lines of a set are 1 KB apart)
    add     r12, r9, r4, lsl #5
    mov     r1, #0
7:  ldr     r5, [r11, r1, lsl #10]          @ allocate
    orr     r2, r1, r4, lsl #8
    orr     r2, r2, #0x5A000000
    str     r2, [r11, r1, lsl #10]          @ dirty
    add     r1, r1, #1
    cmp     r1, #4
    bne     7b
    mov     r3, #0
8:  add     r6, r3, #4
    ldr     r5, [r11, r6, lsl #10]          @ fill another line of the set: evicts one dirty line
    mov     r7, #0
    mov     r1, #0
9:  ldr     r5, [r12, r1, lsl #10]          @ the alias read, at once
    orr     r2, r1, r4, lsl #8
    orr     r2, r2, #0x5A000000
    cmp     r5, r2
    addeq   r7, r7, #1
    add     r1, r1, #1
    cmp     r1, #4
    bne     9b
    add     r6, r3, #1
    cmp     r7, r6
    bne     bad4
    add     r3, r3, #1
    cmp     r3, #4
    bne     8b
    add     r4, r4, #1
    cmp     r4, #32
    bne     6b
    mov     r0, #0
    ldr     r1, =EXIT
    str     r0, [r1]
4:  b       4b
bad4:
    add     r0, r4, #0x400
    ldr     r1, =EXIT
    str     r0, [r1]
8:  b       8b
bad:
    add     r0, r1, #0x100
    ldr     r1, =EXIT
    str     r0, [r1]
5:  b       5b
