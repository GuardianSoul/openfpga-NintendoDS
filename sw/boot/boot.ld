/* Boot ROM (rtl/ds nds_top u_boot): position independent, linked at 0. */
SECTIONS
{
    . = 0;
    .text : { *(.text.vectors) *(.text*) *(.rodata*) }
    /DISCARD/ : { *(.ARM.attributes) *(.comment) *(.ARM.exidx*) }
}
