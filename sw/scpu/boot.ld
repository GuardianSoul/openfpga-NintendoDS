/* SERV's boot code: mailbox words 128-255 (0xC0000200-0xC00003FF), the stack at their top */
ENTRY(_start)
SECTIONS {
    . = 0xC0000200;
    .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) }
    __end = .;
    ASSERT(__end <= 0xC00003E0, "boot code over 480 bytes (its stack frame needs the rest)")
    /DISCARD/ : { *(.data*) *(.sdata*) *(.bss*) *(.sbss*) *(COMMON) }
}
