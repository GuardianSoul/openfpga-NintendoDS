ENTRY(_start)
SECTIONS {
 . = 0x02300000;
 .text : { *(.boot) *(.text*) }
 .rodata : { *(.rodata*) }
 .data : { *(.data*) }
 .bss : { *(.bss*) *(COMMON) }
 /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment*) }
 __end = .;
 ASSERT(__end < 0x023d0000, "adapter overlaps final MAIN dump")
}
