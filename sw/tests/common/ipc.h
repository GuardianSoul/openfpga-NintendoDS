/* ARM9 <-> ARM7 coordination for the test ROMs (not under test itself):
   the ARM7 sets IPCSYNC output = 7 when its init is done; after that the
   ARM9 sends numbered commands through the main-RAM mailbox (ds.h) and
   waits for the ARM7 to copy the number to MB->ack. */
#ifndef IPC_H
#define IPC_H
#include "ds.h"

#define A7_READY 7

/* Spin until cond holds or about `frames` frames have passed (counted on
   VCOUNT reaching 192). Evaluates to 1 if cond holds. */
#define WAIT_UNTIL(cond, frames) ({                                   \
    int _ok = 0, _f = 0, _in = 0;                                     \
    for (;;) {                                                        \
        if (cond) { _ok = 1; break; }                                 \
        int _v = VCOUNT == 192;                                       \
        if (_v && !_in && ++_f > (frames)) break;                     \
        _in = _v;                                                     \
    }                                                                 \
    _ok; })

static inline int a7_wait_ready(void)
{
    return WAIT_UNTIL((IPCSYNC & 0xF) == A7_READY, 120);
}

static inline int a7_cmd(u32 cmd)
{
    MB->cmd = cmd;
    return WAIT_UNTIL(MB->ack == cmd, 120);
}

#endif
