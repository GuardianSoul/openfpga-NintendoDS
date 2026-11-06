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
#define CACHE_W 0x400000u
#define PREFETCH 1
/* blocks fetched past the one asked for, in a demand run and in a prefetch run (at most the table's
 * read-ahead field, up to 4). 0 (2026-11-06, docs/memory-replay.md "Read-ahead of one block"): on the
 * Pocket's link (0.9 ms a command + 2.3 ms a block) unread read-ahead blocks the next demand miss;
 * White 2's event start at the Route 19 gate waited 72 ms in one frame with 4, 28 ms with 0, and every
 * census trace stalls less */
#define AHEAD 0
/* a prefetch run's blocks past its first: 0 after a demand miss that starts a stream; each time the client reaches
 * the stream's prefetched run, or outruns it, the next run takes 2 x + 1, up to PF_MAX. Random reads keep one-block
 * prefetches; a stream gets ahead of the client (docs/memory-replay.md, "Prefetch ramp"). 1 (runs of 1, then 2
 * blocks) with streams: on the Pocket's link (the maintainer's NDSPlay19 log: 4.2-4.6 ms a block) a demand miss behind a
 * 5-block run waited too long; every census trace stalls less with 2 (docs/memory-replay.md, "Streams") */
#define PF_MAX 1
/* streams, each with its own prefetch (docs/memory-replay.md, "Streams"): White 2 reads its map archive as two
 * interleaved sequential streams; with one prefetch each stream's miss replaced the other's prefetch. A demand
 * miss on a stream's next block continues it, any other starts one in the least recently used entry; the
 * cache's new-block event (write 5 bit 29) tells when the client enters a stream's last prefetched run */
#define NS 4
#define NONE 0xFFFFFFFFu

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

static u32 rom_size, nblocks, hand, wrapped, SLOTS, scanning;
/* the run */
static u32 lb, run_n, run_ra[5], run_slot[5];
/* the prefetch in flight (one at a time) */
static u32 pf_fly, pf_lb, pf_k;
/* streams: the next block to fetch (NONE: the file ends), the first block of the last prefetched run (NONE: not
 * watched), the next run's blocks past its first, a prefetch due, last use */
static u32 s_next[NS], s_trig[NS], s_ahead[NS], s_due[NS], s_used[NS], now;

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

/* fetch block b's run (b not cached), cap blocks past b; pfm: a background prefetch. Returns whether the file goes
 * on past the run */
static u32 fetch(u32 b, u32 pfm, u32 cap)
{
    lb = b;
    u32 q = SD(TABLE_W + lb);
    u32 after = nblocks - 1 - lb;
    run_ra[0] = q >> 29; run_n = 1;
    u32 ext = min_ra(q >> 29, after);
    if (ext > cap) ext = cap;
    if (ext != 0) {
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
        pf_fly = 1; pf_lb = lb;
        return run_cont();
    }
    for (u32 tries = 0;; tries++) {
        send(len, 0);
        u32 st;
        while (!((st = IO(0)) & S_MK)) ;
        if (!(st & S_MKERR)) break;
        if (tries == 3) { IO(6) = C_FAIL; break; }
    }
    mark_valid();
    return run_cont();
}

static u32 ramp(u32 a) { return a * 2 + 1 > PF_MAX ? PF_MAX : a * 2 + 1; }

static void due(u32 k)
{
    if (s_next[k] == NONE) return;
    s_due[k] = 1;
    IO(6) = C_DUE;
}

/* the first due stream's next run, in the background (the client is held). Blocks already cached are looked
 * past (up to 8): the run starts at the first that is not */
static void prefetch(void)
{
    for (u32 k = 0; k < NS; k++) {
        if (!s_due[k]) continue;
        s_due[k] = 0;
        u32 b = s_next[k], q;
        for (u32 i = 0; (q = SD(TABLE_W + b)) & 1u << 16; i++) {
            if (!(q >> 29) || b + 1 >= nblocks) { b = NONE; break; }   /* the file ends */
            if (i == 7) break;
            b++;
        }
        if (b == NONE) { s_next[k] = NONE; s_trig[k] = NONE; continue; }
        if (q & 1u << 16) { s_trig[k] = b; s_next[k] = b + 1; continue; }   /* still cached: the client reaching it goes on */
        u32 c = fetch(b, 1, s_ahead[k]);
        pf_k = k; s_trig[k] = b;
        s_next[k] = c ? b + run_n : NONE;
        break;
    }
    for (u32 k = 0; k < NS; k++) if (s_due[k]) { IO(6) = C_DUE; break; }
}

/* a ROM word through the cache (its block fetched if it isn't cached) */
static u32 rom_word(u32 a)
{
    u32 b = a >> 12, q = SD(TABLE_W + b);
    if (!(q & 1u << 16)) { fetch(b, 0, 0); q = SD(TABLE_W + b); }
    return SD(CACHE_W + ((q & 0x3FFFu) << 10) + ((a & 0xFFFu) >> 2));
}

/* the read-ahead fields without the plugin's table: the rule of nds_cart_cache.sv's start-up scan and the plugin's
 * .ndt (tools/pocket-plugin/src/rom.rs Rom::table): for the ARM9 and ARM7 binaries and every FAT entry, a span
 * [s, e) clipped to the ROM, each block whose first byte is in it gets min(4, blocks of the span after it); later
 * spans overwrite earlier ones; at most 4 x blocks marks. Only for a header whose CRC-16 matches. Without it every
 * field stayed 0, so the Pocket never prefetched (the maintainer's NDSPlay19 log: blocks = fetches; the core does not load
 * the .ndt yet, docs/pocket-plugin.md). The start reads the header and fetches the FAT's blocks; the marks run in
 * the background, a chunk at a time between events (a 512 MiB ROM: 128K blocks, seconds on SERV, during the
 * game's logos) */
static u32 budget, sc_i, sc_n, sc_fo, sc_b, sc_se, sc_end;
/* a cached ROM word, or 0 when its block is not cached (the scan then stops) */
static u32 cword(u32 a, u32 *v)
{
    u32 q = SD(TABLE_W + (a >> 12));
    if (!(q & 1u << 16)) return 0;
    *v = SD(CACHE_W + ((q & 0x3FFFu) << 10) + ((a & 0xFFFu) >> 2));
    return 1;
}
static u32 scan_start(void)
{
    u32 c = 0xFFFF;                                 /* the header's CRC-16 (0x15E) over 0x000-0x15D */
    for (u32 i = 0, w = 0; i < 0x15E; i++) {
        if (!(i & 3)) w = rom_word(i);
        c ^= w >> 8 * (i & 3) & 0xFFu;
        for (u32 k = 0; k < 8; k++) c = c & 1 ? c >> 1 ^ 0xA001u : c >> 1;
    }
    if (c != (rom_word(0x15C) >> 16)) return 0;
    u32 fo = rom_word(0x48), fs = rom_word(0x4C);
    if (fo >= rom_size || (fo & 3)) fs = 0;
    if (fs > rom_size - fo) fs = rom_size - fo;
    sc_fo = fo; sc_n = 2 + (fs >> 3);               /* spans: ARM9, ARM7, the FAT's entries */
    for (u32 a = fo; a < fo + (fs & ~7u); a += 4096) rom_word(a);
    if (fs & ~7u) rom_word(fo + (fs & ~7u) - 4);
    budget = nblocks * 4; sc_i = 0; sc_b = sc_se = 0;
    return 1;
}

/* up to 64 marks; 0 when the scan is done */
static u32 scan_step(void)
{
    for (u32 k = 0; k < 64; k++) {
        if (sc_b == sc_se) {                        /* the next span */
            if (sc_i == sc_n || budget == 0) return 0;
            u32 s, e, a = sc_i < 2 ? 0x20 + 0x10 * sc_i : sc_fo + 8 * (sc_i - 2);
            sc_i++;
            if (!cword(a, &s) || !cword(sc_i <= 2 ? a + 12 : a + 4, &e)) return 0;   /* the FAT's block was evicted */
            if (sc_i <= 2) e += s;                  /* the binaries: offset and size */
            if (e > rom_size) e = rom_size;
            if (s >= e) continue;
            sc_b = (s + 0xFFFu) >> 12; sc_se = (e + 0xFFFu) >> 12;
            sc_end = sc_se - sc_b > budget ? sc_b + budget : sc_se;
            budget -= sc_end - sc_b;
            continue;
        }
        if (sc_b == sc_end) { sc_b = sc_se; continue; }   /* capped */
        u32 r = sc_se - 1 - sc_b;
        SD8(TABLE_W + sc_b)[3] = (r > 4 ? 4 : r) << 5;  /* byte 3: the cached bit and slot stay */
        sc_b++;
    }
    return 1;
}

/* the background prefetch's marker: mark its run cached (or drop it on an error) */
static void finish_prefetch(u32 st)
{
    pf_fly = 0;
    IO(6) = C_LANDED;
    lb = pf_lb;
    if (st & S_MKERR) {                             /* dropped: the stream's demand miss on it continues it */
        if (s_trig[pf_k] == pf_lb) { s_next[pf_k] = pf_lb; s_trig[pf_k] = NONE; }
        return;
    }
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
        scanning = PREFETCH && scan_start();
    }
    for (u32 k = 0; k < NS; k++) { s_next[k] = NONE; s_trig[k] = NONE; }
    IO(6) = C_READY;
    if (PREFETCH) IO(5) = 1u << 29;                 /* new-block events */

    for (;;) {
        /* the scan yields to a waiting client (a miss, a hold), not to new-block events: those wait a chunk */
        if (scanning && !(IO(0) & (S_MISS | S_HOLD))) { scanning = scan_step(); continue; }
        u32 st = IO(3);                             /* waits for a miss, a trigger or a held client */
        if (st & S_SEEN) {                          /* the client moved to another cached block */
            IO(6) = C_SEEN;
            u32 b = IO(2) & 0x3FFFFu;
            now++;
            for (u32 k = 0; k < NS; k++)            /* in a stream's last prefetched run: fetch the next */
                if (s_trig[k] != NONE && b >= s_trig[k] && b < s_next[k]) {
                    s_trig[k] = NONE; s_used[k] = now;
                    s_ahead[k] = ramp(s_ahead[k]);
                    due(k);
                }
        } else if (st & S_MISS) {
            if (pf_fly) {                           /* the prefetch's command first, then look again */
                while (!((st = IO(0)) & S_MK)) ;
                finish_prefetch(st);
                IO(6) = C_MISS;
            } else {
                u32 b = st & 0x3FFFFu, f = NS;
                now++;
                for (u32 k = 0; k < NS; k++) if (s_next[k] == b) f = k;   /* a stream that outran its prefetch */
                if (f == NS) {                      /* a new one, in the least recently used entry */
                    f = 0;
                    for (u32 k = 1; k < NS; k++) if (s_used[k] < s_used[f]) f = k;
                    s_ahead[f] = 0;
                } else s_ahead[f] = ramp(s_ahead[f]);
                s_used[f] = now; s_trig[f] = NONE; s_due[f] = 0;
                u32 c = fetch(b, 0, AHEAD);
                IO(7) = run_slot[0];                /* read it from its first slot */
                s_next[f] = c ? b + run_n : NONE;
                if (PREFETCH) due(f);
            }
        } else if (st & S_HOLD) {                   /* the client waits: the prefetch's marker or the next prefetch */
            if (pf_fly && (st & S_MK))
                finish_prefetch(st);
            else if ((st & S_DUE) && !pf_fly) {
                IO(6) = C_UNDUE;
                prefetch();
            }
            IO(6) = C_GO;
        }
    }
}
