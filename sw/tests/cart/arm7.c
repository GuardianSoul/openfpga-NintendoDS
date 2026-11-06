/* cart.nds, ARM7: card reads after the ARM9 hands over the slot. */
#include "../common/ds.h"
#include "../common/ipc.h"
#include "card.h"

static u32 buf[128];

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    IPCSYNC = A7_READY << 8;
    while (MB->cmd != 1)
        ;
    for (int i = 0; i < 128; i++) buf[i] = 0;
    card_read_poll(0x21000, buf);
    MB->val[0] = count_pattern(buf, 0x21000);
    for (int i = 0; i < 128; i++) buf[i] = 0;
    card_read_poll(0x2FE00, buf);
    MB->val[1] = count_pattern(buf, 0x2FE00);
    MB->val[2] = card_chip_id();
    MB->ack = 1;
    for (;;)
        ;
}
