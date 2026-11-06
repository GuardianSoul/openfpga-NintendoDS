/* SPDX-License-Identifier: MIT
 * SERV's boot code (core_top_ds SHELL_CPU 2): the APF command protocol that
 * core_bridge_cmd_lean ran in logic, from power-up, on the mailbox
 * (rtl/pocket/nds_mbox.sv: host words at 64, target words at 96). Once the
 * APF reports all slots loaded and the SDRAM is ready, it starts the ROM
 * cache's firmware (cache.c, from nds_boot.bin in SDRAM), which calls host()
 * for every later host command. No static data: the mailbox is the memory.
 */
typedef unsigned int u32;
#define IO(r)   (*(volatile u32 *)(0x80000000u + 4u * (r)))
#define MB(w)   (*(volatile u32 *)(0xC0000000u + 4u * (w)))
#define HOST    64                  /* host command/status; parameters at 72, response at 80 */
#define TARGET  96
#define ALLC    99                  /* (mailbox words the APF does not use) all slots loaded */
#define RTCW    100                 /* the RTC was set (the first RTC command only) */

void host(void)
{
    u32 c = MB(HOST) & 0xFFFFu, code = 0;
    MB(HOST) = 0x42550000u | c;
    switch (c) {
    case 0x0000: code = 3; break;                               /* idle (boot and setup done) */
    case 0x0080:                                                /* data slot request read (the save, nds_save_read) */
        MB(ALLC) = 0;
        IO(15) = MB(HOST + 8) & 0xFFFFu;
        IO(10) = 1;
        while (!(IO(5) & 4)) ;
        IO(10) = 0;
        break;
    case 0x0082:                                                /* data slot request write: once the SDRAM is ready */
        MB(ALLC) = 0;
        while (!(IO(5) & 8)) ;
        break;
    case 0x008F: MB(ALLC) = 1; break;
    case 0x0090:                                                /* the RTC: the first date and time only */
        if (!MB(RTCW)) { IO(11) = MB(HOST + 9); IO(12) = MB(HOST + 10); IO(10) = 1u << 8; MB(RTCW) = 1; }
        break;
    case 0x00A0: case 0x00A4:                                   /* save states: not supported */
        MB(HOST + 16) = 0; MB(HOST + 17) = 0; MB(HOST + 18) = 0;
        break;
    case 0x0010: case 0x0011: case 0x008A: case 0x00B0: break;
    default: code = 0xFFFFu;
    }
    MB(HOST) = 0x4F4B0000u | code;
}

void boot_main(void)
{
    MB(TARGET) = 0x636D0140u;                                   /* ready to run (core_bridge_cmd's setup done) */
    for (;;) {
        (void)IO(3);                                            /* waits for an event */
        u32 sh = IO(5);
        if (sh & 1) { IO(6) = 1u << 10; host(); }
        if (sh & 2) IO(6) = 1u << 11;                           /* the APF's answer to ready-to-run */
        if (MB(ALLC)) {
            while (!(IO(5) & 8)) ;
            __asm__ volatile ("jr zero");                       /* the ROM cache's firmware at 0 (sw/scpu/cache.c) */
        }
    }
}
