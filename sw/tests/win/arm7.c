/* win.nds, ARM7: report ready, then idle (as hello.nds). */
#include "../common/ds.h"
#include "../common/ipc.h"

extern char _start[];

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    MB->val[0] = (u32)_start;
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    IPCFIFOSEND = 0x1234ABCD;
    IPCSYNC = A7_READY << 8;
    for (;;)
        ;
}
