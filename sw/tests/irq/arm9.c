/* irq.nds, ARM9: VBlank, timer and IPC-sync IRQs through the BIOS IRQ
   handler (vector 0xFFFF0018 -> handler pointer at DTCM+0x3FFC), with the
   BIOS VBlankIntrWait/IntrWait SWIs (flags at DTCM+0x3FF8). */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"

#define DTCM 0x0B000000u
#define BIOS_IRQ_VECTOR R32(DTCM + 0x3FFC)
#define BIOS_IRQ_FLAGS  R32(DTCM + 0x3FF8)

static volatile u32 vbl, tmr, ipc, ipc_in, mode_seen;

static void irq_handler(void)
{
    u32 f = IF & IE;
    if (f & IRQ_VBLANK) vbl++;
    if (f & IRQ_TIMER(0)) tmr++;
    if (f & IRQ_IPCSYNC) { ipc++; ipc_in = IPCSYNC & 0xF; }
    /* mode and I bit; F is left out: melonDS sets it on IRQ entry, the ARM
       cores leave it unchanged (docs/phase2-integration.md) */
    mode_seen = cpsr_read() & 0xBF;
    IF = f;
    BIOS_IRQ_FLAGS |= f;
}

int main(void)
{
    con_init();
    res_begin("IRQ TEST", 9);

    /* ARM7 may raise the IPC-sync IRQ only after we enable it: output 9
       tells it to start. */
    IPCSYNC = 1 << 14;
    BIOS_IRQ_VECTOR = (u32)irq_handler;
    IF = ~0u;
    IE = IRQ_VBLANK | IRQ_IPCSYNC;
    DISPSTAT = 1 << 3;                 /* VBlank IRQ enable */
    IME = 1;
    irq_enable_cpu();
    IPCSYNC = (1 << 14) | (9 << 8);

    swi_vblankintrwait();
    u32 vc = VCOUNT;
    vbl = 0;
    for (int i = 0; i < 60; i++)
        swi_vblankintrwait();
    res_check(0, "A9VBL60", vbl, 60);
    res_check(1, "A9VCOUNT", vc, 192);

    /* timer 0, F/1024, about 10 ms per overflow; VBlank IRQs keep coming */
    tmr = 0;
    TM_CNT_L(0) = (u16)(0x10000 - 327);
    TM_CNT_H(0) = TM_ENABLE | TM_IRQ | 3;
    IE |= IRQ_TIMER(0);
    for (int i = 0; i < 10; i++)
        swi_intrwait(1, IRQ_TIMER(0));
    TM_CNT_H(0) = 0;
    res_check(2, "A9TIMER", tmr, 10);
    res_check(3, "A9MODE", mode_seen, 0x92);

    /* the ARM7 runs the same tests, raises an IPC-sync IRQ with output 3,
       then reports through the mailbox (ack = 0x7D) */
    WAIT_UNTIL(MB->ack == 0x7D, 240);
    res_check(4, "A7VBL60", MB->val[0], 60);
    res_check(5, "A7VCOUNT", MB->val[1], 192);
    res_check(6, "A7TIMER", MB->val[2], 10);
    res_check(7, "A7MODE", MB->val[3], 0x92);
    res_check(8, "IPCIRQ", (ipc << 4) | ipc_in, 0x13);
    res_finish();

    for (;;) {
        swi_vblankintrwait();
        con_printf(TOP, 0, 15, PAL_YELLOW, "VBLANK IRQS %u", vbl);
    }
}
