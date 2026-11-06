// New-only render progress question, not a repeat of run24's34 loads.
// Equal1536 pixels/line at48x32,64x24,128x12: sample CPU-visible RDLINES
// and sticky underflow at every VCOUNT edge across three frames after SWAP.
// Reuses load3d's identity-projection/nearer-last quads and gxplay helpers.
// No assumed8-cycle setup or pixel delay is encoded. Capture frame0 to D;
// no FAT writes, console writes or GX commands occur during the trace.
#include "../common/gxplay.h"
#include <stdio.h>
#include <stdlib.h>

#define VERSION "rdtimeline 1"
#define R_RDLINES REG16(0x04000320)
#define NSAMPLE (3 * 263 + 1)
typedef struct { u32 before, after; u16 line, line_after, rdlines, disp3d; } Sample;
static Sample samples[NSAMPLE];
static u16 capture[256 * 192];

static void vtx(int px, int py, int z)
{
    s32 x = (px - 128) * 4096 / 128, y = (96 - py) * 4096 / 96;
    gxp_put(0x23, ((u32)x & 0xFFFF) | ((u32)y << 16));
    gxp_put(0x23, (u32)z & 0xFFFF);
}

static void scene(int n, int width)
{
    gxp_reset_geometry();
    gxp_put(0x60, 255u << 16 | 191u << 24);
    gxp_put(0x2A, 0);
    int x = (256 - width) / 2;
    for (int i = 0; i < n; i++) {
        int z = 0xE00 - (int)((s64)i * 0x1C00 / n);
        gxp_put(0x29, 31u << 16 | 3u << 6 | (u32)(i & 63) << 24);
        gxp_put(0x20, (i * 37) & 0x7FFF);
        gxp_put(0x40, 1);
        vtx(x, 0, z); vtx(x, 192, z);
        vtx(x + width, 192, z); vtx(x + width, 0, z);
    }
    gxp_put(0x41, 0);
    gxp_wait_idle();
}

static void test(int n, int width)
{
    char key[48];
    snprintf(key,sizeof key,"n%d_s%d",n,width);
    if(!hw_step_begin("rdtimeline_progress.txt",key))return;
    // Empty steady predecessor, to separate this load's register history.
    REG32(0x04000350) = 31u << 16 | 63u << 24;
    REG16(0x04000354) = 0x7FFF;
    gxp_reset_geometry();
    bool ok = gxp_swap(0);
    for (int i = 0; i < 2; i++) {
        u32 t = now32(), spin = 0;
        while (now32() - t < 2130u * 263u && spin++ < 8000000u) {}
        if (now32() - t < 2130u * 263u) ok = false;
    }
    R_DISP3DCNT = 3u << 12;
    scene(n, width);
    u32 rc = gxp_ramcount();
    u32 swap_before = now32();
    ok = gxp_swap(0) && ok;
    u32 swap_after = now32();
    u16 swap_line = R_VCOUNT;
    gxp_capture_start(3);
    u32 start = now32(), ime = REG_IME;
    REG_IME = 0;
    int count = 0, missed = 0;
    u32 spins = 0;
    u16 last = 0xFFFF;
    while (count < NSAMPLE && now32() - start < 2130u * 263u * 5u && spins++ < 12000000u) {
        u16 line = R_VCOUNT;
        if (line == last) continue;
        if (last != 0xFFFF && line != (u16)((last + 1) % 263)) missed++;
        Sample* s = &samples[count++];
        s->before = now32() - start;
        s->line = line;
        s->rdlines = R_RDLINES;
        s->disp3d = R_DISP3DCNT;
        s->line_after = R_VCOUNT;
        s->after = now32() - start;
        last = line;
    }
    REG_IME = ime;
    if (count != NSAMPLE) ok = false;
    bool cap_done = gxp_capture_done();
    if (cap_done) gxp_capture_finish(3, capture);
    char name[64];
    Buf csv = {0};
    buf_printf(&csv, "sample,t_before,t_after,vcount,vcount_after,rdlines_raw,disp3d_raw\n");
    for (int i = 0; i < count; i++) {
        Sample* s = &samples[i];
        buf_printf(&csv, "%d,%lu,%lu,%u,%u,%u,%u\n", i,
                   (unsigned long)s->before, (unsigned long)s->after,
                   s->line, s->line_after, s->rdlines, s->disp3d);
    }
    snprintf(name, sizeof name, "rdtimeline_n%d_s%d.csv", n, width);
    bool saved=buf_write(&csv, name);
    snprintf(name, sizeof name, "rdtimeline_n%d_s%d_f0.bin", n, width);
    if (cap_done) saved=hw_write(name, capture, sizeof capture) && saved;
    buf_printf(&csv, "n,width,polys,verts,swap_before,swap_after,swap_vcount,trace_start,samples,missed_edges,capture_done,gx_ok,timeouts\n");
    buf_printf(&csv, "%d,%d,%lu,%lu,%lu,%lu,%u,%lu,%d,%d,%d,%d,%lu\n", n, width,
               (unsigned long)(rc & 0xFFF), (unsigned long)((rc >> 16) & 0x1FFF),
               (unsigned long)swap_before, (unsigned long)swap_after, swap_line,
               (unsigned long)start, count, missed, cap_done, ok, (unsigned long)gxp_timeouts);
    snprintf(name, sizeof name, "rdtimeline_n%d_s%d_info.csv", n, width);
    saved=buf_write(&csv, name) && saved;
    if(saved && cap_done && ok && !gxp_timeouts)hw_step_done("rdtimeline_progress.txt",key);
}

int main(void)
{
    hw_init(VERSION " - renderer progress");
    gxp_console_on_h(); videoSetMode(MODE_0_3D); glInit();
    REG32(0x04000010) = 0;
    R_VRAMCNT(3) = 0x80;
    static const int points[][2] = {{48,32}, {64,24}, {128,12}};
    hw_write("rdtimeline_info.txt", VERSION "\n3 new equal-pixel loads; no run24A repeat; raw RDLINES/DISP3DCNT per VCOUNT edge; timer F/1; IRQ masked only during trace; no SD writes inside trace\n",
             sizeof(VERSION "\n3 new equal-pixel loads; no run24A repeat; raw RDLINES/DISP3DCNT per VCOUNT edge; timer F/1; IRQ masked only during trace; no SD writes inside trace\n") - 1);
    for (unsigned i = 0; i < sizeof points / sizeof points[0]; i++) test(points[i][0], points[i][1]);
    hw_done();
}
