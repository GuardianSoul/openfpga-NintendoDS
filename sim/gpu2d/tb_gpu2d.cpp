// 2D engine testbench (docs/2d-engine.md): renders line runs (synthetic
// scenes and census dumps) through the RTL and through melonDS's 2D soft
// renderer and diffs every pixel and every capture write.
//   Vgpu2d [--scenes] [--dump FILE]... [--only SUBSTR] [--lat N] [--dcyc N] [--maxq N] [--jitter N] [--skip N] [--max-lines N]
// The external VRAM follows nds_vram's block contract (docs/phase2-integration.md):
// up to --maxq blocks in flight (default 2), answered in order; a block's data
// starts --lat clocks after it is accepted (default 13) or when the previous
// block's data ends, and takes --dcyc clocks (default 16: a 16-bit SDRAM
// word per clock), as four 64-bit beats. 13 + 16 = 29 clocks matches the
// 29.5 measured on the Pocket path. --maxq 1 --dcyc 4 is the earlier model.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
#include <map>
#include <string>
#include <vector>
#include "Vgpu2d.h"
#include "verilated.h"
#include "state2d.h"
#include "golden2d.h"

using namespace g2d;

namespace g2d { std::vector<Segment> builtin_scenes(); }

static const u32 ENG_LINE = 2130;      // clocks per engine-line at 67.03 MHz

struct Rtl
{
    Vgpu2d* m;
    u64 cyc = 0;
    Mem* vm = nullptr;                  // the RTL's own memory image
    const LineState* cur = nullptr;
    int lat = 13, dcyc = 16, maxq = 2;
    // --jitter N: each block waits a further 0..N clocks, and 1 in 16 blocks
    // 30..45 more (refresh, other clients: bursts of 40-60 clocks per block)
    int jitter = 0;
    u32 jrng = 12345;
    u32 jnext() { jrng ^= jrng << 13; jrng ^= jrng >> 17; jrng ^= jrng << 5; return jrng; }
    // VRAM block model: accepted blocks with their beat times
    struct VReq { u32 blk; u64 beat[4]; int next = 0; };
    std::deque<VReq> vq;
    u64 vend = 0;                       // end of the last scheduled block's data
    int vstate = 0;                     // for the timeout message: blocks in flight
    u64 fills = 0;
    // loaded copies
    std::vector<u8> pal, oam;
    u32 stw[2][22];
    u32 glob[2];
    bool loaded = false;
    // outputs of the current line
    u32 px[2][256];
    bool got[2][256];
    std::vector<CapWrite> cap;
    u64 bg_stall = 0, obj_stall = 0;
    // every output pixel and capture write with its clock: equal hashes from two
    // builds mean the same outputs in the same clocks (a retiming's equivalence check)
    u64 ohash = 0;
    void omix(u64 v) { ohash = (ohash ^ v) * 0x100000001B3ull; ohash ^= ohash >> 29; }

    Rtl() : m(new Vgpu2d), pal(2048), oam(2048)
    {
        m->clk = 0; m->rst = 1; m->eval();
        for (int i = 0; i < 4; i++) tick();
        m->rst = 0;
        memset(stw, 0, sizeof(stw));
    }
    ~Rtl() { m->final(); delete m; }

    const u8* vptr(u32 blk)
    {
        u32 sp = blk >> 15, e = (blk >> 14) & 1, off = (blk & 0x3FFF) << 5;
        switch (sp)
        {
        case 0: return e ? &vm->bbg[off & 0x1FFFF] : &vm->abg[off & 0x7FFFF];
        case 1: return e ? &vm->bobj[off & 0x1FFFF] : &vm->aobj[off & 0x3FFFF];
        case 2: return e ? &vm->bbgext[off & 0x7FFF] : &vm->abgext[off & 0x7FFF];
        case 3: return e ? &vm->bobjext[off & 0x1FFF] : &vm->aobjext[off & 0x1FFF];
        default: return &vm->lcdc[(off >> 17) & 3][off & 0x1FFFF];
        }
    }

    void tick()
    {
        m->clk = 0; m->eval();
        // inputs for this cycle
        m->vr_ack = m->vr_req && (int)vq.size() < maxq;
        bool beat = !vq.empty() && vq.front().beat[vq.front().next] == cyc;
        m->vr_rvalid = beat;
        if (beat) { u64 w; memcpy(&w, vptr(vq.front().blk) + vq.front().next * 8, 8); m->vr_rdata = w; }
        m->cap_ready = 1;
        m->eval();
        // sample at the edge
        bool acc = m->vr_req && m->vr_ack;
        u32 blk = m->vr_blk;
        if (m->out_valid)
        {
            px[m->out_eng][m->out_x] = (m->out_rgb & 0x3F) | (((m->out_rgb >> 6) & 0x3F) << 8) | (((m->out_rgb >> 12) & 0x3F) << 16);
            got[m->out_eng][m->out_x] = true;
            omix(cyc << 24 | (u64)m->out_eng << 8 | m->out_x); omix(m->out_rgb);
        }
        if (m->cap_we && m->cap_ready)
        {
            u32 a = m->cap_addr;
            cap.push_back({a, (u16)m->cap_data});
            omix(cyc << 24 | a); omix(m->cap_data);
            memcpy(&vm->lcdc[a >> 16][(a & 0xFFFF) * 2], &m->cap_data, 2);
        }
        bg_stall += m->stat_bg_stall;
        obj_stall += m->stat_obj_stall;
        u32 l3a = m->l3d_raddr, ffa = m->fifo_raddr;
        m->clk = 1; m->eval();
        cyc++;
        m->l3d_rdata = cur ? cur->l3d[l3a] : 0;
        m->fifo_rdata = cur ? cur->fifo[ffa] : 0;
        // VRAM model state
        if (beat && ++vq.front().next == 4) vq.pop_front();
        if (acc)
        {
            VReq r; r.blk = blk;
            u64 extra = 0;
            if (jitter) { extra = jnext() % (jitter + 1); if (jnext() % 16 == 0) extra += 30 + jnext() % 16; }
            u64 st = std::max<u64>(cyc + lat + extra, vend);
            for (int k = 0; k < 4; k++) r.beat[k] = st + (u64)(k + 1) * dcyc / 4;   // dcyc >= 4
            vend = st + dcyc;
            vq.push_back(r);
            fills++;
        }
        vstate = vq.size();
    }

    static void words(const EngState& e, u32* w)
    {
        w[0] = e.dispcnt;
        w[1] = e.bgcnt[0] | (u32)e.bgcnt[1] << 16;
        w[2] = e.bgcnt[2] | (u32)e.bgcnt[3] << 16;
        for (int i = 0; i < 4; i++) w[3 + i] = e.bgxpos[i] | (u32)e.bgypos[i] << 16;
        w[7] = e.xref[0]; w[8] = e.yref[0]; w[9] = e.xref[1]; w[10] = e.yref[1];
        w[11] = (u16)e.rota[0] | (u32)(u16)e.rotc[0] << 16;
        w[12] = (u16)e.rota[1] | (u32)(u16)e.rotc[1] << 16;
        memcpy(&w[13], e.win0, 4); memcpy(&w[14], e.win1, 4); memcpy(&w[15], e.wincnt, 4);
        w[16] = (e.enabled & 1) | (e.forced_blank & 1) << 1 | (e.obj_enable & 1) << 2 | (e.layer_enable & 0x1F) << 3
              | (e.win0_active & 3) << 8 | (e.win1_active & 3) << 10 | (e.bg_mosaic[0] & 15) << 12 | (e.obj_mosaic[0] & 15) << 16;
        w[17] = (e.bg_mosaic_line & 0x1FF) | (e.obj_mosaic_line & 0xFF) << 16;
        w[18] = (e.blendcnt & 0x3FFF) | (u32)(e.eva & 31) << 16 | (u32)(e.evb & 31) << 24;
        w[19] = (e.evy & 31) | (u32)e.master_bright << 16;
        w[20] = w[21] = 0;
    }

    void wstate(int eng, int a, u32 d)
    {
        m->st_we = 1; m->st_eng = eng; m->st_addr = a; m->st_data = d;
        tick();
        m->st_we = 0;
    }

    // Load memory and state for a line (both units idle).
    void load(const LineState& s)
    {
        cur = &s;
        for (int i = 0; i < 512; i++)
        {
            if (loaded && !memcmp(&pal[i * 4], &vm->palette[i * 4], 4)) continue;
            memcpy(&pal[i * 4], &vm->palette[i * 4], 4);
            u32 w; memcpy(&w, &pal[i * 4], 4);
            m->pal_we = 1; m->pal_waddr = i; m->pal_wdata = w; m->pal_be = 0xF; tick(); m->pal_we = 0;
        }
        for (int i = 0; i < 512; i++)
        {
            if (loaded && !memcmp(&oam[i * 4], &vm->oam[i * 4], 4)) continue;
            memcpy(&oam[i * 4], &vm->oam[i * 4], 4);
            u32 w; memcpy(&w, &oam[i * 4], 4);
            m->oam_we = 1; m->oam_waddr = i; m->oam_wdata = w; m->oam_be = 0xF; tick(); m->oam_we = 0;
        }
        for (int e = 0; e < 2; e++)
        {
            u32 w[22]; words(s.e[e], w);
            for (int a = 0; a < 20; a++)
                if (!loaded || w[a] != stw[e][a]) { wstate(e, a, w[a]); stw[e][a] = w[a]; }
        }
        u32 g[2] = {s.capcnt, (u32)(s.lcdc & 15) | (u32)(s.cap_enable & 1) << 4};
        for (int a = 0; a < 2; a++)
            if (!loaded || g[a] != glob[a]) { wstate(0, 20 + a, g[a]); glob[a] = g[a]; }
        loaded = true;
    }

    // Run OBJ jobs (eng 0 then 1) for `objline` and, if bgline >= 0, BG jobs for
    // bgline beside them. Returns the clocks of each unit.
    void run(int bgline, int objline, u32& bgc, u32& objc)
    {
        int bgq = bgline >= 0 ? 0 : 2, objq = objline >= 0 ? 0 : 2;
        bool bgrun = false, objrun = false;
        u64 t0 = cyc, bgend = cyc, objend = cyc;
        memset(got, 0, sizeof(got));
        cap.clear();
        u64 limit = cyc + 200000;
        while ((bgq < 2 || bgrun || objq < 2 || objrun) && cyc < limit)
        {
            m->bg_start = 0; m->obj_start = 0;
            if (!bgrun && bgq < 2)
            {
                m->bg_start = 1; m->bg_eng = bgq; m->bg_line = bgline; m->bg_slot = bgline & 1;
                bgrun = true; bgq++;
            }
            if (!objrun && objq < 2)
            {
                m->obj_start = 1; m->obj_eng = objq; m->obj_line = objline; m->obj_slot = objline & 1;
                objrun = true; objq++;
            }
            tick();
            m->bg_start = 0; m->obj_start = 0;
            if (bgrun && m->bg_done) { bgrun = false; bgend = cyc; }
            if (objrun && m->obj_done) { objrun = false; objend = cyc; }
        }
        if (cyc >= limit)
        {
            fprintf(stderr, "timeout at cycle %llu: bg busy %d (line %d) obj busy %d (line %d) vr_req %d vstate %d stalls bg %d obj %d\n",
                    (unsigned long long)cyc, m->bg_busy, bgline, m->obj_busy, objline, m->vr_req, vstate,
                    m->stat_bg_stall, m->stat_obj_stall);
            exit(3);
        }
        bgc = bgend - t0; objc = objend - t0;
    }
};

struct Stats
{
    u64 lines = 0, px = 0, bad = 0, capw = 0, capbad = 0, refbad = 0, reflines = 0;
    u32 bg_max = 0, obj_max = 0;
    u64 bg_sum = 0, obj_sum = 0;
};

static void apply(Mem& m, const std::vector<Chunk>& ch)
{
    for (auto& c : ch) memcpy((u8*)&m + c.off, c.data.data(), c.data.size());
}

static int g_skip = 0;   // --skip N: the scheduler drops every Nth line's BG jobs (late line)

static bool run_segment(const Segment& seg, int lat, int dcyc, int maxq, int jitter, int maxlines, Stats& tot)
{
    auto gm = std::make_unique<Mem>(*seg.mem0);
    auto rm = std::make_unique<Mem>(*seg.mem0);
    Golden gold;
    gold.set_mem(*gm);
    Rtl rtl;
    rtl.vm = rm.get();
    rtl.lat = lat; rtl.dcyc = dcyc; rtl.maxq = maxq; rtl.jitter = jitter;
    Stats st;
    int firstbad = -1;
    size_t n = std::min<size_t>(seg.steps.size(), maxlines > 0 ? maxlines : seg.steps.size());
    for (size_t i = 0; i < n; i++)
    {
        const Step& sp = seg.steps[i];
        apply(*gm, sp.mem);
        apply(*rm, sp.mem);
        // a VRAM change (anything past palette and OAM) is a VRAM write for
        // the caches (PERSIST)
        for (auto& c : sp.mem)
            if (c.off >= 4096) { rtl.m->vram_wr = 1; rtl.tick(); rtl.m->vram_wr = 0; break; }
        const LineState& s = sp.st;
        bool fresh = i == 0 || seg.steps[i - 1].st.line + 1 != s.line;
        rtl.load(s);
        u32 bgc, objc;
        if (fresh)
        {
            gold.sprites(s, s.line);
            rtl.run(-1, s.line, bgc, objc);
        }
        LineOut go;
        gold.scanline(s, go);
        if (s.line < 191) gold.sprites(s, s.line + 1);
        // nds_disp on a late line: no BG jobs for it, the next line's OBJ jobs still run
        if (g_skip && !fresh && s.line % g_skip == (u32)g_skip - 1)
        {
            rtl.run(-1, s.line < 191 ? (int)s.line + 1 : -1, bgc, objc);
            for (auto& c : go.cap) memcpy(&rm->lcdc[c.addr >> 16][(c.addr & 0xFFFF) * 2], &c.data, 2);
            continue;
        }
        rtl.run(s.line, s.line < 191 ? (int)s.line + 1 : -1, bgc, objc);
        st.lines++;
        if (getenv("G2D_SLOW") && (bgc > (u32)atoi(getenv("G2D_SLOW")) || objc > (u32)atoi(getenv("G2D_SLOW"))))
            fprintf(stderr, "  slow %s line %u: bg %u obj %u; A disp %08x bgcnt %04x %04x %04x %04x; B disp %08x bgcnt %04x %04x %04x %04x\n",
                    seg.name.c_str(), s.line, bgc, objc, s.e[0].dispcnt, s.e[0].bgcnt[0], s.e[0].bgcnt[1], s.e[0].bgcnt[2], s.e[0].bgcnt[3],
                    s.e[1].dispcnt, s.e[1].bgcnt[0], s.e[1].bgcnt[1], s.e[1].bgcnt[2], s.e[1].bgcnt[3]);
        st.bg_max = std::max(st.bg_max, bgc); st.bg_sum += bgc;
        if (s.line < 191) { st.obj_max = std::max(st.obj_max, objc); st.obj_sum += objc; }
        u32 nbad = 0;
        for (int e = 0; e < 2; e++)
            for (int x = 0; x < 256; x++)
            {
                st.px++;
                if (!rtl.got[e][x] || rtl.px[e][x] != go.px[e][x])
                {
                    if (nbad < 3 && st.bad < 6)
                        fprintf(stderr, "  %s line %u eng %c x %d: rtl %06x%s gold %06x\n", seg.name.c_str(), s.line,
                                "AB"[e], x, rtl.px[e][x], rtl.got[e][x] ? "" : "(none)", go.px[e][x]);
                    nbad++;
                }
            }
        st.bad += nbad;
        if (nbad && firstbad < 0)
        {
            firstbad = s.line;
            if (getenv("G2D_VERBOSE"))
                for (int e = 0; e < 2; e++)
                    fprintf(stderr, "  eng %c dispcnt %08x layers %02x bgcnt %04x %04x %04x %04x ref2 %08x,%08x ref3 %08x,%08x"
                            " A/C %d %d %d %d blend %04x mos %d,%d\n", "AB"[e], s.e[e].dispcnt, s.e[e].layer_enable,
                            s.e[e].bgcnt[0], s.e[e].bgcnt[1], s.e[e].bgcnt[2], s.e[e].bgcnt[3], s.e[e].xref[0], s.e[e].yref[0],
                            s.e[e].xref[1], s.e[e].yref[1], s.e[e].rota[0], s.e[e].rotc[0], s.e[e].rota[1], s.e[e].rotc[1],
                            s.e[e].blendcnt, s.e[e].bg_mosaic[0], s.e[e].bg_mosaic[1]);
        }
        st.capw += go.cap.size();
        bool capok = go.cap.size() == rtl.cap.size();
        for (size_t k = 0; capok && k < go.cap.size(); k++)
            capok = go.cap[k].addr == rtl.cap[k].addr && go.cap[k].data == rtl.cap[k].data;
        if (!capok)
        {
            st.capbad++;
            if (st.capbad < 3)
                fprintf(stderr, "  %s line %u: capture differs (gold %zu writes, rtl %zu)\n", seg.name.c_str(), s.line,
                        go.cap.size(), rtl.cap.size());
        }
        if (sp.have_ref)
        {
            st.reflines++;
            for (int e = 0; e < 2; e++)
                for (int x = 0; x < 256; x++) st.refbad += (sp.ref[e][x] & 0x3F3F3F) != go.px[e][x];
        }
    }
    bool ok = st.bad == 0 && st.capbad == 0;
    printf("%-4s %-34s lines %4llu  px %7llu  diff %6llu  capw %6llu capdiff %llu  bg max %4u avg %4llu  obj max %4u avg %4llu  fills %6llu  stall bg %llu obj %llu",
           ok ? "PASS" : "FAIL", seg.name.c_str(), (unsigned long long)st.lines, (unsigned long long)st.px,
           (unsigned long long)st.bad, (unsigned long long)st.capw, (unsigned long long)st.capbad,
           st.bg_max, (unsigned long long)(st.lines ? st.bg_sum / st.lines : 0), st.obj_max,
           (unsigned long long)(st.lines ? st.obj_sum / st.lines : 0), (unsigned long long)rtl.fills,
           (unsigned long long)rtl.bg_stall, (unsigned long long)rtl.obj_stall);
    printf("  out %016llx", (unsigned long long)rtl.ohash);
    if (st.reflines) printf("  vs melonDS run: %llu/%llu px differ", (unsigned long long)st.refbad, (unsigned long long)st.reflines * 512);
    if (firstbad >= 0) printf("  first bad line %d", firstbad);
    printf("\n");
    tot.lines += st.lines; tot.px += st.px; tot.bad += st.bad; tot.capw += st.capw; tot.capbad += st.capbad;
    tot.refbad += st.refbad; tot.reflines += st.reflines;
    tot.bg_max = std::max(tot.bg_max, st.bg_max); tot.obj_max = std::max(tot.obj_max, st.obj_max);
    tot.bg_sum += st.bg_sum; tot.obj_sum += st.obj_sum;
    return ok;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> dumps;
    std::string only;
    bool scenes = false;
    int lat = 13, dcyc = 16, maxq = 2, jitter = 0, maxlines = 0;
    for (int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        if (a == "--scenes") scenes = true;
        else if (a == "--dump" && i + 1 < argc) dumps.push_back(argv[++i]);
        else if (a == "--only" && i + 1 < argc) only = argv[++i];
        else if (a == "--lat" && i + 1 < argc) lat = atoi(argv[++i]);
        else if (a == "--dcyc" && i + 1 < argc) dcyc = atoi(argv[++i]);
        else if (a == "--maxq" && i + 1 < argc) maxq = atoi(argv[++i]);
        else if (a == "--jitter" && i + 1 < argc) jitter = atoi(argv[++i]);
        else if (a == "--skip" && i + 1 < argc) g_skip = atoi(argv[++i]);
        else if (a == "--max-lines" && i + 1 < argc) maxlines = atoi(argv[++i]);
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
    }
    if (!scenes && dumps.empty()) scenes = true;
    std::vector<Segment> segs;
    if (scenes) segs = builtin_scenes();
    for (auto& d : dumps)
        if (!load_dump(d, segs)) { fprintf(stderr, "cannot read %s\n", d.c_str()); return 2; }
    Stats tot;
    int fail = 0, run = 0;
    for (auto& s : segs)
    {
        if (!only.empty() && s.name.find(only) == std::string::npos) continue;
        run++;
        if (!run_segment(s, lat, dcyc, maxq, jitter, maxlines, tot)) fail++;
    }
    printf("%s: %d/%d runs pixel-exact, %llu lines, %llu/%llu px differ, %llu lines with differing capture (%llu writes); "
           "worst line (engines A + B): BG %u, OBJ %u clocks of %u\n",
           fail ? "FAIL" : "PASS", run - fail, run, (unsigned long long)tot.lines, (unsigned long long)tot.bad,
           (unsigned long long)tot.px, (unsigned long long)tot.capbad, (unsigned long long)tot.capw,
           tot.bg_max, tot.obj_max, 2 * ENG_LINE);
    return fail ? 1 : 0;
}
