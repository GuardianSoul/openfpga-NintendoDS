// Golden model: melonDS's SPU.cpp, built unmodified against sim/sound/melonds_shim.
#include <cstring>
#include "golden_snd.h"
#define private public
#include "SPU.h"
#undef private
#include "NDS.h"

using namespace melonDS;

namespace gsnd
{
struct Golden::Impl
{
    melonDS::NDS nds;
    SPU* spu;
};

Golden::Golden(std::function<uint32_t(uint32_t)> rd, std::function<void(uint32_t, uint32_t)> wr) : p(new Impl)
{
    p->nds.Read32 = rd;
    p->nds.Write32 = wr;
    p->spu = new SPU(p->nds, AudioBitDepth::_16Bit, AudioInterpolation::None, 32768.0);
    p->spu->Reset();
    p->spu->SetPowerCnt(1);
}

Golden::~Golden() { delete p->spu; delete p; }

void Golden::write(int bits, uint32_t addr, uint32_t val)
{
    if (bits == 8) p->spu->Write8(addr, val);
    else if (bits == 16) p->spu->Write16(addr, val);
    else p->spu->Write32(addr, val);
}

uint32_t Golden::read(int bits, uint32_t addr)
{
    if (bits == 8) return p->spu->Read8(addr);
    if (bits == 16) return p->spu->Read16(addr);
    return p->spu->Read32(addr);
}

void Golden::power(uint32_t val) { p->spu->SetPowerCnt(val); }

void Golden::step(int16_t out[2])
{
    p->spu->Mix(512);
    out[0] = p->spu->OutputLastSamples[0];
    out[1] = p->spu->OutputLastSamples[1];
}

void Golden::load(const spu::Snap& sn)
{
    SPU& s = *p->spu;
    s.Cnt = sn.cnt; s.MasterVolume = sn.mastervol; s.Bias = sn.bias; s.Mute = sn.mute;
    for (int i = 0; i < 16; i++)
    {
        SPUChannel& c = s.Channels[i];
        const spu::ChanSnap& o = sn.ch[i];
        c.SetCnt(o.cnt);
        c.Cnt = o.cnt; c.SrcAddr = o.srcaddr; c.TimerReload = o.timerreload;
        c.LoopPos = o.looppos; c.Length = o.length; c.KeyOn = o.keyon; c.Timer = o.timer;
        c.Pos = o.pos; c.CurSample = o.cursample; c.NoiseVal = o.noise;
        c.ADPCMVal = o.adpcmval; c.ADPCMIndex = o.adpcmindex;
        c.ADPCMValLoop = o.adpcmvalloop; c.ADPCMIndexLoop = o.adpcmindexloop;
        c.ADPCMCurByte = o.adpcmcurbyte;
        memcpy(c.FIFO, o.fifo, sizeof o.fifo);
        c.FIFOReadPos = o.rp; c.FIFOWritePos = o.wp; c.FIFOReadOffset = o.roff; c.FIFOLevel = o.level;
    }
    for (int i = 0; i < 2; i++)
    {
        SPUCaptureUnit& c = s.Capture[i];
        const spu::CapSnap& o = sn.cap[i];
        c.Cnt = o.cnt; c.DstAddr = o.dstaddr; c.TimerReload = o.timerreload; c.Length = o.length;
        c.Timer = o.timer; c.Pos = o.pos;
        memcpy(c.FIFO, o.fifo, sizeof o.fifo);
        c.FIFOReadPos = o.rp; c.FIFOWritePos = o.wp; c.FIFOWriteOffset = o.woff; c.FIFOLevel = o.level;
    }
}

void Golden::save(spu::Snap& sn)
{
    SPU& s = *p->spu;
    sn.cnt = s.Cnt; sn.mastervol = s.MasterVolume; sn.bias = s.Bias; sn.mute = s.Mute;
    for (int i = 0; i < 16; i++)
    {
        const SPUChannel& c = s.Channels[i];
        spu::ChanSnap& o = sn.ch[i];
        o.cnt = c.Cnt; o.srcaddr = c.SrcAddr; o.timerreload = c.TimerReload;
        o.looppos = c.LoopPos; o.length = c.Length; o.keyon = c.KeyOn; o.timer = c.Timer;
        o.pos = c.Pos; o.cursample = c.CurSample; o.noise = c.NoiseVal;
        o.adpcmval = c.ADPCMVal; o.adpcmindex = c.ADPCMIndex;
        o.adpcmvalloop = c.ADPCMValLoop; o.adpcmindexloop = c.ADPCMIndexLoop;
        o.adpcmcurbyte = c.ADPCMCurByte;
        memcpy(o.fifo, c.FIFO, sizeof o.fifo);
        o.rp = c.FIFOReadPos; o.wp = c.FIFOWritePos; o.roff = c.FIFOReadOffset; o.level = c.FIFOLevel;
    }
}
}
