# SERV start-up (sw/scpu): stack at the top of the 16 KiB window, .bss cleared, main
    .section .text.start
    .global _start
_start:
    li      sp, 0x4000
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
3:  j       3b
