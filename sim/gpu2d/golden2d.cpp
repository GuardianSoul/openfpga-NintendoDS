// Golden model: melonDS's 2D soft renderer, compiled unmodified from
// references/melonDS/src/GPU2D{,_Soft}.{h,cpp} against the shims in
// melonds_shim/. The screen-level steps that live in GPU_Soft.cpp
// (DrawScanlineA/B, DoCapture, ApplyMasterBrightness) are copied below with
// their state routed to this harness; GPU_Soft.cpp itself needs the whole
// renderer.
#include <memory>
#include <cstring>
#include "GPU2D_Soft.h"
#include "GPU_Soft.h"
#include "GPU_ColorOp.h"
#include "golden2d.h"

namespace g2d
{
using namespace melonDS;

struct Golden::Impl
{
    melonDS::GPU gpu;
    GPU2D a {0, gpu}, b {1, gpu};
    SoftRenderer parent;
    SoftRenderer2D ra {a, parent}, rb {b, parent};
    Mem* mem = nullptr;                 // banks A-D for VRAM display and capture
    u32 l3d[256];
};

Golden::Golden() : p(new Impl) { p->a.Reset(); p->b.Reset(); p->ra.Reset(); p->rb.Reset(); }
Golden::~Golden() { delete p; }

void Golden::set_mem(Mem& m)
{
    GPU& g = p->gpu;
    g.Palette = m.palette; g.OAM = m.oam;
    g.VRAMFlat_ABG = m.abg; g.VRAMFlat_BBG = m.bbg; g.VRAMFlat_AOBJ = m.aobj; g.VRAMFlat_BOBJ = m.bobj;
    g.VRAMFlat_ABGExtPal = m.abgext; g.VRAMFlat_BBGExtPal = m.bbgext;
    g.VRAMFlat_AOBJExtPal = m.aobjext; g.VRAMFlat_BOBJExtPal = m.bobjext;
    p->mem = &m;
}

static void load(GPU2D& g, const EngState& e)
{
    g.Enabled = e.enabled;
    g.ForcedBlank = e.forced_blank;
    g.LayerEnable = e.layer_enable;
    g.OBJEnable = e.obj_enable;
    g.DispCnt = e.dispcnt;
    for (int i = 0; i < 4; i++) { g.BGCnt[i] = e.bgcnt[i]; g.BGXPos[i] = e.bgxpos[i]; g.BGYPos[i] = e.bgypos[i]; }
    for (int i = 0; i < 2; i++)
    {
        g.BGXRefInternal[i] = e.xref[i]; g.BGYRefInternal[i] = e.yref[i];
        g.BGRotA[i] = e.rota[i]; g.BGRotC[i] = e.rotc[i];
    }
    memcpy(g.Win0Coords, e.win0, 4); memcpy(g.Win1Coords, e.win1, 4); memcpy(g.WinCnt, e.wincnt, 4);
    g.Win0Active = e.win0_active; g.Win1Active = e.win1_active;
    memcpy(g.BGMosaicSize, e.bg_mosaic, 2); memcpy(g.OBJMosaicSize, e.obj_mosaic, 2);
    g.BGMosaicLine = e.bg_mosaic_line; g.OBJMosaicLine = e.obj_mosaic_line;
    g.BlendCnt = e.blendcnt; g.EVA = e.eva; g.EVB = e.evb; g.EVY = e.evy;
}

void Golden::sprites(const LineState& s, u32 line)
{
    load(p->a, s.e[0]); load(p->b, s.e[1]);
    p->gpu.VCount = s.line;
    p->ra.DrawSprites(line);
    p->rb.DrawSprites(line);
}

// ---- copied from references/melonDS/src/GPU_Soft.cpp (SoftRenderer), with
// GPU.GPU2D_A/B -> the line state, GPU.VRAM[bank] -> Mem::lcdc and
// GPU.VRAMMap_LCDC -> LineState::lcdc.
static void ApplyMasterBrightness(u16 regval, u32* dst)
{
    u16 mode = regval >> 14;
    if (mode == 1)
    {
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;
        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessUp(dst[i], factor, 0x0);
    }
    else if (mode == 2)
    {
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;
        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessDown(dst[i], factor, 0xF);
    }
}

void Golden::scanline(const LineState& s, LineOut& out)
{
    Impl& q = *p;
    load(q.a, s.e[0]); load(q.b, s.e[1]);
    q.gpu.VCount = s.line;
    memcpy(q.l3d, s.l3d, sizeof(q.l3d));
    q.parent.Output3D = q.l3d;
    u32 line = s.line;

    q.ra.DrawScanline(line);
    q.rb.DrawScanline(line);

    // DrawScanlineA
    u32* dst = out.px[0];
    u32 dispcnt = s.e[0].dispcnt;
    bool doMB = true;
    switch ((dispcnt >> 16) & 0x3)
    {
    case 0:
        for (int i = 0; i < 256; i++) dst[i] = 0x3F3F3F;
        doMB = false;
        break;
    case 1:
        for (int i = 0; i < 256; i++) dst[i] = q.parent.Output2D[0][i];
        break;
    case 2:
        {
            u32 vrambank = (dispcnt >> 18) & 0x3;
            if (s.lcdc & (1 << vrambank))
            {
                u16* vram = (u16*)q.mem->lcdc[vrambank];
                vram = &vram[line * 256];
                for (int i = 0; i < 256; i++)
                {
                    u16 color = vram[i];
                    u8 r = (color & 0x001F) << 1;
                    u8 g = (color & 0x03E0) >> 4;
                    u8 b = (color & 0x7C00) >> 9;
                    dst[i] = r | (g << 8) | (b << 16);
                }
            }
            else
                for (int i = 0; i < 256; i++) dst[i] = 0;
        }
        break;
    case 3:
        for (int i = 0; i < 256; i++)
        {
            u16 color = s.fifo[i];
            u8 r = (color & 0x001F) << 1;
            u8 g = (color & 0x03E0) >> 4;
            u8 b = (color & 0x7C00) >> 9;
            dst[i] = r | (g << 8) | (b << 16);
        }
        break;
    }
    if (doMB) ApplyMasterBrightness(s.e[0].master_bright, dst);

    // DrawScanlineB
    dst = out.px[1];
    if ((s.e[1].dispcnt >> 16) & 0x1)
    {
        for (int i = 0; i < 256; i++) dst[i] = q.parent.Output2D[1][i];
        ApplyMasterBrightness(s.e[1].master_bright, dst);
    }
    else
        for (int i = 0; i < 256; i++) dst[i] = 0xFF3F3F3F;

    for (int e = 0; e < 2; e++)
        for (int i = 0; i < 256; i++) out.px[e][i] &= 0x3F3F3F;

    // DoCapture
    out.cap.clear();
    if (!s.cap_enable) return;
    u32 captureCnt = s.capcnt;
    u32 width, height;
    u32 sz = (captureCnt >> 20) & 0x3;
    if (sz == 0) { width = 128; height = 128; }
    else { width = 256; height = 64 * sz; }
    if (line >= height) return;
    u32 dstvram = (captureCnt >> 16) & 0x3;
    if (!(s.lcdc & (1 << dstvram))) return;
    u16* cdst = (u16*)q.mem->lcdc[dstvram];
    u32 dstaddr = (((captureCnt >> 18) & 0x3) << 14) + (line * width);
    cdst += (dstaddr & 0xFFFF);

    u32* srcA;
    if (captureCnt & (1 << 24)) srcA = q.l3d;
    else srcA = q.parent.Output2D[0];

    u16* srcB = nullptr;
    if (captureCnt & (1 << 25))
        srcB = (u16*)s.fifo;
    else
    {
        u32 srcvram = (dispcnt >> 18) & 0x3;
        if (s.lcdc & (1 << srcvram))
        {
            srcB = (u16*)q.mem->lcdc[srcvram];
            u32 offset = line * 256;
            if (((dispcnt >> 16) & 0x3) != 2)
                offset += (((captureCnt >> 26) & 0x3) << 14);
            srcB += (offset & 0xFFFF);
        }
    }

    std::vector<u16> res(width);
    switch ((captureCnt >> 29) & 0x3)
    {
    case 0:
        for (u32 i = 0; i < width; i++)
        {
            u32 val = srcA[i];
            u32 r = (val >> 1) & 0x1F, g = (val >> 9) & 0x1F, b = (val >> 17) & 0x1F;
            u32 a = ((val >> 24) != 0) ? 0x8000 : 0;
            res[i] = r | (g << 5) | (b << 10) | a;
        }
        break;
    case 1:
        for (u32 i = 0; i < width; i++) res[i] = srcB ? srcB[i] : 0;
        break;
    case 2:
    case 3:
        {
            u32 eva = captureCnt & 0x1F;
            u32 evb = (captureCnt >> 8) & 0x1F;
            if (eva > 16) eva = 16;
            if (evb > 16) evb = 16;
            for (u32 i = 0; i < width; i++)
            {
                u32 val = srcA[i];
                u32 rA = (val >> 1) & 0x1F, gA = (val >> 9) & 0x1F, bA = (val >> 17) & 0x1F;
                u32 aA = ((val >> 24) != 0) ? 1 : 0;
                u32 rD, gD, bD, aD;
                if (srcB)
                {
                    val = srcB[i];
                    u32 rB = val & 0x1F, gB = (val >> 5) & 0x1F, bB = (val >> 10) & 0x1F, aB = val >> 15;
                    rD = ((rA * aA * eva) + (rB * aB * evb) + 8) >> 4;
                    gD = ((gA * aA * eva) + (gB * aB * evb) + 8) >> 4;
                    bD = ((bA * aA * eva) + (bB * aB * evb) + 8) >> 4;
                    aD = (eva > 0 ? aA : 0) | (evb > 0 ? aB : 0);
                    if (rD > 0x1F) rD = 0x1F;
                    if (gD > 0x1F) gD = 0x1F;
                    if (bD > 0x1F) bD = 0x1F;
                }
                else
                {
                    rD = ((rA * aA * eva) + 8) >> 4;
                    gD = ((gA * aA * eva) + 8) >> 4;
                    bD = ((bA * aA * eva) + 8) >> 4;
                    aD = (eva > 0 ? aA : 0);
                }
                res[i] = rD | (gD << 5) | (bD << 10) | (aD << 15);
            }
        }
        break;
    }
    // writes land after the reads, as in melonDS (per pixel, same order)
    for (u32 i = 0; i < width; i++)
    {
        cdst[i] = res[i];
        out.cap.push_back({(dstvram << 16) | ((dstaddr & 0xFFFF) + i), res[i]});
    }
}

// ---- scene sequencing: melonDS's per-line register updates
// (GPU::StartScanline / StartHBlank) on a live GPU2D pair.
struct Sequencer::Impl
{
    melonDS::GPU gpu;
    GPU2D a {0, gpu}, b {1, gpu};
};
Sequencer::Sequencer() : p(new Impl) { p->a.Reset(); p->b.Reset(); p->a.SetEnabled(true); p->b.SetEnabled(true); }
Sequencer::~Sequencer() { delete p; }
void Sequencer::write16(int eng, u32 addr, u16 v) { (eng ? p->b : p->a).Write16(addr, v); }
void Sequencer::write32(int eng, u32 addr, u32 v) { (eng ? p->b : p->a).Write32(addr, v); }
void Sequencer::enable(int eng, bool on) { (eng ? p->b : p->a).SetEnabled(on); }

static void save(const GPU2D& g, EngState& e)
{
    e.enabled = g.Enabled; e.forced_blank = g.ForcedBlank; e.layer_enable = g.LayerEnable; e.obj_enable = g.OBJEnable;
    e.dispcnt = g.DispCnt;
    for (int i = 0; i < 4; i++) { e.bgcnt[i] = g.BGCnt[i]; e.bgxpos[i] = g.BGXPos[i]; e.bgypos[i] = g.BGYPos[i]; }
    for (int i = 0; i < 2; i++)
    {
        e.xref[i] = g.BGXRefInternal[i]; e.yref[i] = g.BGYRefInternal[i];
        e.rota[i] = g.BGRotA[i]; e.rotc[i] = g.BGRotC[i];
    }
    memcpy(e.win0, g.Win0Coords, 4); memcpy(e.win1, g.Win1Coords, 4); memcpy(e.wincnt, g.WinCnt, 4);
    e.win0_active = g.Win0Active; e.win1_active = g.Win1Active;
    memcpy(e.bg_mosaic, g.BGMosaicSize, 2); memcpy(e.obj_mosaic, g.OBJMosaicSize, 2);
    e.bg_mosaic_line = g.BGMosaicLine; e.obj_mosaic_line = g.OBJMosaicLine;
    e.blendcnt = g.BlendCnt; e.eva = g.EVA; e.evb = g.EVB; e.evy = g.EVY;
}

void Sequencer::vblank_end()
{
    // VCount 262: StartScanline's UpdateWindows, StartHBlank with resetregs
    p->gpu.VCount = 262;
    p->a.UpdateWindows(262); p->b.UpdateWindows(262);
    p->a.UpdateRegistersPreDraw(true); p->b.UpdateRegistersPreDraw(true);
    p->a.UpdateRegistersPostDraw(true); p->b.UpdateRegistersPostDraw(true);
}

void Sequencer::line(u32 y, LineState& s, const std::function<void(u32*, u32*)>& render)
{
    p->gpu.VCount = y;
    p->a.UpdateWindows(y); p->b.UpdateWindows(y);
    p->a.UpdateRegistersPreDraw(false); p->b.UpdateRegistersPreDraw(false);
    s.line = y;
    save(p->a, s.e[0]); save(p->b, s.e[1]);
    // the window's horizontal state is advanced by rendering (CalculateWindowMask)
    if (render)
    {
        u32 w0[2] = {p->a.Win0Active, p->b.Win0Active}, w1[2] = {p->a.Win1Active, p->b.Win1Active};
        render(w0, w1);
        p->a.Win0Active = w0[0]; p->b.Win0Active = w0[1];
        p->a.Win1Active = w1[0]; p->b.Win1Active = w1[1];
    }
    p->a.UpdateRegistersPostDraw(false); p->b.UpdateRegistersPostDraw(false);
}

void Golden::window_state(u32* w0, u32* w1) const
{
    w0[0] = p->a.Win0Active; w0[1] = p->b.Win0Active;
    w1[0] = p->a.Win1Active; w1[1] = p->b.Win1Active;
}
}
