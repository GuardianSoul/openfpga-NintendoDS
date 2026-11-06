// nds_g3d_plane against a model of melonDS's clear plane (GPU3D::VBlank's
// latch, SoftRenderer3D::ClearBuffers, GetLine's X scroll): random clear
// colours, bitmaps, offsets, BG0HOFS, power bits and write times, frame by
// frame; every 3D-layer pixel of every line is compared.
//   tb_plane [--frames N] [--seed S]
#include "Vnds_g3d_plane.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;

static Vnds_g3d_plane* m;
static std::mt19937 rng;
static u16 vram[0x40000];                 // texture view, halfwords (slot 2 at 0x20000)
struct Blk { u32 addr; int wait; };
static std::deque<Blk> inflight;
static int beat;
static uint64_t cyc;

static void tick()
{
    // block port: ack a request at once, beats after a random latency
    m->t_ack = 0;
    if (m->t_req) { m->t_ack = 1; inflight.push_back({(u32)((m->t_blk & 0x3FFF) << 5), 10 + (int)(rng() % 20)}); }
    m->t_rvalid = 0;
    if (!inflight.empty() && inflight.front().wait <= 0) {
        u32 a = (inflight.front().addr >> 1) + beat * 4;
        uint64_t d = 0;
        for (int k = 0; k < 4; k++) d |= (uint64_t)vram[(a + k) & 0x3FFFF] << (16 * k);
        m->t_rvalid = 1; m->t_rdata = d;
        if (++beat == 4) { beat = 0; inflight.pop_front(); }
    } else if (!inflight.empty()) inflight.front().wait--;
    m->clk = 0; m->eval(); m->clk = 1; m->eval(); cyc++;
    m->io_req = 0; m->line_start = 0; m->l3d_go = 0;
}

// model
struct Model {
    u32 clr1 = 0x3F000000, clr2 = 0x7FFF; u16 xpos = 0;
    bool r_bmp = false; u32 r1 = 0x3F000000, r2 = 0x7FFF;
    bool d_bmp = false; u32 d1 = 0x3F000000, d2 = 0x7FFF;
} md;

static void io_write(u32 addr, u32 data, u32 be, bool rend)
{
    m->io_req = 1; m->io_cpu = 0; m->io_we = 1; m->io_be = be; m->io_addr = (addr & 0xFFFFFF) >> 2; m->io_wdata = data;
    if (rend && (addr == 0x04000350 || addr == 0x04000354)) {
        u32& r = addr == 0x04000350 ? md.clr1 : md.clr2;
        if ((be & 3) == 3) r = (r & 0xFFFF0000) | (data & 0xFFFF);
        if ((be & 12) == 12) r = (r & 0xFFFF) | (data & 0xFFFF0000);
    }
    if (rend && addr == 0x04000010) {
        if (be & 1) md.xpos = (md.xpos & 0x100) | (data & 0xFF);
        if (be & 2) md.xpos = (md.xpos & 0xFF) | (data & 0x100);
    }
    tick();
}

static u32 conv(u16 v, u32 a)
{
    u32 r = (v << 1) & 0x3E; if (r) r++;
    u32 g = (v >> 4) & 0x3E; if (g) g++;
    u32 b = (v >> 9) & 0x3E; if (b) b++;
    return r | g << 8 | b << 16 | a << 24;
}

int main(int argc, char** argv)
{
    int frames = 40; unsigned seed = 1;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--frames") frames = atoi(argv[++i]);
        else if (a == "--seed") seed = atoi(argv[++i]);
    }
    rng.seed(seed);
    m = new Vnds_g3d_plane;
    m->rst = 1; m->powcnt1 = 3; m->disp3dcnt = 0; m->t_ack = 0; m->t_rvalid = 0;
    for (int i = 0; i < 4; i++) tick();
    m->rst = 0;
    long bad = 0, px = 0;
    for (int f = 0; f < frames; f++) {
        for (u32 i = 0x20000; i < 0x30000; i++) vram[i] = rng();
        if (f % 3 == 0) for (u32 i = 0x20000; i < 0x30000; i++) vram[i] &= 0x7FFF | ((i & 7) ? 0x8000 : 0);
        for (int v = 0; v < 263; v++) {
            bool rend = m->powcnt1 & 1, geom = m->powcnt1 & 2;
            // line start: latches as melonDS (VBlank 192, render 215)
            m->line_start = 1; m->vcount = v;
            if (!rend) { md.r_bmp = false; md.r1 = 0x3F000000; md.r2 = 0x7FFF; }
            else if (v == 192 && geom) { md.r_bmp = m->disp3dcnt >> 14 & 1; md.r1 = md.clr1; md.r2 = md.clr2; }
            if (v == 215 && rend) { md.d_bmp = md.r_bmp; md.d1 = md.r1; md.d2 = md.r2; }
            tick();
            // register writes anywhere in the frame (applied for the next one)
            if (rng() % 40 == 0) {
                u32 which = rng() % 4;
                u32 be = (rng() % 4 == 0) ? 3u << (2 * (rng() % 2)) : 15;
                if (which == 0) io_write(0x04000350, rng(), be, rend);
                else if (which == 1) io_write(0x04000354, rng(), be, rend);
                else if (which == 2) io_write(0x04000010, rng() & 0x1FF, rng() % 4 == 0 ? 1 << (rng() % 2) : 3, rend);
                else m->disp3dcnt = (rng() & 1) << 14;
            }
            if (rng() % 300 == 0) m->powcnt1 = rng() % 4 == 0 ? rng() % 4 : 3;
            for (int k = 0; k < 2200; k++) tick();
            if (v >= 192) continue;
            // the BG job of line v: reads x = 0..255, data a clock later
            u16 xp = md.xpos;
            m->l3d_go = 1; m->l3d_line = v; tick();
            u32 raw[256], want[256], got[256];
            u32 yoff = (md.d2 >> 24) & 0xFF, xoff = (md.d2 >> 16) & 0xFF;
            for (int x = 0; x < 256; x++) {
                if (md.d_bmp) {
                    u16 val = vram[(0x40000 + (((yoff + v) & 0xFF) << 9) + (((xoff + x) & 0xFF) << 1)) >> 1];
                    raw[x] = conv(val, val & 0x8000 ? 0x1F : 0);
                } else raw[x] = conv(md.d1 & 0x7FFF, (md.d1 >> 16) & 0x1F);
            }
            for (int i = 0; i < 256; i++) {
                if (xp == 0) want[i] = raw[i];
                else if (xp & 0x100) want[i] = (i < 512 - xp) ? 0 : raw[i - (512 - xp)];
                else want[i] = (i + xp < 256) ? raw[i + xp] : 0;
            }
            for (int x = 0; x < 256; x++) {       // address in one clock, data after its edge
                m->l3d_raddr = x; m->l3d_line = v;
                tick();
                got[x] = m->l3d_rdata;
            }
            for (int x = 0; x < 256; x++, px++)
                if (got[x] != want[x] && bad++ < 10)
                    printf("frame %d line %d x %d: got %08x want %08x (bmp %d xpos %03x clr2 %08x)\n", f, v, x, got[x], want[x], md.d_bmp, xp, md.d2);
        }
    }
    printf("%s: %ld/%ld px differ over %d frames (seed %u)\n", bad ? "FAIL" : "PASS", bad, px, frames, seed);
    return bad ? 1 : 0;
}
