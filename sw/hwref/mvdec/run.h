/* mvdec: a game's movie decoder run in isolation (docs/hw-reference.md
   "mvdec method"). tools/hwref/mkmvdec.py captures the decoder's calls in
   melonDS (census --snap-pcs) and writes, from the maintainer's local ROM, files that
   are never committed:
     main image  the main RAM the calls touch, at the first call; the
                 largest range they never touch holds this program
     call blob   at MV_BLOB: the display set-up, the game's CP15, VRAMCNT,
                 ITCM and DTCM, then per call the function, r0-r3, SP, the
                 game's frame/line at the call, its picture checksum region
                 and the bytes that changed in memory since the previous call
                 returned (the data the game streamed in)
   mvdec_run() puts the ARM9 into the game's CP15 layout, then for each call
   applies its changes, cleans and invalidates both caches, waits for the
   call's frame and line on the game's timeline and times the call.
   IME is 0 during the run. On return the caller's CP15 layout, ITCM and
   DTCM contents and IME are back; VRAMCNT stays as the game had it.
   Built by both front ends (tb.c: sw/tests, no calico; ds.c: calico +
   libfat), so it uses no library calls. MV_BLOB comes from the build. */
#ifndef MVDEC_RUN_H
#define MVDEC_RUN_H

#define MV_MAX_CALLS 128
#define MV_TICKS_PER_LINE 2130u     /* 33.513982 MHz system clock */
#define MV_LINES 263u

typedef struct {
    unsigned int func, target, start, end;  /* ticks since the first call's line */
    unsigned short vc0, vc1;                /* VCOUNT before and after */
    unsigned int cksum;                     /* sampled checksum of the call's picture region, else 0 */
    unsigned int game_ticks;                /* the call in melonDS (census), ticks */
    unsigned int game_cksum;
} kres_t;

typedef struct {   /* control, c9 DTCM/ITCM, c2/c3 cacheability, c5 extended permissions, c6 regions */
    unsigned int control, dtcm, itcm, code_c, data_c, wbuf, code_ap, data_ap, region[8];
} kcp15_t;
void mvdec_cp15_save(kcp15_t *c);
void mvdec_cp15_load(const kcp15_t *c);   /* flushes the caches first */

/* Returns the number of calls run, or a negative error. res, save (48 KiB,
   for the caller's TCM contents) and the stack it runs on are in main RAM
   below 0x023E0000 (the game's MPU denies the rest); the caller's stack may
   be in DTCM. */
int mvdec_run(const unsigned char *blob, kres_t *res, int max, unsigned char *save, void *stack_top);

/* 1 (default): clean and invalidate both caches before every call (cold).
   0: leave them as the previous call left them (warm, as in the game). */
extern int mvdec_flush_each;

#endif
