/* unitmem.nds / unitcpu.nds / unitgx.nds, ARM7: reports ready, then halts
   (BIOS Halt with IRQs off: for good), as a game's ARM7 sits halted between
   IRQs. A core with an ARM9 solo mode (A9_SOLO) then runs the ARM9 alone. */
#include "../common/ds.h"
#include "../common/ipc.h"

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    IPCSYNC = A7_READY << 8;
    for (;;)
        __asm__ volatile("swi 0x060000");   /* Halt */
}
