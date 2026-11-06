/* irq.nds, ARM7: the same IRQ tests through the ARM7 BIOS (handler
   pointer at 0x0380FFFC, IntrWait flags at 0x0380FFF8). */
#include "../common/ds.h"
#include "../common/ipc.h"

#define BIOS_IRQ_VECTOR R32(0x0380FFFC)
#define BIOS_IRQ_FLAGS  R32(0x0380FFF8)

static volatile u32 vbl, tmr, mode_seen;

static void irq_handler(void)
{
    u32 f = IF & IE;
    if (f & IRQ_VBLANK) vbl++;
    if (f & IRQ_TIMER(0)) tmr++;
    mode_seen = cpsr_read() & 0xBF;    /* F left out, see arm9.c */
    IF = f;
    BIOS_IRQ_FLAGS |= f;
}

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    while ((IPCSYNC & 0xF) != 9)
        ;
    BIOS_IRQ_VECTOR = (u32)irq_handler;
    IF = ~0u;
    IE = IRQ_VBLANK;
    DISPSTAT = 1 << 3;
    IME = 1;
    irq_enable_cpu();

    swi_vblankintrwait();
    u32 vc = VCOUNT;
    vbl = 0;
    for (int i = 0; i < 60; i++)
        swi_vblankintrwait();
    MB->val[0] = vbl;
    MB->val[1] = vc;

    tmr = 0;
    TM_CNT_L(0) = (u16)(0x10000 - 327);
    TM_CNT_H(0) = TM_ENABLE | TM_IRQ | 3;
    IE |= IRQ_TIMER(0);
    for (int i = 0; i < 10; i++)
        swi_intrwait(1, IRQ_TIMER(0));
    TM_CNT_H(0) = 0;
    MB->val[2] = tmr;
    MB->val[3] = mode_seen;

    IPCSYNC = (1 << 13) | (3 << 8);    /* output 3 + IRQ to the ARM9 */
    MB->ack = 0x7D;
    for (;;)
        swi_vblankintrwait();
}
