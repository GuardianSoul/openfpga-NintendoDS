@ Branch prediction and Thumb BL pairs resolved in PD. Checks results, and
@ the test's cycle limit in run_tests.py checks that the direction
@ predictor and the PD BL redirect actually work (each loop below costs
@ hundreds of slots more without them). Built for the ARM7 (ARMv4T) and,
@ with V5 and CACHED, for the ARM9, where it also runs BLX both ways.
@ Exit code 0 = pass, else the failing step (r11).
.syntax unified
.arm
.equ EXIT, 0x0F000000
.include "cp15.inc"
.global _start
_start:
.ifdef CACHED
    CP15_REGIONS
    CP15_ENABLE
.endif
    ldr     sp, =0x02010000
    mov     r11, #0

    @ 1: a BL prefix on the wrong path of a redirect, with the redirect
    @ landing on a lone BL suffix: the suffix must branch to LR + its offset,
    @ not to the wrong-path prefix's value. The prefix is the last halfword
    @ of a cache line and the suffix the first of the next; on the cached
    @ ARM9 the suffix's fetch misses, so the POP's PC load redirects while
    @ the prefix has passed PD and the suffix has not.
    mov     r11, #1
    ldr     r0, =t_kill + 1
    bx      r0
.thumb
.balign 4
t_kill:
    ldr     r0, =t_kill_ok - 16             @ suffix offset 8: target LR + 16
    mov     lr, r0
    ldr     r0, =1f + 1
    push    {r0}
    sub     sp, #28
    ldr     r2, [sp]                        @ the POP's loads hit (no replay)
    ldr     r2, [sp, #28]
    b       2f
.balign 32
    .space  28
2:  pop     {r1-r7, pc}                     @ to the suffix below
    .hword  0xF000                          @ BL prefix (wrong path): LR = here + 4
1:  .hword  0xF808                          @ BL suffix (next line): to LR + 16
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail
    b       t_fail                          @ prefix + 4 + 16 lands here
    b       t_fail
t_kill_ok:
    ldr     r0, =a_loops
    bx      r0
t_fail:
    ldr     r0, =fail
    bx      r0
.ltorg

.arm
.balign 4
    @ 2: ARM loop with a forward branch taken 3 times in 4
a_loops:
    mov     r11, #2
    mov     r0, #0
    mov     r2, #0
1:  tst     r0, #3
    bne     2f
    add     r2, r2, #1
2:  add     r0, r0, #1
    cmp     r0, #400
    blt     1b
    cmp     r2, #100
    bne     fail

    @ 3: Thumb loop: forward branch taken 3 times in 4, and a BL call
    mov     r11, #3
    ldr     r0, =t_loop + 1
    bx      r0
.thumb
.balign 4
t_loop:
    movs    r0, #0
    movs    r2, #0
    movs    r3, #0
1:  movs    r1, #3
    tst     r0, r1
    bne     2f
    adds    r2, r2, #1
2:  bl      t_inc3
    adds    r0, r0, #1
    cmp     r0, #200
    blt     1b
    cmp     r2, #50
    bne     t_fail
    ldr     r1, =600
    cmp     r3, r1
    bne     t_fail
.ifdef V5
    @ 4: BLX from Thumb to ARM and back
    movs    r3, #0
    movs    r0, #0
3:  blx     a_inc5
    adds    r0, r0, #1
    cmp     r0, #50
    blt     3b
    cmp     r3, #250
    bne     t_fail
.endif
    ldr     r0, =a_done
    bx      r0

t_inc3:
    adds    r3, r3, #3
    bx      lr
.ltorg

.arm
.balign 4
.ifdef V5
a_inc5:
    mrs     r1, cpsr                        @ in ARM state after the BLX
    tst     r1, #0x20
    bne     fail
    add     r3, r3, #5
    bx      lr
.endif

a_done:
    ldr     r2, =EXIT
    mov     r1, #0
    str     r1, [r2]
    b       .

fail:
    ldr     r2, =EXIT
    str     r11, [r2]
    b       .
.ltorg
