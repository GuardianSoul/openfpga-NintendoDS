@ Directed test for the ARM9 memory system: caches, MPU, TCMs, CP15
@ maintenance. Runs on the ARM9 context from 0x02000000. Uses the map in
@ cp15.inc; 0x02400000 + x shows main RAM at x without the cache, which is
@ how the test sees what has actually reached memory. Exit code 0 = pass,
@ else the failing step (r11).
.syntax unified
.arm
.include "cp15.inc"
.equ EXIT, 0x0F000000
.equ IRQLINE, 0x0F000004
.equ UNC, 0x00400000                        @ offset to the uncached mirror
.equ WBDATA, 0x02010000                     @ write-back data area
.equ WTDATA, 0x02020000                     @ write-through page
.equ PRIV, 0x02030000
.equ RO, 0x02031000
.equ NOACC, 0x02032000
.equ DTCM, 0x0B000000
.global _start
_start:
    mov     r11, #0
    msr     cpsr_c, #0xD7                   @ ABT stack
    ldr     sp, =0x020F8000
    msr     cpsr_c, #0xD3
    ldr     sp, =0x020FC000

    @ 1: ITCM on (MPU still off): copy the vectors to 0, run code from it.
    @ First, an MSR of only the flags of a never-written SPSR: its control
    @ byte reads 0
    mov     r11, #1
    msr     spsr_f, #0xF0000000
    mrs     r0, spsr
    cmp     r0, #0xF0000000
    bne     fail
    CP15_REGIONS
    ldr     r0, =0x00040078                 @ ITCM only
    mcr     p15, 0, r0, c1, c0, 0
    ldr     r1, =vectors
    mov     r2, #0
    mov     r3, #16
1:  ldr     r4, [r1], #4
    str     r4, [r2], #4
    subs    r3, r3, #1
    bne     1b
    ldr     r1, =itcm_fn                    @ a small function into ITCM at 0x1000
    mov     r2, #0x1000
    ldmia   r1, {r4-r7}
    stmia   r2, {r4-r7}
    mov     lr, pc
    mov     pc, #0x1000                     @ returns r0 = 0x1234
    ldr     r1, =0x1234
    cmp     r0, r1
    bne     fail
    ldr     r0, [r2]                        @ data read back from the ITCM
    cmp     r0, r4
    bne     fail

    @ 2: everything on; the code keeps running (now from the I-cache)
    mov     r11, #2
    CP15_ENABLE
    mrc     p15, 0, r0, c1, c0, 0
    ldr     r1, =CP15_CTRL_ON
    cmp     r0, r1
    bne     fail
    mrc     p15, 0, r0, c0, c0, 0           @ main ID
    ldr     r1, =0x41059461
    cmp     r0, r1
    bne     fail
    mrc     p15, 0, r0, c6, c3, 0           @ region 3 reads back
    ldr     r1, =0x02020017
    cmp     r0, r1
    bne     fail

    @ 3: write-back: a store hit stays in the cache until the line is cleaned
    mov     r11, #3
    ldr     r4, =WBDATA
    ldr     r5, =WBDATA + UNC
    mov     r0, #0x11
    str     r0, [r5]                        @ memory = 0x11 (uncached)
    ldr     r1, [r4]                        @ allocates the line
    cmp     r1, #0x11
    bne     fail
    mov     r0, #0x22
    str     r0, [r4]                        @ hit: cache only
    ldr     r1, [r4]
    cmp     r1, #0x22
    bne     fail
    ldr     r1, [r5]                        @ memory still old
    cmp     r1, #0x11
    bne     fail
    mcr     p15, 0, r4, c7, c10, 1          @ clean the line
    mcr     p15, 0, r0, c7, c10, 4          @ drain the write buffer
    ldr     r1, [r5]
    cmp     r1, #0x22
    bne     fail

    @ 4: write-through: memory sees the store at once
    mov     r11, #4
    ldr     r4, =WTDATA
    ldr     r5, =WTDATA + UNC
    ldr     r1, [r4]                        @ allocate
    mov     r0, #0x33
    strb    r0, [r4, #1]
    mcr     p15, 0, r0, c7, c10, 4          @ drain
    ldr     r1, [r5]
    and     r1, r1, #0xFF00
    cmp     r1, #0x3300
    bne     fail
    ldrb    r1, [r4, #1]                    @ and the cached copy has it too
    cmp     r1, #0x33
    bne     fail

    @ 5: invalidate: a stale line until invalidated
    mov     r11, #5
    ldr     r4, =WBDATA + 0x40
    ldr     r5, =WBDATA + 0x40 + UNC
    mov     r0, #0x44
    str     r0, [r5]
    ldr     r1, [r4]                        @ cache has 0x44
    mov     r0, #0x55
    str     r0, [r5]                        @ memory changes behind the cache
    ldr     r1, [r4]
    cmp     r1, #0x44
    bne     fail
    mcr     p15, 0, r4, c7, c6, 1           @ invalidate the line
    ldr     r1, [r4]
    cmp     r1, #0x55
    bne     fail

    @ 6: a dirty line is written back when the set overflows (4 ways): eight
    @ dirty lines in one set evict the first whatever else shares the set
    mov     r11, #6
    ldr     r4, =WBDATA + 0x100             @ lines in one set, 1 KB apart
    mov     r6, #0
2:  add     r7, r4, r6, lsl #10
    ldr     r1, [r7]                        @ allocate
    add     r0, r6, #0x60
    str     r0, [r7]                        @ dirty
    add     r6, r6, #1
    cmp     r6, #8
    bne     2b
    ldr     r5, =WBDATA + 0x100 + UNC       @ the first line was evicted: in memory now
    ldr     r1, [r5]
    cmp     r1, #0x60
    bne     fail
    mov     r6, #0                          @ all eight still read back right
3:  add     r7, r4, r6, lsl #10
    ldr     r1, [r7]
    add     r0, r6, #0x60
    cmp     r1, r0
    bne     fail
    add     r6, r6, #1
    cmp     r6, #8
    bne     3b

    @ 7: self-modifying code needs an I-cache invalidate
    mov     r11, #7
    ldr     r4, =WBDATA + 0x800
    ldr     r1, =smc_fn
    ldmia   r1, {r2, r3}                    @ mov r0, #1 / bx lr
    stmia   r4, {r2, r3}
    mcr     p15, 0, r4, c7, c10, 1          @ clean so the I side can see it
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r4, c7, c5, 1           @ invalidate the I line
    mov     lr, pc
    bx      r4
    cmp     r0, #1
    bne     fail
    ldr     r2, =0xE3A00002                 @ mov r0, #2
    str     r2, [r4]
    mcr     p15, 0, r4, c7, c10, 1
    mcr     p15, 0, r0, c7, c10, 4
    mov     lr, pc
    bx      r4                              @ still the old code from the I-cache
    cmp     r0, #1
    bne     fail
    mcr     p15, 0, r4, c7, c5, 1
    mov     lr, pc
    bx      r4
    cmp     r0, #2
    bne     fail

    @ 8: clean and invalidate the whole D-cache by set/way (DC_FlushAll)
    mov     r11, #8
    ldr     r4, =WBDATA + 0x200
    mov     r0, #0x77
    ldr     r1, [r4]
    str     r0, [r4]                        @ dirty
    ldr     r1, [r4, #0x400]                @ and one in the upper half of the sets
    str     r0, [r4, #0x400]                @ of a 2-way cache (address bit 10)
    mov     r1, #0                          @ way
4:  mov     r2, #0                          @ set
5:  orr     r3, r2, r1
    mcr     p15, 0, r3, c7, c14, 2
    add     r2, r2, #0x20
    cmp     r2, #0x400
    bne     5b
    adds    r1, r1, #0x40000000
    bne     4b
    ldr     r5, =WBDATA + 0x200 + UNC
    ldr     r1, [r5]
    cmp     r1, #0x77
    bne     fail
    ldr     r1, [r5, #0x400]
    cmp     r1, #0x77
    bne     fail

    @ 9: MPU: user mode cannot touch the privileged page, nobody writes the
    @ read-only one; data aborts come back with LR = PC + 8
    mov     r11, #9
    ldr     r4, =PRIV
    ldr     r1, [r4]                        @ privileged: fine
    mov     r8, #0
    msr     cpsr_c, #0xD0                   @ User
    ldr     r1, [r4]                        @ aborts
    cmp     r8, #1
    bne     fail
    mrs     r0, cpsr                        @ the handler returned to User mode
    and     r0, r0, #0x1F
    cmp     r0, #0x10
    bne     fail
    ldr     r4, =RO
    ldr     r1, [r4]                        @ fine
    str     r1, [r4]                        @ aborts
    cmp     r8, #2
    bne     fail
    swi     #0                              @ back to SVC
    cmp     r8, #3
    bne     fail

    @ 10: a jump into a no-access region takes the prefetch abort
    mov     r11, #10
    ldr     r4, =NOACC
    adr     lr, pabt_back
    bx      r4
pabt_back:
    cmp     r8, #4
    bne     fail

    @ 11: DTCM: data at the DTCM base, then the base moves
    mov     r11, #11
    ldr     r4, =DTCM
    ldr     r0, =0xCAFE0001
    str     r0, [r4, #0x10]
    ldr     r1, [r4, #0x10]
    cmp     r1, r0
    bne     fail
    ldr     r2, =0x0C00000A                 @ DTCM to 0x0C000000
    mcr     p15, 0, r2, c9, c1, 0
    ldr     r5, =0x0C000000
    ldr     r1, [r5, #0x10]                 @ same data at the new base
    cmp     r1, r0
    bne     fail
    ldr     r1, [r4, #0x10]                 @ the old base is plain memory again
    cmp     r1, r0
    beq     fail

    @ 12: WFI with an interrupt pending returns at once (I masked)
    mov     r11, #12
    ldr     r2, =IRQLINE
    mov     r1, #1
    str     r1, [r2]
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r0, c7, c0, 4           @ wait for interrupt
    mov     r1, #0
    str     r1, [r2]

    @ 13: back-to-back stores to two ways of one set, and a load right
    @ after a store: both dirty bits survive, the load sees the store
    mov     r11, #13
    ldr     r4, =WBDATA + 0x1A0             @ two lines in one set
    add     r5, r4, #0x400
    ldr     r1, [r4]                        @ allocate both
    ldr     r1, [r5]
    mov     r0, #0x91
    mov     r1, #0x92
    str     r0, [r4]
    str     r1, [r5]
    ldr     r2, [r5]
    cmp     r2, #0x92
    bne     fail
    mcr     p15, 0, r4, c7, c10, 1          @ clean both
    mcr     p15, 0, r5, c7, c10, 1
    mcr     p15, 0, r0, c7, c10, 4
    ldr     r6, =UNC
    ldr     r2, [r4, r6]
    cmp     r2, #0x91
    bne     fail
    ldr     r2, [r5, r6]
    cmp     r2, #0x92
    bne     fail

    @ 14: a line still in the cache is not used once its region is made
    @ uncacheable: the load goes to memory
    mov     r11, #14
    ldr     r4, =WBDATA + 0x300
    ldr     r5, =WBDATA + 0x300 + UNC
    mov     r0, #0xA1
    str     r0, [r5]
    ldr     r1, [r4]                        @ cached: 0xA1
    mov     r0, #0xA2
    str     r0, [r5]                        @ memory changes behind the cache
    mov     r0, #0x88                       @ D cacheable: r3, r7 (not r1)
    mcr     p15, 0, r0, c2, c0, 0
    ldr     r1, [r4]
    mov     r0, #0x8A
    mcr     p15, 0, r0, c2, c0, 0
    mcr     p15, 0, r4, c7, c6, 1           @ drop the stale line
    cmp     r1, #0xA2
    bne     fail

    @ 15: round-robin replacement: four dirty lines in one fresh set take the
    @ four ways (none written back yet); a fifth evicts the oldest only
    mov     r11, #15
    ldr     r4, =WBDATA + 0x2C0
    ldr     r5, =UNC
    mov     r6, #0
6:  add     r7, r4, r6, lsl #10
    ldr     r1, [r7]                        @ allocate
    add     r0, r6, #0x70
    str     r0, [r7]                        @ dirty
    add     r6, r6, #1
    cmp     r6, #4
    bne     6b
    mov     r6, #0
7:  add     r7, r4, r6, lsl #10
    ldr     r1, [r7, r5]                    @ memory: not written back yet
    add     r0, r6, #0x70
    cmp     r1, r0
    beq     fail
    add     r6, r6, #1
    cmp     r6, #4
    bne     7b
    add     r7, r4, #0x1000                 @ a fifth line in the set
    ldr     r1, [r7]
    ldr     r1, [r4, r5]                    @ the first line went back
    cmp     r1, #0x70
    bne     fail
    add     r7, r4, #0x400
    ldr     r1, [r7, r5]                    @ the second did not
    cmp     r1, #0x71
    beq     fail

    @ 16: an I-cache line invalidate clears only that line: a second line of
    @ the same set (2 KB apart) stays stale
    mov     r11, #16
    ldr     r4, =WBDATA + 0xC00
    add     r5, r4, #0x800
    ldr     r1, =smc_fn
    ldmia   r1, {r2, r3}                    @ mov r0, #1 / bx lr
    stmia   r4, {r2, r3}
    stmia   r5, {r2, r3}
    mcr     p15, 0, r4, c7, c10, 1
    mcr     p15, 0, r5, c7, c10, 1
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r4, c7, c5, 1
    mcr     p15, 0, r5, c7, c5, 1
    mov     lr, pc
    bx      r4                              @ both lines now in the I-cache
    mov     lr, pc
    bx      r5
    ldr     r2, =0xE3A00002                 @ mov r0, #2 into both
    str     r2, [r4]
    str     r2, [r5]
    mcr     p15, 0, r4, c7, c10, 1
    mcr     p15, 0, r5, c7, c10, 1
    mcr     p15, 0, r0, c7, c10, 4
    mcr     p15, 0, r4, c7, c5, 1           @ invalidate the first only
    mov     lr, pc
    bx      r4
    cmp     r0, #2
    bne     fail
    mov     lr, pc
    bx      r5                              @ still the old code
    cmp     r0, #1
    bne     fail

    @ 17: CP15 read-back of the TCM regions, lockdown and c13
    mov     r11, #17
    ldr     r0, =0x0C0000CB                 @ the same DTCM region, with bits 7:6
    mcr     p15, 0, r0, c9, c1, 0           @ and 0 set (they read back as 0)
    mrc     p15, 0, r0, c9, c1, 0
    ldr     r1, =0x0C00000A
    cmp     r0, r1
    bne     fail
    mrc     p15, 0, r0, c9, c1, 1           @ ITCM: size only
    cmp     r0, #0x0C
    bne     fail
    ldr     r0, =0x12345678
    mcr     p15, 0, r0, c9, c0, 0           @ D lockdown
    ldr     r0, =0x9ABCDEF0
    mcr     p15, 0, r0, c9, c0, 1           @ I lockdown
    ldr     r0, =0x0F00BA00
    mcr     p15, 0, r0, c13, c0, 1          @ process ID
    mrc     p15, 0, r1, c9, c0, 0
    ldr     r2, =0x12345678
    cmp     r1, r2
    bne     fail
    mrc     p15, 0, r1, c9, c0, 1
    ldr     r2, =0x9ABCDEF0
    cmp     r1, r2
    bne     fail
    mrc     p15, 0, r1, c13, c0, 1
    cmp     r1, r0
    bne     fail
    mrc     p15, 0, r1, c6, c7, 0           @ region 7 still reads back
    ldr     r2, =0x08000031
    cmp     r1, r2
    bne     fail

    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .

fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .

@ ---- copied to 0: vectors
vectors:
    b       fail                            @ 0x00 (unused)
    b       fail
    ldr     pc, [pc, #24]                   @ 0x08 SWI
    ldr     pc, [pc, #24]                   @ 0x0C prefetch abort
    ldr     pc, [pc, #24]                   @ 0x10 data abort
    b       fail
    b       fail
    b       fail
    .word   0, 0
    .word   swi_handler, pabt_handler, dabt_handler, 0, 0, 0

swi_handler:                                @ back to SVC with mode kept
    mov     r8, #3
    bx      lr
pabt_handler:
    mrs     r0, cpsr
    and     r0, r0, #0x1F
    cmp     r0, #0x17
    bne     fail
    ldr     r0, =NOACC + 4                  @ LR = faulting PC + 4
    cmp     lr, r0
    bne     fail
    mov     r8, #4
    msr     cpsr_c, #0xD3
    ldr     pc, =pabt_back
dabt_handler:
    mrs     r0, cpsr
    and     r0, r0, #0x1F
    cmp     r0, #0x17
    bne     fail
    add     r8, r8, #1
    subs    pc, lr, #4                      @ to the instruction after the abort

@ ---- copied into the ITCM
itcm_fn:
    ldr     r0, [pc, #0]
    bx      lr
    .word   0x1234
    .word   0

@ ---- copied into main RAM and modified
smc_fn:
    mov     r0, #1
    bx      lr
.ltorg
