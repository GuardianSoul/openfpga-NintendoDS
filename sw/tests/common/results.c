#include "results.h"
#include "con.h"

static int nchecks;

static u32 full_mask(void)
{
    return nchecks >= 32 ? 0xFFFFFFFFu : (1u << nchecks) - 1;
}

static void draw_mask(const char *state, int pal)
{
    con_printf(TOP, 0, 1, PAL_WHITE, "MASK %08X OF %08X", RESULT->mask, full_mask());
    con_puts(TOP, 0, 2, pal, state);
}

void res_begin(const char *title, int n)
{
    nchecks = n;
    RESULT->done = 0;
    RESULT->magic = RESULT_MAGIC;
    RESULT->n = (u32)n;
    RESULT->mask = 0;
    for (int i = 0; i < 32; i++)
        RESULT->value[i] = 0;
    con_puts(TOP, 0, 0, PAL_YELLOW, title);
    draw_mask("RUNNING   ", PAL_YELLOW);
}

int res_record(int i, const char *name, u32 value, int pass)
{
    RESULT->value[i] = value;
    if (pass)
        RESULT->mask |= 1u << i;
    else
        RESULT->mask &= ~(1u << i);
    int scr = i < 20 ? TOP : BOTTOM;
    int row = i < 20 ? 4 + i : 4 + i - 20;
    char nm[9];
    int k = 0;
    for (; k < 8 && name[k]; k++)
        nm[k] = name[k];
    for (; k < 8; k++)
        nm[k] = ' ';
    nm[8] = 0;
    con_printf(scr, 0, row, PAL_WHITE, "%02u %s %08X", (u32)i, nm, value);
    con_puts(scr, 29, row, pass ? PAL_GREEN : PAL_RED, pass ? "OK " : "BAD");
    return pass;
}

int res_check(int i, const char *name, u32 value, u32 expected)
{
    return res_record(i, name, value, value == expected);
}

void res_finish(void)
{
    int ok = (RESULT->mask & full_mask()) == full_mask();
    draw_mask(ok ? "ALL PASS  " : "FAIL      ", ok ? PAL_GREEN : PAL_RED);
    RESULT->done = 1;
    /* ROMs that turn the MPU and D-cache on (cputime, unitmem, unitcpu) hold
       the block in write-back lines: clean and invalidate the D-cache (4 KiB,
       4 ways, 32-byte lines; harmless with the cache off), drain the write
       buffer, so the testbench and melonDS's savestate see it in RAM */
    for (u32 way = 0; way < 4; way++)
        for (u32 i = 0; i < 32; i++)
            __asm__ volatile("mcr p15, 0, %0, c7, c14, 2" :: "r"((way << 30) | (i << 5)));
    __asm__ volatile("mcr p15, 0, %0, c7, c10, 4" :: "r"(0));
}
