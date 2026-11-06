/* dmacpu.nds, ARM7: idle (the probe is ARM9-only). */
#include "../common/ds.h"
#include "../common/ipc.h"

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    IPCSYNC = A7_READY << 8;
    for (;;)
        ;
}
