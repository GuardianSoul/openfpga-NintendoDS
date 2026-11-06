/* SERV's window (rtl/pocket/nds_cart_scpu.sv): 16 KiB at 0, code first */
ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { *(.text.start) *(.text*) }
    .rodata : { *(.rodata*) *(.srodata*) }
    .data : { *(.data*) *(.sdata*) }
    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss*) *(.sbss*) *(COMMON) }
    . = ALIGN(4);
    __bss_end = .;
}
