/* Physical-DS/Pocket math probe, not a claim of a known native-hardware pass.
   Root checks label the mathematical floor; division overflow stays raw.
   Common crt0 leaves IRQ/FIQ disabled, IME=0, and main RAM uncached. */
#include "../common/con.h"
#include "../common/results.h"

enum {
    ROOTS = 9, CHECK_SEED = 9, CHECK_WAIT = 10, CHECKS = 11,
    RAW_SEED_QLO = 11, RAW_SEED_QHI, RAW_SEED_RLO, RAW_SEED_RHI,
    RAW_OVER_QLO, RAW_OVER_QHI, RAW_OVER_RLO, RAW_OVER_RHI,
    RAW_SEED_CNT, RAW_OVER_CNT, RAW_READY, RAW_VERSION,
    POLL_LIMIT = 1000000
};

struct root_case {
    u32 lo, hi, mode, floor;
    const char *name;
};

static const struct root_case roots[ROOTS] = {
    {0x00000000u, 0x00000000u, 1, 0x00000000u, "ZERO64"},
    {0x00000051u, 0x00000000u, 1, 0x00000009u, "NINE64"},
    {0xFFFFFFFFu, 0x3FFFFFFFu, 1, 0x7FFFFFFFu, "BELOW62"},
    {0x00000000u, 0x40000000u, 1, 0x80000000u, "AT62"},
    {0x00000001u, 0x40000000u, 1, 0x80000000u, "BUG62P1"},
    {0x00000000u, 0xFFFFFFFEu, 1, 0xFFFFFFFEu, "TOPSQM1"},
    {0x00000001u, 0xFFFFFFFEu, 1, 0xFFFFFFFFu, "TOPSQ"},
    {0xFFFFFFFFu, 0xFFFFFFFFu, 1, 0xFFFFFFFFu, "MAX64"},
    {0xFFFFFFFFu, 0xA5A5A5A5u, 0, 0x0000FFFFu, "HIIGN32"}
};

static u32 timeout_stage;

/* A poll-count bound, not a calibrated hardware-latency measurement. */
static int wait_ready(volatile u16 *cnt, u32 stage)
{
    for (u32 i = 0; i < POLL_LIMIT; i++)
        if (!(*cnt & 0x8000u))
            return 1;
    if (!timeout_stage)
        timeout_stage = stage;
    return 0;
}

static void snapshot_div(int base, int cnt_slot)
{
    /* Only interpret these as completed results when RAW_READY says so. */
    RESULT->value[base] = DIV_RES_L;
    RESULT->value[base + 1] = DIV_RES_H;
    RESULT->value[base + 2] = DIV_REM_L;
    RESULT->value[base + 3] = DIV_REM_H;
    RESULT->value[cnt_slot] = DIVCNT;
}

static void show_raw(int row, const char *name, u32 hi, u32 lo)
{
    /* The common formatter accepts 32-bit arguments only. */
    con_printf(BOTTOM, 0, row, PAL_WHITE, "%s %08X:%08X", name, hi, lo);
}

int main(void)
{
    con_init();
    res_begin("MATH HARDWARE PROBE", CHECKS);
    con_puts(TOP, 0, 16, PAL_YELLOW, "ROOT CHECKS = EXPECTED FLOOR");
    con_puts(TOP, 0, 17, PAL_YELLOW, "NATIVE RESULTS NOT PREJUDGED");
    u32 ready = 0;
    for (int i = 0; i < ROOTS; i++) {
        SQRT_PARAM_L = roots[i].lo;
        SQRT_PARAM_H = roots[i].hi;
        SQRTCNT = (u16)roots[i].mode;  /* final write restarts with this mode */
        int done = wait_ready(&SQRTCNT, (u32)i + 1);
        u32 observed = SQRT_RESULT;
        if (done)
            ready |= 1u << i;
        res_record(i, roots[i].name, observed, done && observed == roots[i].floor);
    }

    /* Use an already-overflow-sized numerator for a nonoverflow seed:
       INT_MIN / -3 gives Q=0x2AAAAAAA, R=-2. Then a SINGLE operand write
       starts INT_MIN / -1. No intermediate division can replace the seed.
       Do not format text or call another math user between the snapshots. */
    DIV_NUMER_L = 0x80000000u;
    DIV_NUMER_H = 0xFFFFFFFFu;
    DIV_DENOM_L = 0xFFFFFFFDu;
    DIV_DENOM_H = 0xFFFFFFFFu;
    DIVCNT = 0;
    int seed_done = wait_ready(&DIVCNT, 0x100u);
    snapshot_div(RAW_SEED_QLO, RAW_SEED_CNT);
    if (seed_done)
        ready |= 1u << 9;

    DIV_DENOM_L = 0xFFFFFFFFu;       /* only write triggering overflow */
    int over_done = wait_ready(&DIVCNT, 0x101u);
    snapshot_div(RAW_OVER_QLO, RAW_OVER_CNT);
    if (over_done)
        ready |= 1u << 10;
    RESULT->value[RAW_READY] = ready;
    RESULT->value[RAW_VERSION] = 0x4D505231u; /* MPR1 layout */

    /* These check the nonoverflow setup and completion, not overflow policy. */
    res_record(CHECK_SEED, "SEEDREM", RESULT->value[RAW_SEED_RLO],
               seed_done && RESULT->value[RAW_SEED_QLO] == 0x2AAAAAAAu &&
               RESULT->value[RAW_SEED_QHI] == 0 &&
               RESULT->value[RAW_SEED_RLO] == 0xFFFFFFFEu &&
               RESULT->value[RAW_SEED_RHI] == 0xFFFFFFFFu);
    res_check(CHECK_WAIT, "TIMEOUT", timeout_stage, 0);

    con_puts(BOTTOM, 0, 0, PAL_YELLOW, "DIV OVERFLOW: RAW ONLY");
    con_puts(BOTTOM, 0, 1, PAL_YELLOW, "NO REMAINDER POLICY VERDICT");
    show_raw(3, "SEED Q", RESULT->value[RAW_SEED_QHI], RESULT->value[RAW_SEED_QLO]);
    show_raw(4, "SEED R", RESULT->value[RAW_SEED_RHI], RESULT->value[RAW_SEED_RLO]);
    show_raw(6, "OVER Q", RESULT->value[RAW_OVER_QHI], RESULT->value[RAW_OVER_QLO]);
    show_raw(7, "OVER R", RESULT->value[RAW_OVER_RHI], RESULT->value[RAW_OVER_RLO]);
    con_printf(BOTTOM, 0, 9, PAL_WHITE, "CNT SEED %04X OVER %04X",
               RESULT->value[RAW_SEED_CNT], RESULT->value[RAW_OVER_CNT]);
    con_printf(BOTTOM, 0, 10, PAL_WHITE, "READY %08X TIMEOUT %08X", ready, timeout_stage);
    con_puts(BOTTOM, 0, 12, PAL_YELLOW, "RAW VALID ONLY IF READY BIT SET");
    con_puts(BOTTOM, 0, 13, PAL_WHITE, "SEED INT_MIN/-3; THEN DEN=-1");
    res_finish();
    con_puts(TOP, 0, 2, PAL_YELLOW, "MASK: FLOOR/SEED/WAIT ONLY");
    for (;;)
        __asm__ volatile("nop");
}
