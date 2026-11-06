/* <tag>.nds for tb_ds and melonDS (sw/tests runtime, no calico): run.h.
   tools/hwref/mkmvdec.py links this at the start of the main RAM range the
   game's calls never touch, inside the game's main image, with the call
   blob at MV_BLOB. The screens show the movie as the blob's display set-up
   puts it.

   Results, after the run:
     0x023F2000  "MVDCRES1", u32 n, u32 ticks per line, then n kres_t (run.h)
     result block (results.h): 0 calls run, 1 pictures whose checksum differs
     from the game's in melonDS, 2 ARM9 cycles of all calls, 3 calls started
     more than a line after the game's start
   then the ARM9 spins at mvdec_done (tb_ds --dump-mram-pc). */
#include "../../tests/common/con.h"
#include "../../tests/common/results.h"
#include "run.h"

#define TABLE_ADDR 0x023F2000u

static kres_t res[MV_MAX_CALLS];
static u8 save[0xC000];
static u32 stack[4096] __attribute__((aligned(8)));

__attribute__((noinline, used)) void mvdec_done(void)
{
    for (;;)
        __asm__ volatile("");
}

int main(void)
{
    int n = mvdec_run((const u8 *)MV_BLOB, res, MV_MAX_CALLS, save, stack + 4096);

    volatile u32 *t = (volatile u32 *)TABLE_ADDR;
    t[0] = 0x4344564D;                  /* "MVDCRES1" */
    t[1] = 0x31534552;
    t[2] = n;
    t[3] = MV_TICKS_PER_LINE;
    u32 bad = 0, late = 0, cyc = 0;
    for (int i = 0; i < n; i++)
    {
        const u32 *r = (const u32 *)&res[i];
        for (u32 k = 0; k < sizeof(kres_t) / 4; k++) t[4 + i * (sizeof(kres_t) / 4) + k] = r[k];
        if (res[i].cksum != res[i].game_cksum) bad++;
        if (res[i].start > res[i].target + MV_TICKS_PER_LINE) late++;
        cyc += 2 * (res[i].end - res[i].start);
    }
    con_init();
    res_begin("MOVIE DECODE " MV_TAG, 4);
    res_record(0, "CALLS", n, n > 0);
    res_record(1, "CKSUMBAD", bad, n > 0 && bad == 0);
    res_record(2, "CYCLES", cyc, 1);
    res_record(3, "LATE", late, 1);
    res_finish();
    mvdec_done();
    return 0;
}
