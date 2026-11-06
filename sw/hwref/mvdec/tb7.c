/* mvdec (tb build), ARM7: idle (the run is ARM9-only). */
#include "../../tests/common/ds.h"
#include "../../tests/common/ipc.h"

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    IPCSYNC = A7_READY << 8;
    for (;;)
        ;
}
