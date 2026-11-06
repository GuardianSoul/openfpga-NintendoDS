// Synthetic 2D scenes, one or more per feature (docs/2d-engine.md, "Tests").
// Each scene is built from GPU2D register writes and sequenced through
// melonDS's own per-line register updates (golden2d.h Sequencer), with
// random VRAM, palettes and OAM from a fixed seed.
#include <functional>
#include "golden2d.h"

namespace g2d
{
namespace
{
struct Rng
{
    u32 s;
    explicit Rng(u32 seed) : s(seed * 2654435761u + 12345) {}
    u32 next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
    u32 r(u32 n) { return next() % n; }
    bool p(u32 pct) { return r(100) < pct; }
};

struct B
{
    Segment seg;
    Mem* m;
    Sequencer seq;
    Rng rng;
    LineState st {};
    std::function<void(u32, B&)> perline;
    std::vector<Chunk> pending;         // memory writes before the next line
    // rewrite `len` bytes of the memory image at `off` between lines
    void poke(const void* at, u32 len)
    {
        Chunk c;
        c.off = (const u8*)at - (const u8*)m;
        c.data.resize(len);
        for (auto& v : c.data) v = rng.next();
        pending.push_back(std::move(c));
    }
    u32 ylo = 0, yhi = 191;

    B(const std::string& name, u32 seed) : rng(seed)
    {
        seg.name = name;
        seg.mem0 = std::make_shared<Mem>();
        m = seg.mem0.get();
        memset(m, 0, sizeof(Mem));
        st.lcdc = 0;
        for (int e = 0; e < 2; e++) st.e[e].master_bright = 0;
    }
    void w16(int e, u32 a, u16 v) { seq.write16(e, a, v); }
    void w32(int e, u32 a, u32 v) { seq.write32(e, a, v); }

    // random bytes with a share of zero nibbles (transparent pixels)
    void fill(u8* p, size_t n, int zpct)
    {
        for (size_t i = 0; i < n; i++)
        {
            u8 lo = rng.p(zpct) ? 0 : rng.r(16), hi = rng.p(zpct) ? 0 : rng.r(16);
            p[i] = lo | hi << 4;
        }
    }
    void fill_any(u8* p, size_t n) { for (size_t i = 0; i < n; i++) p[i] = rng.next(); }
    // tile maps: 16-bit entries with tile numbers below `ntiles`
    void maps(u8* p, size_t bytes, u32 ntiles)
    {
        for (size_t i = 0; i + 1 < bytes; i += 2)
        {
            u16 v = rng.r(ntiles) | (rng.r(4) << 10) | (rng.r(16) << 12);
            p[i] = v; p[i + 1] = v >> 8;
        }
    }
    void l3d_rand(int zpct)
    {
        for (int i = 0; i < 256; i++)
        {
            u32 a = rng.p(zpct) ? 0 : rng.r(32);
            st.l3d[i] = rng.r(64) | rng.r(64) << 8 | rng.r(64) << 16 | a << 24;
        }
    }
    void memory()
    {
        fill_any(m->palette, sizeof(m->palette));
        fill(m->abg, sizeof(m->abg), 25); fill(m->bbg, sizeof(m->bbg), 25);
        fill(m->aobj, sizeof(m->aobj), 25); fill(m->bobj, sizeof(m->bobj), 25);
        fill_any(m->abgext, sizeof(m->abgext)); fill_any(m->bbgext, sizeof(m->bbgext));
        fill_any(m->aobjext, sizeof(m->aobjext)); fill_any(m->bobjext, sizeof(m->bobjext));
        fill_any((u8*)m->lcdc, sizeof(m->lcdc));
        for (int i = 0; i < 256; i++) st.fifo[i] = rng.next();
        l3d_rand(30);
    }
    // text BG map regions get real map entries (tile numbers in range)
    void text_maps(int e)
    {
        u8* bg = e ? m->bbg : m->abg;
        size_t n = e ? sizeof(m->bbg) : sizeof(m->abg);
        for (size_t o = 0; o < n; o += 0x10000)
            if (rng.p(50)) maps(bg + o, 0x8000, 1024);
    }
    // a random OAM: `kinds` picks the OBJ types
    void oam(int e, int normal, int affine, int bitmap, int window)
    {
        u16* o = (u16*)&m->oam[e ? 0x400 : 0];
        for (int n = 0; n < 128; n++)
        {
            u32 k = rng.r(normal + affine + bitmap + window + 1);
            u16 a0 = rng.r(256), a1 = rng.r(512), a2 = rng.r(1024) | rng.r(4) << 10 | rng.r(16) << 12;
            u32 shape = rng.p(95) ? rng.r(3) : 3, size = rng.r(4);
            a0 |= shape << 14; a1 |= size << 14;
            if (rng.p(30)) a0 |= 1 << 13;                  // 256 colours
            if (rng.p(15)) a0 |= 1 << 12;                  // mosaic
            if (k < (u32)normal)
            {
                a0 |= (rng.p(25) ? 1 : 0) << 10;            // semi-transparent
                a1 |= rng.r(4) << 12;                        // flips
            }
            else if (k < (u32)(normal + affine))
            {
                a0 |= (rng.p(50) ? 1 : 3) << 8;
                a0 |= (rng.p(20) ? 1 : 0) << 10;
                a1 = (a1 & ~0x3E00) | rng.r(32) << 9;
            }
            else if (k < (u32)(normal + affine + bitmap))
            {
                a0 |= 3 << 10;
                if (rng.p(30)) a0 |= (rng.p(50) ? 1 : 3) << 8;
                else a1 |= rng.r(4) << 12;
            }
            else if (k < (u32)(normal + affine + bitmap + window))
            {
                a0 |= 2 << 10;
                if (rng.p(30)) { a0 |= 1 << 8; a1 = (a1 & ~0x3E00) | rng.r(32) << 9; }
            }
            else a0 |= 2 << 8;                               // disabled
            o[n * 4] = a0; o[n * 4 + 1] = a1; o[n * 4 + 2] = a2;
            static const s16 sc[] = {0x100, 0x80, 0x200, 0xC0, -0x100, 0x40};
            o[n * 4 + 3] = rng.p(50) ? sc[rng.r(6)] : (s16)(rng.r(0x400) - 0x200);
        }
    }
    void bgcnt_rand(int e, int bg, bool text)
    {
        u16 v = rng.r(4) | rng.r(16) << 2 | rng.r(32) << 8 | rng.r(4) << 14;
        if (rng.p(40)) v |= 1 << 7;
        if (rng.p(40)) v |= 1 << 13;
        if (!text && rng.p(20)) v |= 1 << 6;
        if (text && rng.p(10)) v |= 1 << 6;
        w16(e, 0x008 + bg * 2, v);
    }
    void affine_rand(int e, int i)
    {
        u32 base = i ? 0x030 : 0x020;
        static const s16 sc[] = {0x100, 0x80, 0x200, 0x180, -0x100, 0, 0x40};
        w16(e, base + 0, rng.p(50) ? sc[rng.r(7)] : rng.r(0x600) - 0x300);
        w16(e, base + 2, rng.p(50) ? 0 : rng.r(0x600) - 0x300);
        w16(e, base + 4, rng.p(50) ? 0 : rng.r(0x600) - 0x300);
        w16(e, base + 6, rng.p(50) ? sc[rng.r(7)] : rng.r(0x600) - 0x300);
        w32(e, base + 8, (rng.next() & 0x0FFFFFFF) >> rng.r(12));
        w32(e, base + 12, (rng.next() & 0x0FFFFFFF) >> rng.r(12));
        if (rng.p(20)) w32(e, base + 8, -(s32)rng.r(0x8000));
    }
    void blend_rand(int e)
    {
        w16(e, 0x050, rng.next() & 0x3FFF);
        w16(e, 0x052, rng.r(20) | rng.r(20) << 8);
        w16(e, 0x054, rng.r(20));
    }
    void windows_rand(int e)
    {
        w16(e, 0x040, rng.r(256) << 8 | rng.r(256));
        w16(e, 0x042, rng.r(256) << 8 | rng.r(256));
        w16(e, 0x044, rng.r(192) << 8 | rng.r(192));
        w16(e, 0x046, rng.r(192) << 8 | rng.r(192));
        w16(e, 0x048, rng.next() & 0x3F3F);
        w16(e, 0x04A, rng.next() & 0x3F3F);
    }

    Segment build()
    {
        auto scratch = std::make_unique<Mem>(*m);
        Golden gold;
        gold.set_mem(*scratch);
        seq.vblank_end();
        std::vector<Chunk> carry;
        for (u32 y = 0; y < 192; y++)
        {
            if (perline) perline(y, *this);
            for (auto& c : pending) memcpy((u8*)scratch.get() + c.off, c.data.data(), c.data.size());
            carry.insert(carry.end(), pending.begin(), pending.end());
            pending.clear();
            LineState s = st;
            s.frame = 0;
            seq.line(y, s, [&](u32* w0, u32* w1) {
                LineOut o;
                gold.scanline(s, o);
                gold.window_state(w0, w1);
            });
            for (int e = 0; e < 2; e++) s.e[e].master_bright = st.e[e].master_bright;
            if (y >= ylo && y <= yhi) { Step sp; sp.st = s; sp.mem = std::move(carry); carry.clear(); seg.steps.push_back(sp); }
        }
        return seg;
    }
};

// DISPCNT helpers
u32 disp(u32 mode, u32 layers, u32 extra = 0) { return mode | layers << 8 | 1 << 16 | extra; }
}

std::vector<Segment> builtin_scenes()
{
    std::vector<Segment> out;
    auto add = [&](B& b) { out.push_back(b.build()); };

    // basic: one text layer per engine, no effects (bring-up scenes)
    for (u32 v = 0; v < 4; v++)
    {
        B b("basic-text-" + std::to_string(v), 300 + v);
        b.memory(); b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(0, 1u << (v & 3)));
            b.w16(e, 0x008 + (v & 3) * 2, (v & 1 ? 0x80 : 0) | 4 << 2 | 2 << 8 | (v >> 1) << 14);
            b.w16(e, 0x010 + (v & 3) * 4, v * 3);
            b.w16(e, 0x012 + (v & 3) * 4, v * 5);
        }
        b.yhi = 15;
        add(b);
    }
    // text layers, both engines, random bases, sizes, scrolls, 4/8bpp
    for (u32 seed = 1; seed <= 3; seed++)
    {
        B b("text-" + std::to_string(seed), seed);
        b.memory();
        b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            u32 x = e ? 0 : (b.rng.r(8) << 24 | b.rng.r(8) << 27);
            b.w32(e, 0, disp(0, 0xF, x | (seed == 3 ? 1u << 30 : 0)));
            for (int bg = 0; bg < 4; bg++)
            {
                b.bgcnt_rand(e, bg, true);
                b.w16(e, 0x010 + bg * 4, seed == 2 ? b.rng.next() : b.rng.r(512));
                b.w16(e, 0x012 + bg * 4, seed == 2 ? b.rng.next() : b.rng.r(512));
            }
            b.blend_rand(e);
            b.w16(e, 0x04C, b.rng.r(256));
        }
        b.perline = [](u32 y, B& b) {
            if (y % 16 == 5) b.w16(b.rng.r(2), 0x010 + b.rng.r(4) * 4, b.rng.next());
            if (y % 32 == 9) b.blend_rand(b.rng.r(2));
        };
        add(b);
    }
    // text with extended palettes and slot swaps
    {
        B b("text-extpal", 11);
        b.memory(); b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(0, 0xF, 1u << 30));
            for (int bg = 0; bg < 4; bg++) { b.bgcnt_rand(e, bg, true); b.w16(e, 0x008 + bg * 2, (b.rng.next() | 0x80) & ~0x40); }
            b.w16(e, 0x050, 0);
        }
        add(b);
    }
    // affine (modes 1, 2) and extended (3, 4, 5) BGs
    for (u32 mode = 1; mode <= 5; mode++)
        for (u32 seed = 0; seed < 2; seed++)
        {
            B b("affine-mode" + std::to_string(mode) + "-" + std::to_string(seed), 20 + mode * 2 + seed);
            b.memory();
            for (int e = 0; e < 2; e++)
            {
                u32 x = e ? 0 : (b.rng.r(8) << 24 | b.rng.r(8) << 27);
                b.w32(e, 0, disp(mode, 0xF, x | (b.rng.p(50) ? 1u << 30 : 0)));
                for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, bg < 2);
                b.affine_rand(e, 0); b.affine_rand(e, 1);
                b.blend_rand(e);
                b.w16(e, 0x04C, b.rng.r(256));
            }
            b.perline = [](u32 y, B& b) {
                if (y % 48 == 17) b.affine_rand(b.rng.r(2), b.rng.r(2));
                if (y % 64 == 3) b.w16(b.rng.r(2), 0x04C, b.rng.r(256));
            };
            add(b);
        }
    // bitmaps in mode 5 with each size and wrap
    for (u32 seed = 0; seed < 2; seed++)
    {
        B b("bitmap-" + std::to_string(seed), 40 + seed);
        b.memory();
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(5, 0xC));
            for (int bg = 2; bg < 4; bg++) b.w16(e, 0x008 + bg * 2, (b.rng.next() & ~0x40) | 0x80);
            b.affine_rand(e, 0); b.affine_rand(e, 1);
            b.blend_rand(e);
        }
        add(b);
    }
    // large bitmap (mode 6) with the 3D layer
    for (u32 seed = 0; seed < 2; seed++)
    {
        B b("large-3d-" + std::to_string(seed), 50 + seed);
        b.memory();
        b.w32(0, 0, disp(6, 0x5, 1u << 3));
        b.w16(0, 0x008, b.rng.r(4));
        b.w16(0, 0x00C, b.rng.next() & ~0x40);
        b.affine_rand(0, 0);
        b.blend_rand(0);
        b.w32(1, 0, disp(0, 0x3));
        add(b);
    }
    // the 3D layer with every colour effect
    for (u32 seed = 0; seed < 3; seed++)
    {
        B b("3d-blend-" + std::to_string(seed), 60 + seed);
        b.memory(); b.text_maps(0);
        b.w32(0, 0, disp(0, 0xF, 1u << 3));
        for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(0, bg, true);
        b.oam(0, 3, 1, 1, 0);
        b.w32(0, 0, disp(0, 0x1F, 1u << 3 | 1u << 4));
        b.perline = [](u32 y, B& b) {
            if (y % 8 == 0) { b.blend_rand(0); b.l3d_rand(40); }
        };
        add(b);
    }
    // windows 0/1 and the OBJ window, coordinates changing per line
    for (u32 seed = 0; seed < 3; seed++)
    {
        B b("windows-" + std::to_string(seed), 70 + seed);
        b.memory(); b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(0, 0x1F, 7u << 13 | 1u << 4));
            for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, true);
            b.oam(e, 2, 1, 0, 2);
            b.windows_rand(e);
            b.blend_rand(e);
        }
        b.perline = [](u32 y, B& b) { if (y % 12 == 4) b.windows_rand(b.rng.r(2)); if (y % 20 == 0) b.blend_rand(b.rng.r(2)); };
        add(b);
    }
    // window edge cases: equal edges (the clear wins), wrap-around, zero width,
    // full width, vertical edges at the line
    {
        B b("windows-edges", 79);
        b.memory(); b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(0, 0x1F, 7u << 13 | 1u << 4));
            for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, true);
            b.oam(e, 2, 0, 0, 2);
            b.w16(e, 0x048, 0x2A15); b.w16(e, 0x04A, 0x3F0E);
        }
        b.perline = [](u32 y, B& b) {
            static const u8 xs[][2] = {{40, 40}, {200, 40}, {0, 0}, {0, 255}, {255, 0}, {128, 129}, {129, 128}, {255, 255}};
            for (int e = 0; e < 2; e++)
            {
                auto& p = xs[(y + e) % 8];
                auto& q = xs[(y / 8 + 3 * e) % 8];
                b.w16(e, 0x040, p[0] << 8 | p[1]);
                b.w16(e, 0x042, q[0] << 8 | q[1]);
                b.w16(e, 0x044, (y % 50) << 8 | ((y + 20) % 192));
                b.w16(e, 0x046, ((y * 7) % 192) << 8 | (y % 192));
            }
        };
        add(b);
    }
    // OBJs: normal, affine/double-size, bitmap, mixed; 1D/2D mappings, boundaries, ext palettes, mosaic
    const char* objn[] = {"obj-normal", "obj-affine", "obj-bitmap", "obj-mixed"};
    for (u32 kind = 0; kind < 4; kind++)
        for (u32 seed = 0; seed < 3; seed++)
        {
            B b(std::string(objn[kind]) + "-" + std::to_string(seed), 80 + kind * 4 + seed);
            b.memory(); b.text_maps(0); b.text_maps(1);
            for (int e = 0; e < 2; e++)
            {
                u32 x = (seed & 1) << 4 | b.rng.r(4) << 20 | (b.rng.p(50) ? 1u << 31 : 0);
                if (kind >= 2) x |= b.rng.r(4) << 5 | b.rng.r(2) << 22;
                b.w32(e, 0, disp(0, 0x13, x));
                for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, true);
                if (kind == 0) b.oam(e, 1, 0, 0, 0);
                else if (kind == 1) b.oam(e, 0, 1, 0, 0);
                else if (kind == 2) b.oam(e, 0, 0, 1, 0);
                else b.oam(e, 3, 2, 1, 1);
                b.blend_rand(e);
                b.w16(e, 0x04C, b.rng.r(256));
            }
            b.perline = [](u32 y, B& b) { if (y % 40 == 7) b.w16(b.rng.r(2), 0x04C, b.rng.r(256)); };
            add(b);
        }
    // VRAM, ext palettes, palette and OAM rewritten between lines: a cache or
    // buffer that kept data across lines would show stale pixels
    for (u32 seed = 0; seed < 2; seed++)
    {
        B b("vram-updates-" + std::to_string(seed), 95 + seed);
        b.memory(); b.text_maps(0); b.text_maps(1);
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(seed ? 5 : 0, 0x1F, 1u << 4 | 1u << 30 | 1u << 31));
            for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, !seed || bg < 2);
            b.affine_rand(e, 0); b.affine_rand(e, 1);
            b.oam(e, 3, 2, 1, 0);
        }
        b.perline = [](u32 y, B& b) {
            // small regions, so the same blocks are read on the next lines
            for (int k = 0; k < 6; k++)
            {
                b.poke(&b.m->abg[b.rng.r(4) * 0x4000 + b.rng.r(64) * 32], 32);
                b.poke(&b.m->bbg[b.rng.r(4) * 0x4000 + b.rng.r(64) * 32], 32);
                b.poke(&b.m->aobj[b.rng.r(256) * 32], 32);
                b.poke(&b.m->bobj[b.rng.r(256) * 32], 32);
            }
            b.poke(&b.m->abgext[b.rng.r(1024) * 32], 32);
            b.poke(&b.m->bbgext[b.rng.r(1024) * 32], 32);
            // BG palettes only: OBJ colours are looked up a line early
            // (docs/2d-engine.md, "Differences from melonDS")
            b.poke(&b.m->palette[(b.rng.r(2) * 0x400) + b.rng.r(16) * 32], 32);
            if (y % 4 == 0) b.poke(&b.m->oam[b.rng.r(256) * 8], 8);
        };
        add(b);
    }
    // master brightness, display modes, engine B off, forced blank, disabled engines
    {
        B b("display-modes", 100);
        b.memory(); b.text_maps(0); b.text_maps(1);
        b.st.lcdc = 0x5;
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, disp(0, 0x1F, 1u << 4));
            for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, true);
            b.oam(e, 2, 1, 1, 0);
        }
        b.perline = [](u32 y, B& b) {
            for (int e = 0; e < 2; e++)
                b.st.e[e].master_bright = b.rng.r(4) << 14 | b.rng.r(32);
            u32 d = b.rng.r(4) << 16 | b.rng.r(4) << 18 | 0x1F10;
            if (y % 24 == 11) d |= 1 << 7;                       // forced blank
            b.w32(0, 0, d);
            b.w32(1, 0, (b.rng.p(80) ? 1u << 16 : 0) | 0x1F10);
            // engines powered off for the rest of the frame (re-enabling mid-frame is
            // a known difference: docs/2d-engine.md, "Differences from melonDS")
            if (y == 120) b.seq.enable(1, false);
            if (y == 150) b.seq.enable(0, false);
            if (y % 32 == 0) b.st.lcdc = b.rng.r(16);
        };
        add(b);
    }
    // display capture: every source, mode, size and offset
    for (u32 seed = 0; seed < 6; seed++)
    {
        B b("capture-" + std::to_string(seed), 110 + seed);
        b.memory(); b.text_maps(0);
        b.st.lcdc = 0xF;
        b.st.cap_enable = 1;
        b.w32(0, 0, disp(0, 0x1F, 1u << 3 | 1u << 4 | (seed & 1 ? 2u << 16 : 0) | b.rng.r(4) << 18));
        for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(0, bg, true);
        b.oam(0, 2, 1, 0, 0);
        b.blend_rand(0);
        b.st.capcnt = b.rng.r(20) | b.rng.r(20) << 8 | b.rng.r(4) << 16 | b.rng.r(4) << 18 | (seed % 4) << 20
                    | b.rng.r(2) << 24 | b.rng.r(2) << 25 | b.rng.r(4) << 26 | (seed % 4) << 29 | 1u << 31;
        b.perline = [](u32 y, B& b) {
            if (y % 16 == 3) b.st.capcnt = (b.st.capcnt & ~0x6300001Fu) | b.rng.r(20) | b.rng.r(2) << 24
                                           | b.rng.r(2) << 25 | b.rng.r(4) << 29;
            if (y % 40 == 30) b.st.lcdc = b.rng.r(16);
            if (y % 8 == 0) b.l3d_rand(40);
        };
        add(b);
    }
    // everything at once, random
    for (u32 seed = 0; seed < 4; seed++)
    {
        B b("all-" + std::to_string(seed), 200 + seed);
        b.memory(); b.text_maps(0); b.text_maps(1);
        b.st.lcdc = b.rng.r(16);
        b.st.cap_enable = b.rng.p(50);
        b.st.capcnt = b.rng.next() | 1u << 31;
        for (int e = 0; e < 2; e++)
        {
            b.w32(e, 0, (b.rng.next() & ~0x80u & ~(3u << 16)) | 1u << 16);
            for (int bg = 0; bg < 4; bg++) b.bgcnt_rand(e, bg, b.rng.p(50));
            b.affine_rand(e, 0); b.affine_rand(e, 1);
            b.oam(e, 3, 2, 1, 1);
            b.windows_rand(e); b.blend_rand(e);
            b.w16(e, 0x04C, b.rng.r(256));
            b.st.e[e].master_bright = b.rng.r(4) << 14 | b.rng.r(32);
        }
        b.perline = [](u32 y, B& b) {
            int e = b.rng.r(2);
            switch (y % 7)
            {
            case 0: b.windows_rand(e); break;
            case 2: b.blend_rand(e); break;
            case 4: b.w16(e, 0x010 + b.rng.r(4) * 4, b.rng.next()); break;
            case 5: if (y % 35 == 5) b.affine_rand(e, b.rng.r(2)); break;
            default: break;
            }
            if (y % 8 == 0) b.l3d_rand(40);
        };
        add(b);
    }
    return out;
}
}
