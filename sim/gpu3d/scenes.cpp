// Synthetic renderer scenes, one or more per renderer feature, until census
// captures (docs/plan.md 0.1) replace them. Every scene is deterministic.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include "scene.h"

namespace g3d
{

namespace
{

struct Rng
{
    std::mt19937 m;
    explicit Rng(uint32_t seed) : m(seed) {}
    int range(int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(m); }
    bool chance(int pct) { return range(0, 99) < pct; }
    uint32_t bits(int n) { return n >= 32 ? (uint32_t)m() : (uint32_t)m() & ((1u << n) - 1); }
};

uint16_t rgb15(int r, int g, int b) { return (r & 31) | ((g & 31) << 5) | ((b & 31) << 10); }

struct Feat
{
    bool tex = false;          // random texture parameters
    bool translucent = 0;      // some polygons translucent
    bool wire = false;         // some wireframe polygons
    bool toon = false;         // blend mode 2 allowed
    bool equal_w = false;      // all vertices share one W (linear path)
    bool wlow = false;         // ... with bit 6 or bit 0 set: linear along one axis only (DS_YPERSP's 0x3F vs 0x7E)
    int linear_pct = 15;       // otherwise, chance a polygon has equal W
    int max_rad = 70;
    int maxv = 6;
    int depth_equal_pct = 5;
    int fog_pct = 50;
    int flip_pct = 4;          // facing that disagrees with screen winding
    bool wbuffer = false;
};

void fill_vram(Scene& sc, Rng& r)
{
    for (auto& b : sc.tex) b = r.bits(8);
    for (auto& b : sc.pal) b = r.bits(8);
}

void random_tables(Scene& sc, Rng& r)
{
    for (auto& t : sc.toon) t = r.bits(15);
    for (auto& e : sc.edge) e = r.bits(15);
    int acc = 0;
    for (auto& f : sc.fog_table) { acc += r.range(0, 8); f = std::min(acc, 127); }
    sc.fog_color = r.bits(15) | (r.bits(5) << 16);
}

uint32_t random_texparam(Rng& r)
{
    uint32_t fmt = r.range(1, 7);
    uint32_t ss = r.chance(80) ? r.range(0, 4) : r.range(0, 7);
    uint32_t ts = r.chance(80) ? r.range(0, 4) : r.range(0, 7);
    return r.bits(16) | (r.bits(4) << 16) | (ss << 20) | (ts << 23) | (fmt << 26) | (r.bits(1) << 29);
}

Poly random_poly(Rng& r, const Feat& f)
{
    Poly p;
    int n = r.chance(45) ? 3 : r.chance(70) ? 4 : r.range(5, f.maxv);
    double cx = r.range(-30, 300), cy = r.range(-20, 210);
    double rad = r.chance(10) ? r.range(0, 4) : r.range(2, f.max_rad);
    double sx = r.range(50, 150) / 100.0, sy = r.range(50, 150) / 100.0;
    std::vector<double> ang(n);
    for (auto& a : ang) a = r.range(0, 35999) / 18000.0 * M_PI;
    std::sort(ang.begin(), ang.end());
    bool ccw = r.chance(50);
    if (ccw) std::reverse(ang.begin(), ang.end());
    uint32_t wbase = f.equal_w || r.chance(f.linear_pct) ? (r.range(1, 511) << 7) : 0;
    if (wbase && f.wlow) wbase |= r.chance(50) ? 0x40 : 0x01;
    uint32_t zbase = r.bits(24), zspan = r.chance(30) ? r.bits(12) : r.bits(22);
    for (int i = 0; i < n; i++)
    {
        Vtx v;
        v.x = std::clamp((int)std::lround(cx + rad * sx * std::cos(ang[i])), 0, 511);
        v.y = std::clamp((int)std::lround(cy + rad * sy * std::sin(ang[i])), 0, 192);
        v.w = wbase ? wbase : (uint32_t)r.range(0x100, 0xFFFF);
        uint32_t z = zbase + (r.bits(24) % (zspan + 1));
        v.z = std::min<uint32_t>(z, 0xFFFFFF);
        if (f.wbuffer && r.chance(70)) v.z = std::min<uint32_t>(v.w << r.range(0, 8), 0xFFFFFF);
        v.r = r.bits(9); v.g = r.bits(9); v.b = r.bits(9);
        if (r.chance(30)) { int c = r.bits(5); v.r = c ? (c << 4) + 15 : 0; v.g = v.r; v.b = v.r; }
        v.s = (int16_t)r.range(-2048, 8192);
        v.t = (int16_t)r.range(-2048, 8192);
        p.v.push_back(v);
    }
    double area = 0;
    for (int i = 0; i < n; i++)
    {
        const Vtx &a = p.v[i], &b = p.v[(i + 1) % n];
        area += (double)a.x * b.y - (double)b.x * a.y;
    }
    p.facing = area < 0;
    if (r.chance(f.flip_pct)) p.facing = !p.facing;

    uint32_t alpha = 31;
    if (f.translucent && r.chance(40)) alpha = r.range(1, 30);
    if (f.wire && r.chance(15)) alpha = 0;
    uint32_t mode = f.toon ? r.range(0, 2) : r.range(0, 1);
    p.attr = (mode << 4) | (alpha << 16) | (r.bits(6) << 24);
    if (r.chance(50)) p.attr |= 1 << 11;
    if (r.chance(f.depth_equal_pct)) p.attr |= 1 << 14;
    if (r.chance(f.fog_pct)) p.attr |= 1 << 15;
    if (f.tex && r.chance(75))
    {
        p.texparam = random_texparam(r);
        p.texpal = r.bits(13);
    }
    p.wbuffer = f.wbuffer;
    return p;
}

void ysort(Scene& sc)
{
    std::stable_sort(sc.polys.begin(), sc.polys.end(), [](const Poly& a, const Poly& b) {
        PolyDerived da = derive(a), db = derive(b);
        uint32_t ka = (da.ybot << 8) | da.ytop | (da.translucent ? 0x10000 : 0);
        uint32_t kb = (db.ybot << 8) | db.ytop | (db.translucent ? 0x10000 : 0);
        return ka < kb;
    });
}

Scene random_scene(const std::string& name, uint32_t seed, uint32_t dispcnt, int npolys, const Feat& f)
{
    Scene sc;
    sc.name = name;
    Rng r(seed);
    fill_vram(sc, r);
    random_tables(sc, r);
    sc.dispcnt = dispcnt;
    sc.clear_attr1 = r.bits(15) | (r.bits(1) << 15) | (r.range(0, 31) << 16) | (r.bits(6) << 24);
    sc.clear_attr2 = r.chance(80) ? 0x7FFF - r.bits(8) : r.bits(15);
    sc.fog_offset = r.bits(15);
    for (int i = 0; i < npolys; i++) sc.polys.push_back(random_poly(r, f));
    ysort(sc);
    return sc;
}

Vtx V(int x, int y, uint32_t z, uint32_t w, int r, int g, int b, int s = 0, int t = 0)
{
    Vtx v; v.x = x; v.y = y; v.z = z; v.w = w; v.r = r; v.g = g; v.b = b; v.s = s; v.t = t;
    return v;
}

// Hand-placed shapes covering the edge-walk cases: vertical edges, 45-degree
// edges, x-major and y-major slopes both ways, a single-line polygon,
// polygons touching the screen edges, one past x=255 and a swapped span.
Scene shapes_scene(const std::string& name, uint32_t dispcnt)
{
    Scene sc;
    sc.name = name;
    sc.dispcnt = dispcnt;
    sc.clear_attr1 = rgb15(4, 4, 8) | (31 << 16) | (63u << 24);
    sc.clear_attr2 = 0x7FFF;
    for (int i = 0; i < 8; i++) sc.edge[i] = rgb15(31 - i * 3, i * 4, 16);
    auto quad = [&](std::vector<Vtx> v, uint32_t id, bool facing = true) {
        Poly p; p.v = v; p.attr = (31 << 16) | (id << 24); p.facing = facing;
        sc.polys.push_back(p);
    };
    const uint32_t W = 0x1000;
    // axis-aligned rectangle (vertical edges): top-left, bottom-left, bottom-right, top-right
    quad({V(10, 10, 0x100000, W, 511, 0, 0), V(10, 40, 0x100000, W, 511, 0, 0),
          V(60, 40, 0x100000, W, 511, 0, 0), V(60, 10, 0x100000, W, 511, 0, 0)}, 1);
    // 45-degree diamond
    quad({V(100, 5, 0x200000, W, 0, 511, 0), V(80, 25, 0x200000, W, 0, 511, 0),
          V(100, 45, 0x200000, W, 0, 511, 0), V(120, 25, 0x200000, W, 0, 511, 0)}, 2);
    // x-major thin triangle
    quad({V(130, 10, 0x300000, W, 0, 0, 511), V(135, 18, 0x300000, 0x2000, 0, 200, 511),
          V(250, 14, 0x300000, 0x3000, 300, 0, 511)}, 3);
    // y-major steep triangle
    quad({V(20, 50, 0x180000, 0x0800, 400, 400, 0), V(15, 150, 0x180000, 0x4000, 0, 400, 400),
          V(30, 120, 0x180000, 0x8000, 400, 0, 400)}, 4);
    // single-line polygon (ytop == ybot)
    quad({V(40, 60, 0x100000, W, 511, 511, 511), V(90, 60, 0x100000, W, 511, 511, 511),
          V(70, 60, 0x100000, W, 511, 511, 511)}, 5);
    // touching top-left corner and bottom edge
    quad({V(0, 0, 0x080000, W, 200, 100, 50), V(0, 192, 0x080000, W, 200, 100, 50),
          V(8, 192, 0x080000, W, 200, 100, 50)}, 6);
    // extends past x=255
    quad({V(230, 60, 0x0C0000, 0x1800, 100, 300, 200), V(200, 110, 0x0C0000, 0x1800, 100, 300, 200),
          V(300, 120, 0x0C0000, 0x1800, 100, 300, 200), V(320, 70, 0x0C0000, 0x1800, 100, 300, 200)}, 7);
    // same quad with the facing flag reversed -> swapped spans
    quad({V(150, 60, 0x0A0000, W, 50, 50, 300), V(120, 110, 0x0A0000, W, 50, 50, 300),
          V(190, 120, 0x0A0000, W, 50, 50, 300), V(200, 70, 0x0A0000, W, 50, 50, 300)}, 8, false);
    // overlapping depth-tested pair
    quad({V(60, 130, 0x400000, 0x1000, 511, 0, 511), V(50, 180, 0x200000, 0x3000, 511, 0, 511),
          V(140, 185, 0x200000, 0x5000, 511, 0, 511), V(150, 135, 0x400000, 0x2000, 511, 0, 511)}, 9);
    quad({V(100, 120, 0x300000, 0x1000, 0, 511, 511), V(70, 170, 0x300000, 0x1000, 0, 511, 511),
          V(170, 175, 0x300000, 0x1000, 0, 511, 511)}, 10);
    // back-facing then front-facing at equal depth (front wins with <=)
    quad({V(200, 140, 0x500000, W, 511, 300, 0), V(250, 140, 0x500000, W, 511, 300, 0),
          V(225, 185, 0x500000, W, 511, 300, 0)}, 11, false);
    quad({V(200, 140, 0x500000, W, 0, 300, 511), V(225, 185, 0x500000, W, 0, 300, 511),
          V(250, 140, 0x500000, W, 0, 300, 511)}, 12, true);
    return sc;
}

// One quad per texture format and wrap mode, textured with structured data
// so wrap/flip/clamp mistakes are visible in the diff images.
Scene texture_scene(const std::string& name, uint32_t seed, bool perspective, bool decal)
{
    Scene sc;
    sc.name = name;
    Rng r(seed);
    fill_vram(sc, r);
    sc.dispcnt = 1 | (1 << 3);
    sc.clear_attr1 = rgb15(0, 8, 0) | (31 << 16) | (1u << 24);
    int i = 0;
    for (uint32_t fmt = 1; fmt <= 7; fmt++)
        for (uint32_t wrap = 0; wrap < 4; wrap++, i++)
        {
            int cx = 16 + (i % 8) * 31, cy = 18 + (i / 8) * 40;
            uint32_t ss = r.range(0, 3), ts = r.range(0, 3);
            int ws = 8 << ss, hs = 8 << ts;
            uint32_t rep = wrap == 0 ? 0 : wrap == 1 ? 3 : 0xF;
            if (wrap == 3) rep = 0x5;
            uint32_t off = r.bits(16);
            if (fmt == 5) off = (r.chance(50) ? 0 : 0x8000) + r.bits(12); // texels in slot 0 or 2
            Poly p;
            p.texparam = off | (rep << 16) | (ss << 20) | (ts << 23) | (fmt << 26) | ((wrap & 1) << 29);
            p.texpal = r.bits(13);
            p.attr = ((decal ? 1u : 0u) << 4) | (31 << 16) | ((uint32_t)i << 24);
            uint32_t w0 = perspective ? 0x0800 : 0x1000, w1 = perspective ? 0x6000 : 0x1000;
            int s0 = -ws * 8, s1 = ws * 16 * 2, t0 = -hs * 8, t1 = hs * 16 * 2;
            p.v = {V(cx - 14, cy - 17, 0x100000, w0, 511, 511, 511, s0, t0),
                   V(cx - 14, cy + 17, 0x100000, w0, 300, 400, 511, s0, t1),
                   V(cx + 14, cy + 17, 0x100000, w1, 511, 200, 100, s1, t1),
                   V(cx + 14, cy - 17, 0x100000, w1, 100, 511, 300, s1, t0)};
            p.facing = true;
            sc.polys.push_back(p);
        }
    return sc;
}

// Direct-colour 32x32 texture whose texel (s,t) has colour (s, t, 0):
// output colour shows the sampled coordinates directly.
Scene texcoord_scene(const std::string& name, bool perspective)
{
    Scene sc;
    sc.name = name;
    sc.dispcnt = 1;
    sc.clear_attr1 = (31 << 16);
    for (int t = 0; t < 32; t++)
        for (int s = 0; s < 32; s++)
        {
            uint16_t c = rgb15(s, t, 0) | 0x8000;
            sc.tex[(t * 32 + s) * 2] = c & 0xFF;
            sc.tex[(t * 32 + s) * 2 + 1] = c >> 8;
        }
    Poly p;
    p.texparam = (2u << 20) | (2u << 23) | (7u << 26);
    p.attr = (1 << 4) | (31 << 16);
    uint32_t w0 = perspective ? 0x0800 : 0x1000, w1 = perspective ? 0x7000 : 0x1000;
    p.v = {V(20, 20, 0x100000, w0, 0, 0, 0, 0, 0), V(30, 170, 0x100000, w0, 0, 0, 0, 0, 32 * 16 - 1),
           V(230, 160, 0x100000, w1, 0, 0, 0, 32 * 16 - 1, 32 * 16 - 1), V(220, 30, 0x100000, w1, 0, 0, 0, 32 * 16 - 1, 0)};
    sc.polys.push_back(p);
    return sc;
}

// Depth-test boundaries: flat-Z overlays at exact offsets from a flat-Z
// background, for the equal test (bit 14, +-0x200 Z / +-0xFF W) and the
// less / less-or-equal tests (front over back-facing).
Scene depth_edge_scene(const std::string& name, bool wbuffer)
{
    Scene sc;
    sc.name = name;
    sc.clear_attr1 = rgb15(0, 0, 8) | (31 << 16);
    const uint32_t Z0 = wbuffer ? 0x8000 : 0x400000;
    const int lim = wbuffer ? 0xFF : 0x200;
    const int offs[] = {-lim - 2, -lim - 1, -lim, -lim + 1, -1, 0, 1, lim - 1, lim, lim + 1, lim + 2};
    for (int band = 0; band < 2; band++)
    {
        // background: one back-facing (band 1) or front-facing (band 0) strip
        Poly bg;
        int y0 = 10 + band * 90, y1 = y0 + 80;
        bool back = band == 1;
        bg.v = {V(0, y0, Z0, 0x1000, 100, 100, 100), V(0, y1, Z0, 0x1000, 100, 100, 100),
                V(255, y1, Z0, 0x1000, 100, 100, 100), V(255, y0, Z0, 0x1000, 100, 100, 100)};
        bg.facing = !back;
        if (back) std::swap(bg.v[1], bg.v[3]);
        bg.attr = (31 << 16) | (1u << 24);
        bg.wbuffer = wbuffer;
        sc.polys.push_back(bg);
        for (int i = 0; i < 11; i++)
            for (int eq = 0; eq < 2; eq++)
            {
                Poly p;
                int x0 = 4 + i * 23, ya = y0 + 4 + eq * 38;
                uint32_t z = Z0 + offs[i];
                p.v = {V(x0, ya, z, 0x1000, 500, 100 * eq, 40 * i), V(x0, ya + 34, z, 0x1000, 500, 100 * eq, 40 * i),
                       V(x0 + 20, ya + 34, z, 0x1000, 500, 100 * eq, 40 * i), V(x0 + 20, ya, z, 0x1000, 500, 100 * eq, 40 * i)};
                p.attr = (31 << 16) | ((uint32_t)(2 + i) << 24) | (eq ? 1u << 14 : 0);
                p.wbuffer = wbuffer;
                sc.polys.push_back(p);
            }
    }
    return sc;
}

// Fog table edges: entries near 126/127, every shift, bands of flat Z
// stepping through the density table so integer and fractional parts and
// the >=127 -> 128 clamp are all hit.
Scene fog_edge_scene(const std::string& name, uint32_t shift, uint32_t seed)
{
    Scene sc;
    sc.name = name;
    Rng r(seed);
    sc.dispcnt = (1 << 7) | (shift << 8);
    sc.clear_attr1 = rgb15(31, 0, 0) | (31 << 16) | (1u << 15);
    sc.fog_color = rgb15(0, 31, 0) | (17 << 16);
    sc.fog_offset = 0x0400;
    static const uint8_t tbl[32] = {0, 2, 4, 30, 60, 100, 120, 124, 125, 126, 127, 127, 126, 125, 127, 126,
                                    1, 0, 64, 65, 126, 125, 127, 124, 126, 126, 127, 120, 110, 126, 127, 127};
    for (int i = 0; i < 32; i++) sc.fog_table[i] = tbl[i];
    // band k covers z so that density index sweeps 0..32 with fractions
    for (int k = 0; k < 96; k++)
    {
        Poly p;
        int x0 = (k % 12) * 21, y0 = (k / 12) * 24;
        uint32_t step = 0x80000u >> shift;                // one table entry
        uint32_t z = 0x0400 * 0x200 + (uint32_t)(k * step / 3) + r.bits(4);
        z = std::min<uint32_t>(z, 0xFFFFFF);
        uint32_t z2 = std::min<uint32_t>(z + step / 3, 0xFFFFFF);
        p.v = {V(x0, y0, z, 0x1000, 300, 300, 300), V(x0, y0 + 22, z2, 0x1000, 300, 300, 300),
               V(x0 + 20, y0 + 22, z2, 0x1000, 300, 300, 300), V(x0 + 20, y0, z, 0x1000, 300, 300, 300)};
        p.attr = (31 << 16) | (1u << 15) | ((uint32_t)(k & 63) << 24);
        sc.polys.push_back(p);
    }
    return sc;
}

// Shadow volumes as games draw them (manual translucent sort): opaque
// receivers, then per shadow a mask polygon (mode 3, id 0) or two and a
// shadow polygon (mode 3, id != 0) over the same area.
Scene shadow_scene(const std::string& name, uint32_t seed, uint32_t dispcnt, bool wbuffer)
{
    Scene sc;
    sc.name = name;
    Rng r(seed);
    fill_vram(sc, r);
    random_tables(sc, r);
    sc.dispcnt = dispcnt;
    sc.clear_attr1 = rgb15(6, 6, 12) | (31 << 16) | (r.bits(6) << 24);
    sc.clear_attr2 = 0x7FFF;
    Feat f; f.wbuffer = wbuffer; f.tex = (dispcnt & 1) != 0; f.max_rad = 60;
    std::vector<Poly> opaque, trans;
    for (int i = 0; i < 40; i++)
    {
        Poly p = random_poly(r, f);
        p.attr = (p.attr & ~0x001F0030u) | (31u << 16);
        opaque.push_back(p);
    }
    for (int i = 0; i < 24; i++)
    {
        Feat sf = f; sf.max_rad = 70; sf.tex = false; sf.flip_pct = 0;
        Poly mask = random_poly(r, sf);
        int zmode = r.range(0, 9);   // far (fails against most receivers), mid, or random
        for (auto& v : mask.v)
            if (zmode < 4) v.z = 0xFFFFFF - r.bits(12);
            else if (zmode < 7) v.z = 0x600000 + r.bits(22);
        uint32_t a = r.chance(15) ? 31 : r.range(1, 30);
        mask.attr = (3u << 4) | (a << 16) | (r.chance(50) ? 1u << 11 : 0) | (r.chance(10) ? 1u << 14 : 0);
        trans.push_back(mask);
        if (r.chance(40))
        {
            Poly m2 = mask;
            for (auto& v : m2.v) v.z = std::min<uint32_t>(v.z + r.bits(16), 0xFFFFFF);
            m2.facing = !m2.facing;
            trans.push_back(m2);
        }
        Poly sh = mask;
        uint32_t sa = r.chance(10) ? 31 : r.range(1, 30);
        sh.attr = (3u << 4) | (sa << 16) | ((uint32_t)r.range(1, 63) << 24) | (r.chance(50) ? 1u << 15 : 0);
        bool near = r.chance(80);
        for (auto& v : sh.v) { v.z = near ? r.bits(10) : v.z; v.r = r.bits(9); v.g = r.bits(9); v.b = r.bits(9); }
        if (f.tex && r.chance(30)) { sh.texparam = random_texparam(r); sh.texpal = r.bits(13); }
        trans.push_back(sh);
        if (r.chance(20)) trans.push_back(random_poly(r, sf));   // an ordinary polygon in between
    }
    sc.polys = opaque;
    ysort(sc);                                                  // opaque polygons only
    for (auto& p : trans) sc.polys.push_back(p);
    return sc;
}

// Shadow on the lower layer: AA on, a far receiver under many thin near
// slivers (their edge pixels push the far one down), depth-equal masks at
// the slivers' depth (stencil bit 1 only), and shadows between the two
// depths, so they draw on the lower layer only.
Scene shadow_layers_scene(const std::string& name, uint32_t seed)
{
    Scene sc;
    sc.name = name;
    Rng r(seed);
    sc.dispcnt = (1 << 3) | (1 << 4);
    sc.clear_attr1 = rgb15(2, 2, 2) | (31 << 16);
    Poly far;
    far.v = {V(0, 0, 0x500000, 0x1000, 400, 400, 100), V(0, 192, 0x500000, 0x1000, 400, 400, 100),
             V(255, 192, 0x500000, 0x1000, 400, 400, 100), V(255, 0, 0x500000, 0x1000, 400, 400, 100)};
    far.attr = (31 << 16) | (1u << 24);
    sc.polys.push_back(far);
    for (int i = 0; i < 60; i++)
    {
        Poly p;
        int x = r.range(0, 250), y = r.range(0, 180), w = r.range(1, 6), h = r.range(6, 40);
        int dx = std::max(r.range(-12, 12), -x);
        p.v = {V(x, y, 0x300000, 0x1000, 100, 200, 500), V(x + dx, std::min(y + h, 192), 0x300000, 0x1000, 100, 200, 500),
               V(x + dx + w, std::min(y + h, 192), 0x300000, 0x1000, 100, 200, 500), V(x + w, y, 0x300000, 0x1000, 100, 200, 500)};
        p.attr = (31 << 16) | ((uint32_t)r.range(2, 63) << 24);
        sc.polys.push_back(p);
    }
    for (int i = 0; i < 10; i++)
    {
        int x = r.range(0, 200), y = r.range(0, 150), w = r.range(20, 60), h = r.range(20, 50);
        Poly m;
        m.v = {V(x, y, 0x300000, 0x1000, 0, 0, 0), V(x, std::min(y + h, 192), 0x300000, 0x1000, 0, 0, 0),
               V(x + w, std::min(y + h, 192), 0x300000, 0x1000, 0, 0, 0), V(x + w, y, 0x300000, 0x1000, 0, 0, 0)};
        m.attr = (3u << 4) | (10u << 16) | (1u << 14);
        sc.polys.push_back(m);
        Poly sh = m;
        for (auto& v : sh.v) { v.z = 0x400000; v.r = 0; v.g = 0; v.b = 0; }
        sh.attr = (3u << 4) | (16u << 16) | ((uint32_t)r.range(1, 63) << 24);
        sc.polys.push_back(sh);
    }
    return sc;
}

} // namespace

std::vector<Scene> builtin_scenes()
{
    std::vector<Scene> v;
    Feat plain;
    v.push_back(shapes_scene("shapes", 0));
    v.push_back(shapes_scene("shapes_aa", 1 << 4));
    v.push_back(shapes_scene("shapes_edge", 1 << 5));
    v.push_back(random_scene("flat_gouraud", 11, 0, 60, plain));
    {
        Feat f; f.equal_w = true;
        v.push_back(random_scene("linear_w", 12, 0, 60, f));
        f.wlow = true;
        v.push_back(random_scene("linear_wmask", 13, 0, 60, f));
    }
    v.push_back(texcoord_scene("texcoord_linear", false));
    v.push_back(texcoord_scene("texcoord_persp", true));
    v.push_back(texture_scene("tex_formats_linear", 21, false, false));
    v.push_back(texture_scene("tex_formats_persp", 22, true, false));
    v.push_back(texture_scene("tex_formats_decal", 23, true, true));
    {
        Feat f; f.tex = true;
        v.push_back(random_scene("tex_random", 24, 1, 80, f));
    }
    {
        Feat f; f.wbuffer = true; f.tex = true;
        v.push_back(random_scene("wbuffer", 31, 1, 80, f));
        f.depth_equal_pct = 30;
        v.push_back(random_scene("wbuffer_equal", 32, 1, 80, f));
    }
    {
        Feat f; f.depth_equal_pct = 30;
        v.push_back(random_scene("zbuffer_equal", 33, 0, 80, f));
    }
    // normalized W can be 0 at a vertex whose raw W is far below the
    // polygon's largest (GPU3D.cpp shifts it out); the perspective factor
    // is then 0 or exactly 256 along X
    for (int wb = 0; wb < 2; wb++)
    {
        Feat f; f.tex = true; f.wbuffer = wb;
        Scene sc = random_scene(wb ? "w_zero_wbuf" : "w_zero", 34 + wb, 1, 80, f);
        Rng r(77 + wb);
        for (auto& p : sc.polys)
        {
            p.w_shifted_out = true;
            for (auto& vx : p.v)
                if (r.chance(35)) vx.w = 0;
        }
        v.push_back(sc);
    }
    v.push_back(depth_edge_scene("depth_edges_z", false));
    v.push_back(depth_edge_scene("depth_edges_w", true));
    {
        Feat f; f.translucent = true; f.tex = true;
        v.push_back(random_scene("blend", 41, 1 | (1 << 3), 80, f));
        v.push_back(random_scene("blend_off", 42, 1, 80, f));
        Scene sc = random_scene("alpha_test", 43, 1 | (1 << 2) | (1 << 3), 80, f);
        sc.alpharef = 12;
        v.push_back(sc);
    }
    {
        Feat f; f.toon = true; f.tex = true;
        v.push_back(random_scene("toon", 51, 1, 60, f));
        v.push_back(random_scene("highlight", 52, 1 | (1 << 1), 60, f));
    }
    {
        Feat f; f.translucent = true;
        v.push_back(random_scene("aa", 61, (1 << 4) | (1 << 3), 80, f));
        f.tex = true;
        v.push_back(random_scene("aa_tex", 62, 1 | (1 << 4) | (1 << 3), 80, f));
        // transparent clear colour, as games use under the 2D layers
        for (int k = 0; k < 2; k++)
        {
            Scene sc = random_scene(k ? "aa_clear0_fog" : "aa_clear0", 63 + k,
                                    1 | (1 << 4) | (1 << 3) | (k ? (1 << 7) | (4 << 8) : 0), 80, f);
            sc.clear_attr1 &= ~0x001F0000u;
            v.push_back(sc);
        }
    }
    {
        Feat f;
        v.push_back(random_scene("edgemark", 71, 1 << 5, 80, f));
        f.translucent = true;
        v.push_back(random_scene("edgemark_aa", 72, (1 << 5) | (1 << 4) | (1 << 3), 80, f));
    }
    {
        Feat f; f.translucent = true;
        v.push_back(random_scene("fog", 81, (1 << 7) | (1 << 3) | (6 << 8), 80, f));
        v.push_back(random_scene("fog_alpha_only", 82, (1 << 7) | (1 << 6) | (1 << 3) | (3 << 8), 80, f));
        v.push_back(random_scene("fog_aa", 83, (1 << 7) | (1 << 4) | (1 << 3) | (10 << 8), 80, f));
        v.push_back(random_scene("fog_wrap", 84, (1 << 7) | (15 << 8), 80, f));
        for (uint32_t sh : {0u, 2u, 5u, 9u, 12u})
            v.push_back(fog_edge_scene("fog_edges_s" + std::to_string(sh), sh, 85 + sh));
    }
    {
        Feat f; f.wire = true; f.translucent = true;
        v.push_back(random_scene("wireframe", 91, 1 << 3, 80, f));
        v.push_back(random_scene("wireframe_aa", 92, (1 << 3) | (1 << 4), 80, f));
    }
    v.push_back(shadow_scene("shadow", 111, 1 << 3, false));
    v.push_back(shadow_scene("shadow_aa", 112, (1 << 3) | (1 << 4), false));
    v.push_back(shadow_scene("shadow_w_tex", 113, 1 | (1 << 3) | (1 << 4) | (1 << 5), true));
    v.push_back(shadow_scene("shadow_noblend", 114, 1 << 4, false));
    v.push_back(shadow_layers_scene("shadow_layers", 115));
    {
        // Pokemon-style state: AA, edge marking, blending, fog, toon, textures.
        Feat f; f.tex = true; f.translucent = true; f.toon = true; f.max_rad = 40;
        v.push_back(random_scene("pokemon_mix", 101, 1 | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 7) | (5 << 8), 300, f));
    }
    for (uint32_t seed = 0; seed < 16; seed++) v.push_back(random_mix_scene(seed));
    return v;
}

// Random render state and polygons; seeds 0..15 are built in, others are
// for `tb_gpu3d --random N --seed S` stress runs.
Scene random_mix_scene(uint32_t seed)
{
    Rng r(1000 + seed);
    Feat f;
    f.tex = r.chance(70); f.translucent = r.chance(60); f.toon = r.chance(40);
    f.wire = r.chance(20); f.wbuffer = r.chance(30); f.equal_w = r.chance(15);
    f.max_rad = r.range(10, 90);
    f.maxv = r.chance(30) ? 10 : 6;
    uint32_t dc = r.bits(12) & ~(1u << 2);
    char nm[32]; snprintf(nm, sizeof nm, "random_%02u", seed);
    Scene sc = random_scene(nm, 2000 + seed, dc, r.range(20, 200), f);
    if (r.chance(30)) { sc.dispcnt |= 1 << 2; sc.alpharef = r.range(0, 30); }
    return sc;
}

// Scene file: little-endian, "G3DSCN01", then the fields in struct order.
// Census captures (plan 0.1) can be written in this format and replayed with
// `tb_gpu3d --scene <file>`.
namespace
{
template<typename T> void put(FILE* f, const T& v) { fwrite(&v, sizeof v, 1, f); }
template<typename T> bool get(FILE* f, T& v) { return fread(&v, sizeof v, 1, f) == 1; }
}

bool save_scene(const Scene& sc, const std::string& path)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;
    fwrite("G3DSCN01", 8, 1, f);
    put(f, sc.dispcnt); put(f, sc.alpharef); put(f, sc.clear_attr1); put(f, sc.clear_attr2);
    put(f, sc.fog_color); put(f, sc.fog_offset);
    put(f, sc.toon); put(f, sc.edge); put(f, sc.fog_table);
    fwrite(sc.tex.data(), 1, sc.tex.size(), f);
    fwrite(sc.pal.data(), 1, sc.pal.size(), f);
    uint32_t n = sc.polys.size();
    put(f, n);
    for (const Poly& p : sc.polys)
    {
        uint32_t nv = p.v.size();
        uint8_t facing = p.facing, wb = p.wbuffer;
        put(f, nv); put(f, p.attr); put(f, p.texparam); put(f, p.texpal); put(f, facing); put(f, wb);
        for (const Vtx& v : p.v)
        {
            int32_t x = v.x, y = v.y, r = v.r, g = v.g, b = v.b;
            put(f, x); put(f, y); put(f, v.z); put(f, v.w); put(f, r); put(f, g); put(f, b); put(f, v.s); put(f, v.t);
        }
    }
    fclose(f);
    return true;
}

bool load_scene(Scene& sc, const std::string& path)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    char magic[8];
    bool ok = fread(magic, 8, 1, f) == 1 && !memcmp(magic, "G3DSCN01", 8);
    ok = ok && get(f, sc.dispcnt) && get(f, sc.alpharef) && get(f, sc.clear_attr1) && get(f, sc.clear_attr2)
            && get(f, sc.fog_color) && get(f, sc.fog_offset)
            && get(f, sc.toon) && get(f, sc.edge) && get(f, sc.fog_table)
            && fread(sc.tex.data(), 1, sc.tex.size(), f) == sc.tex.size()
            && fread(sc.pal.data(), 1, sc.pal.size(), f) == sc.pal.size();
    uint32_t n = 0;
    ok = ok && get(f, n) && n <= 2048;
    for (uint32_t i = 0; ok && i < n; i++)
    {
        Poly p;
        uint32_t nv; uint8_t facing, wb;
        ok = get(f, nv) && nv <= 10 && get(f, p.attr) && get(f, p.texparam) && get(f, p.texpal) && get(f, facing) && get(f, wb);
        p.facing = facing; p.wbuffer = wb;
        for (uint32_t j = 0; ok && j < nv; j++)
        {
            Vtx v; int32_t x, y, r, g, b;
            ok = get(f, x) && get(f, y) && get(f, v.z) && get(f, v.w) && get(f, r) && get(f, g) && get(f, b) && get(f, v.s) && get(f, v.t);
            v.x = x; v.y = y; v.r = r; v.g = g; v.b = b;
            p.v.push_back(v);
        }
        sc.polys.push_back(p);
    }
    fclose(f);
    if (sc.name.empty()) sc.name = path;
    return ok;
}

}
