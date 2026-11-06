/* hello.nds, ARM9: both screens of text by polling (no IRQs). */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

int main(void)
{
    con_init();
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    res_begin("HELLO DS", 5);
    con_puts(BOTTOM, 0, 0, PAL_YELLOW, "BOTTOM");
    con_puts(BOTTOM, 0, 1, PAL_WHITE, "ENGINE B, VRAM BANK C");

    /* 0: the word the ARM7 sent through the IPC FIFO */
    u32 v = 0;
    if (WAIT_UNTIL(!(IPCFIFOCNT & FIFO_RECV_EMPTY), 60))
        v = IPCFIFORECV;
    res_check(0, "FIFO7TO9", v, 0x1234ABCD);

    /* 1: highest VCOUNT over a frame (263 lines: 0..262) */
    wait_vblank();
    u32 maxv = 0;
    for (;;) {
        u32 l = VCOUNT;
        if (l > maxv) maxv = l;
        if (l == 0 && maxv > 200) break;
    }
    res_check(1, "VCOUNTMX", maxv, 262);

    /* 2: POWCNT1 read back */
    res_check(2, "POWCNT1", POWCNT1, 0x8203);

    /* 3: DISPSTAT VBlank flag: rising edges during 10 frames */
    u32 edges = 0, last;
    while (VCOUNT != 100) ;
    last = DISPSTAT & 1;
    for (int f = 0; f < 10; f++) {
        do { u32 b = DISPSTAT & 1; if (b && !last) edges++; last = b; } while (VCOUNT == 100);
        do { u32 b = DISPSTAT & 1; if (b && !last) edges++; last = b; } while (VCOUNT != 100);
    }
    res_check(3, "VBLFLAG", edges, 10);

    /* 4: where the ARM7 runs (its _start, reported through the mailbox) */
    a7_wait_ready();
    res_check(4, "ARM7BASE", MB->val[0], A7BASE);
    res_finish();

    con_printf(TOP, 0, 11, PAL_WHITE, "IPC FIFO FROM ARM7: %08X", v);
    con_printf(TOP, 0, 12, PAL_WHITE, "ARM7 RUNS AT %08X", MB->val[0]);
    con_puts(BOTTOM, 0, 3, PAL_GREEN, "0123456789 !\"#$%&'()*+,-./:;<=>?");
    con_puts(BOTTOM, 0, 4, PAL_GREEN, "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_");
    for (u32 frame = 0;; frame++) {
        wait_vblank();
        con_printf(TOP, 0, 10, PAL_YELLOW, "FRAME %u", frame);
        con_printf(BOTTOM, 0, 2, PAL_YELLOW, "FRAME %08X", frame);
    }
}
