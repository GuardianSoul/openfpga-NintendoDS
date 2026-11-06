# SERV's boot code in the mailbox (rtl/pocket/nds_mbox.sv words 128-255, core_top_ds SHELL_CPU 2)
    .section .text.start
    .global _start
_start:
    j       boot_entry              # 0xC0000200: reset
    j       host                    # 0xC0000204: the host command handler (the ROM cache's firmware calls it)
boot_entry:
    li      sp, 0xC0000400          # the stack: the mailbox's last words
    call    boot_main
1:  j       1b
