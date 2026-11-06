/* unita7.nds, ARM9: maps VRAM C to the ARM7, starts the ARM7's timing
   kernels (arm7.c) and copies its results into the result block. While the
   ARM7 measures, the ARM9 polls IPCSYNC (I/O) only, so it stays off main RAM
   (on the DS the hwref run had the ARM9 waiting in calico). */
#include "../common/con.h"
#include "../common/ipc.h"
#include "../common/results.h"

static const char *const s_name[] = {
    "ALU", "ALUSR", "B", "MUL8", "MUL32", "MLA32", "LDRWRAM", "STRWRAM", "LDM4WRAM", "STM4WRAM",
    "LDRMAIN", "STRMAIN", "LDM4MAIN", "STM4MAIN", "SWPMAIN", "MCALU", "MCB", "MCLDRW", "MCSTRW",
    "LDRVRAMC", "STRVRAMC",
};
#define N (int)(sizeof s_name / sizeof s_name[0])

int main(void)
{
    con_init();
    res_begin("UNITA7", N + 1);
    int ok = a7_wait_ready();
    R8(0x04000242) = 0x82;   /* VRAM C: ARM7 at 0x06000000 */
    MB->ack = 0;
    MB->cmd = 1;
    if (ok) ok = WAIT_UNTIL((IPCSYNC & 0xF) == 1, 600);
    for (int i = 0; i < N; i++) res_record(i, s_name[i], ok ? MB->val[i] : 0, ok);
    res_record(N, "DONE", ok, ok);
    res_finish();
    for (;;)
        ;
}
