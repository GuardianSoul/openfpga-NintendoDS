/* Linker script for both CPUs. The load address comes from
   --defsym=__base=ADDR (ARM9 0x02000000; ARM7 0x037F8000 or 0x02380000).
   .iwram (ARM7 only) runs at 0x0380C000 and is copied there by crt0. */
ENTRY(_start)
SECTIONS
{
    . = __base;
    .text : { KEEP(*(.crt0)) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }
    . = ALIGN(4);
    __iwram_lma = .;
    .iwram 0x0380C000 : AT(__iwram_lma) {
        __iwram_start = .;
        *(.iwram .iwram.*)
        . = ALIGN(4);
        __iwram_end = .;
    }
    . = __iwram_lma + SIZEOF(.iwram);
    __load_end = .;
    .bss (NOLOAD) : { __bss_start = .; *(.bss .bss.* COMMON) . = ALIGN(4); __bss_end = .; }
    __end = .;
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) *(.comment) }
}
/* An ARM7 image in shared WRAM (0x037F8000) must stay below 0x0380C000. */
ASSERT(__base < 0x03000000 || __end <= 0x0380C000, "ARM7 image overlaps .iwram/stacks")
ASSERT(__base >= 0x03000000 || __end <= 0x023F0000, "image overlaps the result block")
