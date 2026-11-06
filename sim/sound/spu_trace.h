// SPU trace format: written by the census (--spu-trace, tools/melonds-census),
// replayed by the sound testbench (sim/sound/tb_sound.cpp, docs/sound.md).
// File: "NDSSPU01", one Snap record, then Rec records in emulation order.
// Each mixer step is M, the F and C records it caused, then O.
#pragma once
#include <cstdint>

namespace spu
{
enum : uint8_t
{
    RecSnap = 'S',   // followed by sizeof(Snap) bytes: the SPU at trace start
    RecWrite = 'W',  // register write: size (bits), a = address, b = value
    RecPower = 'P',  // POWCNT2: b = value
    RecMix = 'M',    // a mixer step starts
    RecFetch = 'F',  // sample fetch: a = address, b = word read
    RecCap = 'C',    // capture write: a = address, b = word written
    RecOut = 'O',    // step output: a = left, b = right (s16)
};

struct Rec
{
    uint8_t type, size;
    uint16_t pad;
    uint32_t a, b;
};

// melonDS SPUChannel / SPUCaptureUnit fields (SPU.h), unconverted.
struct ChanSnap
{
    uint32_t cnt, srcaddr, timerreload, looppos, length, keyon, timer;
    int32_t pos, cursample, noise;
    int32_t adpcmval, adpcmindex, adpcmvalloop, adpcmindexloop, adpcmcurbyte;
    uint32_t fifo[8], rp, wp, roff, level;
};

struct CapSnap
{
    uint32_t cnt, dstaddr, timerreload, length, timer;
    int32_t pos;
    uint32_t fifo[4], rp, wp, woff, level;
};

struct Snap
{
    uint32_t cnt, mastervol, bias, mute;
    ChanSnap ch[16];
    CapSnap cap[2];
};
}
