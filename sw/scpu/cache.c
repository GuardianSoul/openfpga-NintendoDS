/* SPDX-License-Identifier: MIT
 * The ROM cache's policy on SERV (rtl/pocket/nds_cart_scpu.sv): the same
 * steps as nds_cart_cache.sv's state machine (its header documents the
 * layout and the strategy), in the same order, so that the same client
 * reads give the same APF commands, slots and table.
 */
typedef unsigned int u32;

#define TABLE_W 0x300000u
#define OWNER_W 0x340000u
#define NDT_W   (TABLE_W - 0x400u)
#define PREFETCH 1

#define IO(r)   (*(volatile u32 *)(0x80000000u + 4u * (r)))
#define SD(w)   (*(volatile u32 *)(0x40000000u + 4u * (w)))
#define SD8(w)  ((volatile unsigned char *)(0x40000000u + 4u * (w)))

/* status (read 0 / 3) */
#define S_MISS   (1u << 31)
#define S_SEEN   (1u << 30)
#define S_MK     (1u << 29)
#define S_MKERR  (1u << 28)
#define S_BUSY   (1u << 27)
#define S_REF    (1u << 26)
#define S_LASTV  (1u << 25)
/* control (write 6) */
#define C_READY  1u
#define C_FAIL   2u
#define C_MISS   4u
#define C_LAST   8u
#define C_SEEN   16u
#define C_GO     64u      /* release the held client */
#define C_DUE    128u     /* a prefetch is due */
#define C_UNDUE  256u
#define C_LANDED 512u     /* the background prefetch is finished */
#define S_HOLD   (1u << 24)
#define S_DUE    (1u << 23)

static u32 rom_size, nblocks, hand, wrapped, SLOTS;
/* the run */
static u32 lb, run_n, run_ra[5], run_slot[5];
/* prefetch */
static u32 pf_fly, pf_b, pf_lb, pf_next;

static u32 ref_get(u32 s) { IO(4) = s; return IO(0) & S_REF; }
static void ref_set(u32 s, u32 v) { IO(4) = s | v << 16 | 1u << 17; }

static u32 min_ra(u32 ra, u32 after) { return ra > after ? after & 7u : ra; }

/* allocate the run's slots (CLOCK), evicting their old blocks. In the hand's first round no slot has
 * an owner and no reference bit counts (nothing clears them: stale after a reset, garbage in SDRAM) */
static void alloc(void)
{
    for (u32 k = 0; k < run_n; k++) {
        for (;;) {
            u32 h = hand;
            hand = hand == SLOTS - 1 ? 0 : hand + 1;
            if (wrapped && ref_get(h)) { ref_set(h, 0); continue; }
            run_slot[k] = h;
            ref_set(h, 1);
            u32 o = wrapped ? SD(OWNER_W + h) : 0;
            if (o >> 31) {
                u32 b = o & 0x3FFFFu;
                volatile unsigned char *t = SD8(TABLE_W + b);   /* byte enables 0111: the read-ahead field stays */
                t[0] = 0; t[1] = 0; t[2] = 0;
                if ((IO(0) & S_LASTV) && (IO(2) & 0x3FFFFu) == b) IO(6) = C_LAST;
            }
            SD(OWNER_W + h) = 1u << 31 | (lb + k);
            if (hand == 0) wrapped = 1;
            break;
        }
    }
}

static void send(u32 len, u32 bg)
{
    while (IO(0) & S_BUSY) ;
    for (u32 k = 0; k < run_n; k++) IO(8 + k) = run_slot[k];
    IO(2) = run_n | lb << 3;
    IO(3) = len | 1u << 31 | bg << 30;
}

static void mark_valid(void)
{
    for (u32 k = 0; k < run_n; k++)
        SD(TABLE_W + lb + k) = run_ra[k] << 29 | 1u << 16 | (run_slot[k] & 0x3FFFu);
}

static u32 run_cont(void)
{
    return run_ra[run_n - 1] != 0 && lb + run_n < nblocks;
}

/* look block b up and fetch its run if it is not cached; pfm: a background prefetch */
static void fetch(u32 b, u32 pfm)
{
    lb = b;
    u32 q = SD(TABLE_W + lb);
    if (q & 1u << 16) return;                       /* cached (a prefetch: nothing to do) */
    u32 after = nblocks - 1 - lb;
    run_ra[0] = q >> 29; run_n = 1;
    u32 ext = min_ra(q >> 29, after);
    if ((q >> 29) != 0 && after != 0) {
        for (;;) {
            q = SD(TABLE_W + lb + run_n);
            if (q & 1u << 16) break;
            run_ra[run_n] = q >> 29;
            if (run_n++ == ext) break;
        }
    }
    alloc();
    u32 end = lb + run_n;
    u32 len = end == nblocks && (rom_size & 0xFFFu) ? ((run_n - 1) << 12) + (rom_size & 0xFFFu) : run_n << 12;
    if (pfm) {
        send(len, 1);
        pf_fly = 1; pf_lb = lb; pf_next = end;
        IO(5) = lb | 1u << 31 | run_cont() << 30;   /* the trigger: the client reaching this run */
        return;
    }
    for (u32 tries = 0;; tries++) {
        send(len, 0);
        u32 st;
        while (!((st = IO(0)) & S_MK)) ;
        if (!(st & S_MKERR)) break;
        if (tries == 3) { IO(6) = C_FAIL; break; }
    }
    mark_valid();
    if (PREFETCH && run_cont()) { pf_b = end; IO(6) = C_DUE; }
}

/* the background prefetch's marker: mark its run cached (or drop it on an error) */
static void finish_prefetch(u32 st)
{
    pf_fly = 0;
    IO(6) = C_LANDED;
    lb = pf_lb;
    if (st & S_MKERR) { IO(5) = 0; return; }
    mark_valid();
}

void main(void)
{
    rom_size = IO(1);
    SLOTS = IO(2) >> 18;
    nblocks = (rom_size >> 12 & 0x3FFFFu) + ((rom_size & 0xFFFu) != 0);
    if (SD(NDT_W) == 0x3154444Eu && SD(NDT_W + 1) == 1 && SD(NDT_W + 3) == rom_size)
        SD(NDT_W) = 0;                              /* the plugin's table: use it once */
    else {
        for (u32 b = 0; b < nblocks; b++) SD(TABLE_W + b) = 0;
    }
    IO(6) = C_READY;

    for (;;) {
        u32 st = IO(3);                             /* waits for a miss, a trigger or a held client */
        if (st & S_SEEN) {                          /* the client reached the prefetched run (due set if it goes on) */
            IO(6) = C_SEEN;
            pf_b = pf_next;
        } else if (st & S_MISS) {
            if (pf_fly) {                           /* the prefetch's command first, then look again */
                while (!((st = IO(0)) & S_MK)) ;
                finish_prefetch(st);
                IO(6) = C_MISS;
            } else {
                fetch(st & 0x3FFFFu, 0);
                IO(7) = run_slot[0];                /* read it from its first slot */
            }
        } else if (st & S_HOLD) {                   /* the client waits: the prefetch's marker or the next prefetch */
            if (pf_fly && (st & S_MK))
                finish_prefetch(st);
            else if ((st & S_DUE) && !pf_fly) {
                IO(6) = C_UNDUE;
                fetch(pf_b, 1);
            }
            IO(6) = C_GO;
        }
    }
}
