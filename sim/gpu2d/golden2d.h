// Golden model and scene sequencer around melonDS's 2D renderer (golden2d.cpp).
#pragma once
#include <functional>
#include "state2d.h"

namespace g2d
{
// Renders lines from LineState + Mem with melonDS's SoftRenderer2D. Call
// sprites() for the first line of a run, then per line scanline() followed
// by sprites(state, line + 1), as GPU::StartHBlank does.
class Golden
{
public:
    Golden();
    ~Golden();
    void set_mem(Mem& m);               // used in place; capture writes land in m.lcdc
    void sprites(const LineState& s, u32 line);
    void scanline(const LineState& s, LineOut& out);
    void window_state(u32* w0, u32* w1) const;   // Win0/1Active after the last scanline
private:
    struct Impl;
    Impl* p;
};

// melonDS's GPU2D register file and per-line updates, for building synthetic
// scenes from register writes (GPU2D::Write16/32 offsets, 0x000-0x06F).
class Sequencer
{
public:
    Sequencer();
    ~Sequencer();
    void enable(int eng, bool on);
    void write16(int eng, u32 addr, u16 v);
    void write32(int eng, u32 addr, u32 v);
    void vblank_end();                  // line 262: reload affine references, reset mosaic
    // Line y: StartScanline + PreDraw, snapshot into s (frame fields left
    // alone), let `render` advance Win0/1Active, then PostDraw.
    void line(u32 y, LineState& s, const std::function<void(u32*, u32*)>& render);
private:
    struct Impl;
    Impl* p;
};
}
