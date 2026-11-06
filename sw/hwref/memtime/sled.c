// memtime: the main-RAM NOP sled (normal .text, cacheable by the I-cache),
// ARM state. mt_ifetch() enters it n NOPs before its bx lr.
__asm__(".section .text.mt_sled_main, \"ax\", %progbits\n.arm\n.align 5\n"
	".global mt_sled_main\n.type mt_sled_main, %function\nmt_sled_main:\n"
	".rept 1024\nnop\n.endr\nbx lr\n.size mt_sled_main, . - mt_sled_main\n"
	".thumb\n.previous\n");
